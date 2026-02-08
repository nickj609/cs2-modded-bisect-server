# CS2 Server Update Script for Bisect Hosting
# Retrieves stored credentials and syncs latest files via SFTP
# Uses helper functions from helpers.ps1 for API and SFTP operations

param(
    [string]$ServerUuid,
    [string]$ApiKey,
    [string]$SftpHost,
    [string]$SftpPort,
    [string]$SftpUsername,
    [string]$SftpPassword,
    [switch]$UpdateCredentials,
    [switch]$CustomFilesOnly,
    [int]$LogRetention = 5
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

# Get credentials
$hasCredentialParams = $ApiKey -or $SftpHost -or $SftpPort -or $SftpUsername -or $SftpPassword
if ($hasCredentialParams) {
    $credentials = Set-BisectCredentials -ApiKey $ApiKey -SftpHost $SftpHost -SftpPort $SftpPort -SftpUsername $SftpUsername -SftpPassword $SftpPassword
}
elseif ($UpdateCredentials) {
    $credentials = Set-BisectCredentials
}
else {
    $credentials = Get-BisectCredentials
}

# Get server UUID if not provided
if (!$ServerUuid) {
    $ServerUuid = Get-DefaultServerUuid
    if ([string]::IsNullOrWhiteSpace($ServerUuid)) {
        Write-Host ""
        $ServerUuid = Read-Host "Enter Server UUID"
        $parsedUuid = [Guid]::Empty
        while (-not [Guid]::TryParse($ServerUuid, [ref]$parsedUuid)) {
            Write-Host "Invalid UUID format. Please paste the full server UUID from the Bisect panel." -ForegroundColor Yellow
            $ServerUuid = Read-Host "Enter Server UUID"
        }
    }
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
                          -RemotePath "/game/csgo") {
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
