<#
  Migrate bulky AI-tool directories (home dot-dirs + AppData caches) off C:
  onto a fixed disk via NTFS junctions, by invoking the bundled
  junction_migrate.ps1 for each one.

  Target layout: D:\tool_tem\<appname>\<original-name>
    e.g.  C:\Users\hello\.qoder-cn  ->  D:\tool_tem\qoder-cn\.qoder-cn
          C:\Users\hello\AppData\Roaming\Trae  ->  D:\tool_tem\Trae\Trae

  Run this LOCALLY (not from a restricted host) after fully quitting Trae /
  Qoder / WebStorm / TabNine / any JetBrains IDE (including tray icons).

  Selection (pick what to migrate at runtime):
    - Interactive (default): script lists numbered items with sizes, then you
      type "1,3,5-8" (ranges allowed), "all", or "q" to quit.
    - Non-interactive:
        -Items "1,3,5-8"        pick by index
        -Items "qoder-cn,trae"  pick by directory name (with or without dot)
        -All                    migrate every item without prompting
        -Restore                UNDO: roll the selected items back to C:
                                (remove junction, copy data back)

  Interactive extra commands (after the list is shown):
    delete 4,7,8   = send UNINSTALLED apps' leftovers to the Recycle Bin
    restore 3,5    = undo a migration (junction -> real dir on original disk)

  Usage:
    powershell -ExecutionPolicy Bypass -File migrate_all_ai_dirs.ps1
    powershell -ExecutionPolicy Bypass -File migrate_all_ai_dirs.ps1 -Items "1,3,7-10"
    powershell -ExecutionPolicy Bypass -File migrate_all_ai_dirs.ps1 -All -TargetRoot "E:\tool_tem"
    powershell -ExecutionPolicy Bypass -File migrate_all_ai_dirs.ps1 -Restore -Items "3,5"
#>
param(
    [string]$TargetRoot = 'D:\tool_tem',
    [string]$ScriptPath = '',
    [string]$RollbackScript = '',
    [string[]]$Items = @(),
    [switch]$All,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$usrHome = $env:USERPROFILE
$roam  = $env:APPDATA
$local = $env:LOCALAPPDATA

# Source directories to migrate (home dot-dirs + AppData caches).
# NOTE: Cursor's globalStorage is migrated separately; Roaming\Cursor is
# intentionally excluded to avoid disturbing that existing junction.
$rawItems = @(
    (Join-Path $usrHome '.qoder-cn'),
    (Join-Path $usrHome '.qoder'),
    (Join-Path $usrHome '.WebStorm'),
    (Join-Path $usrHome '.trae'),
    (Join-Path $usrHome '.trae-cn'),
    (Join-Path $usrHome '.tabnine'),
    (Join-Path $usrHome '.codex'),
    (Join-Path $usrHome '.cache\codex-runtimes'),
    (Join-Path $usrHome '.codegeex'),
    (Join-Path $usrHome '.dsh'),
    (Join-Path $roam 'Trae'),
    (Join-Path $roam 'Trae CN'),
    (Join-Path $roam 'Qoder'),
    (Join-Path $local 'JetBrains')
)

# App-name overrides (basename -> app folder name under TargetRoot)
$appOverrides = @{
    'codex-runtimes' = 'codex'
}

# --- Installed-app detection (registry uninstall keys + common install paths) ---
function Test-AppInstalled {
    param([string[]]$Patterns, [string[]]$Paths, [string[]]$Commands = @())
    foreach ($c in $Commands) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { return $true }
    }
    foreach ($p in $Paths) { if (Test-Path $p) { return $true } }
    $regKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($rk in $regKeys) {
        $apps = Get-ItemProperty $rk -ErrorAction SilentlyContinue
        foreach ($a in $apps) {
            if ($a.DisplayName) {
                foreach ($pt in $Patterns) {
                    if ($a.DisplayName -like "*$pt*") { return $true }
                }
            }
        }
    }
    return $false
}

