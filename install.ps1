# PBZ Auto QTE - installer (Windows PowerShell 5.1+)
# Installs UE4SS (if missing) + the Phantom Blade Zero UE4SS config + the PBZAutoQTE mod.
# Nothing in the game itself is modified: only new files are added next to PBZ.exe.
param(
    [string]$GamePath = "",
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
$ModName = "PBZAutoQTE"
$AppId = "4115450"
$TestedVersion = "CL-301524_JKS-17219"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Marker = ".installed-by-PBZAutoQTE"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Finish($code) {
    if (-not $NoPause) { Write-Host ""; Read-Host "Press Enter to close" | Out-Null }
    exit $code
}

# ---------------------------------------------------------------------------- find the game
function Find-SteamLibraries {
    $libs = @()
    $steam = $null
    foreach ($key in "HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam") {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($p.SteamPath) { $steam = $p.SteamPath } elseif ($p.InstallPath) { $steam = $p.InstallPath }
        } catch {}
        if ($steam) { break }
    }
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs += $m.Groups[1].Value.Replace("\\", "\")
            }
        }
    }
    return $libs | Select-Object -Unique
}

function Find-EpicInstalls {
    # Epic Games Launcher keeps one JSON manifest per installed game.
    $dirs = @()
    $manifests = Join-Path $env:ProgramData "Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path $manifests) {
        foreach ($f in Get-ChildItem $manifests -Filter *.item -ErrorAction SilentlyContinue) {
            try {
                $m = Get-Content $f.FullName -Raw | ConvertFrom-Json
                if ($m.DisplayName -match 'Phantom\s*Blade' -and $m.InstallLocation) { $dirs += $m.InstallLocation }
            } catch {}
        }
    }
    return $dirs
}

function Find-GogInstalls {
    $dirs = @()
    foreach ($root in "HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games", "HKLM:\SOFTWARE\GOG.com\Games") {
        if (Test-Path $root) {
            foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
                try {
                    $p = Get-ItemProperty $k.PSPath
                    if ($p.gameName -match 'Phantom\s*Blade' -and $p.path) { $dirs += $p.path }
                } catch {}
            }
        }
    }
    return $dirs
}

