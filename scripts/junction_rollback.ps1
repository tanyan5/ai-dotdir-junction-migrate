<#
.SYNOPSIS
    Roll back a junction_migrate.ps1 migration: turn the C: junction back into a
    real directory containing the original data, then optionally wipe the target
    disk copy. Long-path safe, idempotent, and SAFE BY DESIGN.

.DESCRIPTION
    After junction_migrate.ps1 moved a directory, the original path (e.g.
    C:\Users\hello\.WebStorm) is an NTFS junction pointing at D:\tool_tem\... .
    This script restores the pre-migration state:
      1. Refuse to run unless $SourceDir is an actual junction (ReparsePoint).
         It will NOT touch a real directory - that would be the wrong target.
      2. Read the junction target. If -TargetDir is not given, use the junction's
         own target (single source of truth).
      3. Confirm the target holds a real directory with data.
      4. Remove ONLY the link, in pure PowerShell:
         [IO.Directory]::Delete("<source>", $false)  (non-recursive).
         This removes the reparse point itself and never descends into the
         target, so the data on the other disk is never touched. No cmd.exe
         dependency, so this also works where cmd is unavailable/blocked.
      5. Copy the data from target BACK to the original path with robocopy /E
         (long-path safe). Transient lock files (.port/.lock/.pid) are not on the
         target and are recreated by the app, so nothing is lost.
      6. Verify the original path is a real directory and readable.
      7. If -DeleteTarget: after verification, wipe the target dir and rmdir it.
         If omitted, the D: copy is kept as a free safety backup.

    SAFETY: at no point does this script recurse into the junction - neither
    "rmdir /s" nor "Remove-Item -Recurse" is ever used on it, because either
    would destroy the real data. The restore is two-phase (copy back -> verify
    -> wipe target) so the data is never lost even if something fails mid-way.

.PARAMETER SourceDir
    The original junction path (same value you passed as -SourceDir to the
    migration). Example: "C:\Users\hello\.WebStorm"

.PARAMETER TargetDir
    Optional. The data's current location on the other disk. If omitted, it is
    read from the junction itself. Example: "D:\tool_tem\WebStorm\.WebStorm"

.PARAMETER DeleteTarget
    Optional switch. After a successful restore, also delete the D: copy. If you
    keep the D: copy, re-migrating later is a simple re-run.

    Leftover cleanup: if the source is already a real directory (you previously
    restored, but the D: backup was left behind), pass BOTH -DeleteTarget and
    -TargetDir to delete only the redundant D: copy. You must type the source
    path exactly to confirm; C: is never touched.

.PARAMETER Scan
    Optional switch. Do NOT restore anything - just list every junction on the
    system whose target lives on another disk (i.e. every migration done by these
    scripts). Use this a month later when you have forgotten which dirs were
    migrated: pick the SourceDir from the output and run again.

.EXAMPLE
    # List all current migrations (no mutation)
    powershell -ExecutionPolicy Bypass -File junction_rollback.ps1 -Scan

.EXAMPLE
    # Roll back .WebStorm, keep the D: backup copy
    powershell -ExecutionPolicy Bypass -File junction_rollback.ps1 -SourceDir "C:\Users\hello\.WebStorm"

.EXAMPLE
    # Roll back AND remove the D: copy (use only after confirming the app works)
    powershell -ExecutionPolicy Bypass -File junction_rollback.ps1 -SourceDir "C:\Users\hello\.WebStorm" -DeleteTarget

.EXAMPLE
    # Already restored, but the D: backup lingers. Remove only the D: copy
    # (type the source path when prompted to confirm; C: is left alone).
    powershell -ExecutionPolicy Bypass -File junction_rollback.ps1 -SourceDir "C:\Users\hello\.WebStorm" -TargetDir "D:\tool_tem\WebStorm\.WebStorm" -DeleteTarget
#>

param(
    [string]$SourceDir = '',
    [string]$TargetDir = '',
    [switch]$DeleteTarget,
    [switch]$Scan
)

$ErrorActionPreference = 'Stop'

function Fail($m) {
    Write-Host "ERROR: $m" -ForegroundColor Red
    throw $m
}