# Map a directory name to the app that owns it
function Get-OwnerInfo {
    param([string]$Base)
    switch -Regex ($Base.ToLower()) {
        '^\.?qoder-cn$' { return @{ Pat=@('Qoder');    Paths=@("$env:LOCALAPPDATA\Programs\Qoder", "$env:LOCALAPPDATA\Programs\qoder-cn") } }
        '^\.?qoder$'    { return @{ Pat=@('Qoder');    Paths=@("$env:LOCALAPPDATA\Programs\Qoder") } }
        '^\.?webstorm$' { return @{ Pat=@('WebStorm'); Paths=@("$env:LOCALAPPDATA\JetBrains\Toolbox\apps\WebStorm", "$env:PROGRAMFILES\JetBrains\WebStorm*") } }
        '^\.?trae-cn$'  { return @{ Pat=@('Trae');     Paths=@("$env:LOCALAPPDATA\Programs\Trae CN", "$env:LOCALAPPDATA\Programs\Trae") } }
        '^\.?trae$'     { return @{ Pat=@('Trae');     Paths=@("$env:LOCALAPPDATA\Programs\Trae", "$env:LOCALAPPDATA\Programs\Trae CN") } }
        '^\.?tabnine$'  { return @{ Pat=@('Tabnine');  Paths=@("$env:LOCALAPPDATA\Tabnine") } }
        '^\.?codex$'    { return @{ Pat=@('Codex','OpenAI'); Paths=@("$env:APPDATA\npm\codex.ps1", "$env:APPDATA\npm\codex.cmd"); Cmds=@('codex') } }
        '^codex-runtimes$' { return @{ Pat=@('Codex','OpenAI'); Paths=@(); Cmds=@('codex') } }
        '^\.?codegeex$' { return @{ Pat=@('CodeGeeX'); Paths=@("$env:USERPROFILE\.vscode\extensions\*codegeex*", "$env:USERPROFILE\.jetbrains\*codegeex*") } }
        '^\.?dsh$'      { return @{ Pat=@('dsh'); Paths=@(); Cmds=@('dsh') } }
        '^trae cn$'     { return @{ Pat=@('Trae');     Paths=@("$env:LOCALAPPDATA\Programs\Trae CN") } }
        '^trae$'        { return @{ Pat=@('Trae');     Paths=@("$env:LOCALAPPDATA\Programs\Trae", "$env:LOCALAPPDATA\Programs\Trae CN") } }
        '^qoder$'       { return @{ Pat=@('Qoder');    Paths=@("$env:LOCALAPPDATA\Programs\Qoder") } }
        '^jetbrains$'   { return @{ Pat=@('PyCharm','IntelliJ','WebStorm','DataGrip','GoLand','CLion','Rider','PhpStorm','RubyMine','Android Studio'); Paths=@("$env:LOCALAPPDATA\JetBrains\Toolbox") } }
        default         { return @{ Pat=@($Base);      Paths=@() } }
    }
}

