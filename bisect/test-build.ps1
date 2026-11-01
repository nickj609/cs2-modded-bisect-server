# One command from local code to a running test server:
#   1. builds GameModeManager from the sibling repo, as the same zip a release publishes
#   2. installs that zip into this repo's game/csgo (not committed; marked <version>-test.<commit> in plugins.yaml)
#   3. runs ServerBundleCheck
#   4. deploys to the test server and waits until it runs
# Production is never touched. The weekly plugin update replaces the test build with the next real release.
#
#   .\test-build.ps1 -Plan                     # build and show what would change; nothing is written or uploaded
#   .\test-build.ps1 -FirstDeploy              # first time on a new server
#   .\test-build.ps1                           # every time after that

param(
    [string]$Server,                # name from servers-config.json; default: the only server with role "test"
    [string]$GameModeManagerRepo,   # default: ..\..\GameModeManager next to this repo
    [switch]$Plan,
    [switch]$FirstDeploy,           # start tracking deletions on a server that has no deployed commit yet
    [int]$HealthTimeout = 300,
    [int]$LogRetention = 5
)

. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\bisect.ps1"

$script:LogTag = "test-build"
$script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -LogTag $script:LogTag -MaxFiles $LogRetention

function Write-Status { param([string]$Message) Write-Log $Message -Level Info -LogFile $script:LogFile }
function Write-Success { param([string]$Message) Write-Log $Message -Level Success -LogFile $script:LogFile }
function Stop-WithError { param([string]$Message) Write-Log $Message -Level Error -LogFile $script:LogFile; exit 1 }

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$git = Resolve-GitExe
if (-not $git) { Stop-WithError "git not found" }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Stop-WithError "dotnet not found" }

# A test build must not land on the branch production deploys from
$branch = ("$(& $git -C $repoRoot rev-parse --abbrev-ref HEAD)").Trim()
if ($branch -in @("main", "master") -and -not $Plan) {
    Stop-WithError "This repo is on '$branch'. Switch to a feature branch (e.g. bisect or test) before installing a test build."
}

# The test server: never one with role production
$entry = $null
$servers = @(Read-ServerConfig -ConfigPath (Get-ServersConfigPath) | Where-Object { $_ })
if ($Server) {
    $entry = $servers | Where-Object { $_.name -eq $Server } | Select-Object -First 1
    if (-not $entry) { Stop-WithError "No server '$Server' in servers-config.json. Add it: .\install.ps1 -AddServer $Server -Role test" }
    if ((Get-ServerRole $entry) -ne "test") { Stop-WithError "'$Server' has role '$(Get-ServerRole $entry)': this script only deploys to test servers." }
}
else {
    $testServers = @($servers | Where-Object { (Get-ServerRole $_) -eq "test" })
    if ($testServers.Count -eq 1) { $entry = $testServers[0] }
    elseif ($testServers.Count -gt 1) { Stop-WithError "Several test servers: pick one with -Server ($(@($testServers | ForEach-Object { $_.name }) -join ', '))" }
    elseif (-not $Plan) { Stop-WithError "No test server yet. Add it: .\install.ps1 -AddServer test -Role test" }
}
if ($entry) { Write-Status "Test server: $($entry.name) $($entry.uuid)" }

# GameModeManager 2.0 does nothing useful without GG1MapChooser loaded
$gg1 = Join-Path $repoRoot "game\csgo\addons\counterstrikesharp\plugins\GG1MapChooser\GG1MapChooser.dll"
if (-not (Test-Path $gg1)) {
    $message = "GG1MapChooser isn't in plugins/ yet (still in plugins/disabled/): the go-live changes on this branch come first. See docs/GG1_MAPCHOOSER_SETUP.md."
    if ($Plan) { Write-Host "[WARNING] $message" -ForegroundColor Yellow } else { Stop-WithError $message }
}

