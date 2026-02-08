# CS2 Server Uninstall Script for Bisect Hosting
# Removes scheduled tasks and optionally clears stored credentials

param(
    [switch]$ClearCredentials,
    [string]$ServerUuid
)

# Load credential manager functions
. "$PSScriptRoot\helpers.ps1"

# Initialize logging (default until server UUID known)
$script:LogTag = "uninstall"
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

# Main script
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " CS2 Server Uninstall - Bisect Hosting" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Status "Logging to: $script:LogFile"

# Check if running from servers-config.json or single server
Write-Host ""
Write-Host "Uninstall Mode:" -ForegroundColor Yellow
Write-Host "  1. Single Server (remove one task)"
Write-Host "  2. Multiple Servers (remove all tasks from config)"
$modeChoice = Read-Host "Select mode (1-2, default: 1)"
if (!$modeChoice) { $modeChoice = "1" }

if ($modeChoice -eq "2") {
    # Multi-server uninstall
    $script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -ServerUuid "multi" -LogTag $script:LogTag -MaxFiles 5
    Write-Host ""
    Write-Status "Multi-Server Uninstall Mode"
    Write-Host ""
    
    # Check if config exists
    $configPath = "$PSScriptRoot\..\servers-config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error-Status "servers-config.json not found!"
        exit 1
    }
    
    # Validate config
    $configTest = Test-ServerConfig -ConfigPath $configPath
    if (-not $configTest.IsValid) {
        Write-Error-Status "Invalid configuration: $($configTest.Message)"
        exit 1
    }
    
    Write-Success $configTest.Message
    Write-Host ""
    
    # Read servers from config
    $servers = Read-ServerConfig -ConfigPath $configPath
    
    # Display servers that will be uninstalled
    Write-Host "Scheduled tasks to remove:" -ForegroundColor Yellow
    $servers | ForEach-Object {
        Write-Host "  • CS2 Server Update - $($_.name) ($($_.uuid))" -ForegroundColor Cyan
    }
    Write-Host ""
    
    $confirmChoice = Read-Host "Remove all scheduled tasks? (y/n)"
    if ($confirmChoice -ne 'y' -and $confirmChoice -ne 'Y') {
        Write-Status "Uninstall cancelled"
        exit 0
    }
    
    # Remove each task
    Write-Host ""
    $removedCount = 0
    $failureCount = 0
    
    foreach ($server in $servers) {
        $taskName = "CS2 Server Update - $($server.name) ($($server.uuid))"
        
        Write-Status "Removing task: $taskName"
        try {
            $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($existingTask) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
                Write-Success "Task removed: $taskName"
                Write-Log "Removed scheduled task: $taskName" -Level Success -LogFile $script:LogFile
                $removedCount++
            } else {
                Write-Status "Task not found (already removed): $taskName"
            }
        }
        catch {
            Write-Error-Status "Failed to remove task: $_"
            Write-Log "Failed to remove task $taskName : $_" -Level Error -LogFile $script:LogFile
            $failureCount++
        }
    }
    
    Write-Host ""
    Write-Success "$removedCount task(s) removed"
    if ($failureCount -gt 0) {
        Write-Error-Status "$failureCount task(s) failed to remove"
    }
    
} else {
    # Single server uninstall
    Write-Host ""
    
    if (-not $ServerUuid) {
        $ServerUuid = Read-Host "Enter Server UUID to uninstall"
    }
    
    if (-not $ServerUuid) {
        Write-Error-Status "Server UUID required"
        exit 1
    }

    $script:LogFile = Set-LogPath -BaseDir $PSScriptRoot -ServerUuid $ServerUuid -LogTag $script:LogTag -MaxFiles 5
    Write-Status "Searching for tasks for UUID: $ServerUuid"
    
    # Find all tasks matching this UUID
    try {
        $tasks = Get-ScheduledTask | Where-Object { $_.TaskName -match $ServerUuid }
        
        if ($tasks) {
            Write-Host ""
            Write-Host "Found scheduled tasks:" -ForegroundColor Yellow
            if ($tasks -is [array]) {
                $tasks | ForEach-Object { Write-Host "  • $($_.TaskName)" -ForegroundColor Cyan }
            } else {
                Write-Host "  • $($tasks.TaskName)" -ForegroundColor Cyan
            }
            Write-Host ""
            
            $confirmChoice = Read-Host "Remove these tasks? (y/n)"
            if ($confirmChoice -eq 'y' -or $confirmChoice -eq 'Y') {
                if ($tasks -is [array]) {
                    foreach ($task in $tasks) {
                        Write-Status "Removing: $($task.TaskName)"
                        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false | Out-Null
                        Write-Success "Removed: $($task.TaskName)"
                        Write-Log "Removed scheduled task: $($task.TaskName)" -Level Success -LogFile $script:LogFile
                    }
                } else {
                    Write-Status "Removing: $($tasks.TaskName)"
                    Unregister-ScheduledTask -TaskName $tasks.TaskName -Confirm:$false | Out-Null
                    Write-Success "Removed: $($tasks.TaskName)"
                    Write-Log "Removed scheduled task: $($tasks.TaskName)" -Level Success -LogFile $script:LogFile
                }
            } else {
                Write-Status "Uninstall cancelled"
                exit 0
            }
        } else {
            Write-Status "No scheduled tasks found for UUID: $ServerUuid"
        }
    }
    catch {
        Write-Error-Status "Failed to find tasks: $_"
        Write-Log "Failed to find scheduled tasks: $_" -Level Error -LogFile $script:LogFile
        exit 1
    }
}

