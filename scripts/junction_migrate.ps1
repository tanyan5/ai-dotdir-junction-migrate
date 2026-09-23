<#
.SYNOPSIS
    Move any directory off the C: drive to another fixed disk using an NTFS
    junction, freeing C: space. Works for AI tool data dirs such as
    .qoder, .trae, .tabnine, .WebStorm, Cursor's globalStorage, etc.

.DESCRIPTION
    End-to-end, idempotent, long-path-safe. Steps:
      1. Require the owning application to be fully quit (you are responsible).
      2. If source is already a junction -> report and exit (idempotent).
      3. Check target drive has enough free space.
      4. Copy source -> target with robocopy (handles >260-char paths and
         read-only files). If the copy already exists and matches, skip.
      5. Verify target exactly matches source (file count + total bytes).
      6. Wipe the source leftover via robocopy /MIR (long-path safe).
      7. Remove the now-empty source directory.
      8. Create the NTFS junction: original path -> new location.
      9. Verify files are readable through the original path.

    Any failure aborts WITHOUT deleting the source, so it is safe to re-run.

.PARAMETER SourceDir
    The directory to move. Must be a real directory (not a junction).
    Example: "C:\Users\<you>\.qoder-cn"

.PARAMETER TargetDir
    Destination on a FIXED (non-removable) disk.
    Example: "D:\AIData\qoder-cn"

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File junction_migrate.ps1 -SourceDir "C:\Users\hello\.qoder-cn" -TargetDir "D:\AIData\qoder-cn"

.ROLLBACK
    Never delete the junction with "rmdir /s" or "Remove-Item -Recurse" (that
    would erase the real data on the target disk). To undo, use the dedicated
    script (it removes only the link, then copies the data back to C:):
      powershell -ExecutionPolicy Bypass -File junction_rollback.ps1 -SourceDir "<original source path>"
    Add -DeleteTarget to also remove the D: backup copy after a successful restore.
#>

param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$TargetDir
)

$ErrorActionPreference = 'Stop'

function Fail($m) {
    Write-Host "ERROR: $m" -ForegroundColor Red
    exit 1
}

