<#
.SYNOPSIS
Reports new plugin releases, GameModeManager bundle drift and new commits in kus's repo. Changes nothing in the repos.

.DESCRIPTION
Writes a short report to %USERPROFILE%\Documents\CS2\updates\latest.md and prints one result line:
"NO UPDATES" or "UPDATES: <n> plugin(s), <n> bundle, <n> kus commit(s)". The review skill only reads the report when
there is something in it, so a quiet week costs almost nothing.

.PARAMETER MarkKusReviewed
Records kus's current commit as reviewed, so the next report only lists newer ones.

.EXAMPLE
.\scripts\Check-Updates.ps1
.\scripts\Check-Updates.ps1 -MarkKusReviewed
#>
[CmdletBinding()]
param(
    [switch]$MarkKusReviewed,
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) "cs2-plugin-updates"),
    [string]$ReportPath = (Join-Path $env:USERPROFILE "Documents\CS2\updates\latest.md")
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$gmm = Join-Path (Split-Path -Parent $repo) "GameModeManager"
$project = Join-Path $repo "ci/ServerBundleCheck"
$tool = Join-Path $project "bin/Release/net10.0/ServerBundleCheck.dll"
$marker = Join-Path $PSScriptRoot "kus-reviewed.txt"

# Define what GameModeManager is built on: a new release of these needs a real review
$integrated = @("CounterStrikeSharp", "PanoramaMenuManager", "GG1MapChooser", "PMM_GG1MapChooser", "CS2-SimpleAdmin", "PMM_SimpleAdmin", "MultiAddonManager")

# Define what the report leaves out. GameModeManager's own release is older than its test builds until 2.0 is published.
$ignored = @("GameModeManager")

# Define the files GameModeManager's release carries, by component, and the DLL that shows each one's version
$bundled = [ordered]@{
    "PanoramaMenuManager" = "plugins/MenuManagerCore/MenuManagerCore.dll"
    "GG1MapChooser"       = "plugins/GG1MapChooser/GG1MapChooser.dll"
    "PMM_GG1MapChooser"   = "plugins/PMM_GG1MapChooser/PMM_GG1MapChooser.dll"
}

function Get-GitHubSources {
    $sources = @{}
    $name = $null
    foreach ($line in Get-Content (Join-Path $repo "plugins.yaml")) {
        if ($line -match '^\s+- name:\s*(.+?)\s*$') { $name = $Matches[1] }
        elseif ($name -and $line -match 'source:\s*\{\s*github:\s*([^\s,}]+)') { $sources[$name] = $Matches[1] }
    }
    return $sources
}

