<#
.SYNOPSIS
    Move any directory off the C: drive to another fixed disk using an NTFS
    junction, freeing C: space. Works for AI tool data dirs such as
    .qoder, .trae, .tabnine, .WebStorm, Cursor's globalStorage, etc.

.DESCRIPTION
    End-to-end, idempotent, long-path-safe. Steps:
      1. Pre-flight guard: refuse to run while the owning application is still
         running (locked files / live SQLite WAL) -> prevents TORN database
         copies. Skippable with -AllowRunningApp.
      2. If source is already a junction -> report and exit (idempotent).
      3. Check target drive has enough free space.
      4. Copy source -> target with robocopy (handles >260-char paths and
         read-only files). If the copy already exists and matches, skip.
      5. Verify target exactly matches source (robocopy list-only).
      6. Re-run the guard, then wipe the source leftover via robocopy /MIR.
      7. Remove the now-empty source directory.
      8. Create the NTFS junction: original path -> new location.
      9. Verify files are readable through the original path.

    Any failure aborts WITHOUT deleting the source, so it is safe to re-run.
    Re-running resumes: the copy step is skipped/refreshed, then the wipe and
    the junction are retried.

.WHY THE RUNNING-APP GUARD EXISTS
    A copy is only valid if nothing is writing during it. For SQLite apps
    (workbuddy.db, state.vscdb, *.sqlite) the database plus its -wal/-shm side
    files must be captured atomically; while the app runs, the copy is a torn
    snapshot that still passes "size + timestamp in sync" verification, and the
    app then starts on the copy and rewrites an EMPTY index (list gone) even
    though the underlying content files are still on disk.
    Observed in the wild: migrating C:\Users\<u>\.workbuddy while WorkBuddy was
    running -> sessions index emptied; robocopy /MIR could not wipe the locked
    source either.

.PARAMETER SourceDir
    The directory to move. Must be a real directory (not a junction).
    Example: "C:\Users\<you>\.qoder-cn"

.PARAMETER TargetDir
    Destination on a FIXED (non-removable) disk.
    Example: "D:\AIData\qoder-cn"

.PARAMETER AllowRunningApp
    Escape hatch. Skips the running-app guard. Only for directories you are
    certain are idle (e.g. a plain cache with no database and no open handles).

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
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [switch]$AllowRunningApp
)

$ErrorActionPreference = 'Stop'

function Fail($m) {
    Write-Host "ERROR: $m" -ForegroundColor Red
    throw $m
}

function Write-Warn2($m) { Write-Host "WARNING: $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Running-app guard
# Three independent signals (any one aborts):
#   a) a process that owns / mentions the directory is alive, or whose name
#      matches the app name derived from the folder (".workbuddy" -> workbuddy)
#   b) a FRESH SQLite -wal / -shm / -journal (database not closed cleanly)
#   c) one of the ~400 newest files cannot be opened with FileShare.None
#      (i.e. somebody is holding a handle)
# Run BEFORE the copy and again BEFORE the wipe: the owner may be started
# mid-copy, and only the second check proves the snapshot is not torn.
# ---------------------------------------------------------------------------
function Get-AppTokens([string]$dir) {
    $leaf = (Split-Path $dir -Leaf).TrimStart('.').ToLower()
    $t = New-Object System.Collections.ArrayList
    if ($leaf.Length -ge 4) { [void]$t.Add($leaf) }
    # product name != folder name for a few well-known tools
    if ($leaf -eq 'workbuddy') { [void]$t.Add('codebuddy') }
    return @($t)
}

function Find-OwningProcesses([string]$dir) {
    $found = New-Object System.Collections.ArrayList
    $dl = $dir.TrimEnd('\').ToLower()
    $tokens = Get-AppTokens $dir
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $name = ''
        if ($p.Name) { $name = $p.Name.ToLower() }
        $exe = ''
        if ($p.ExecutablePath) { $exe = $p.ExecutablePath.ToLower() }
        $cmd = ''
        if ($p.CommandLine) { $cmd = $p.CommandLine.ToLower() }
        $hit = $false
        if ($exe -and $exe.StartsWith($dl)) { $hit = $true }
        if (-not $hit -and $cmd -and $cmd.Contains($dl)) { $hit = $true }
        if (-not $hit) {
            foreach ($t in $tokens) {
                if ($name -and $name.Contains($t)) { $hit = $true; break }
            }
        }
        if ($hit) { [void]$found.Add(('{0} (PID {1})' -f $p.Name, $p.ProcessId)) }
    }
    return @($found)
}

function Test-TreeBusy([string]$dir) {
    $r = @{
        Scanned = 0
        Probed  = 0
        Locked  = (New-Object System.Collections.ArrayList)
        Wal     = (New-Object System.Collections.ArrayList)
    }
    $skip = @('.port', '.lock', '.pid')
    $files = @(Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $n = $_.Name.ToLower()
            -not ($n -in $skip -or $n -like '*.lock' -or $n -like '*.pid')
        })
    $r.Scanned = $files.Count
    foreach ($f in $files) {
        $n = $f.Name.ToLower()
        if ($n.EndsWith('-wal') -or $n.EndsWith('-shm') -or $n.EndsWith('-journal')) {
            [void]$r.Wal.Add($f.FullName)
        }
    }
    # Only the newest slice is probed: a fully-open app always has recent files.
    $newest = @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 400)
    $r.Probed = $newest.Count
    foreach ($f in $newest) {
        try {
            $fs = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $fs.Dispose()
        } catch {
            [void]$r.Locked.Add($f.FullName)
        }
    }
    return $r
}

