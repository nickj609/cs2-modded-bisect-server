# CS2 Server Stop Script for Bisect Hosting
# Stops a server using the Bisect Hosting API

param(
    [string]$ServerUuid,
    [string]$ApiKey
)

# Load helper functions
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\bisect.ps1"

# Initialize logging (default until server UUID known)
$script:LogTag = "stop"
$script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -LogTag $script:LogTag -MaxFiles 5

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

# Display banner
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " CS2 Server Stop - Bisect Hosting" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Status "Logging to: $script:LogFile"

# Get credentials
$credentials = Get-BisectCredentials

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
$script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -ServerUuid $ServerUuid -LogTag $script:LogTag -MaxFiles 5

# Use provided API key or credential manager key
if (!$ApiKey) {
    $ApiKey = $credentials.ApiKey
}

# Validate
if (!$ApiKey -or !$ServerUuid) {
    Write-Error-Status "Missing required API key or server UUID"
    exit 1
}

# Validate API key
Write-Status "Validating API key..."
if (-not (Test-BisectApiKey -ApiKey $ApiKey -ServerUuid $ServerUuid)) {
    Write-Error-Status "API key validation failed"
    exit 1
}
Write-Success "API key validated"

# Stop server
if (Stop-BisectServer -ServerUuid $ServerUuid -ApiKey $ApiKey) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Server Stop Complete!" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
    
    Write-Host "Server UUID: $ServerUuid" -ForegroundColor Cyan
    Write-Host "Logs saved to: $script:LogFile" -ForegroundColor Gray
    Write-Host ""
}
else {
    Write-Error-Status "Failed to stop server"
    exit 1
}
