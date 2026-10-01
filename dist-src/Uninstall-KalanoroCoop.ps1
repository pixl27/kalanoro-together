# Removes the Kalanoro co-op mod and restores the Steam API.
# Usage: powershell -ExecutionPolicy Bypass -File Uninstall-KalanoroCoop.ps1 [-GameDir <path>]
param([string]$GameDir)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-GameDir {
    param([string]$Start)
    $dir = $Start
    while ($dir) {
        if (Test-Path (Join-Path $dir "Kalanoro\Binaries\Win64\Kalanoro-Win64-Shipping.exe")) { return $dir }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

if (-not $GameDir) { $GameDir = Find-GameDir $here }
if (-not $GameDir) { $GameDir = Read-Host "Kalanoro game folder (the one that contains Kalanoro.exe)" }
$win64 = Join-Path $GameDir "Kalanoro\Binaries\Win64"
$ue4ss = Join-Path $win64 "ue4ss"
if (Get-Process -Name "Kalanoro-Win64-Shipping" -ErrorAction SilentlyContinue) {
    Write-Host "Close Kalanoro first (its files are in use), then run the uninstaller again." -ForegroundColor Red
    exit 1
}

foreach ($mod in @("KalanoroCoop", "KalanoroFix")) {
    $modDir = Join-Path $ue4ss "Mods\$mod"
    if (Test-Path $modDir) { Remove-Item $modDir -Recurse -Force; Write-Host "  $mod removed" }
}

$modsTxt = Join-Path $ue4ss "Mods\mods.txt"
if (Test-Path $modsTxt) {
    Get-Content $modsTxt | Where-Object { $_ -notmatch '^\s*(KalanoroCoop|KalanoroFix)\s*:' } | Set-Content "$modsTxt.tmp" -Encoding ASCII
    Move-Item "$modsTxt.tmp" $modsTxt -Force
}

# Remove UE4SS only if this mod's installer put it there.
if (Test-Path (Join-Path $ue4ss "KalanoroCoop.installed-ue4ss")) {
    Remove-Item $ue4ss -Recurse -Force
    Remove-Item (Join-Path $win64 "dwmapi.dll") -Force -ErrorAction SilentlyContinue
    $backup = Join-Path $win64 "dwmapi.dll.kcoop_backup"
    if (Test-Path $backup) { Move-Item $backup (Join-Path $win64 "dwmapi.dll") -Force }
    Write-Host "  UE4SS removed"
}

$steamDirs = Get-ChildItem (Join-Path $GameDir "Engine\Binaries\ThirdParty\Steamworks") -Directory -ErrorAction SilentlyContinue
foreach ($d in $steamDirs) {
    $dll = Join-Path $d.FullName "Win64\steam_api64.dll"
    foreach ($suffix in @(".kcoop_disabled", ".coopoff")) {
        if ((Test-Path "$dll$suffix") -and -not (Test-Path $dll)) {
            Move-Item "$dll$suffix" $dll
            Write-Host "  Steam API restored ($($d.Name))"
        }
    }
}

# Temporary copies of a host's save made during a session (the game's own save files are not touched).
Remove-Item (Join-Path $env:LOCALAPPDATA "Kalanoro\Saved\SaveGames\KCOOP_*.sav") -Force -ErrorAction SilentlyContinue

Get-NetFirewallRule -DisplayName "Kalanoro Co-op" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
Write-Host "Done." -ForegroundColor Green
