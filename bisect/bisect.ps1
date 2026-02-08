# Bisect Hosting API and Server Management Functions
# Shared utilities for install.ps1 and update.ps1

function Invoke-BisectApi {
    <#
    .SYNOPSIS
    Calls Bisect Hosting API endpoints
    
    .PARAMETER Endpoint
    API endpoint path (e.g., /servers, /servers/{uuid}/power)
    
    .PARAMETER Method
    HTTP method (GET, POST, etc.)
    
    .PARAMETER Body
    Request body as object (will be converted to JSON)
    
    .PARAMETER ApiKey
    Bearer token for authentication
    #>
    
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body,
        [string]$ApiKey
    )
    
    $headers = @{
        "Authorization" = "Bearer $ApiKey"
        "Accept" = "application/json"
    }
    
    $uri = "https://games.bisecthosting.com/api/client$Endpoint"
    
    try {
        $params = @{
            Uri = $uri
            Headers = $headers
            Method = $Method
            ErrorAction = "Stop"
        }
        
        if ($Body) {
            $params["Body"] = $Body | ConvertTo-Json
            $params["ContentType"] = "application/json"
        }
        
        return Invoke-RestMethod @params
    }
    catch {
        Write-Error-Status "API call failed: $($_.Exception.Message)"
        throw $_
    }
}

function Stop-BisectServer {
    <#
    .SYNOPSIS
    Stops a server via Bisect Hosting API
    
    .PARAMETER ServerUuid
    UUID of the server to stop
    
    .PARAMETER ApiKey
    API key for authentication
    
    .OUTPUTS
    $true if stopped successfully, $false otherwise
    #>
    
    param([string]$ServerUuid, [string]$ApiKey)
    
    Write-Status "Stopping server via Bisect API..."
    
    try {
        # Send stop signal
        Invoke-BisectApi -Endpoint "/servers/$ServerUuid/power" -Method "POST" -ApiKey $ApiKey -Body @{ signal = "stop" } | Out-Null
        
        # Poll for stopped status (60 second timeout)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed.TotalSeconds -lt 60) {
            Start-Sleep -Seconds 2
            
            $resources = Invoke-BisectApi -Endpoint "/servers/$ServerUuid/resources" -ApiKey $ApiKey
            $currentState = $resources.attributes.current_state
            
            # Check for common stopped states
            if ($currentState -in @("stopped", "offline", "off", "idle")) {
                Write-Success "Server stopped (state: $currentState)"
                return $true
            }
        }
        
        Write-Error-Status "Server did not stop within 60 seconds (final state: $currentState)"
        return $false
    }
    catch {
        Write-Error-Status "Failed to stop server: $_"
        return $false
    }
}