# Send a path to the Recycle Bin (silent, recoverable). Falls back to a permanent
# delete with a loud warning if the COM route fails (e.g. a path too long for it).
function Remove-ToRecycleBin($path) {
    $p = (Resolve-Path $path -ErrorAction SilentlyContinue).Path
    if (-not $p) { return $false }
    try {
        $shell = New-Object -ComObject Shell.Application
        $recycle = $shell.NameSpace(10)
        $recycle.MoveHere($p)
        Write-Host "Moved to Recycle Bin: $p (recoverable)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Recycle Bin move failed ($_). Falling back to permanent delete." -ForegroundColor Yellow
        Remove-Item $p -Recurse -Force -ErrorAction Stop
        Write-Host "Permanently deleted: $p" -ForegroundColor Red
        return $true
    }
}

# Find every junction whose target is on a DIFFERENT disk than its source. Those
# are the migrations done by these scripts. Scan depth:
#   - home: 1 level (the ".app" dot dirs)
#   - Roaming/Local: 3 levels (covers e.g. Roaming\Cursor\User\globalStorage)
# PS 5.1 Get-ChildItem -Recurse does NOT descend into junctions, so this cannot
# loop forever or cross onto the target disk.
function Find-Migrations {
    $roots = @(
        @{ Path = $env:USERPROFILE;  Depth = 1 }
        @{ Path = $env:APPDATA;      Depth = 3 }
        @{ Path = $env:LOCALAPPDATA; Depth = 3 }
    )
    $found = @()
    $seen = @{}
    foreach ($r in $roots) {
        if (-not (Test-Path $r.Path)) { continue }
        Write-Host "Scanning $($r.Path) (depth $($r.Depth))..." -ForegroundColor DarkGray
        $dirs = @(Get-ChildItem $r.Path -Force -Directory -Recurse -Depth $r.Depth -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            if ($seen.ContainsKey($d.FullName)) { continue }
            $seen[$d.FullName] = $true
            if (-not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $t = ''
            try { $t = [string](@($d.Target) | Select-Object -First 1) } catch { }
            if (-not $t) { continue }
            $srcQual = Split-Path $d.FullName -Qualifier
            $tgtQual = Split-Path $t -Qualifier
            if ($srcQual -eq $tgtQual) { continue }   # same-disk link, not ours
            $sz = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if (-not $sz) { $sz = 0 }
            $found += [PSCustomObject]@{ Src = $d.FullName; Target = $t; MB = [math]::Round($sz/1MB,1) }
        }
    }
    return $found   # caller wraps with @() to survive single-element unwrap
}

# -Scan mode: list migrations and exit (no mutation).
if ($Scan) {
    $m = @(Find-Migrations)   # @() guards against unwrap on single result
    if ($m.Count -eq 0) {
        Write-Host "No cross-disk junction migrations found under: $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA" -ForegroundColor Yellow
        return
    }
    Write-Host "Junction migrations found:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $m.Count; $i++) {
        Write-Host ("  [{0}] {1}  ({2} MB)" -f ($i+1), $m[$i].Src, $m[$i].MB) -ForegroundColor Cyan
        Write-Host ("       -> {0}" -f $m[$i].Target) -ForegroundColor DarkGray
    }
    Write-Host "To restore one:  junction_rollback.ps1 -SourceDir ""<its Source>""" -ForegroundColor Yellow
    return
}

if (-not $SourceDir) { Fail 'Provide -SourceDir "<junction path>" to restore, or -Scan to list migrations.' }

# 0. Basic sanity
$src = [System.IO.Path]::GetFullPath($SourceDir)