# 1. Build the release package
if (-not $GameModeManagerRepo) { $GameModeManagerRepo = Join-Path $repoRoot "..\GameModeManager" }
if (-not (Test-Path (Join-Path $GameModeManagerRepo "GameModeManager.sln"))) { Stop-WithError "GameModeManager repo not found at $GameModeManagerRepo" }
$GameModeManagerRepo = (Resolve-Path $GameModeManagerRepo).Path
$packager = Join-Path $GameModeManagerRepo ".github\scripts\package-release.ps1"
if (-not (Test-Path $packager)) { Stop-WithError "$packager not found: is GameModeManager on the pmm-migration branch?" }

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "cs2-test-build"
Write-Status "Building GameModeManager from $GameModeManagerRepo ($("$(& $git -C $GameModeManagerRepo rev-parse --abbrev-ref HEAD)".Trim()))..."
try { $zip = & $packager -OutDir $workDir | Select-Object -Last 1 }
catch { Stop-WithError "Build failed: $_" }
Write-Success "Built $(Split-Path $zip -Leaf)"

$version = [regex]::Match((Split-Path $zip -Leaf), 'GameModeManager_v(.+)\.zip').Groups[1].Value
$commit = ("$(& $git -C $GameModeManagerRepo rev-parse --short HEAD)").Trim()
$testVersion = "$version-test.$commit"

# 2. Install it into game/csgo, through the same mapping and placement rules as a release
$checker = Join-Path $repoRoot "ci\ServerBundleCheck"
& dotnet build $checker --configuration Release --nologo -v quiet | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-WithError "ServerBundleCheck didn't build" }
$checkerDll = Join-Path $checker "bin\Release\net10.0\ServerBundleCheck.dll"

$updateArgs = @($checkerDll, "update", "--repo", $repoRoot, "--component", "GameModeManager", "--from-zip", $zip,
                "--version", $testVersion, "--prune", "--work-dir", (Join-Path $workDir "updates"))
if ($Plan) { $updateArgs += "--dry-run" }
& dotnet @updateArgs
if ($LASTEXITCODE -ne 0) { Stop-WithError "Installing the test build failed" }

if ($Plan) {
    if ($entry) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "update.ps1") -Server "$($entry.name)" -PlanDeletions -TestBuild
    }
    Write-Success "Plan finished: nothing was written or uploaded"
    exit 0
}

# 3. Check
& dotnet $checkerDll check --repo $repoRoot
if ($LASTEXITCODE -ne 0) { Stop-WithError "ServerBundleCheck found errors; nothing deployed." }
Write-Success "ServerBundleCheck passed"

# 4. Deploy to the test server only
$deployArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "update.ps1"),
                "-Server", "$($entry.name)", "-LogRetention", "$LogRetention", "-TestBuild")
if ($FirstDeploy) { $deployArgs += @("-SinceCommit", "HEAD", "-AllowLargeDelete") }
& powershell.exe @deployArgs
if ($LASTEXITCODE -ne 0) { Stop-WithError "Deploy to '$($entry.name)' failed" }

try { $creds = Get-ServerCredentials -Name "$($entry.name)" -Role (Get-ServerRole $entry) -NoPrompt }
catch { Stop-WithError "$_" }
Write-Status "Waiting for '$($entry.name)' to report running (up to $HealthTimeout s)..."
if (-not (Wait-BisectServerRunning -ServerUuid "$($entry.uuid)" -ApiKey $creds.ApiKey -TimeoutSeconds $HealthTimeout)) {
    Stop-WithError "'$($entry.name)' did not come up"
}
Write-Success "GameModeManager $testVersion is on '$($entry.name)'"

Write-Host ""
Write-Host "Check on the server console:" -ForegroundColor Cyan
Write-Host "  meta list                 Metamod and CounterStrikeSharp loaded"
Write-Host "  css_plugins list          GameModeManager, GG1_MapChooser, both bridges, CS2-SimpleAdmin"
Write-Host "  css_pmm_gg1               GG1 bridge patches applied"
Write-Host "  css_pmm_sa status         SimpleAdmin bridge patches applied"
Write-Host "In game:" -ForegroundColor Cyan
Write-Host "  !mode surf, then !nominate   only surf maps"
Write-Host "  !rtv, !game, !changemode, !maps, !modes, !warmup, !admin, !map de_dust2"
exit 0
