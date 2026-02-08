# CS2 Server Installation Script for Bisect Hosting
# Deploys server files and stores credentials for future updates
# Supports both single-server and multi-server modes

param(
    [string]$ApiKey,
    [string]$SftpHost,
    [string]$SftpPort,
    [string]$SftpUsername,
    [string]$SftpPassword,
    [string]$ServerUuid,
    [switch]$UpdateCredentials,
    [switch]$UpdateApiKeyOnly,
    [switch]$MultiServer
)

# Load credential manager functions
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\bisect.ps1"

# Initialize logging (default until server UUID known)
$script:LogTag = "install"
$script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -LogTag $script:LogTag -MaxFiles 5
$script:Credentials = $null
$script:ServersToProcess = @()

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

# Main script
Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host "CS2 Modded Server Installation - Bisect Hosting" -ForegroundColor Cyan
Write-Host "================================================`n" -ForegroundColor Cyan
Write-Status "Logging to: $script:LogFile"
# Handle API key update only
if ($UpdateApiKeyOnly) {
    Write-Host ""
    $result = Update-BisectApiKey
    if ($result) {
        Write-Success "API key has been updated in Credential Manager"
        Write-Host ""
        Write-Host "Your SFTP host, port, username, and password remain unchanged." -ForegroundColor Green
    }
    exit 0
}

# Check if user wants single or multi-server installation
Write-Host ""
Write-Host "Installation Mode:" -ForegroundColor Yellow
Write-Host "  1. Single Server (deploy to one server)"
Write-Host "  2. Multiple Servers (deploy to multiple servers via config)"
$modeChoice = Read-Host "Select mode - 1 or 2 (default: 1)"
if (!$modeChoice) { $modeChoice = "1" }

# Single server mode (original flow)
Write-Host ""

# Get credentials
$hasCredentialParams = $ApiKey -or $SftpHost -or $SftpPort -or $SftpUsername -or $SftpPassword
if ($hasCredentialParams) {
    Write-Status "Using provided credentials"
    $script:Credentials = Set-BisectCredentials -ApiKey $ApiKey -SftpHost $SftpHost -SftpPort $SftpPort -SftpUsername $SftpUsername -SftpPassword $SftpPassword
    if ($ServerUuid) {
        $script:Credentials["ServerUuid"] = $ServerUuid
    }
    if (-not $MultiServer) {
        if (-not $ServerUuid) {
            $ServerUuid = Get-DefaultServerUuid
            if ([string]::IsNullOrWhiteSpace($ServerUuid)) {
                $ServerUuid = Read-Host "Enter Server UUID"
                $parsedUuid = [Guid]::Empty
                while (-not [Guid]::TryParse($ServerUuid, [ref]$parsedUuid)) {
                    Write-Host "Invalid UUID format. Please paste the full server UUID from the Bisect panel." -ForegroundColor Yellow
                    $ServerUuid = Read-Host "Enter Server UUID"
                }
            }
        }
        $script:Credentials["ServerUuid"] = $ServerUuid
        $script:ServersToProcess = @(@{ uuid = $ServerUuid; name = "Single Server" })
        Set-DefaultServerUuid -ServerUuid $ServerUuid | Out-Null
    }
}
elseif ($UpdateCredentials) {
    $script:Credentials = Set-BisectCredentials
    if (!$MultiServer) {
        $serverUuid = Get-DefaultServerUuid
        if ([string]::IsNullOrWhiteSpace($serverUuid)) {
            $serverUuid = Read-Host "Enter Server UUID"
            $parsedUuid = [Guid]::Empty
            while (-not [Guid]::TryParse($serverUuid, [ref]$parsedUuid)) {
                Write-Host "Invalid UUID format. Please paste the full server UUID from the Bisect panel." -ForegroundColor Yellow
                $serverUuid = Read-Host "Enter Server UUID"
            }
        }
        $script:Credentials["ServerUuid"] = $serverUuid
        $script:ServersToProcess = @(@{ uuid = $serverUuid; name = "Single Server" })
        Set-DefaultServerUuid -ServerUuid $serverUuid | Out-Null
    }
}
else {
    Write-Status "Checking Credential Manager..."
    $script:Credentials = Get-BisectCredentials
    if (!$MultiServer) {
        $serverUuid = Get-DefaultServerUuid
        if ([string]::IsNullOrWhiteSpace($serverUuid)) {
            $serverUuid = Read-Host "Enter Server UUID"
            $parsedUuid = [Guid]::Empty
            while (-not [Guid]::TryParse($serverUuid, [ref]$parsedUuid)) {
                Write-Host "Invalid UUID format. Please paste the full server UUID from the Bisect panel." -ForegroundColor Yellow
                $serverUuid = Read-Host "Enter Server UUID"
            }
        }
        $script:Credentials["ServerUuid"] = $serverUuid
        $script:ServersToProcess = @(@{ uuid = $serverUuid; name = "Single Server" })
        Set-DefaultServerUuid -ServerUuid $serverUuid | Out-Null
    }
}

