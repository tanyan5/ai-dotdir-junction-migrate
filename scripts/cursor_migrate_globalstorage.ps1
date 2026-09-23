<#
.SYNOPSIS
    Move Cursor's bulky globalStorage (chat / agent / composer history) off the
    C: drive to another fixed disk using an NTFS junction, to free C: space.

.DESCRIPTION
    End-to-end, idempotent, long-path-safe. Steps:
      1. Require Cursor fully quit (incl. tray icon).
      2. If source is already a junction -> report and exit (idempotent).
      3. Check target drive has enough free space.
      4. Copy C: -> D: with robocopy (handles >260-char paths and read-only files).
         If the copy already exists and matches, skip (resume support).
      5. Verify D: exactly matches C: (file count + total bytes) before deleting.
      6. Wipe the C: leftover via robocopy /MIR (long-path + read-only safe).
      7. Remove the now-empty C: directory.
      8. Create the NTFS junction so Cursor keeps using the original path.
      9. Verify files are readable through the C: path.

    Any failure aborts WITHOUT deleting the C: source, so it is safe to re-run.

.PARAMETER TargetPath
    Destination on a fixed (non-removable) disk, e.g. "D:\CursorData\globalStorage".
    MUST be on a local fixed drive that is always present. Do NOT use a USB stick.

.EXAMPLE
    # Use default path (D:\CursorData\globalStorage):
    powershell -ExecutionPolicy Bypass -File cursor_migrate_globalstorage.ps1

.EXAMPLE
    # Custom destination:
    powershell -ExecutionPolicy Bypass -File cursor_migrate_globalstorage.ps1 -TargetPath "D:\tool_tem\WorkBuddy\CursorData\globalStorage"

.ROLLBACK
    Never delete the junction with "rmdir /s" or "Remove-Item -Recurse" (that would
    erase the real data on D:). To undo:
      cmd /c rmdir "<C: globalStorage path>"     # removes only the link
      Move-Item "<D: path>\*" "<C: globalStorage path>\"
#>

param(
    [string]$TargetPath = 'D:\CursorData\globalStorage'
)

$ErrorActionPreference = 'Stop'
$src = Join-Path $env:APPDATA 'Cursor\User\globalStorage'
$dst = $TargetPath

function Fail($m) {
    Write-Host "ERROR: $m" -ForegroundColor Red
    exit 1
}

# 0. Prereq: Cursor must be fully closed
if (Get-Process Cursor -ErrorAction SilentlyContinue) {
    Fail 'Cursor is still running. Quit it (including the tray icon) first.'
}

# 1. Source exists?
if (-not (Test-Path $src)) {
    Write-Host "Source not found: $src" -ForegroundColor Yellow
    Write-Host "Nothing to migrate. Aborting." -ForegroundColor Yellow
    exit 0
}

# 2. Already a junction? -> idempotent, just report
$srcItem = Get-Item $src -ErrorAction SilentlyContinue
if ($srcItem -and ($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    $tgt = ''
    try { $tgt = (Get-Item $src).Target } catch { }
    Write-Host "ALREADY MIGRATED: $src is a junction -> $tgt" -ForegroundColor Green
    $c = (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host "Files readable through junction: $c" -ForegroundColor Green
    exit 0
}

# 3. Measure source; check target drive free space
$srcFiles = Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue
$srcCount = $srcFiles.Count
$srcSize  = ($srcFiles | Measure-Object Length -Sum).Sum
$qual = Split-Path $dst -Qualifier
$drive = New-Object System.IO.DriveInfo $qual
if (-not $drive.IsReady) { Fail "Target drive $qual is not ready." }
$free = $drive.AvailableFreeSpace
if ($free -lt $srcSize) {
    Fail ("Target drive {0} has only {1:N2} GB free but {2:N2} GB is needed." -f $qual, ($free/1GB), ($srcSize/1GB))
}
Write-Host ("Source: {0:N2} GB / {1} files | Target {2} free: {3:N2} GB" -f ($srcSize/1GB), $srcCount, $qual, ($free/1GB)) -ForegroundColor Cyan

# 4. Copy (skip if destination already matches exactly)
$copyNeeded = $true
if (Test-Path $dst) {
    $dF = Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue
    $dN = $dF.Count; $dB = ($dF | Measure-Object Length -Sum).Sum
    if ($dN -eq $srcCount -and $dB -eq $srcSize) {
        Write-Host "Target already matches source; skipping copy (resume mode)." -ForegroundColor Cyan
        $copyNeeded = $false
    }
}
if ($copyNeeded) {
    New-Item -ItemType Directory -Force $dst | Out-Null
    Write-Host "Copying $src -> $dst (robocopy, long-path safe)..." -ForegroundColor Cyan
    robocopy "$src" "$dst" /E /COPY:DAT /DCOPY:T /NFL /NDL /NJH /NJS /NP /R:1 /W:1
    if ($LASTEXITCODE -ge 8) { Fail 'robocopy copy failed (exit code >= 8). Source untouched.' }
}

# 5. Verify D: exactly matches C: before touching C:
$dFiles = Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue
$dN = $dFiles.Count; $dB = ($dFiles | Measure-Object Length -Sum).Sum
Write-Host ("Verify: C files=$srcCount bytes=$srcSize | D files=$dN bytes=$dB")
if ($srcCount -ne $dN -or $srcSize -ne $dB) {
    Fail 'Copy verification mismatch. Nothing deleted. Re-run to retry the copy.'
}

# 6. Wipe C: leftover (robocopy /MIR from an empty dir; long-path + read-only safe)
$empty = Join-Path $env:TEMP ('empty_del_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $empty | Out-Null
Write-Host "Wiping C: leftover (robocopy /MIR)..." -ForegroundColor Cyan
robocopy "$empty" "$src" /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1
if ($LASTEXITCODE -ge 8) { Fail 'robocopy /MIR wipe failed. Nothing else changed.' }
Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue

# 7. Remove the now-empty C: directory
if (Test-Path $src) { Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $src) {
    Fail ("C: dir still present: $src. Delete it manually, then: New-Item -ItemType Junction -Path `"$src`" -Value `"$dst`"")
}

# 8. Create the junction
New-Item -ItemType Junction -Path $src -Value $dst | Out-Null
$ji = Get-Item $src
Write-Host ("Junction created: {0} -> {1}" -f $src, $dst) -ForegroundColor Green
Write-Host ("Attributes: {0}" -f $ji.Attributes)

# 9. Final readability check through the C: path
$final = (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host ("Readable through C: path: $final files") -ForegroundColor Green
if ($final -ne $dN) {
    Write-Host "WARNING: file count through junction ($final) != D: side ($dN). Investigate before using." -ForegroundColor Yellow
}

Write-Host "DONE. Start Cursor and confirm your chat history is intact." -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT - do NOT delete this junction with 'rmdir /s' or 'Remove-Item -Recurse'" -ForegroundColor Yellow
Write-Host "  (that would delete the real data on D:). To roll back:" -ForegroundColor Yellow
Write-Host ("    cmd /c rmdir `"$src`"        # removes only the link" ) -ForegroundColor Yellow
Write-Host ("    Move-Item `"$dst\*`" `"$src\`"   # restore onto C:") -ForegroundColor Yellow