# 1. Must be an actual junction. Never operate on a real directory.
if (-not (Test-Path $src)) {
    Write-Host "Nothing to roll back: path not found: $src" -ForegroundColor Yellow
    return
}
$srcItem = Get-Item $src -ErrorAction SilentlyContinue
if (-not ($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    # The migration is already undone (source is a real dir again) but the D:
    # backup copy may still linger. -DeleteTarget + explicit -TargetDir = safe
    # leftover cleanup: we never touch C:, only remove the redundant D: copy.
    if ($DeleteTarget -and $TargetDir) {
        Write-Host "Source is already a real directory (migration already rolled back): $src" -ForegroundColor Yellow
        Write-Host "You asked to delete the leftover target copy on the other disk:" -ForegroundColor Cyan
        Write-Host "    $TargetDir" -ForegroundColor Cyan
        Write-Host "WARNING: this removes the redundant backup now that the live data is on C:." -ForegroundColor Red
        Write-Host "          It goes to the Recycle Bin first (recoverable)." -ForegroundColor Red
        Write-Host "          Type the source path below EXACTLY to confirm." -ForegroundColor Red
        $confirm = Read-Host "Confirm by typing: $src"
        if ($confirm -ne $src) { Fail 'Confirmation did not match the source path. Aborting - nothing changed.' }
        if (-not (Test-Path $TargetDir)) {
            Write-Host "Target not found: $TargetDir (nothing to delete)." -ForegroundColor Yellow
            return
        }
        Remove-ToRecycleBin $TargetDir
        return
    }
    Write-Host "NOT A JUNCTION: $src is a real directory. Nothing to roll back (or it was already restored)." -ForegroundColor Yellow
    return
}

# 2. Resolve target (junction's own target if not provided)
$jTarget = ''
try { $jTarget = $srcItem.Target } catch { }
if (-not $TargetDir) {
    if (-not $jTarget) { Fail "Could not read the junction target for $src. Pass -TargetDir explicitly." }
    $TargetDir = $jTarget
}
$dst = [System.IO.Path]::GetFullPath($TargetDir)
if ($src -eq $dst) { Fail 'Source and target resolve to the same path.' }

# 3. Confirm target holds a real directory with data
if (-not (Test-Path $dst)) { Fail "Junction target not found: $dst. Cannot restore from a missing source." }
$dstItem = Get-Item $dst
if ($dstItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail "Junction target $dst is itself a junction - refusing to act." }
$dstFiles = Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue
if ($dstFiles.Count -eq 0) { Write-Host "WARNING: target $dst appears empty - restore will produce an empty directory." -ForegroundColor Yellow }
Write-Host ("Junction: $src  ->  $dst   ({0} files on target)" -f $dstFiles.Count) -ForegroundColor Cyan

# 4. Remove ONLY the link, in pure PowerShell (no cmd.exe, no /s, no recursion).
#    [IO.Directory]::Delete(<path>, $false) removes the reparse point itself and
#    never descends into the target, so the real data on the other disk is safe.
Write-Host "Removing junction link only (non-recursive .NET delete; target untouched)..." -ForegroundColor Cyan
try { [System.IO.Directory]::Delete($src, $false) } catch { }
if (Test-Path $src) {
    try { (Get-Item $src -Force).Delete() } catch { }
}
if (Test-Path $src) {
    Fail ("Failed to remove junction: $src still exists. Do NOT use Remove-Item -Recurse or rmdir /s - either would erase the real data on $dst.")
}
# Belt and braces: the data on the other disk must still be there.
if (-not (Test-Path $dst)) { Fail "Junction link removed but target $dst is missing - stopping here. Investigate before doing anything else." }
Write-Host "Junction removed. Original path is now gone (data still safe on target)." -ForegroundColor Green

# 5. Restore data to the original path (two-phase: copy back first)
New-Item -ItemType Directory -Force $src | Out-Null
Write-Host "Restoring data from $dst -> $src (robocopy, long-path safe)..." -ForegroundColor Cyan
& robocopy "$dst" "$src" /E /COPY:DAT /DCOPY:T /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { Fail "Restore copy failed (exit $LASTEXITCODE). The D: data is intact - re-run this script." }

# 6. Verify original path is now a real directory and readable
$newItem = Get-Item $src
if ($newItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail "Restore produced another junction, not a real directory. Investigate." }
$probe = Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($probe) {
    Write-Host ("Restored and readable: OK (sample: {0})" -f $probe.FullName) -ForegroundColor Green
} else {
    Write-Host "WARNING: restored directory appears empty. The D: copy is preserved - investigate before deleting it." -ForegroundColor Yellow
}

# 7. Optionally wipe the target backup
if ($DeleteTarget) {
    Write-Host "Deleting target backup: $dst" -ForegroundColor Cyan
    $empty = Join-Path $env:TEMP ('empty_del_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $empty | Out-Null
    robocopy "$empty" "$dst" /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $dst) {
        Write-Host "Could not fully remove $dst (some files locked). Data is on C: now; delete $dst manually when free." -ForegroundColor Yellow
    } else {
        Write-Host "Target backup removed." -ForegroundColor Green
    }
} else {
    Write-Host "Kept D: backup at $dst as a safety copy. Pass -DeleteTarget to remove it later." -ForegroundColor Cyan
}

Write-Host "DONE. Start the application and confirm everything works from C:." -ForegroundColor Green
return