# Handle multi-server mode
if ($MultiServer) {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "Multi-Server Mode Enabled" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Check for servers-config.json
    $configPath = Join-Path $PSScriptRoot "../servers-config.json"
    
    if (-not (Test-Path $configPath)) {
        Write-Error-Status "servers-config.json not found at $configPath"
        Write-Host "Create servers-config.json with the following template:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host (Get-ConfigTemplate) -ForegroundColor Gray
        exit 1
    }
    
    # Validate config
    $configTest = Test-ServerConfig -ConfigPath $configPath
    if (-not $configTest.IsValid) {
        Write-Error-Status "Invalid configuration: $($configTest.Message)"
        exit 1
    }
    
    # Load servers from config
    $servers = Read-ServerConfig -ConfigPath $configPath
    $script:ServersToProcess = $servers
    
    Write-Success "Loaded $($configTest.ServerCount) server(s) from configuration"
    Write-Host ""
}

# Validate
if (!$script:Credentials.ApiKey -or ($script:ServersToProcess.Count -eq 0)) {
    Write-Error-Status "Missing required API key or server configuration"
    exit 1
}

# Validate credentials before proceeding
Write-Status "Validating credentials..."
Write-Status "Testing API key..."
$validationUuid = $script:Credentials.ServerUuid
if ([string]::IsNullOrWhiteSpace($validationUuid) -and $script:ServersToProcess.Count -gt 0) {
    $validationUuid = $script:ServersToProcess[0].uuid
}

if (-not (Test-BisectApiKey -ApiKey $script:Credentials.ApiKey -ServerUuid $validationUuid)) {
    Write-Error-Status "API key validation failed. Please check your API key."
    $retryChoice = Read-Host "Try different credentials? (y/n)"
    if ($retryChoice -eq 'y' -or $retryChoice -eq 'Y') {
        $script:Credentials = Set-BisectCredentials
        if (-not (Test-BisectApiKey -ApiKey $script:Credentials.ApiKey -ServerUuid $validationUuid)) {
            Write-Error-Status "API key still invalid. Aborting."
            exit 1
        }
    } else {
        exit 1
    }
}
Write-Success "API key validated"
Write-Status "Testing SFTP connection..."
if ($script:Credentials.SftpHost -and $script:Credentials.SftpUsername -and $script:Credentials.SftpPassword) {
    if (Test-SftpConnection -SftpHost $script:Credentials.SftpHost -SftpPort $script:Credentials.SftpPort -SftpUsername $script:Credentials.SftpUsername -SftpPassword $script:Credentials.SftpPassword) {
        Write-Success "SFTP connection validated"
    } else {
        Write-Host "[WARNING] SFTP validation skipped (WinSCP not found or connection failed)" -ForegroundColor Yellow
    }
}
else {
    Write-Status "SFTP credentials not yet set, will collect during setup"
}

