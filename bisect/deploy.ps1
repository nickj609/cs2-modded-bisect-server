# CS2 Server Deploy for Bisect Hosting: test servers first, then production
#
# 1. (optional -Pull) git pull --ff-only, so plugin-update PRs merged on GitHub are included
# 2. ServerBundleCheck (needs the .NET SDK; skipped with a warning if dotnet is missing)
# 3. update.ps1 -Server <name> for every "role": "test" server in servers-config.json, then wait until the Bisect
#    API reports it running
# 4. only if every test server passed: update.ps1 -Server <name> for every production server
#
# Each server uses its own credentials (install.ps1 -AddServer <name>). Deletions and the deployed-commit marker
# work per server (see README, "Deleted files").

param(
    [switch]$Pull,                 # git pull --ff-only first (aborts on local changes)
    [switch]$SkipCheck,            # don't run ServerBundleCheck
    [switch]$SkipTest,             # deploy production even without a passing test server
    [switch]$PlanDeletions,        # only show what each server would delete; nothing is stopped or uploaded
    [string]$SinceCommit,          # passed to update.ps1 for every server (first deploy with deletions)
    [switch]$AllowLargeDelete,     # passed to update.ps1
    [int]$HealthTimeout = 300,     # seconds to wait for a test server to report "running"
    [int]$LogRetention = 5,
    # Scheduled task for this script (replaces per-server update tasks)
    [switch]$RegisterTask,
    [ValidateSet("Daily", "Weekly", "Monthly")] [string]$Schedule = "Weekly",
    [string]$Day = "Monday",
    [string]$Time = "04:00"
)

. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\bisect.ps1"

$script:LogTag = "deploy"
$script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -LogTag $script:LogTag -MaxFiles $LogRetention

function Write-Status { param([string]$Message) Write-Log $Message -Level Info -LogFile $script:LogFile }
function Write-Success { param([string]$Message) Write-Log $Message -Level Success -LogFile $script:LogFile }
function Write-Error-Status { param([string]$Message) Write-Log $Message -Level Error -LogFile $script:LogFile }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " CS2 Deploy - test, then production" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Status "Logging to: $script:LogFile"

if ($RegisterTask) {
    $taskArgs = "-Pull -LogRetention $LogRetention"
    if ($Schedule -eq "Daily") { $Day = "" }
    if (New-ScheduledUpdateTask -TaskName "CS2 Deploy (test then production)" -Schedule $Schedule -Day $Day -Time $Time `
                                -ScriptName "deploy.ps1" -Arguments $taskArgs) {
        Write-Host "Remove older per-server tasks with: .\uninstall.ps1" -ForegroundColor Gray
        exit 0
    }
    exit 1
}

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

# Servers
$configTest = Test-ServerConfig -ConfigPath (Get-ServersConfigPath)
if (-not $configTest.IsValid) {
    Write-Error-Status "servers-config.json: $($configTest.Message). Add servers with .\install.ps1 -AddServer <name>"
    exit 1
}
$servers = @(Read-ServerConfig -ConfigPath (Get-ServersConfigPath) | Where-Object { $_ })
$testServers = @($servers | Where-Object { (Get-ServerRole $_) -eq "test" })
$prodServers = @($servers | Where-Object { (Get-ServerRole $_) -eq "production" })
Write-Status "Test: $(@($testServers | ForEach-Object { $_.name }) -join ', ')   Production: $(@($prodServers | ForEach-Object { $_.name }) -join ', ')"

# 1. Pull
if ($Pull) {
    $git = Resolve-GitExe
    if (-not $git) { Write-Error-Status "git not found"; exit 1 }
    if (& $git -C $repoRoot status --porcelain) {
        Write-Error-Status "The repo has uncommitted changes; not pulling. Commit or discard them first."
        exit 1
    }
    & $git -C $repoRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { Write-Error-Status "git pull --ff-only failed"; exit 1 }
    Write-Success "Pulled $((& $git -C $repoRoot rev-parse --short HEAD))"
}

# 2. Bundle check
if (-not $SkipCheck) {
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $project = Join-Path $repoRoot "ci/ServerBundleCheck"
        Write-Status "Running ServerBundleCheck..."
        & dotnet build $project --configuration Release --nologo -v quiet | Out-Null
        & dotnet (Join-Path $project "bin/Release/net10.0/ServerBundleCheck.dll") check --repo $repoRoot
        if ($LASTEXITCODE -ne 0) {
            Write-Error-Status "ServerBundleCheck found errors; nothing deployed."
            exit 1
        }
        Write-Success "ServerBundleCheck passed"
    }
    else {
        Write-Host "[WARNING] dotnet not found: ServerBundleCheck skipped" -ForegroundColor Yellow
    }
}

function Invoke-ServerUpdate {
    param($Entry)

    $updateArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "update.ps1"),
                    "-Server", "$($Entry.name)", "-LogRetention", "$LogRetention")
    if ($PlanDeletions) { $updateArgs += "-PlanDeletions" }
    if ($SinceCommit) { $updateArgs += @("-SinceCommit", $SinceCommit) }
    if ($AllowLargeDelete) { $updateArgs += "-AllowLargeDelete" }

    Write-Status "---- $($Entry.name) ($((Get-ServerRole $Entry))) ----"
    & powershell.exe @updateArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Status "update.ps1 failed for '$($Entry.name)' (exit $LASTEXITCODE)"
        return $false
    }
    if ($PlanDeletions) { return $true }

    try { $creds = Get-ServerCredentials -Name "$($Entry.name)" -Role (Get-ServerRole $Entry) -NoPrompt }
    catch { Write-Error-Status "$_"; return $false }
    Write-Status "Waiting for '$($Entry.name)' to report running (up to $HealthTimeout s)..."
    if (-not (Wait-BisectServerRunning -ServerUuid "$($Entry.uuid)" -ApiKey $creds.ApiKey -TimeoutSeconds $HealthTimeout)) {
        Write-Error-Status "'$($Entry.name)' did not come up"
        return $false
    }
    Write-Success "'$($Entry.name)' is running"
    return $true
}

# 3. Test servers
if ($testServers.Count -eq 0) {
    if ($SkipTest -or $PlanDeletions) { Write-Status "No test server configured" }
    else {
        Write-Host "[WARNING] No test server in servers-config.json: deploying production after the checks only." -ForegroundColor Yellow
    }
}
foreach ($t in $testServers) {
    if (-not (Invoke-ServerUpdate -Entry $t)) {
        if ($SkipTest) {
            Write-Host "[WARNING] Test server '$($t.name)' failed; continuing because of -SkipTest" -ForegroundColor Yellow
        }
        else {
            Write-Error-Status "Test server '$($t.name)' failed: production NOT deployed."
            exit 1
        }
    }
}

# 4. Production
$failed = 0
foreach ($p in $prodServers) {
    if (-not (Invoke-ServerUpdate -Entry $p)) { $failed++ }
}

if ($failed -gt 0) {
    Write-Error-Status "$failed production server(s) failed"
    exit 1
}
Write-Success "Deploy finished"
exit 0
