<#
.SYNOPSIS
Applies chosen plugin updates to the server repo and GameModeManager's bundle, then checks both still fit together.

.DESCRIPTION
Pinned components update too, because they are named here on purpose. Refuses to run on main or master.
Nothing is committed or deployed.

.PARAMETER Component
Components to update, as named in plugins.yaml. Leave out to only sync the bundle and run the checks.

.EXAMPLE
.\scripts\Apply-Updates.ps1 -Component GG1MapChooser,PanoramaMenuManager
.\scripts\Apply-Updates.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Component = @(),
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) "cs2-plugin-updates")
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$gmm = Join-Path (Split-Path -Parent $repo) "GameModeManager"
$project = Join-Path $repo "ci/ServerBundleCheck"
$tool = Join-Path $project "bin/Release/net10.0/ServerBundleCheck.dll"
$failed = $false

# Define the folders GameModeManager's release carries. Native libraries are trimmed to the platforms it supports.
$bundleFolders = [ordered]@{
    "plugins/MenuManagerCore"   = "MenuManagerCore.dll"
    "plugins/GG1MapChooser"     = "GG1MapChooser.dll"
    "plugins/PMM_GG1MapChooser" = "PMM_GG1MapChooser.dll"
    "shared/MenuManagerApi"     = "MenuManagerApi.dll"
    "shared/ggmcAPI"            = "ggmcAPI.dll"
}
$keepRuntimes = @("linux-x64", "linux-musl-x64", "win", "win-x64")

# Define the private members GameModeManager reaches by reflection. A new release that renames one breaks it at run time,
# which a build can't see. Names are looked for in the DLL's metadata; nothing is loaded. The bundled plugins' lists are in
# GameModeManager's src/GameModeManager/Core/ReflectedMembers.cs. CS2-SimpleAdmin isn't bundled, so its list is here.
$reflectedSource = Get-Content (Join-Path $gmm "src/GameModeManager/Core/ReflectedMembers.cs") -Raw
function Get-ReflectedList([string]$Name) {
    $list = [regex]::Match($reflectedSource, "string\[\] $Name\s*=\s*\{(.*?)\}", 'Singleline')
    if (-not $list.Success) { throw "No $Name list in GameModeManager's ReflectedMembers.cs" }
    return @([regex]::Matches($list.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
}
$reflected = [ordered]@{
    "plugins/GG1MapChooser/GG1MapChooser.dll"         = Get-ReflectedList "GG1MapChooser"
    "plugins/PMM_GG1MapChooser/PMM_GG1MapChooser.dll" = Get-ReflectedList "PMM_GG1MapChooser"
    "plugins/CS2-SimpleAdmin/CS2-SimpleAdmin.dll"     = @("RegisterMenuCategory", "RegisterMenu", "UnregisterMenu", "CreateMenuWithBack", "AddMenuOption", "AddSubMenu", "LogCommand")
}

$branch = ("$(& git -C $repo rev-parse --abbrev-ref HEAD)").Trim()
if ($branch -in @("main", "master")) { throw "This repo is on '$branch'. Switch to a branch for updates first." }

& dotnet build $project --configuration Release --nologo -v quiet | Out-Null
if ($LASTEXITCODE -ne 0) { throw "ServerBundleCheck didn't build" }

foreach ($name in $Component) {
    & dotnet $tool update --repo $repo --work-dir $WorkDir --component $name
    if ($LASTEXITCODE -ne 0) { Write-Warning "$name could not be updated"; $failed = $true }
}

# Copy a folder into the bundle when its main DLL changed. Configs and lang files stay: GameModeManager ships its own wording.
foreach ($folder in $bundleFolders.Keys) {
    $source = Join-Path $repo "game/csgo/addons/counterstrikesharp/$folder"
    $target = Join-Path $gmm "bundle/csgo/addons/counterstrikesharp/$folder"
    if (-not (Test-Path $source)) { continue }
    $dll = $bundleFolders[$folder]
    if ((Test-Path (Join-Path $target $dll)) -and (Get-FileHash (Join-Path $source $dll)).Hash -eq (Get-FileHash (Join-Path $target $dll)).Hash) { continue }

    $sourceRoot = (Resolve-Path $source).Path
    foreach ($file in Get-ChildItem $sourceRoot -Recurse -File) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
        if ($relative -like 'lang/*') { continue }
        if ($relative -match '^runtimes/([^/]+)/' -and $keepRuntimes -notcontains $Matches[1]) { continue }
        $destination = Join-Path $target $relative
        if ((Test-Path $destination) -and (Get-FileHash $destination).Hash -eq (Get-FileHash $file.FullName).Hash) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        Write-Host "  bundle: $folder/$relative"
    }
}

# Checks
Write-Host "`nChecking the members GameModeManager reflects on..." -ForegroundColor Cyan
foreach ($dll in $reflected.Keys) {
    $path = Join-Path $repo "game/csgo/addons/counterstrikesharp/$dll"
    if (-not (Test-Path $path)) { Write-Warning "$dll not found"; $failed = $true; continue }
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    $missing = @($reflected[$dll] | Where-Object { $text.IndexOf($_, [StringComparison]::Ordinal) -lt 0 })
    if ($missing.Count -gt 0) { Write-Warning "$dll no longer has: $($missing -join ', ')"; $failed = $true }
    else { Write-Host "  ok: $dll" }
}

Write-Host "`nChecking the server bundle..." -ForegroundColor Cyan
& dotnet $tool check --repo $repo
if ($LASTEXITCODE -ne 0) { $failed = $true }

Write-Host "`nBuilding GameModeManager..." -ForegroundColor Cyan
& dotnet build (Join-Path $gmm "GameModeManager.sln") -c Release --nologo -v quiet
if ($LASTEXITCODE -ne 0) { $failed = $true }
& dotnet clean (Join-Path $gmm "GameModeManager.sln") -c Release --nologo -v quiet | Out-Null

Write-Host "`nChecking the addon and visuals..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "Check-Visuals.ps1") | ForEach-Object { Write-Output "TO DO: $_" }

if ($failed) { Write-Output "RESULT: PROBLEMS FOUND"; exit 1 }
Write-Output "RESULT: OK. Not committed or deployed."