# Process each server
$isMultiServer = ($script:ServersToProcess.Count -gt 1) -or ($modeChoice -eq "2") -or $MultiServer
foreach ($server in $script:ServersToProcess) {
    $script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -ServerUuid $server.uuid -LogTag $script:LogTag -MaxFiles 5
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "Processing Server: $($server.name)" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "UUID: $($server.uuid)" -ForegroundColor Yellow
    Write-Host ""
    
    # Stop server
    if (!(Stop-BisectServer -ServerUuid $server.uuid -ApiKey $script:Credentials.ApiKey)) {
        if ($isMultiServer) {
            Write-Error-Status "Failed to stop server '$($server.name)'. Skipping to next server."
            continue
        }
        Write-Error-Status "Failed to stop server '$($server.name)'. Aborting."
        exit 1
    }
    
    # Sync files to server via SFTP
    Write-Status "Syncing files to server via SFTP..."
    try {
        $repoPath = "$PSScriptRoot\..\game\csgo"
        Write-Status "Uploading files from: $repoPath"
        
        if (Sync-FilesViaSftp -SftpHost $script:Credentials.SftpHost `
                             -SftpPort $script:Credentials.SftpPort `
                             -SftpUsername $script:Credentials.SftpUsername `
                             -SftpPassword $script:Credentials.SftpPassword `
                             -LocalPath $repoPath `
                             -RemotePath "/game/csgo") {
            Write-Success "Files synced to server"
        } else {
            if ($isMultiServer) {
                Write-Error-Status "Failed to sync files via SFTP. Skipping to next server."
                continue
            }
            Write-Error-Status "Failed to sync files via SFTP. Aborting."
            exit 1
        }
    }
    catch {
        if ($isMultiServer) {
            Write-Error-Status "Failed to sync files: $_. Skipping to next server."
            continue
        }
        Write-Error-Status "Failed to sync files: $_. Aborting."
        exit 1
    }
    # Sync custom_files overrides
    if (!(Sync-CustomFiles -SftpHost $script:Credentials.SftpHost `
                           -SftpPort $script:Credentials.SftpPort `
                           -SftpUsername $script:Credentials.SftpUsername `
                           -SftpPassword $script:Credentials.SftpPassword `
                           -ServerUuid $server.uuid)) {
        if ($isMultiServer) {
            Write-Error-Status "Failed to sync custom files. Skipping to next server."
            continue
        }
        Write-Error-Status "Failed to sync custom files. Aborting."
        exit 1
    }
    # Start server
    Write-Status "Starting server..."
    try {
        Invoke-BisectApi -Endpoint "/servers/$($server.uuid)/power" -Method "POST" -Body @{signal="start"} -ApiKey $script:Credentials.ApiKey | Out-Null
        Write-Success "Server '$($server.name)' started successfully"
    }
    catch {
        Write-Error-Status "Failed to start server: $_"
    }
}
# Create scheduled tasks
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Scheduled Task Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
$taskChoice = Read-Host "Create scheduled update tasks? (y/n)"
if ($taskChoice -eq 'y' -or $taskChoice -eq 'Y') {
    if (-not $isMultiServer) {
        $logRetention = Read-Host "Keep how many log files per script? (default: 5)"
        if (-not $logRetention) { $logRetention = "5" }
        $parsedRetention = 0
        while (-not [int]::TryParse($logRetention, [ref]$parsedRetention)) {
            Write-Host "Please enter a valid number (0 to disable cleanup)." -ForegroundColor Yellow
            $logRetention = Read-Host "Keep how many log files per script? (default: 5)"
            if (-not $logRetention) { $logRetention = "5" }
        }
        $logRetentionValue = $parsedRetention
    }

    foreach ($server in $script:ServersToProcess) {
        $taskName = "CS2 Server Update - $($server.name) ($($server.uuid))"
        
        # For single-server mode, prompt for schedule
        if (!$isMultiServer) {
            Write-Host ""
            Write-Host "Schedule options:" -ForegroundColor Yellow
            Write-Host "  1. Daily"
            Write-Host "  2. Weekly"
            Write-Host "  3. Monthly"
            $scheduleChoice = Read-Host "Select schedule - 1, 2, or 3 (default: 2 - Weekly)"
            if (!$scheduleChoice) { $scheduleChoice = "2" }
            
            $scheduleType = switch ($scheduleChoice) {
                "1" { "Daily" }
                "2" { "Weekly" }
                "3" { "Monthly" }
                default { "Weekly" }
            }
            
            # Get time
            $taskTime = Read-Host "Enter time to run updates in HH:MM format (default: 02:00)"
            if (!$taskTime) { $taskTime = "02:00" }
            
            # Get day if Weekly/Monthly
            $taskDay = ""
            if ($scheduleType -eq "Weekly") {
                Write-Host ""
                Write-Host "Days of week: Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday"
                $taskDay = Read-Host "Enter day (default: Monday)"
                if (!$taskDay) { $taskDay = "Monday" }
            }
            elseif ($scheduleType -eq "Monthly") {
                $taskDay = Read-Host "Enter day of month (1-31, default: 1)"
                if (!$taskDay) { $taskDay = "1" }
            }
        }
        else {
            # Use config values for multi-server
            $scheduleType = $server.schedule
            $taskDay = $server.day
            $taskTime = $server.time
            $logRetentionValue = if ($null -ne $server.logRetention) { [int]$server.logRetention } else { 5 }
        }
        
        # Create the task
        New-ScheduledUpdateTask -TaskName $taskName -ServerUuid $server.uuid -Schedule $scheduleType -Day $taskDay -Time $taskTime -LogRetention $logRetentionValue
    }
}
else {
    Write-Status "Skipped task creation. You can create tasks manually later."
}
# Final summary
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "      Installation Complete!" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host ""

Write-Host "Processed servers:" -ForegroundColor Cyan
foreach ($server in $script:ServersToProcess) {
    Write-Host "$($server.name) ($($server.uuid))"
}
Write-Host ""
Write-Host "Logging to: $script:LogFile" -ForegroundColor Cyan