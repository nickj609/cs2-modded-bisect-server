# CS2 Server Update Script for Bisect Hosting
# Retrieves stored credentials and syncs latest files via SFTP
# Uses helper functions from helpers.ps1 for API and SFTP operations

param(
    [string]$Server,               # name from servers-config.json (uses that server's own credentials)
    [string]$ServerUuid,
    [string]$ApiKey,
    [string]$SftpHost,
    [string]$SftpPort,
    [string]$SftpUsername,
    [string]$SftpPassword,
    [switch]$UpdateCredentials,
    [switch]$CustomFilesOnly,
    [int]$LogRetention = 5,
    # Deletions: files removed from the repo since the deployed commit are deleted on the server (WinSCP).
    [string]$SinceCommit,          # baseline instead of the commit recorded on the server (first deploy: what's on it now, e.g. master)
    [switch]$AllowLargeDelete,     # allow deleting more than 25% of the tracked files
    [switch]$TestBuild,            # from test-build.ps1: its GameModeManager install isn't an uncommitted change to warn about
    [switch]$PlanDeletions,        # only list what would be deleted; don't stop the server or upload
    [switch]$NoDeletions           # upload only, like before (the deployed commit is not recorded)
)

# Load credential manager and helper functions
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\bisect.ps1"

# Initialize logging (default until server UUID known)
$script:LogTag = "update"
$script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -LogTag $script:LogTag -MaxFiles $LogRetention

function Write-Status {
    param([string]$Message)
    Write-Log $Message -Level Info -LogFile $script:LogFile
}

function Write-Success {
    param([string]$Message)
    Write-Log $Message -Level Success -LogFile $script:LogFile
}

function Write-Error-Status {
    param([string]$Message)
    Write-Log $Message -Level Error -LogFile $script:LogFile
}

# Display banner (ASCII to avoid encoding issues)
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " CS2 Server Update - Bisect Hosting" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Status "Logging to: $script:LogFile"

# Work out the server and its credentials (servers-config.json + per-server credentials, or the old single set)
try {
    $target = Resolve-TargetServer -Server $Server -ServerUuid $ServerUuid
}
catch {
    Write-Error-Status "$_"
    exit 1
}
$ServerUuid = $target.Uuid
$credentials = $target.Credentials
Write-Status "Server: $($target.Name) ($($target.Role)) $ServerUuid"

$hasCredentialParams = $ApiKey -or $SftpHost -or $SftpPort -or $SftpUsername -or $SftpPassword
if ($target.Legacy) {
    # Old single-server behaviour
    if ($hasCredentialParams) {
        $credentials = Set-BisectCredentials -ApiKey $ApiKey -SftpHost $SftpHost -SftpPort $SftpPort -SftpUsername $SftpUsername -SftpPassword $SftpPassword
    }
    elseif ($UpdateCredentials) {
        $credentials = Set-BisectCredentials
    }
}
elseif ($hasCredentialParams -or $UpdateCredentials) {
    $credentials = Read-ServerCredentialsInteractive -Name $target.Name -ApiKey $ApiKey -SftpHost $SftpHost -SftpPort $SftpPort `
                                                     -SftpUsername $SftpUsername -SftpPassword $SftpPassword
    Save-ServerCredentials -Name $target.Name @credentials
    Write-Success "Credentials for '$($target.Name)' updated"
}

# Update log path now that ServerUuid is known
$script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -ServerUuid $ServerUuid -LogTag $script:LogTag -MaxFiles $LogRetention

# Validate
if (!$credentials.ApiKey -or !$ServerUuid -or !$credentials.SftpHost) {
    Write-Error-Status "Missing required credentials or server UUID"
    exit 1
}

# Validate credentials
Write-Status "Validating API key..."
if (-not (Test-BisectApiKey -ApiKey $credentials.ApiKey -ServerUuid $ServerUuid)) {
    Write-Error-Status "API key validation failed"
    exit 1
}
Write-Success "API key validated"
Write-Status "Testing SFTP connection..."
if (-not (Test-SftpConnection -SftpHost $credentials.SftpHost `
                              -SftpPort $credentials.SftpPort `
                              -SftpUsername $credentials.SftpUsername `
                              -SftpPassword $credentials.SftpPassword)) {
    Write-Host '[WARNING] SFTP validation skipped - WinSCP not available or connection failed' -ForegroundColor Yellow
}
else {
    Write-Success "SFTP connection validated"
}

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$syncRepoRoot = if ($NoDeletions) { $null } else { $repoRoot }

# Preview deletions without touching the server
if ($PlanDeletions) {
    Write-Status "Planning deletions (the server is not stopped, nothing is uploaded)..."
    $ok = Sync-FilesViaSftp -SftpHost $credentials.SftpHost `
                            -SftpPort $credentials.SftpPort `
                            -SftpUsername $credentials.SftpUsername `
                            -SftpPassword $credentials.SftpPassword `
                            -LocalPath "$repoRoot\game\csgo" `
                            -RemotePath "/game/csgo" `
                            -RepoRoot $repoRoot -SinceCommit $SinceCommit -AllowLargeDelete:$AllowLargeDelete -TestBuild:$TestBuild -PlanDeletions
    if ($ok) { exit 0 } else { exit 1 }
}

# Stop server
if (!(Stop-BisectServer -ServerUuid $ServerUuid -ApiKey $credentials.ApiKey)) {
    Write-Error-Status "Failed to stop server"
    exit 1
}
# Sync files
if (-not $CustomFilesOnly) {
    Write-Status "Syncing mod files to server via SFTP..."
    $repoPath = "$PSScriptRoot\..\game\csgo"

    if (-not (Test-Path $repoPath)) {
        Write-Error-Status "Local mod path not found: $repoPath"
        exit 1
    }

    if (Sync-FilesViaSftp -SftpHost $credentials.SftpHost `
                          -SftpPort $credentials.SftpPort `
                          -SftpUsername $credentials.SftpUsername `
                          -SftpPassword $credentials.SftpPassword `
                          -LocalPath $repoPath `
                          -RemotePath "/game/csgo" `
                          -RepoRoot $syncRepoRoot `
                          -SinceCommit $SinceCommit `
                          -AllowLargeDelete:$AllowLargeDelete -TestBuild:$TestBuild) {
        Write-Success "Files synced successfully"
    }
    else {
        Write-Error-Status "File sync failed"
        exit 1
    }
} else {
    Write-Status "Custom files only mode enabled. Skipping mod file sync."
}

# Sync custom_files overrides
if (!(Sync-CustomFiles -SftpHost $credentials.SftpHost `
                       -SftpPort $credentials.SftpPort `
                       -SftpUsername $credentials.SftpUsername `
                       -SftpPassword $credentials.SftpPassword `
                       -ServerUuid $ServerUuid)) {
    Write-Error-Status "Failed to sync custom files"
    exit 1
}
# Start server
Write-Status "Starting server..."
try {
    Invoke-BisectApi -Endpoint "/servers/$ServerUuid/power" -Method "POST" -ApiKey $credentials.ApiKey -Body @{signal="start"} | Out-Null
    Write-Success "Server started"
}
catch {
    Write-Error-Status "Failed to start server: $_"
    Write-Host "[WARNING] Server may need to be started manually from Bisect panel" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Update Complete!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

Write-Host "Your server is now updated with the latest mod files." -ForegroundColor Cyan
Write-Host "Logs saved to: $script:LogFile" -ForegroundColor Gray
Write-Host ""