# First lines of the release notes: enough to spot what to look at, without the whole page
function Get-ReleaseNotes([string]$github) {
    $headers = @{ "User-Agent" = "cs2-check-updates" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
    try {
        # Windows PowerShell guesses the wrong encoding for GitHub's answer, so decode the bytes here
        $response = Invoke-WebRequest -UseBasicParsing -Uri "https://api.github.com/repos/$github/releases/latest" -Headers $headers -TimeoutSec 20
        $release = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
        $body = "$($release.body)".Trim()
        if ($body.Length -gt 1500) { $body = $body.Substring(0, 1500) + " ...(cut)" }
        return "$($release.html_url)`n`n$body"
    }
    catch { return "(release notes not available: $($_.Exception.Message))" }
}

& dotnet build $project --configuration Release --nologo -v quiet | Out-Null
if ($LASTEXITCODE -ne 0) { throw "ServerBundleCheck didn't build" }

# Kus: only the fetch and the marker; nothing is merged
& git -C $repo fetch upstream master --quiet
if ($LASTEXITCODE -ne 0) { throw "git fetch upstream failed" }
$kusHead = ("$(& git -C $repo rev-parse upstream/master)").Trim()
if ($MarkKusReviewed) {
    Set-Content -LiteralPath $marker -Value $kusHead -Encoding Ascii
    Write-Host "Marked kus's $($kusHead.Substring(0, 8)) as reviewed"
    exit 0
}

$sections = New-Object System.Collections.ArrayList

# Plugins
$plan = & dotnet $tool update --repo $repo --dry-run --no-download --work-dir $WorkDir
$planExit = $LASTEXITCODE
$rows = foreach ($line in $plan) {
    if ($line -match '^(update|pinned|error)\s+(.+?)\s{2,}(\S+)\s+->\s+(\S*)') {
        [PSCustomObject]@{ Status = $Matches[1]; Name = $Matches[2].Trim(); Current = $Matches[3]; Latest = $Matches[4] }
    }
}
$rows = @($rows)
$errors = @($plan | Where-Object { $_ -match '^error\s' })
# A pinned component whose latest release is older than what's installed isn't an update (PMM's AnyBaseLib stub is 1.0.0)
function Test-Older([string]$latest, [string]$current) {
    $a = $null; $b = $null
    return [version]::TryParse(($latest -replace '^[^\d]*', ''), [ref]$a) -and [version]::TryParse(($current -replace '^[^\d]*', ''), [ref]$b) -and $a -lt $b
}
$new = @($rows | Where-Object { $_.Status -ne "error" -and $ignored -notcontains $_.Name -and -not (Test-Older $_.Latest $_.Current) })
if ($new.Count -gt 0) {
    $sources = Get-GitHubSources
    [void]$sections.Add("## Plugin updates`n")
    foreach ($row in ($new | Sort-Object { $integrated -notcontains $_.Name }, Name)) {
        $kind = if ($integrated -contains $row.Name) { "INTEGRATED: review for breaking changes" } else { "other" }
        [void]$sections.Add("### $($row.Name): $($row.Current) -> $($row.Latest) ($kind, $($row.Status))`n")
        # A pinned plugin we don't build on stays pinned on purpose: the line is enough
        if ($sources.ContainsKey($row.Name) -and ($integrated -contains $row.Name -or $row.Status -eq "update")) { [void]$sections.Add((Get-ReleaseNotes $sources[$row.Name]) + "`n") }
    }
}
if ($errors.Count -gt 0 -or $planExit -ne 0) {
    [void]$sections.Add("## Update check errors`n`n" + (($errors | ForEach-Object { "- $_" }) -join "`n") + "`n")
}

# GameModeManager's bundle against the server repo
$drift = @()
foreach ($component in $bundled.Keys) {
    $path = "addons/counterstrikesharp/" + $bundled[$component]
    $server = Join-Path $repo "game/csgo/$path"
    $bundle = Join-Path $gmm "GameModeManager/lib/csgo/$path"
    if ((Test-Path $server) -and (Test-Path $bundle) -and (Get-FileHash $server).Hash -ne (Get-FileHash $bundle).Hash) { $drift += $component }
}
if ($drift.Count -gt 0) {
    [void]$sections.Add("## GameModeManager bundle differs from the server repo`n`n" + (($drift | ForEach-Object { "- $_" }) -join "`n") + "`n")
}

# Kus: what changed outside the plugin binaries, which plugins.yaml owns here
$kusBase = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { ("$(& git -C $repo merge-base HEAD upstream/master)").Trim() }
$kusCount = [int]("$(& git -C $repo rev-list --count "$kusBase..$kusHead")").Trim()
if ($kusCount -gt 0) {
    # Plugin version bumps and merges say nothing here, because plugins.yaml owns the plugins
    $commits = @(& git -C $repo log --no-merges --format="%h %s" "$kusBase..$kusHead" | Where-Object { $_ -notmatch '^\S+ -? ?UPDATED:' } | Select-Object -First 30)
    $files = @(& git -C $repo diff --name-status "$kusBase" "$kusHead" -- game/csgo/cfg game/csgo/gamemodes_server.txt game/csgo/subscribed_file_ids.txt | Select-Object -First 60)
    [void]$sections.Add("## Kus: $kusCount new commit(s) since $($kusBase.Substring(0, 8))`n`n" + (($commits | ForEach-Object { "- $_" }) -join "`n") + "`n`nCfg and map files changed ($($files.Count), at most 60 listed):`n`n" + (($files | ForEach-Object { "- $_" }) -join "`n") + "`n")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath) | Out-Null
$title = "# Update report $(Get-Date -Format 'yyyy-MM-dd')`n`n"
[IO.File]::WriteAllText($ReportPath, $title + ($sections -join "`n"), (New-Object Text.UTF8Encoding($false)))

if ($sections.Count -eq 0) {
    Write-Output "NO UPDATES"
}
else {
    Write-Output "UPDATES: $($new.Count) plugin(s), $($drift.Count) bundle, $kusCount kus commit(s). Report: $ReportPath"
}
