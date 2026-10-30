# PBZ Auto QTE - uninstaller (Windows PowerShell 5.1+)
# Removes the mod. If UE4SS was installed by our installer, it can be removed too.
param(
    [string]$GamePath = "",
    [switch]$RemoveUE4SS,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
$ModName = "PBZAutoQTE"
$Marker = ".installed-by-PBZAutoQTE"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Finish($code) {
    if (-not $NoPause) { Write-Host ""; Read-Host "Press Enter to close" | Out-Null }
    exit $code
}

function Resolve-GameRoot($path) {
    if (-not $path) { return $null }
    $path = $path.Trim('"').TrimEnd("\")
    if (-not (Test-Path $path)) { return $null }
    $candidates = @($path)
    $platform = Join-Path $path "platform"
    if (Test-Path $platform) { $candidates = @(Get-ChildItem $platform -Directory | ForEach-Object { $_.FullName }) + $candidates }
    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate "ue4ss\Mods\$ModName")) { return $candidate }
    }
    return $null
}

function Find-OtherInstalls {
    $dirs = @()
    $manifests = Join-Path $env:ProgramData "Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path $manifests) {
        foreach ($f in Get-ChildItem $manifests -Filter *.item -ErrorAction SilentlyContinue) {
            try { $m = Get-Content $f.FullName -Raw | ConvertFrom-Json; if ($m.DisplayName -match 'Phantom\s*Blade') { $dirs += $m.InstallLocation } } catch {}
        }
    }
    foreach ($root in "HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games", "HKLM:\SOFTWARE\GOG.com\Games") {
        if (Test-Path $root) {
            foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
                try { $p = Get-ItemProperty $k.PSPath; if ($p.gameName -match 'Phantom\s*Blade') { $dirs += $p.path } } catch {}
            }
        }
    }
    return $dirs
}

function Find-SteamLibraries {
    $libs = @()
    foreach ($key in "HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam") {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            $steam = if ($p.SteamPath) { $p.SteamPath } else { $p.InstallPath }
            if ($steam) {
                $libs += $steam
                $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
                if (Test-Path $vdf) {
                    foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value.Replace("\\", "\") }
                }
                break
            }
        } catch {}
    }
    return $libs | Select-Object -Unique
}

Say "=== PBZ Auto QTE - uninstaller ===" Cyan
$ExeDir = Resolve-GameRoot $GamePath
if (-not $ExeDir) {
    $places = @()
    foreach ($lib in Find-SteamLibraries) { $places += Join-Path $lib "steamapps\common\PBZ" }
    $places += Find-OtherInstalls
    foreach ($place in $places) {
        $ExeDir = Resolve-GameRoot $place
        if ($ExeDir) { break }
    }
}
if (-not $ExeDir) {
    $answer = Read-Host "The mod was not found automatically. Paste the game folder, or leave empty to cancel"
    $ExeDir = Resolve-GameRoot $answer
    if (-not $ExeDir) { Say "The mod is not installed there." Yellow; Finish 1 }
}
if (-not $env:PBZ_SKIP_RUNNING_CHECK -and (Get-Process -Name "PBZ" -ErrorAction SilentlyContinue)) { Say "Close Phantom Blade Zero first." Red; Finish 1 }

$Ue4ss = Join-Path $ExeDir "ue4ss"
$Mods = Join-Path $Ue4ss "Mods"
Remove-Item (Join-Path $Mods $ModName) -Recurse -Force
$modsTxt = Join-Path $Mods "mods.txt"
if (Test-Path $modsTxt) {
    Set-Content -Path $modsTxt -Value @(Get-Content $modsTxt | Where-Object { $_ -notmatch "^\s*$ModName\s*:" }) -Encoding ASCII
}
$modsJson = Join-Path $Mods "mods.json"
if (Test-Path $modsJson) {
    $json = @((Get-Content $modsJson -Raw | ConvertFrom-Json) | ForEach-Object { $_ } | Where-Object { $_.mod_name -ne $ModName })
    Set-Content -Path $modsJson -Value (ConvertTo-Json -InputObject $json -Depth 3) -Encoding ASCII
}
Say "Mod removed." Green

# Other mods still use UE4SS (for example PBZ Auto Parry & Dodge): keep it.
$others = @(Get-ChildItem $Mods -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "PBZ*" } | ForEach-Object { $_.Name })
if ($others.Count -gt 0) {
    Say "UE4SS is kept because other mods still use it: $($others -join ', ')." Yellow
} elseif (Test-Path (Join-Path $Ue4ss $Marker)) {
    if (-not $RemoveUE4SS -and -not $NoPause) {
        $RemoveUE4SS = (Read-Host "UE4SS was installed together with this mod. Remove UE4SS too? (y/N)") -match '^[yY]'
    }
    if ($RemoveUE4SS) {
        Remove-Item (Join-Path $ExeDir "dwmapi.dll") -Force -ErrorAction SilentlyContinue
        Remove-Item $Ue4ss -Recurse -Force
        Say "UE4SS removed. The game folder is back to its original state." Green
    }
}
Finish 0