# Optional: Clear credentials
Write-Host ""
if (-not $ClearCredentials) {
    $clearChoice = Read-Host "Clear stored credentials? (y/n)"
    if ($clearChoice -eq 'y' -or $clearChoice -eq 'Y') {
        $ClearCredentials = $true
    }
}

if ($ClearCredentials) {
    Write-Status "Clearing stored credentials..."
    try {
        $vault = [Windows.Security.Credentials.PasswordVault]::new()
        
        # New web credential format
        $resources = @(
            "https://games.bisecthosting.com/api",
            "BisectHosting"
        )

        foreach ($resource in $resources) {
            foreach ($user in @("ApiKey", "BisectHosting", "SftpHost", "SftpPort")) {
                try {
                    $cred = $vault.Retrieve($resource, $user)
                    if ($cred) { $vault.Remove($cred) }
                } catch { }
            }
        }

        # Remove SFTP username/password and SSH fingerprint if present
        try {
            $creds = $vault.RetrieveAll()
            foreach ($c in $creds) {
                if ($c.Resource -like "sftp://*" -and ($c.UserName -in @("username", "password", "BisectHosting", "SshHostKeyFingerprint"))) {
                    try { $vault.Remove($c) } catch { }
                }
            }
        } catch { }

        # Default server UUID
        try {
            $cred = $vault.Retrieve("https://games.bisecthosting.com/api", "DefaultServerUuid")
            if ($cred) { $vault.Remove($cred) }
        } catch { }
        
        Write-Success "All credentials cleared from Credential Manager"
        Write-Log "Cleared all stored credentials" -Level Success -LogFile $script:LogFile
    }
    catch {
        Write-Error-Status "Failed to clear credentials: $_"
        Write-Log "Failed to clear credentials: $_" -Level Error -LogFile $script:LogFile
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "            Uninstall Complete!                  " -ForegroundColor Green
Write-Host "============================================`n" -ForegroundColor Green

Write-Status "Uninstall logged to: $script:LogFile"

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "Scheduled tasks have been removed"
if ($ClearCredentials) {
    Write-Host "Stored credentials have been cleared"
} else {
    Write-Host "Stored credentials remain (you can remove them later)"
}
Write-Host "Game files remain on server and in local directory`n" -ForegroundColor Gray
