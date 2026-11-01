<#
.SYNOPSIS
Lists what's out of date in the Workshop addon, its pictures, the screenshots and the README's bundled versions. Changes nothing.

.DESCRIPTION
Prints one line per finding, each saying what to run, and nothing when all is current. Check-Updates.ps1 puts these in the weekly
report, and Apply-Updates.ps1 prints them after an update.
#>
[CmdletBinding()]
param(
    [string]$WorkshopId = "3831211166",
    [string]$ZipFolder = (Join-Path $env:USERPROFILE "Downloads")
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$gmm = Join-Path (Split-Path -Parent $repo) "GameModeManager"
. (Join-Path $PSScriptRoot "Visuals-Common.ps1")

# Maps and modes that have no picture yet
$manifestPath = Join-Path $script:VisualsDir "images.json"
if (-not (Test-Path $manifestPath)) {
    Write-Output "No pictures have been made on this PC. Run bisect\build-menu-images.ps1."
}
else {
    $images = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $known = @($images.maps.PSObject.Properties.Name) + @($images.modes.PSObject.Properties.Name) + @($images.noPreview)
    $serverMaps = Get-ServerMaps $repo
    $newMaps = @($serverMaps.Keys | Where-Object { $serverMaps[$_] -and $known -notcontains $_ })
    if ($newMaps.Count -gt 0) {
        Write-Output "$($newMaps.Count) workshop map(s) in gamemodes_server.txt have no picture: $($newMaps -join ', '). Run bisect\build-menu-images.ps1, then rebuild the addon."
    }

    $configFile = Join-Path $repo "game\csgo\addons\counterstrikesharp\configs\plugins\PMM_GG1MapChooser\PMM_GG1MapChooser.json"
    $config = [IO.File]::ReadAllText($configFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $entries = @($config.Maps.PSObject.Properties.Name)
    $modesText = [IO.File]::ReadAllText((Join-Path $repo "game\csgo\addons\counterstrikesharp\configs\plugins\GameModeManager\GameModeManager.json"), [Text.Encoding]::UTF8)
    $section = $modesText.Substring($modesText.IndexOf('"MapGroupFile"'))
    $newModes = @([regex]::Matches($section, '"Name":\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $entries -notcontains $_ } | Select-Object -Unique)
    if ($newModes.Count -gt 0) {
        Write-Output "$($newModes.Count) mode(s) have no picture: $($newModes -join ', '). Run bisect\build-menu-images.ps1, then rebuild the addon."
    }
}

# Server names: a new mode, or one sharing another's cfg, would show the wrong name
$overrides = Join-Path $repo "custom_files\game\csgo\cfg"
$modesConfig = [IO.File]::ReadAllText((Join-Path $repo "game\csgo\addons\counterstrikesharp\configs\plugins\GameModeManager\GameModeManager.json"), [Text.Encoding]::UTF8)
$modesSection = $modesConfig.Substring($modesConfig.IndexOf('"MapGroupFile"'))
$seenNames = @{}
foreach ($mode in [regex]::Matches($modesSection, '"Name":\s*"([^"]+)",\s*"Config":\s*"([^"]+)"')) {
    $cfg = Join-Path $repo "game\csgo\cfg\$($mode.Groups[2].Value)"
    if (-not (Test-Path $cfg)) { continue }
    $text = [IO.File]::ReadAllText($cfg)
    $inner = [regex]::Match($text, '(?m)^\s*exec\s+"?(\w[\w.-]*)')
    $custom = [regex]::Match($text, '(?m)^\s*exec\s+"?(custom_[^\s"]+)').Groups[1].Value
    if (-not $custom -and $inner.Success -and (Test-Path (Join-Path $repo "game\csgo\cfg\$($inner.Groups[1].Value)"))) {
        $custom = [regex]::Match([IO.File]::ReadAllText((Join-Path $repo "game\csgo\cfg\$($inner.Groups[1].Value)")), '(?m)^\s*exec\s+"?(custom_[^\s"]+)').Groups[1].Value
    }
    if (-not $custom -or -not (Test-Path (Join-Path $overrides $custom))) {
        Write-Output "Mode '$($mode.Groups[1].Value)' has no server name. Add custom_files\game\csgo\cfg\$(if ($custom) { $custom } else { 'custom_<mode>.cfg, and exec it from its cfg' })."
    }
    elseif ($seenNames.ContainsKey($custom)) {
        Write-Output "Modes '$($seenNames[$custom])' and '$($mode.Groups[1].Value)' share $custom, so they show the same server name."
    }
    else { $seenNames[$custom] = $mode.Groups[1].Value }
}

# The addon: built from the current files, and uploaded since
$stamp = Read-Stamp $script:AddonStamp
if (-not $stamp -or $stamp.hash -ne (Get-AddonInputsHash $repo)) {
    Write-Output "The addon's files or plugin versions changed since its last build. Close CS2, run bisect\build-menu-addon.ps1, then upload it from Workshop Tools."
}
elseif ($WorkshopId) {
    try {
        $body = @{ itemcount = 1; "publishedfileids[0]" = $WorkshopId }
        $item = (Invoke-RestMethod -Method Post -Uri "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" -Body $body -TimeoutSec 30).response.publishedfiledetails[0]
        if ([long]$item.time_updated -lt [long]$stamp.time) {
            Write-Output "The addon was built but hasn't been uploaded since. Upload it from Workshop Tools."
        }
    }
    catch { Write-Output "Couldn't ask Steam when the addon was last uploaded: $($_.Exception.Message)" }
}

# The zips the addon is built from: it takes the newest of each from Downloads
$zips = [ordered]@{ "PanoramaMenuManager" = "MenuManagerCS2-*.zip"; "PMM_GG1MapChooser" = "PMM_GG1MapChooser-*.zip"; "PMM_SimpleAdmin" = "PMM_SimpleAdmin-*.zip" }
foreach ($name in $zips.Keys) {
    $version = Get-PluginVersion $repo $name
    $zip = Get-ChildItem -Path $ZipFolder -Filter $zips[$name] -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) { Write-Output "$name's zip isn't in $ZipFolder. Download $version from its releases page before rebuilding the addon." }
    elseif (-not $zip.Name.StartsWith($version)) { Write-Output "The newest $name zip in $ZipFolder is $($zip.Name), but plugins.yaml has $version. Download the right one before rebuilding the addon." }
}

# Screenshots and thumbnail: drawn from the mockups, which should follow the menu theme
$render = Read-Stamp $script:RenderStamp
if (-not $render -or $render.hash -ne (Get-VisualsInputsHash $repo)) {
    Write-Output "The mockups or menu theme changed since the screenshots were made. Update bisect\addon\mockups if the menus look different, run bisect\render-visuals.ps1, commit GameModeManager's docs\images, and upload the changed images on the Workshop page."
}

# GameModeManager's README lists what its zip carries
$readme = Join-Path $gmm "README.md"
if (Test-Path $readme) {
    $text = [IO.File]::ReadAllText($readme, [Text.Encoding]::UTF8)
    foreach ($name in @("PanoramaMenuManager", "GG1MapChooser", "PMM_GG1MapChooser")) {
        $version = [regex]::Match((Get-PluginVersion $repo $name), '\d+(\.\d+)+').Value
        $row = [regex]::Match($text, "\|\s*\[$name\]\([^)]*\)\s*\|\s*([^|]+?)\s*\|")
        if ($row.Success -and $row.Groups[1].Value -ne $version) {
            Write-Output "GameModeManager's README says $name $($row.Groups[1].Value), but plugins.yaml has $version. Update its Included table."
        }
    }
}