function Assert-OwnerStopped([string]$dir, [string]$phase) {
    if ($AllowRunningApp) {
        Write-Warn2 "AllowRunningApp given - skipping the running-app guard ($phase). A torn database copy is possible."
        return
    }
    $procs = @(Find-OwningProcesses $dir)
    $busy  = Test-TreeBusy $dir
    $cut   = (Get-Date).AddMinutes(-15)
    $freshWal = @()
    foreach ($w in $busy.Wal) {
        $wi = Get-Item $w -ErrorAction SilentlyContinue
        if ($wi -and $wi.LastWriteTime -gt $cut) { $freshWal += $w }
    }
    $problem = $false
    if ($procs.Count -gt 0) {
        $problem = $true
        Write-Host ("Owner process(es) still alive ({0}):" -f $phase) -ForegroundColor Yellow
        foreach ($p in $procs) { Write-Host ("   {0}" -f $p) -ForegroundColor Yellow }
    }
    if ($freshWal.Count -gt 0) {
        $problem = $true
        Write-Host ("Live SQLite WAL/journal ({0}) - the database was NOT closed cleanly:" -f $freshWal.Count) -ForegroundColor Yellow
        foreach ($w in @($freshWal | Select-Object -First 5)) { Write-Host ("   {0}" -f $w) -ForegroundColor Yellow }
    }
    if ($busy.Locked.Count -gt 0) {
        $problem = $true
        Write-Host ("{0} of the {1} newest files are held open (handle lock):" -f $busy.Locked.Count, $busy.Probed) -ForegroundColor Yellow
        foreach ($l in @($busy.Locked | Select-Object -First 5)) { Write-Host ("   {0}" -f $l) -ForegroundColor Yellow }
    }
    if ($problem) {
        Fail @"
Refusing to migrate while the owning application is still running ($phase).
A live database copies as a TORN snapshot: verification still says "in sync",
but the app then starts on the copy and can rewrite an EMPTY index.

What to do:
  1. Quit the application COMPLETELY - window, tray icon, helper/serve processes.
     If you are running this from inside that very application (e.g. migrating
     ~/.workbuddy while WorkBuddy itself is open), you cannot do it from there:
     quit it and run this from another tool or a plain terminal.
  2. Re-run the EXACT same command. It resumes: the copy is refreshed and the
     wipe + junction are retried. Nothing has been deleted so far.

Override only if you are certain nothing is writing: add -AllowRunningApp
"@
    }
    Write-Host ("Guard OK ({0}): no owner process, no live WAL, newest files unlocked." -f $phase) -ForegroundColor Green
}

