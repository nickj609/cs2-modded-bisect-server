# CS2 Server Start Script for Bisect Hosting
# Starts a server using the Bisect Hosting API

param(
    [string]$ServerUuid,
    [string]$ApiKey
)

# Load helper functions
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\bisect.ps1"

# Initialize logging (default until server UUID known)
$script:LogTag = "start"
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
Write-Host " CS2 Server Start - Bisect Hosting" -ForegroundColor Cyan
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

# Start server
Write-Status "Starting server..."
try {
    Invoke-BisectApi -Endpoint "/servers/$ServerUuid/power" -Method "POST" -Body @{signal="start"} -ApiKey $ApiKey | Out-Null
    
    # Poll for started status (60 second timeout)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    while ($stopwatch.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Seconds 2
        
        try {
            $resources = Invoke-BisectApi -Endpoint "/servers/$ServerUuid/resources" -ApiKey $ApiKey
            $currentState = $resources.attributes.current_state
            
            # Check for common running states
            if ($currentState -in @("running", "online", "starting", "started")) {
                Write-Success "Server started (state: $currentState)"
                $started = $true
                break
            }
        }
        catch {
            # Continue polling
        }
    }
    
    if (-not $started) {
        Write-Host "[WARNING] Server state could not be confirmed within 60 seconds" -ForegroundColor Yellow
        Write-Host "Please check the Bisect panel to verify server status." -ForegroundColor Yellow
    }
}
catch {
    Write-Error-Status "Failed to start server: $_"
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Server Start Complete!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

Write-Host "Server UUID: $ServerUuid" -ForegroundColor Cyan
Write-Host "Logs saved to: $script:LogFile" -ForegroundColor Gray
Write-Host ""
