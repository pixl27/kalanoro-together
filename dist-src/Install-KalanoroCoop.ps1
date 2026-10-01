# Installs the Kalanoro co-op mod (UE4SS + KalanoroCoop) into a Kalanoro game folder.
# Usage: right-click > Run with PowerShell, or:  powershell -ExecutionPolicy Bypass -File Install-KalanoroCoop.ps1 [-GameDir <path>]
param([string]$GameDir)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = Join-Path $here "files"

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
if (-not $GameDir) {
    $GameDir = Read-Host "Kalanoro game folder (the one that contains Kalanoro.exe)"
}
$win64 = Join-Path $GameDir "Kalanoro\Binaries\Win64"
if (-not (Test-Path (Join-Path $win64 "Kalanoro-Win64-Shipping.exe"))) {
    Write-Host "Kalanoro-Win64-Shipping.exe not found under '$GameDir'." -ForegroundColor Red
    exit 1
}
if (Get-Process -Name "Kalanoro-Win64-Shipping" -ErrorAction SilentlyContinue) {
    Write-Host "Close Kalanoro first (its files are in use), then run the installer again." -ForegroundColor Red
    exit 1
}
Write-Host "Installing into $GameDir"

# 1. UE4SS (mod loader). Keep an existing UE4SS install and its mods.
$ue4ss = Join-Path $win64 "ue4ss"
if (-not (Test-Path (Join-Path $ue4ss "UE4SS.dll"))) {
    $existingProxy = Join-Path $win64 "dwmapi.dll"
    if (Test-Path $existingProxy) { Copy-Item $existingProxy "$existingProxy.kcoop_backup" -Force }
    Copy-Item (Join-Path $files "dwmapi.dll") $win64 -Force
    Copy-Item (Join-Path $files "ue4ss") $win64 -Recurse -Force
    New-Item -ItemType File -Force (Join-Path $ue4ss "KalanoroCoop.installed-ue4ss") | Out-Null
    Write-Host "  UE4SS installed"
} else {
    Write-Host "  UE4SS already present, keeping it"
}

# 2. The mods (co-op + fixes/graphics). Keep each player's config.ini on reinstall/update.
$ourMods = @("KalanoroCoop", "KalanoroFix")
foreach ($mod in $ourMods) {
    $modDir = Join-Path $ue4ss "Mods\$mod"
    $savedConfig = $null
    if (Test-Path (Join-Path $modDir "config.ini")) { $savedConfig = Get-Content (Join-Path $modDir "config.ini") -Raw }
    if (Test-Path $modDir) { Remove-Item $modDir -Recurse -Force }
    Copy-Item (Join-Path $files "ue4ss\Mods\$mod") (Join-Path $ue4ss "Mods") -Recurse -Force
    if ($savedConfig) { Set-Content (Join-Path $modDir "config.ini") $savedConfig -Encoding UTF8 -NoNewline }
}

# 3. Enable them in mods.txt (UE4SS requires the built-in Keybinds entry to stay last).
$modsTxt = Join-Path $ue4ss "Mods\mods.txt"
$lines = @()
if (Test-Path $modsTxt) { $lines = Get-Content $modsTxt | Where-Object { $_ -notmatch '^\s*(KalanoroCoop|KalanoroFix)\s*:' } }
$entries = $ourMods | ForEach-Object { "$_ : 1" }
$keybindIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*; Built-in keybinds' -or $lines[$i] -match '^\s*Keybinds\s*:') { $keybindIndex = $i; break }
}
if ($keybindIndex -ge 0) {
    # (blank lines left by a previous install are dropped so updates don't add one each time)
    $last = $keybindIndex - 1
    while ($last -ge 0 -and -not $lines[$last].Trim()) { $last-- }
    $before = if ($last -ge 0) { @($lines[0..$last]) + @("") } else { @() }
    $lines = $before + $entries + @("") + $lines[$keybindIndex..($lines.Count - 1)]
} else {
    $lines += $entries
}
Set-Content $modsTxt $lines -Encoding ASCII
Write-Host "  KalanoroCoop and KalanoroFix enabled"

# 4. Online play uses Unreal's UDP networking; the game's Steam socket layer blocks it, so disable the Steam API.
$steamDirs = Get-ChildItem (Join-Path $GameDir "Engine\Binaries\ThirdParty\Steamworks") -Directory -ErrorAction SilentlyContinue
foreach ($d in $steamDirs) {
    $dll = Join-Path $d.FullName "Win64\steam_api64.dll"
    if (Test-Path $dll) {
        Move-Item $dll "$dll.kcoop_disabled" -Force
        Write-Host "  Steam API disabled ($($d.Name))"
    }
}

# 5. Allow the game through Windows Firewall (needs admin; the host must accept UDP 7777).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$exe = Join-Path $win64 "Kalanoro-Win64-Shipping.exe"
if ($isAdmin) {
    Get-NetFirewallRule -DisplayName "Kalanoro Co-op" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName "Kalanoro Co-op" -Direction Inbound -Program $exe -Protocol UDP -LocalPort 7777 -Action Allow | Out-Null
    Write-Host "  Firewall rule added (UDP 7777)"
} else {
    Write-Host "  Not running as administrator: when Windows asks, allow Kalanoro on private AND public networks" -ForegroundColor Yellow
    Write-Host "  (Windows counts Hamachi as a public network)." -ForegroundColor Yellow
}

Write-Host ""
$modsDir = Join-Path $ue4ss "Mods"
Write-Host "Done. Co-op settings: $modsDir\KalanoroCoop\config.ini (PlayerName, keys)." -ForegroundColor Green
Write-Host "Graphics and fixes:  $modsDir\KalanoroFix\config.ini (VSync, frame cap, HDR, TSR, performance mode)."
Write-Host "In game: F5 host (your IP is copied to the clipboard), copy the host's IP then F6 to join, F7 leave,"
Write-Host "F8 teleport to partner, middle mouse ping, F11 unstuck controls."
Write-Host "Not on the same network as your friends? Everyone installs Hamachi (or Radmin VPN, ZeroTier) and joins the"
Write-Host "same network; F5 then copies your Hamachi IP for them. See README.md."