function Resolve-GameRoot($path) {
    # Accepts the game folder or the folder that contains PBZ.exe. The real game executable is the big
    # PBZ.exe under platform\<store>\ (Steam: platform\steam); the small one elsewhere is only a launcher.
    if (-not $path) { return $null }
    $path = $path.Trim('"').TrimEnd("\")
    if (-not (Test-Path $path)) { return $null }
    $candidates = @($path)
    $platform = Join-Path $path "platform"
    if (Test-Path $platform) { $candidates = @(Get-ChildItem $platform -Directory | ForEach-Object { $_.FullName }) + $candidates }
    foreach ($candidate in $candidates) {
        $exe = Join-Path $candidate "PBZ.exe"
        if ((Test-Path $exe) -and ((Get-Item $exe).Length -gt 50MB -or $env:PBZ_ALLOW_SMALL_EXE)) { return $candidate }
    }
    return $null
}

Say "=== PBZ Auto QTE - installer ===" Cyan
$ExeDir = Resolve-GameRoot $GamePath
if (-not $ExeDir) {
    $places = @()
    foreach ($lib in Find-SteamLibraries) { $places += Join-Path $lib "steamapps\common\PBZ" }
    $places += Find-EpicInstalls
    $places += Find-GogInstalls
    foreach ($place in $places) {
        $ExeDir = Resolve-GameRoot $place
        if ($ExeDir) { break }
    }
}
while (-not $ExeDir) {
    Say "Phantom Blade Zero was not found automatically." Yellow
    $answer = Read-Host "Paste the game folder (Steam: Manage > Browse local files; Epic: Manage > Installation folder), or leave empty to cancel"
    if (-not $answer) { Say "Cancelled." ; Finish 1 }
    $ExeDir = Resolve-GameRoot $answer
    if (-not $ExeDir) { Say "PBZ.exe was not found in that folder." Red }
}
Say "Game found: $ExeDir" Green

if (-not $env:PBZ_SKIP_RUNNING_CHECK -and (Get-Process -Name "PBZ" -ErrorAction SilentlyContinue)) {
    Say "The game is running. Close Phantom Blade Zero and run the installer again." Red
    Finish 1
}

try {
    $ver = (Get-Item (Join-Path $ExeDir "PBZ.exe")).VersionInfo.ProductVersion
    if ($ver -and $ver -ne $TestedVersion) {
        Say "Note: this mod was tested on game version $TestedVersion, you have $ver. It will probably work; if not, see Troubleshooting in the README." Yellow
    }
} catch {}

# ---------------------------------------------------------------------------- UE4SS
$Ue4ss = Join-Path $ExeDir "ue4ss"
$Proxy = Join-Path $ExeDir "dwmapi.dll"
$Mods = Join-Path $Ue4ss "Mods"
$freshUe4ss = $false

if ((Test-Path $Proxy) -and (Test-Path (Join-Path $Ue4ss "UE4SS.dll"))) {
    Say "UE4SS is already installed - keeping it." Green
} else {
    Say "Downloading UE4SS (experimental build, needed for Unreal Engine 5.7) from github.com/UE4SS-RE ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ "User-Agent" = "PBZAutoQTE-installer" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest" -Headers $headers
    $asset = $release.assets | Where-Object { $_.name -match '^UE4SS_v.*\.zip$' } | Select-Object -First 1
    if (-not $asset) { Say "Could not find the UE4SS download. Install UE4SS manually (see README)." Red; Finish 1 }
    $tmp = Join-Path $env:TEMP ("pbz-ue4ss-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $headers -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp "x") -Force
    $src = Join-Path $tmp "x"
    if (-not (Test-Path (Join-Path $src "dwmapi.dll")) -or -not (Test-Path (Join-Path $src "ue4ss\UE4SS.dll"))) {
        Say "Unexpected UE4SS package layout ($($asset.name)). Install UE4SS manually (see README)." Red
        Finish 1
    }
    Copy-Item (Join-Path $src "dwmapi.dll") $ExeDir -Force
    Copy-Item (Join-Path $src "ue4ss") $ExeDir -Recurse -Force
    Remove-Item $tmp -Recurse -Force
    Set-Content -Path (Join-Path $Ue4ss $Marker) -Value "UE4SS $($asset.name) installed by PBZ Auto QTE" -Encoding ASCII
    $freshUe4ss = $true
    Say "UE4SS installed ($($asset.name))." Green
}

# Phantom Blade Zero needs a custom UE4SS config (memory layout + signatures) - always refresh it.
Copy-Item (Join-Path $Here "ue4ss-config\MemberVariableLayout.ini") $Ue4ss -Force
New-Item -ItemType Directory -Path (Join-Path $Ue4ss "UE4SS_Signatures") -Force | Out-Null
Copy-Item (Join-Path $Here "ue4ss-config\UE4SS_Signatures\*.lua") (Join-Path $Ue4ss "UE4SS_Signatures") -Force
Say "Phantom Blade Zero config for UE4SS installed." Green

# ---------------------------------------------------------------------------- the mod
$Dest = Join-Path $Mods $ModName
$settings = Join-Path $Dest "settings.txt"
$keep = $null
if (Test-Path $settings) { $keep = Get-Content $settings -Raw }
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Copy-Item (Join-Path $Here "mod\$ModName\*") $Dest -Recurse -Force
if ($keep) { Set-Content -Path $settings -Value $keep -NoNewline -Encoding ASCII }

# Enable it in mods.txt (before the built-in Keybinds line, which must stay last) ...
$modsTxt = Join-Path $Mods "mods.txt"
$lines = @()
if (Test-Path $modsTxt) { $lines = @(Get-Content $modsTxt) }
if ($freshUe4ss) {
    # Fresh UE4SS: switch off its built-in mods - the mod was tested with them off, and the Keybinds
    # dump hotkeys can crash this game (UE4SS issue #1483).
    $lines = $lines | ForEach-Object { if ($_ -match '^\s*([A-Za-z0-9_]+)\s*:\s*1\s*$') { "$($Matches[1]) : 0" } else { $_ } }
}
$lines = @($lines | Where-Object { $_ -notmatch "^\s*$ModName\s*:" })
$idx = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Keybinds\s*:') { $idx = $i; break } }
if ($idx -ge 0) {
    $before = if ($idx -gt 0) { $lines[0..($idx - 1)] } else { @() }
    $lines = @($before) + "$ModName : 1" + $lines[$idx..($lines.Count - 1)]
} else {
    $lines += "$ModName : 1"
}
Set-Content -Path $modsTxt -Value $lines -Encoding ASCII

# ... and in mods.json (newer UE4SS builds read it too).
$modsJson = Join-Path $Mods "mods.json"
if (Test-Path $modsJson) {
    # PowerShell 5.1 returns a JSON array as one pipeline object; piping through ForEach-Object unrolls it.
    $json = @((Get-Content $modsJson -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
    if ($freshUe4ss) { foreach ($m in $json) { $m.mod_enabled = $false } }
    $json = @($json | Where-Object { $_.mod_name -ne $ModName })
    $json += [pscustomobject]@{ mod_name = $ModName; mod_enabled = $true }
    Set-Content -Path $modsJson -Value (ConvertTo-Json -InputObject $json -Depth 3) -Encoding ASCII
}

Say ""
Say "Done! PBZ Auto QTE is installed." Green
Say "Start the game normally (Steam or Epic). After loading a save you will see the mod status on screen."
Say "Key:  F3 = auto QTE on/off"
Finish 0
