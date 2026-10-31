<#
.SYNOPSIS
Updates the plugins listed in plugins.yaml from their GitHub releases, then checks the result.

.DESCRIPTION
Builds ci/ServerBundleCheck and runs its 'update' command, then 'check'. Nothing is committed or deployed:
review the changes in GitHub Desktop, commit, and deploy with bisect/update.ps1.

Works in Windows PowerShell 5.1 and PowerShell 7 (GitHub Actions). Needs the .NET 10 SDK.

GitHub allows 60 API requests an hour without a token. Set GITHUB_TOKEN (or pass -GitHubToken) to raise that
to 5000. Release answers are cached in the work folder for 6 hours.

.PARAMETER DryRun
Download and map every update, report what would change, write nothing.

.PARAMETER Component
Update only this component (name as in plugins.yaml).

.PARAMETER Prune
Also delete files from before plugins.lock.json existed that an updated component no longer ships
(old runtimes, dropped dependencies). Review them first with -DryRun -Verbose.

.PARAMETER NoDownload
Only compare versions (fast; no downloads).

.EXAMPLE
.\scripts\Update-Plugins.ps1 -DryRun -Verbose
.\scripts\Update-Plugins.ps1 -Component MatchZy
.\scripts\Update-Plugins.ps1 -Prune
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Component,
    [switch]$Prune,
    [switch]$NoDownload,
    [string]$GitHubToken,
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) "cs2-plugin-updates"),
    [string]$SummaryPath
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repo "ci/ServerBundleCheck"
$tool = Join-Path $project "bin/Release/net10.0/ServerBundleCheck.dll"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet not found. Install the .NET 10 SDK: https://dotnet.microsoft.com/download"
}
if ($GitHubToken) { $env:GITHUB_TOKEN = $GitHubToken }

Write-Host "Building ServerBundleCheck..." -ForegroundColor Cyan
& dotnet build $project --configuration Release --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

if (-not (Test-Path (Join-Path $repo "plugins.lock.json"))) {
    Write-Host "No plugins.lock.json yet: recording what is installed now." -ForegroundColor Yellow
    & dotnet $tool lock --init --repo $repo
    if ($LASTEXITCODE -ne 0) { throw "lock --init failed" }
}

$updateArgs = @("update", "--repo", $repo, "--work-dir", $WorkDir)
if ($DryRun) { $updateArgs += "--dry-run" }
if ($NoDownload) { $updateArgs += "--no-download" }
if ($Prune) { $updateArgs += "--prune" }
if ($Component) { $updateArgs += @("--component", $Component) }
if ($SummaryPath) { $updateArgs += @("--summary", $SummaryPath) }
if ($VerbosePreference -eq "Continue") { $updateArgs += "--verbose" }

Write-Host ""
& dotnet $tool @updateArgs
$updateExit = $LASTEXITCODE

Write-Host ""
Write-Host "Checking the server bundle..." -ForegroundColor Cyan
& dotnet $tool check --repo $repo
$checkExit = $LASTEXITCODE

if ($updateExit -ne 0) { Write-Warning "Some components could not be updated (see 'error' lines above)." }
if ($checkExit -ne 0) { Write-Warning "ServerBundleCheck found errors. Fix them before committing." }
if (-not $DryRun -and $updateExit -eq 0 -and $checkExit -eq 0) {
    Write-Host "Done. Review the changes in GitHub Desktop, commit, then deploy." -ForegroundColor Green
}
exit ([Math]::Max($updateExit, $checkExit))