# Resolve the generic script (default: next to this file)
if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot 'junction_migrate.ps1' }
if (-not (Test-Path $ScriptPath)) {
    Write-Host "ERROR: generic script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

# 1. Abort if any owning app is still running (locked files -> copy fails)
$procNames = @('Trae','Qoder','WebStorm','tabnine','jetbrains','idea',
               'pycharm','goland','clion','androidstudio','datagrip','rider')
$running = @()
foreach ($pr in $procNames) {
    $m = Get-Process -Name $pr -ErrorAction SilentlyContinue
    if ($m) { $running += ($m | Select-Object -First 1).Name }
}
if ($running.Count -gt 0) {
    Write-Host "ERROR: these are still running, quit them first: $($running -join ', ')" -ForegroundColor Red
    exit 1
}

# Resolve the rollback script (default: next to this file)
if (-not $RollbackScript) { $RollbackScript = Join-Path $PSScriptRoot 'junction_rollback.ps1' }
if (-not (Test-Path $RollbackScript)) {
    Write-Host "ERROR: rollback script not found: $RollbackScript" -ForegroundColor Red
    exit 1
}

# Build the full candidate list with metadata (size, target, migrated-flag)
$allItems = @()
foreach ($src in $rawItems) {
    if (-not (Test-Path $src)) { continue }
    $base = Split-Path $src -Leaf
    $app  = $base -replace '^\.'
    if ($appOverrides.ContainsKey($app)) { $app = $appOverrides[$app] }
    $dst  = Join-Path (Join-Path $TargetRoot $app) $base
    $sz   = (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $srcItem = Get-Item $src -ErrorAction SilentlyContinue
    $isJ = $false
    if ($srcItem -and ($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $isJ = $true }
    $oi = Get-OwnerInfo -Base $base
    $inst = Test-AppInstalled -Patterns $oi.Pat -Paths $oi.Paths -Commands $oi.Cmds
    $allItems += [PSCustomObject]@{
        Index    = $null
        Src      = $src
        Base     = $base
        App      = $app
        Dst      = $dst
        Size     = $sz
        MB       = [math]::Round($sz/1MB,1)
        Migrated = $isJ
        Installed = $inst
    }
}
for ($i = 0; $i -lt $allItems.Count; $i++) { $allItems[$i].Index = $i + 1 }

if ($allItems.Count -eq 0) {
    Write-Host "No candidate directories found. Nothing to do." -ForegroundColor Yellow
    exit 0
}

# --- selection helpers ---
function Resolve-Selection {
    param([string[]]$Tokens, $List)
    $flat = @()
    foreach ($t in $Tokens) { $flat += ($t -split ',') | Where-Object { $_ -ne '' } }
    $nums = @()
    $names = @()
    foreach ($tk in $flat) {
        if ($tk -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($x = $a; $x -le $b; $x++) { if ($x -ge 1 -and $x -le $List.Count) { $nums += $x } }
        } elseif ($tk -match '^\d+$') {
            $n = [int]$tk; if ($n -ge 1 -and $n -le $List.Count) { $nums += $n }
        } else {
            $names += $tk
        }
    }
    $sel = @($List | Where-Object { $nums -contains $_.Index })
    foreach ($nm in $names) {
        $lc = $nm.ToLower()
        $m = $List | Where-Object {
            $_.Base.ToLower() -eq $lc -or
            $_.App.ToLower() -eq $lc -or
            $_.Base.ToLower() -eq ("." + $lc)
        }
        if ($m) { $sel += $m }
    }
    $seen = @{}
    $out = @()
    foreach ($s in $sel) { if (-not $seen[$s.Index]) { $seen[$s.Index] = $true; $out += $s } }
    return $out
}

function Show-List {
    param($List)
    Write-Host ""
    Write-Host "Directories available to migrate:" -ForegroundColor Cyan
    foreach ($it in $List) {
        $tags = @()
        if ($it.Migrated)  { $tags += 'done' }
        if (-not $it.Installed) { $tags += 'app-NOT-installed' }
        $tagStr = if ($tags.Count) { ' [' + ($tags -join ',') + ']' } else { '' }
        Write-Host ("  [{0,2}] {1,-16} {2,8} MB{3}" -f $it.Index, $it.Base, $it.MB, $tagStr)
        Write-Host ("       {0}" -f $it.Src) -ForegroundColor DarkGray
        Write-Host ("       -> {0}" -f $it.Dst) -ForegroundColor DarkGray
    }
}

function Invoke-Recycle {
    param($Selected)
    Add-Type -AssemblyName Microsoft.VisualBasic
    foreach ($s in $Selected) {
        if (Test-Path $s.Src) {
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($s.Src, 'OnlyErrorDialogs', 'SendToRecycleBin')
                Write-Host ("Recycled: {0} ({1} MB)" -f $s.Src, $s.MB) -ForegroundColor Green
            } catch {
                Write-Host ("FAILED to recycle {0}: {1}" -f $s.Src, $_.Exception.Message) -ForegroundColor Red
            }
        }
    }
    Write-Host "Sent to Recycle Bin (recoverable). Empty the Recycle Bin to actually free C: space." -ForegroundColor Yellow
}

function Invoke-Restore {
    param($Selected)
    foreach ($s in $Selected) {
        if (-not $s.Migrated) {
            Write-Host ("  skip {0}: not a junction (not migrated)" -f $s.Src) -ForegroundColor Yellow
            continue
        }
        # Ensure the data's ORIGINAL drive (where it is going back to) has room.
        $qual = Split-Path $s.Src -Qualifier
        $drv  = New-Object System.IO.DriveInfo $qual
        if ($drv.AvailableFreeSpace -lt $s.Size) {
            Write-Host ("  SKIP {0}: {1} has only {2:N2} GB free, need ~{3:N2} GB" -f $s.Src, $qual, ($drv.AvailableFreeSpace/1GB), ($s.Size/1GB)) -ForegroundColor Red
            continue
        }
        Write-Host ("`n=== Restoring $($s.Src) (junction -> real dir on original disk) ===") -ForegroundColor Cyan
        & $RollbackScript -SourceDir $s.Src
        if ($LASTEXITCODE -ne 0) { Write-Host ("  restore FAILED for $($s.Src)") -ForegroundColor Red }
    }
}

# Re-read each item's ReparsePoint flag after a restore (the item may no longer
# be a junction). Mutates $List in place.
function Refresh-Migrated($List) {
    foreach ($it in $List) {
        $si = Get-Item $it.Src -ErrorAction SilentlyContinue
        $it.Migrated = ($si -and ($si.Attributes -band [IO.FileAttributes]::ReparsePoint))
    }
}

function Prompt-Selection {
    param($List)
    Show-List -List $List
    Write-Host ""
    Write-Host "Enter item numbers to MIGRATE (e.g. 1,3,5-8). 'all' = everything, 'q' = quit." -ForegroundColor Yellow
    Write-Host "Or 'delete 4,7,8' = send leftovers of UNINSTALLED apps to the Recycle Bin." -ForegroundColor Yellow
    Write-Host "Or 'restore 3,5' = undo a migration (remove junction, copy data back to C:)." -ForegroundColor Yellow
    while ($true) {
        $raw = Read-Host "Select"
        if ($raw -eq 'q' -or $raw -eq 'quit') { Write-Host "Aborted." -ForegroundColor Yellow; exit 0 }
        if ($raw -eq 'all' -or $raw -eq 'a') { return $List }
        if ($raw -match '^(delete|del)\s+(.+)$') {
            # NOTE: @() wrapper - PowerShell unwraps a single-element array on
            # return, so without it a single match yields a bare object whose
            # .Count is $null and breaks the checks below.
            $sel = @(Resolve-Selection -Tokens @($Matches[2]) -List $List)
            if ($sel.Count -eq 0) { Write-Host "Invalid selection for delete." -ForegroundColor Red; continue }
            Write-Host "About to send these directories to the Recycle Bin:" -ForegroundColor Yellow
            foreach ($s in $sel) {
                $st = if ($s.Installed) { '[WARNING: app IS installed]' } else { '[app not installed]' }
                Write-Host ("  {0}  {1} MB  {2}" -f $s.Src, $s.MB, $st)
            }
            $conf = Read-Host "Type YES to confirm"
            if ($conf -ceq 'YES') {
                Invoke-Recycle -Selected $sel
                $List = @($List | Where-Object { $sel.Index -notcontains $_.Index })
                if ($List.Count -eq 0) { Write-Host "Nothing left to migrate. Bye." -ForegroundColor Green; exit 0 }
                Show-List -List $List
            } else {
                Write-Host "Delete cancelled." -ForegroundColor Yellow
            }
            continue
        }
        if ($raw -match '^(restore|undo)\s+(.+)$') {
            $sel = @(Resolve-Selection -Tokens @($Matches[2]) -List $List)
            if ($sel.Count -eq 0) { Write-Host "Invalid selection for restore." -ForegroundColor Red; continue }
            Write-Host "About to restore these to the ORIGINAL disk (junction removed, data copied back):" -ForegroundColor Yellow
            foreach ($s in $sel) {
                $st = if ($s.Migrated) { '[junction]' } else { '[NOT migrated - will skip]' }
                Write-Host ("  {0}  {1} MB  {2}" -f $s.Src, $s.MB, $st)
            }
            $conf = Read-Host "Type YES to confirm"
            if ($conf -ceq 'YES') {
                Invoke-Restore -Selected $sel
                Refresh-Migrated -List $List
                Show-List -List $List
            } else {
                Write-Host "Restore cancelled." -ForegroundColor Yellow
            }
            continue
        }
        $sel = @(Resolve-Selection -Tokens @($raw) -List $List)
        if ($sel.Count -gt 0) { return $sel }
        Write-Host "Invalid selection. Try again (e.g. 1,3,5-8), 'all', 'delete 4,7', or 'q'." -ForegroundColor Red
    }
}

# --- decide selection ---
if ($All) {
    $selected = $allItems
    Write-Host "(-All) migrating every candidate." -ForegroundColor Cyan
} elseif ($Items.Count -gt 0 -and -not ($Items.Count -eq 1 -and $Items[0] -eq '')) {
    $selected = @(Resolve-Selection -Tokens $Items -List $allItems)
    if ($selected.Count -eq 0) {
        Write-Host "ERROR: no items matched your -Items selection. Aborting." -ForegroundColor Red
        exit 1
    }
    Write-Host ("Selected by -Items: {0} item(s)." -f $selected.Count) -ForegroundColor Cyan
} else {
    $selected = @(Prompt-Selection -List $allItems)
}

# Non-interactive restore mode: -Restore re-runs the selection as a rollback.
if ($Restore) {
    Write-Host "(-Restore) undoing migration for the selected item(s)..." -ForegroundColor Cyan
    Invoke-Restore -Selected $selected
    exit 0
}

# 2. Check aggregate size of the SELECTED items vs target drive free space
$qual = Split-Path $TargetRoot -Qualifier
$drive = New-Object System.IO.DriveInfo $qual
if (-not $drive.IsReady) {
    Write-Host "ERROR: target drive $qual is not ready." -ForegroundColor Red
    exit 1
}
$total = ($selected | Measure-Object Size -Sum).Sum
if ($drive.AvailableFreeSpace -lt $total) {
    Write-Host ("ERROR: target {0} has only {1:N2} GB free but {2:N2} GB needed for the selected items." -f $qual, ($drive.AvailableFreeSpace/1GB), ($total/1GB)) -ForegroundColor Red
    exit 1
}

Write-Host ("Target {0} free: {1:N2} GB | selected to migrate: {2:N2} GB" -f $qual, ($drive.AvailableFreeSpace/1GB), ($total/1GB)) -ForegroundColor Cyan
Write-Host "Selected plan:" -ForegroundColor Cyan
foreach ($p in $selected) {
    $mark = if ($p.Migrated) { " (already migrated, will skip)" } else { "" }
    Write-Host ("  {0}  ->  {1}   ({2} MB){3}" -f $p.Src, $p.Dst, $p.MB, $mark)
}

# 3. Migrate each selected directory (completed ones are skipped via resume logic)
$ok = @(); $fail = @()
foreach ($p in $selected) {
    Write-Host ("`n=== Migrating $($p.Src) -> $($p.Dst) ===") -ForegroundColor Cyan
    & $ScriptPath -SourceDir $p.Src -TargetDir $p.Dst
    if ($LASTEXITCODE -eq 0) { $ok += $p.Src } else { $fail += $p.Src }
}

# 4. Summary
Write-Host "`n================ SUMMARY ================" -ForegroundColor Green
Write-Host ("OK   ({0}): {1}" -f $ok.Count, ($ok -join "`n        "))
$col = if ($fail.Count -gt 0) { 'Red' } else { 'Green' }
Write-Host ("FAIL ({0}): {1}" -f $fail.Count, ($fail -join ', ')) -ForegroundColor $col
if ($fail.Count -gt 0) {
    Write-Host "Re-run this script; already-completed dirs are skipped (idempotent)." -ForegroundColor Yellow
}
exit 0