# 0. Basic sanity checks
$src = [System.IO.Path]::GetFullPath($SourceDir)
$dst = [System.IO.Path]::GetFullPath($TargetDir)
if ($src -eq $dst) { Fail 'Source and target are the same path.' }
if ($src.TrimEnd('\') -in @('C:\','C:',"$env:USERPROFILE")) { Fail 'Refusing to migrate a root/home directory. Pick a specific subdirectory.' }

# 1. Source exists and is NOT already a junction?
if (-not (Test-Path $src)) {
    Write-Host "Source not found: $src. Nothing to migrate." -ForegroundColor Yellow
    return
}
$srcItem = Get-Item $src -ErrorAction SilentlyContinue
if ($srcItem -and ($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    $tgt = ''
    try { $tgt = (Get-Item $src).Target } catch { }
    Write-Host "ALREADY MIGRATED: $src is a junction -> $tgt" -ForegroundColor Green
    $c = (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host "Files readable through junction: $c" -ForegroundColor Green
    return
}

# 1b. Guard: is the owning app still running / still writing?
Assert-OwnerStopped $src 'pre-copy'

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

# 4. Verify target is in sync with source before touching the source.
# This proves "same bytes at this instant", NOT "the writer was idle" - that is
# what the second guard below is for.
Write-Host "Verifying copy (robocopy list-only, long-path safe)..." -ForegroundColor Cyan
if (-not (Test-CopyInSync $src $dst)) {
    Fail 'Copy verification failed: files still differ. Nothing deleted. Re-run to retry the copy.'
}
Write-Host "Verify OK." -ForegroundColor Green

# 4b. Guard again: if the app was started (or is still writing) during the
# copy, the snapshot above is torn -> abort now, while the source is intact.
Assert-OwnerStopped $src 'pre-wipe'

# 5. Wipe source leftover (robocopy /MIR from an empty dir; long-path safe).
# Retried once: a just-closed app can still hold handles for a couple seconds.
$empty = Join-Path $env:TEMP ('empty_del_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $empty | Out-Null
Write-Host "Wiping source leftover (robocopy /MIR)..." -ForegroundColor Cyan
for ($wipe = 1; $wipe -le 2; $wipe++) {
    & robocopy "$empty" "$src" /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XF $script:xfNames | Out-Null
    $wrc = $LASTEXITCODE
    if (-not (Test-Path $src)) { break }
    if (Test-Path $src) { Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $src)) { break }
    if ($wipe -lt 2) {
        Write-Host "Source still present, retrying the wipe in 3s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }
}
Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue

# 6. If the source survived the wipe, diagnose it instead of asking for a
# manual delete (a hand-typed Remove-Item is how data gets destroyed).
if (Test-Path $src) {
    $left = @(Get-ChildItem $src -Recurse -File -Force -ErrorAction SilentlyContinue)
    Write-Host ("Source still present: {0}" -f $src) -ForegroundColor Yellow
    Write-Host ("{0} file(s) could not be removed; newest first:" -f $left.Count) -ForegroundColor Yellow
    foreach ($l in @($left | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
        Write-Host ("   {0}" -f $l.FullName) -ForegroundColor Yellow
    }
    $procs = @(Find-OwningProcesses $src)
    if ($procs.Count -gt 0) {
        Write-Host "Process(es) that can hold these files:" -ForegroundColor Yellow
        foreach ($p in $procs) { Write-Host ("   {0}" -f $p) -ForegroundColor Yellow }
    }
    Fail @"
Wipe incomplete. GOOD NEWS: the copy is complete and verified, and the source
is still intact - nothing has been lost.

The files listed above are held open by a running application. Fully quit that
application (window + tray + helper/serve processes) and RE-RUN the exact same
command: it resumes, skips the copy and finishes the wipe + junction.

Do NOT delete the source directory by hand - one typo in a Remove-Item path
destroys real data. Let the script do it, or roll back with junction_rollback.ps1.
"@
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

return