# 0. Basic sanity checks
$src = [System.IO.Path]::GetFullPath($SourceDir)
$dst = [System.IO.Path]::GetFullPath($TargetDir)
if ($src -eq $dst) { Fail 'Source and target are the same path.' }
if ($src.TrimEnd('\') -in @('C:\','C:',"$env:USERPROFILE")) { Fail 'Refusing to migrate a root/home directory. Pick a specific subdirectory.' }

# 1. Source exists and is NOT already a junction?
if (-not (Test-Path $src)) {
    Write-Host "Source not found: $src. Nothing to migrate." -ForegroundColor Yellow
    exit 0
}
$srcItem = Get-Item $src -ErrorAction SilentlyContinue
if ($srcItem -and ($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    $tgt = ''
    try { $tgt = (Get-Item $src).Target } catch { }
    Write-Host "ALREADY MIGRATED: $src is a junction -> $tgt" -ForegroundColor Green
    $c = (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host "Files readable through junction: $c" -ForegroundColor Green
    exit 0
}

# 2. Measure source; check target drive free space
# Transient lock files (e.g. JetBrains' .port) are held open with exclusive
# access by IDE runtimes and cannot be copied. They are recreated by the app
# on startup, so we EXCLUDE them from the copy and from verification.
$script:xfNames = @('.port', '.lock', '.pid', '*.lock', '*.pid')
function Get-MigratableFiles([string]$dir) {
    Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $n = $_.Name.ToLower()
        -not ($n -in $script:xfNames -or $n -like '*.lock' -or $n -like '*.pid')
    }
}
$srcFiles = Get-MigratableFiles $src
$srcCount = $srcFiles.Count
$srcSize  = ($srcFiles | Measure-Object Length -Sum).Sum
$qual = Split-Path $dst -Qualifier
$drive = New-Object System.IO.DriveInfo $qual
if (-not $drive.IsReady) { Fail "Target drive $qual is not ready." }
$free = $drive.AvailableFreeSpace
# NOTE: $srcSize is a LOWER BOUND - PS 5.1 Get-ChildItem silently drops files
# on long paths (>260 chars) and access-denied subtrees, so the real size can
# be larger. robocopy (the copier) is long-path safe and sees everything.
if ($free -lt $srcSize) {
    Fail ("Target drive {0} has only {1:N2} GB free but ~{2:N2} GB is needed." -f $qual, ($free/1GB), ($srcSize/1GB))
}
Write-Host ("Source: ~{0:N2} GB / ~{1} files (PS estimate; long paths may hide more) | Target {2} free: {3:N2} GB" -f ($srcSize/1GB), $srcCount, $qual, ($free/1GB)) -ForegroundColor Cyan

# Single source of truth for "is dst in sync with src": robocopy in list-only
# mode (/L). Same engine as the copy -> same view of long paths and locked
# files. Count/byte comparisons via Get-ChildItem are unreliable in PS 5.1
# because the source enumeration silently undercounts, which produced bogus
# "verification mismatch" errors while the copy itself was actually complete.
# robocopy /L exit bits: 0x01 = files would be copied, 0x02 = extra files in
# dst (tolerated: e.g. lock files copied by an older run), 0x08 = failures.
function Test-CopyInSync([string]$s, [string]$d) {
    & robocopy "$s" "$d" /E /L /NFL /NDL /NJH /NJS /NP /R:0 /W:0 /XF $script:xfNames | Out-Null
    $bit = $LASTEXITCODE
    if ($bit -ge 8) { Fail "robocopy list-only check failed (exit code $bit)." }
    return (($bit -band 0x01) -eq 0)
}

# 3. Copy (skip if destination is already in sync)
$copyNeeded = $true
if (Test-Path $dst) {
    if (Test-CopyInSync $src $dst) {
        Write-Host "Target already in sync; skipping copy (resume mode)." -ForegroundColor Cyan
        $copyNeeded = $false
    }
}
if ($copyNeeded) {
    New-Item -ItemType Directory -Force $dst | Out-Null
    Write-Host "Copying $src -> $dst (robocopy, long-path safe)..." -ForegroundColor Cyan
    # Retry once: some locks (AV scans, lingering handles) clear after a pause.
    $rc = 16
    for ($attempt = 1; $attempt -le 2 -and $rc -ge 8; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "Copy failed, retrying in 3s (robocopy resumes where it left off)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }
        & robocopy "$src" "$dst" /E /COPY:DAT /DCOPY:T /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XF $script:xfNames | Out-Null
        $rc = $LASTEXITCODE
    }
    if ($rc -ge 8) { Fail "robocopy copy failed (exit code $rc, after retry). Source untouched." }
}

# 4. Verify target is in sync with source before touching the source
Write-Host "Verifying copy (robocopy list-only, long-path safe)..." -ForegroundColor Cyan
if (-not (Test-CopyInSync $src $dst)) {
    Fail 'Copy verification failed: files still differ. Nothing deleted. Re-run to retry the copy.'
}
Write-Host "Verify OK." -ForegroundColor Green

# 5. Wipe source leftover (robocopy /MIR from an empty dir; long-path safe)
$empty = Join-Path $env:TEMP ('empty_del_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $empty | Out-Null
Write-Host "Wiping source leftover (robocopy /MIR)..." -ForegroundColor Cyan
robocopy "$empty" "$src" /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XF $script:xfNames | Out-Null
if ($LASTEXITCODE -ge 8) { Fail 'robocopy /MIR wipe failed. Nothing else changed.' }
Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue

# 6. Remove the now-empty source directory
if (Test-Path $src) { Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $src) {
    Fail ("Source dir still present: $src. Delete it manually, then: New-Item -ItemType Junction -Path `"$src`" -Value `"$dst`"")
}

# 7. Create the junction
New-Item -ItemType Junction -Path $src -Value $dst | Out-Null
$ji = Get-Item $src
Write-Host ("Junction created: {0} -> {1}" -f $src, $dst) -ForegroundColor Green
Write-Host ("Attributes: {0}" -f $ji.Attributes)

# 8. Final readability check through the original path (the junction).
# Sample-based: count comparisons are unreliable for long-path trees (see note
# at step 2), so we prove the tree is reachable instead of comparing counts.
$probe = Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($probe) {
    Write-Host ("Readable through original path: OK (sample: {0})" -f $probe.FullName) -ForegroundColor Green
} else {
    Write-Host "WARNING: could not enumerate any file through the junction. Investigate before using." -ForegroundColor Yellow
}

Write-Host "DONE. Start the application and confirm everything works." -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT - do NOT delete this junction with 'rmdir /s' or 'Remove-Item -Recurse'" -ForegroundColor Yellow
Write-Host "  (that would delete the real data on the target disk). To roll back safely," -ForegroundColor Yellow
Write-Host "  use the bundled script:" -ForegroundColor Yellow
Write-Host ("    powershell -ExecutionPolicy Bypass -File `"$PSScriptRoot\junction_rollback.ps1`" -SourceDir `"$src`"") -ForegroundColor Yellow
Write-Host "  (it removes only the link, copies the data back, then verifies)" -ForegroundColor Yellow

exit 0
