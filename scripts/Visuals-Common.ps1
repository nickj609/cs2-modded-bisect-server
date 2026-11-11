# Shared by bisect\build-menu-images.ps1, Check-Visuals.ps1, and GameModeManager's tools\build-menu-addon.ps1 and tools\render-visuals.ps1.
# Runs on Windows PowerShell 5.1.

$script:VisualsDir = Join-Path $env:USERPROFILE "Documents\CS2\addon-images"
$script:AddonStamp = Join-Path $script:VisualsDir "addon-build.json"
$script:RenderStamp = Join-Path $script:VisualsDir "visuals-render.json"

# The addon's theme, footers, mockups and build script are in GameModeManager, next to this repo
function Get-GameModeManagerRepo([string]$Repo) {
    return Join-Path (Split-Path -Parent $Repo) "GameModeManager"
}

# Every map in gamemodes_server.txt: name -> workshop ID, "" for an official map. The same rule as GameModeManager's MapGroupManager.
function Get-ServerMaps([string]$Repo) {
    $text = [IO.File]::ReadAllText((Join-Path $Repo "game\csgo\gamemodes_server.txt"), [Text.Encoding]::UTF8)
    $maps = [ordered]@{}
    foreach ($block in [regex]::Matches($text, '"maps"\s*\{(.*?)\}', 'Singleline')) {
        foreach ($entry in [regex]::Matches($block.Groups[1].Value, '"([^"]+)"\s*"[^"]*"')) {
            $key = $entry.Groups[1].Value
            if ($key -match '^workshop/(\d+)') { $maps[($key -split '/')[-1]] = $Matches[1] }
            elseif (-not $maps.Contains($key)) { $maps[$key] = "" }
        }
    }
    return $maps
}

# A component's version in plugins.yaml
function Get-PluginVersion([string]$Repo, [string]$Name) {
    $current = $null
    foreach ($line in Get-Content (Join-Path $Repo "plugins.yaml")) {
        if ($line -match '^\s+- name:\s*(.+?)\s*$') { $current = $Matches[1] }
        elseif ($current -eq $Name -and $line -match '^\s+version:\s*"?([^"\s]+)"?') { return $Matches[1] }
    }
    return ""
}

function Get-TextHash([string[]]$Parts) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Parts -join "`n")))) -replace '-', '' }
    finally { $sha.Dispose() }
}

function Get-FilesHash([string[]]$Files) {
    return Get-TextHash @($Files | ForEach-Object { if (Test-Path -LiteralPath $_) { (Get-FileHash -LiteralPath $_).Hash } else { "missing" } })
}

# What the addon is built from. A change to any of these means it needs building and uploading again.
function Get-AddonInputsHash([string]$Repo) {
    $gmm = Get-GameModeManagerRepo $Repo
    $files = @("addon\menu_theme.css", "addon\vote_footer.css", "addon\admin_theme.css", "tools\build-menu-addon.ps1",
        "addon\images\notify_ok.png", "addon\images\notify_warn.png", "addon\images\notify_err.png") | ForEach-Object { Join-Path $gmm $_ }
    $versions = @("PanoramaMenuManager", "PMM_GG1MapChooser", "PMM_SimpleAdmin") | ForEach-Object { Get-PluginVersion $Repo $_ }
    $pictures = ""
    $manifest = Join-Path $script:VisualsDir "images.json"
    if (Test-Path $manifest) {
        $images = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $pictures = (@($images.maps.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) + @($images.modes.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" })) -join ";"
    }
    return Get-TextHash (@((Get-FilesHash $files)) + $versions + @($pictures))
}

# What the screenshots and thumbnail are drawn from
function Get-VisualsInputsHash([string]$Repo) {
    $gmm = Get-GameModeManagerRepo $Repo
    return Get-FilesHash (@("addon\mockups\scenes.html", "addon\mockups\thumbnail.html", "addon\menu_theme.css", "addon\vote_footer.css", "addon\admin_theme.css") | ForEach-Object { Join-Path $gmm $_ })
}

function Write-Stamp([string]$Path, [string]$Hash) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $stamp = @{ hash = $Hash; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json
    [IO.File]::WriteAllText($Path, $stamp, (New-Object Text.UTF8Encoding($false)))
}

function Read-Stamp([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}