function New-ScheduledUpdateTask {
    <#
    .SYNOPSIS
    Creates a scheduled task for automatic server updates
    
    .PARAMETER TaskName
    Name of the scheduled task
    
    .PARAMETER ServerUuid
    UUID of server to update
    
    .PARAMETER Schedule
    Schedule type: Weekly, Monthly, or Daily
    
    .PARAMETER Day
    Day of week (for Weekly) or day of month (for Monthly) or ignored (for Daily)
    
    .PARAMETER Time
    Time to run in HH:MM format
    
    .OUTPUTS
    $true if successful, $false otherwise
    #>
    
    param(
        [string]$TaskName,
        [string]$ServerUuid,
        [string]$Schedule,
        [string]$Day,
        [string]$Time,
        [int]$LogRetention = 5
    )
    
    try {
        # Remove existing task if present
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Status "Removing existing task: $taskName"
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }
        
        # Create appropriate trigger based on schedule
        if ($Schedule -eq "Weekly") {
            $validDays = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
            if ($Day -notin $validDays) {
                Write-Error-Status "Invalid day for scheduled task: $Day"
                return $false
            }
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Time
        }
        elseif ($Schedule -eq "Monthly") {
            try {
                $dayNum = [int]$Day
                if ($dayNum -lt 1 -or $dayNum -gt 31) {
                    Write-Error-Status "Invalid day for scheduled task: $Day (must be 1-31)"
                    return $false
                }
                $trigger = New-ScheduledTaskTrigger -Monthly -Day $dayNum -At $Time
            }
            catch {
                Write-Error-Status "Invalid day format: $_"
                return $false
            }
        }
        elseif ($Schedule -eq "Daily") {
            $trigger = New-ScheduledTaskTrigger -Daily -At $Time
        }
        else {
            Write-Error-Status "Unknown schedule type: $Schedule"
            return $false
        }
        
        # Create task action
        $scriptPath = Join-Path $PSScriptRoot "update.ps1"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ServerUuid `"$ServerUuid`" -LogRetention $LogRetention"
        
        # Task settings
        $settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable `
            -StartWhenAvailable -DontStopIfGoingOnBatteries
        
        # Register task
        Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action `
            -Settings $settings -Description "CS2 server auto-update for $taskName" `
            -Force | Out-Null
        
        Write-Success "Created task: $taskName"
        Write-Success "Schedule: $Schedule $Day at $Time"
        return $true
    }
    catch {
        Write-Error-Status "Failed to create scheduled task: $_"
        return $false
    }
}

function Sync-CustomFiles {
    <#
    .SYNOPSIS
    Copies remote custom_files into /home/container
    
    .DESCRIPTION
    Checks /home/container/custom_files on the server and copies its contents
    into /home/container using a remote command.
    
    .PARAMETER SftpHost
    SFTP server hostname
    
    .PARAMETER SftpPort
    SFTP server port (default: 22)
    
    .PARAMETER SftpUsername
    SFTP username
    
    .PARAMETER SftpPassword
    SFTP password (SecureString)

    .PARAMETER ServerUuid
    Server UUID used for local backup path
    
    .OUTPUTS
    $true if successful or no custom files, $false on error
    #>
    
    param(
        [string]$SftpHost,
        [string]$SftpPort = "22",
        [string]$SftpUsername,
        [System.Security.SecureString]$SftpPassword,
        [string]$ServerUuid
    )

    $winscp_path = Get-ChildItem -Path "C:\Program Files*" -Filter "WinSCPnet.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName }
    if (-not $winscp_path) {
        Write-Status "WinSCP not available. Skipping remote custom_files copy."
        return $true
    }

    try {
        Add-Type -Path $winscp_path

        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($SftpPassword)
        )

        $session = New-Object WinSCP.Session
        $sessionOptions = New-Object WinSCP.SessionOptions
        $sessionOptions.Protocol = [WinSCP.Protocol]::Sftp
        $sessionOptions.HostName = $SftpHost
        $sessionOptions.UserName = $SftpUsername
        $sessionOptions.Password = $plainPassword
        $sessionOptions.PortNumber = [int]$SftpPort

        $storedFingerprint = Get-SshHostKeyFingerprint -SftpHost $SftpHost -SftpPort $SftpPort
        if ($storedFingerprint) {
            $sessionOptions.SshHostKeyFingerprint = $storedFingerprint
        }

        $session.Open($sessionOptions)

        # Backup remote custom_files locally (outside repo)
        if ([string]::IsNullOrWhiteSpace($ServerUuid)) {
            $ServerUuid = "unknown-server"
        }
        $backupRoot = Join-Path $env:USERPROFILE "Documents\CS2\$ServerUuid\custom_files"
        if (-not (Test-Path $backupRoot)) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        }
        $backupPath = Join-Path $backupRoot (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
        New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

        try {
            $transferOptions = New-Object WinSCP.TransferOptions
            $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
            $backupResult = $session.SynchronizeDirectories(
                [WinSCP.SynchronizationMode]::Local,
                $backupPath,
                "/home/container/custom_files",
                $false,
                $false,
                [WinSCP.SynchronizationCriteria]::Time,
                $transferOptions
            )
            $backupResult.Check()
            Write-Status "Backed up remote custom_files to: $backupPath"
        }
        catch {
            Write-Status "Warning: Failed to back up remote custom_files (continuing)"
        }

        Write-Status "Applying remote custom_files into /home/container..."
        $command = "if [ -d /home/container/custom_files ]; then cp -r /home/container/custom_files/. /home/container/; else echo 'custom_files missing'; fi"
        $exec = $session.ExecuteCommand($command)
        if ($exec.ExitCode -ne 0) {
            Write-Error-Status "Remote custom_files copy failed: $($exec.ErrorOutput)"
            $session.Close()
            return $false
        }
        if ($exec.Output -match "custom_files missing") {
            Write-Status "Remote custom_files not found (skipping)"
            $session.Close()
            return $true
        }

        Write-Success "Custom files applied"
        $session.Close()
        return $true
    }
    catch {
        Write-Error-Status "Failed to apply remote custom_files: $_"
        return $false
    }
}
