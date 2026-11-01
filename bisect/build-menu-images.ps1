# Makes the vote panel's pictures: each workshop map's Steam preview. Each mode shows its default map's picture, or CS2's
# own screenshot for an official map, so modes need no files of their own.
# Pictures go in a folder outside the repo, listed in images.json, and build-menu-addon.ps1 puts them in the addon.
# Safe to run again: downloads only what's missing. The map previews belong to their authors, so credit them on the Workshop page.
#
#   .\build-menu-images.ps1                # everything, and adds the pictures to PMM_GG1MapChooser.json
#   .\build-menu-images.ps1 -Limit 5       # try a few maps first; the config isn't touched

[CmdletBinding()]
param(
    [int]$Limit = 0,
    [string]$OutDir = (Join-Path $env:USERPROFILE "Documents\CS2\addon-images")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$repo = Split-Path -Parent $PSScriptRoot
$poolsFile = Join-Path $repo "game\csgo\cfg\GGMCmaps.tuning.json"
$configFile = Join-Path $repo "game\csgo\addons\counterstrikesharp\configs\plugins\PMM_GG1MapChooser\PMM_GG1MapChooser.json"
$modesFile = Join-Path $repo "game\csgo\addons\counterstrikesharp\configs\plugins\GameModeManager\GameModeManager.json"
$mapsDir = Join-Path $OutDir "maps"
$sourceDir = Join-Path $OutDir "steam-previews"
New-Item -ItemType Directory -Force -Path $mapsDir, $sourceDir | Out-Null

# Define the picture size: the panel draws 80x45, and twice that stays sharp without adding much to the download
$width = 160
$height = 90

# Define the official maps CS2 has a screenshot for (BuiltinMaps in PMM_GG1MapChooser)
$officialMaps = @("ar_baggage", "ar_pool_day", "ar_shoots", "ar_shoots_night", "cs_italy", "cs_office", "cs_shelter", "de_ancient", "de_ancient_night", "de_anubis", "de_boulder", "de_cache", "de_debris", "de_dust", "de_dust2", "de_eldorado", "de_fachwerk", "de_inferno", "de_mirage", "de_nuke", "de_overpass", "de_poseidon", "de_train", "de_vertigo")

# The same rule as PMM_GG1MapChooser's San(): this makes the file name and its CSS class
function Get-SafeName([string]$name) {
    return (-join ($name.Trim().ToLowerInvariant().ToCharArray() | ForEach-Object { if ($_ -match '[a-z0-9_-]') { $_ } else { '_' } }))
}

function New-Canvas {
    $bitmap = New-Object Drawing.Bitmap $width, $height
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = 'AntiAlias'
    $graphics.InterpolationMode = 'HighQualityBicubic'
    $graphics.PixelOffsetMode = 'HighQuality'
    return @($bitmap, $graphics)
}

# Draws a picture over the whole canvas, cropping it instead of stretching it
function Add-Cover($graphics, [string]$path) {
    $image = [Drawing.Image]::FromFile($path)
    try {
        $scale = [Math]::Max($width / $image.Width, $height / $image.Height)
        $w = [int][Math]::Ceiling($image.Width * $scale)
        $h = [int][Math]::Ceiling($image.Height * $scale)
        $graphics.DrawImage($image, [int](($width - $w) / 2), [int](($height - $h) / 2), $w, $h)
    }
    finally { $image.Dispose() }
}

$pools = [IO.File]::ReadAllText($poolsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json

# Maps: key -> workshop ID
$workshop = [ordered]@{}
foreach ($mode in $pools.PSObject.Properties) {
    foreach ($entry in $mode.Value.PSObject.Properties) {
        if ($entry.Value.ws -and "$($entry.Value.mapid)" -match '^\d+$') {
            $workshop[$entry.Name] = "$($entry.Value.mapid)"
        }
    }
}

$keys = @($workshop.Keys)
if ($Limit -gt 0) { $keys = @($keys | Select-Object -First $Limit) }

# Ask Steam about the maps whose previews are missing, 100 at a time
$missing = @($keys | Where-Object { -not (Test-Path (Join-Path $sourceDir ((Get-SafeName $_) + ".img"))) })
$failed = New-Object System.Collections.ArrayList
for ($start = 0; $start -lt $missing.Count; $start += 100) {
    $batch = @($missing | Select-Object -Skip $start -First 100)
    $body = @{ itemcount = $batch.Count }
    for ($i = 0; $i -lt $batch.Count; $i++) { $body["publishedfileids[$i]"] = $workshop[$batch[$i]] }
    $details = (Invoke-RestMethod -Method Post -Uri "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" -Body $body -TimeoutSec 60).response.publishedfiledetails
    foreach ($key in $batch) {
        $item = $details | Where-Object { "$($_.publishedfileid)" -eq $workshop[$key] } | Select-Object -First 1
        if (-not $item -or -not $item.preview_url) { [void]$failed.Add($key); continue }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $item.preview_url -OutFile (Join-Path $sourceDir ((Get-SafeName $key) + ".img")) -TimeoutSec 60
        }
        catch { [void]$failed.Add($key) }
    }
    Write-Host "  previews: $([Math]::Min($start + 100, $missing.Count)) / $($missing.Count)"
}

# Make the map pictures
$made = [ordered]@{}
foreach ($key in $keys) {
    $safe = Get-SafeName $key
    $source = Join-Path $sourceDir "$safe.img"
    $target = Join-Path $mapsDir "$safe.png"
    if (-not (Test-Path $source)) { continue }
    if (-not (Test-Path $target)) {
        try {
            $bitmap, $graphics = New-Canvas
            Add-Cover $graphics $source
            $bitmap.Save($target, [Drawing.Imaging.ImageFormat]::Png)
            $graphics.Dispose(); $bitmap.Dispose()
        }
        catch {
            Write-Warning "Skipped $key`: its preview isn't a usable image"
            [void]$failed.Add($key)
            continue
        }
    }
    $made[$key] = "$safe.png"
}

# Each mode shows its default map: mode name -> what the bridge's Image setting takes
$cards = [ordered]@{}
$noPicture = New-Object System.Collections.ArrayList
# Read as text: Windows PowerShell's JSON parser rejects this file, though the plugin reads it fine
$modesText = [IO.File]::ReadAllText($modesFile, [Text.Encoding]::UTF8)
$section = $modesText.Substring($modesText.IndexOf('"MapGroupFile"'))
foreach ($mode in [regex]::Matches($section, '"Name":\s*"([^"]+)"[^{}]*?"DefaultMap":\s*"([^"]*)"')) {
    $name = $mode.Groups[1].Value
    $map = $mode.Groups[2].Value
    # A default map can be set by its workshop ID
    $byId = @($workshop.Keys | Where-Object { $workshop[$_] -eq $map }) | Select-Object -First 1
    if ($byId) { $map = $byId }
    if ($made.Contains($map)) { $cards[$name] = "maps/$($made[$map])" }
    elseif ($officialMaps -contains $map.ToLowerInvariant()) { $cards[$name] = "s2r://panorama/images/map_icons/screenshots/360p/$($map.ToLowerInvariant())_png.vtex" }
    else { [void]$noPicture.Add("$name ($map)") }
}

# The list build-menu-addon.ps1 reads
$utf8 = New-Object Text.UTF8Encoding($false)
$manifest = [ordered]@{ maps = $made; modes = $cards }
[IO.File]::WriteAllText((Join-Path $OutDir "images.json"), ($manifest | ConvertTo-Json -Depth 4), $utf8)

# Tell the bridge which picture each entry has. Entries set by hand are kept.
if ($Limit -eq 0) {
    $text = [IO.File]::ReadAllText($configFile, [Text.Encoding]::UTF8)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $config = $text | ConvertFrom-Json
    $existing = @($config.Maps.PSObject.Properties.Name)
    $block = ""
    foreach ($key in $made.Keys) {
        if ($existing -notcontains $key) { $block += "    `"$key`": {$nl      `"Title`": `"`",$nl      `"Image`": `"maps/$($made[$key])`",$nl      `"Badge`": `"`"$nl    },$nl" }
    }
    foreach ($mode in $cards.Keys) {
        $name = $mode -replace '"', '\"'
        if ($existing -notcontains $mode) { $block += "    `"$name`": {$nl      `"Title`": `"$name`",$nl      `"Image`": `"$($cards[$mode])`",$nl      `"Badge`": `"Mode`"$nl    },$nl" }
    }
    $anchor = [regex]::Match($text, '"Maps":\s*\{\s*')
    if (-not $anchor.Success) { throw "No Maps section in $configFile" }
    $text = $text.Insert($anchor.Index + $anchor.Length, $block.TrimStart())
    $null = $text | ConvertFrom-Json
    [IO.File]::WriteAllText($configFile, $text, $utf8)
    Write-Host "  Added $(([regex]::Matches($block, '"Image"')).Count) picture(s) to PMM_GG1MapChooser.json"
}

$bytes = (Get-ChildItem $mapsDir -Filter *.png | Measure-Object Length -Sum).Sum
Write-Host "[OK] $($made.Count) map picture(s), $($cards.Count) mode(s) using a default map's picture, $([int]($bytes / 1KB)) KB of PNGs in $mapsDir" -ForegroundColor Green
if ($noPicture.Count -gt 0) { Write-Host "Mode's default map has no picture: $($noPicture -join ', ')" -ForegroundColor Yellow }
if ($failed.Count -gt 0) { Write-Host "No preview for: $(@($failed | Select-Object -Unique) -join ', ')" -ForegroundColor Yellow }
