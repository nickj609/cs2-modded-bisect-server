# Credential Management Helper Functions for Bisect Hosting
# Uses Windows Credential Manager (DPAPI) for secure storage

function New-PasswordVault {
    <#
    .SYNOPSIS
    Creates a PasswordVault instance when available.
    #>

    try {
        return [Windows.Security.Credentials.PasswordVault]::new()
    }
    catch {
        try {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
            $vaultType = [Windows.Security.Credentials.PasswordVault, Windows.Security.Credentials, ContentType=WindowsRuntime]
            return [Activator]::CreateInstance($vaultType)
        }
        catch {
            return $null
        }
    }
}

function Set-BisectCredentials 
{
    <#
    .SYNOPSIS
    Prompts user for credentials and stores them securely in Windows Credential Manager
    
    .DESCRIPTION
    Interactively gathers Bisect Hosting API key, SFTP host, username and password
    Stores them using Windows Credential Manager (DPAPI encryption, user-scoped)
    
    .OUTPUTS
    PSCustomObject with ApiKey, SftpHost, SftpUsername, SftpPassword
    #>
    
    param(
        [string]$ApiKey,
        [string]$SftpHost,
        [string]$SftpPort,
        [string]$SftpUsername,
        [string]$SftpPassword,
        [switch]$NoPrompt
    )

    Write-Host ""
    Write-Host "===================================" -ForegroundColor Cyan
    Write-Host "  Bisect Hosting Credential Setup" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not $NoPrompt) {
        Write-Host "Enter your Bisect Hosting API credentials:" -ForegroundColor Yellow
        Write-Host "(These will be stored securely using Windows Credential Manager)`n" -ForegroundColor Gray
    }

    $apiKey = $ApiKey
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        if ($NoPrompt) { throw "ApiKey is required when -NoPrompt is used." }
        $apiKey = Read-Host "Bisect Hosting API Key"
    }

    $sftpHost = $SftpHost
    if ([string]::IsNullOrWhiteSpace($sftpHost)) {
        if ($NoPrompt) { throw "SftpHost is required when -NoPrompt is used." }
        $sftpHost = Read-Host "SFTP Host (e.g., sftp.example.com)"
    }

    $sftpPort = $SftpPort
    if ([string]::IsNullOrWhiteSpace($sftpPort)) { $sftpPort = "22" }

    $sftpUsername = $SftpUsername
    if ([string]::IsNullOrWhiteSpace($sftpUsername)) {
        if ($NoPrompt) { throw "SftpUsername is required when -NoPrompt is used." }
        $sftpUsername = Read-Host "SFTP Username"
    }

    $sftpPasswordSecure = $null
    if ([string]::IsNullOrWhiteSpace($SftpPassword)) {
        if ($NoPrompt) { throw "SftpPassword is required when -NoPrompt is used." }
        $sftpPasswordSecure = Read-Host "SFTP Password" -AsSecureString
    } else {
        $sftpPasswordSecure = ConvertTo-SecureString -String $SftpPassword -AsPlainText -Force
    }

    # Convert SecureString to plain text ONLY for PasswordVault storage
    # PasswordVault API requires string input, but stores encrypted with DPAPI
    # We minimize the time plain text is in memory by converting only when needed
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($sftpPasswordSecure)
    )
    
    # Store credentials in Windows Credential Manager (DPAPI-encrypted)
    $storedPassword = $plainPassword
    try
    {
        $vault = New-PasswordVault
        if (-not $vault) {
            throw "PasswordVault unavailable"
        }
        
        # Clear old entries if they exist (security best practice)
        @("https://games.bisecthosting.com/api", "sftp://${sftpHost}:${sftpPort}") | ForEach-Object {
            try {
                # Try generic credential (old format)
                $cred = $vault.Retrieve("BisectHosting", "ApiKey")
                if ($cred) { $vault.Remove($cred) }
            }
            catch { }
            try {
                $cred = $vault.Retrieve($_, "BisectHosting")
                if ($cred) { $vault.Remove($cred) }
            }
            catch { }
        }
        
        # Store credentials securely in Credential Manager as web credentials (using URIs)
        # All credentials stored here are DPAPI-encrypted by Windows
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("https://games.bisecthosting.com/api", "BisectHosting", $apiKey))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("https://games.bisecthosting.com/api", "ApiKey", $apiKey))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("https://games.bisecthosting.com/api", "SftpHost", $sftpHost))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("https://games.bisecthosting.com/api", "SftpPort", $sftpPort))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("sftp://${sftpHost}:${sftpPort}", "BisectHosting", $sftpUsername))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("sftp://${sftpHost}:${sftpPort}", "username", $sftpUsername))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("sftp://${sftpHost}:${sftpPort}", "password", $plainPassword))
        
        # Convert password back to SecureString for return value
        $storedPassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
        
        # Clear plain text password from memory immediately after storage
        $plainPassword = $null
        [System.GC]::Collect()
        
        Write-Host "Credentials stored successfully in Credential Manager (DPAPI-encrypted)" -ForegroundColor Green
    }
    catch 
    {
        Write-Host "Warning: Could not store credentials in Credential Manager: $_" -ForegroundColor Yellow
        Write-Host "This is optional - credentials will still be available for this session." -ForegroundColor Yellow
        # Note: plainPassword will be cleared when function exits
    }
    
    return @{
        ApiKey = $apiKey
        SftpHost = $sftpHost
        SftpPort = $sftpPort
        SftpUsername = $sftpUsername
        SftpPassword = $storedPassword  # SecureString
        }

}

function Get-BisectCredentials {
    <#
    .SYNOPSIS
    Retrieves Bisect credentials from Windows Credential Manager
    
    .DESCRIPTION
    Attempts to retrieve stored credentials from Credential Manager
    Prompts user if credentials not found or prompts user to update
    
    .PARAMETER Prompt
    If $true, always prompts user even if credentials exist
    
    .OUTPUTS
    PSCustomObject with ApiKey, SftpHost, SftpUsername, SftpPassword
    #>
    
    param([switch]$Prompt)
    
    try {
        $vault = New-PasswordVault
        if (-not $vault) {
            throw "PasswordVault unavailable"
        }
        
        # Try to retrieve from new web credential format first, fall back to old generic format
        try {
            $apiKey = $vault.Retrieve("https://games.bisecthosting.com/api", "ApiKey").Password
            $sftpHost = $vault.Retrieve("https://games.bisecthosting.com/api", "SftpHost").Password
            $sftpPort = $vault.Retrieve("https://games.bisecthosting.com/api", "SftpPort").Password
        }
        catch {
            # Fall back to old generic credentials (for backwards compatibility)
            $apiKey = $vault.Retrieve("BisectHosting", "ApiKey").Password
            $sftpHost = $vault.Retrieve("BisectHosting", "SftpHost").Password
            $sftpPort = $vault.Retrieve("BisectHosting", "SftpPort").Password
        }
        
        # Retrieve SFTP credentials from web credential URI
        try {
            $sftpUsername = $vault.Retrieve("sftp://${sftpHost}:${sftpPort}", "username").Password
            $sftpPasswordPlain = $vault.Retrieve("sftp://${sftpHost}:${sftpPort}", "password").Password
        }
        catch {
            # Fall back to old format
            $sftpUsername = $vault.Retrieve("BisectHosting", "SftpUsername").Password
            $sftpPasswordPlain = $vault.Retrieve("BisectHosting", "SftpPassword").Password
        }
        
        # Convert password to SecureString
        $sftpPassword = ConvertTo-SecureString -String $sftpPasswordPlain -AsPlainText -Force
        
        if ($Prompt) {
            Write-Host ""
            $updateChoice = Read-Host "Credentials found. Update them? (y/n)"
            if ($updateChoice -eq 'y' -or $updateChoice -eq 'Y') {
                return Set-BisectCredentials
            }
        }
        
        return @{
            ApiKey = $apiKey
            SftpHost = $sftpHost
            SftpPort = $sftpPort
            SftpUsername = $sftpUsername
            SftpPassword = $sftpPassword  # SecureString
        }
    }
    catch {
        Write-Host "No credentials found in Credential Manager" -ForegroundColor Yellow
        return Set-BisectCredentials
    }
}

function Update-StoredCredentials {
    <#
    .SYNOPSIS
    Updates stored credentials by prompting the user
    
    .DESCRIPTION
    Simple wrapper for Set-BisectCredentials
    #>
    
    Write-Host "Updating credentials..." -ForegroundColor Cyan
    Set-BisectCredentials | Out-Null
}

function Update-BisectApiKey {
    <#
    .SYNOPSIS
    Updates only the API key without changing other credentials
    
    .DESCRIPTION
    Prompts for a new API key and updates it in Credential Manager
    Preserves existing SFTP host, port, username, and password
    
    .OUTPUTS
    $true if successful, $false otherwise
    #>
    
    Write-Host ""
    Write-Host "===================================" -ForegroundColor Cyan
    Write-Host "  Update Bisect Hosting API Key" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor Cyan
    Write-Host ""
    
    try {
        $vault = New-PasswordVault
        if (-not $vault) {
            throw "PasswordVault unavailable"
        }
        
        # Prompt for new API key
        $newApiKey = Read-Host "Enter new Bisect Hosting API Key"
        
        if ([string]::IsNullOrWhiteSpace($newApiKey)) {
            Write-Host "API key cannot be empty. Cancelling update." -ForegroundColor Yellow
            return $false
        }
        
        # Remove old API key entries
        try {
            $oldCred = $vault.Retrieve("https://games.bisecthosting.com/api", "ApiKey")
            if ($oldCred) { $vault.Remove($oldCred) }
        }
        catch { }
        
        try {
            $oldCred = $vault.Retrieve("https://games.bisecthosting.com/api", "BisectHosting")
            if ($oldCred) { $vault.Remove($oldCred) }
        }
        catch { }
        
        try {
            $oldCred = $vault.Retrieve("BisectHosting", "ApiKey")
            if ($oldCred) { $vault.Remove($oldCred) }
        }
        catch { }
        
        # Store new API key
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("https://games.bisecthosting.com/api", "ApiKey", $newApiKey))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("https://games.bisecthosting.com/api", "BisectHosting", $newApiKey))
        
        Write-Host "API key updated successfully!" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Error updating API key: $_" -ForegroundColor Red
        return $false
    }
}

function Test-BisectApiKey {
    <#
    .SYNOPSIS
    Validates Bisect API key by making a test API call
    
    .DESCRIPTION
    Attempts to call the Bisect API servers endpoint (optionally with a server UUID)
    to verify the API key is valid
    
    .PARAMETER ApiKey
    The API key to test

    .PARAMETER ServerUuid
    Optional server UUID to validate against
    
    .OUTPUTS
    $true if valid, $false if invalid
    #>
    
    param(
        [string]$ApiKey,
        [string]$ServerUuid
    )
    
    try {
        $headers = @{
            "Authorization" = "Bearer $ApiKey"
            "Content-Type" = "application/json"
        }
        
        $endpoint = "https://games.bisecthosting.com/api/client/servers"
        if (-not [string]::IsNullOrWhiteSpace($ServerUuid)) {
            $endpoint = "$endpoint/$ServerUuid"
        }

        Invoke-RestMethod `
            -Uri $endpoint `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 10 `
            -ErrorAction Stop
        
        return $true
    }
    catch {
        Write-Log "API Key validation failed: $_" -Level Warning
        return $false
    }
}

function Test-SftpConnection {
    <#
    .SYNOPSIS
    Validates SFTP credentials by attempting a connection
    
    .DESCRIPTION
    Attempts to establish SFTP connection and list root directory
    Uses WinSCP .NET library
    
    .PARAMETER SftpHost
    SFTP server hostname
    
    .PARAMETER SftpPort
    SFTP server port (default: 22)
    
    .PARAMETER SftpUsername
    SFTP username
    
    .PARAMETER SftpPassword
    SFTP password (SecureString or plain text)
    
    .OUTPUTS
    $true if connection successful, $false otherwise
    #>
    
    param(
        [string]$SftpHost,
        [string]$SftpPort = "22",
        [string]$SftpUsername,
        [System.Security.SecureString]$SftpPassword
    )
    
    try {
        # Check if WinSCP DLL exists
        $winscp_path = Get-ChildItem -Path "C:\Program Files*" -Filter "WinSCPnet.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName }
        
        if (-not $winscp_path) {
            Write-Log "WinSCP not found. Skipping SFTP validation." -Level Warning
            return $false
        }
        
        Add-Type -Path $winscp_path
        
        # Convert SecureString to plain text only for WinSCP API call
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
        
        # Try to connect; on first connection with unknown key, scan and prompt user
        try 
        {
            $session.Open($sessionOptions)
        }
        catch {
            # If fingerprint not set, scan it and ask user to verify
            if ($_ -match "SshHostKeyFingerprint is not set" -or $_ -match "does not match") {
                Write-Host ""
                Write-Host "Scanning SSH host key fingerprint..." -ForegroundColor Yellow
                
                try {
                    $fingerprint = $session.ScanFingerprint($sessionOptions, "SHA-256")
                    Write-Host ""
                    Write-Host "SSH Host Key Fingerprint (SHA-256):" -ForegroundColor Cyan
                    Write-Host "$fingerprint" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "Please verify this fingerprint matches your server's key." -ForegroundColor Gray
                    Write-Host ""
                    $accept = Read-Host "Accept this SSH key? (yes/no)"
                    
                    if ($accept -eq "yes" -or $accept -eq "y") {
                        $sessionOptions.SshHostKeyFingerprint = $fingerprint
                        $session.Open($sessionOptions)
                        if (Set-SshHostKeyFingerprint -SftpHost $SftpHost -SftpPort $SftpPort -Fingerprint $fingerprint) {
                            Write-Host "SSH key accepted and saved for future connections." -ForegroundColor Green
                        }
                        else {
                            Write-Host "SSH key accepted for this session (unable to store fingerprint)." -ForegroundColor Yellow
                        }
                    }
                    else {
                        Write-Log "SSH key rejected by user" -Level Warning
                        return $false
                    }
                }
                catch {
                    Write-Log "Failed to scan SSH host key: $_" -Level Warning
                    return $false
                }
            }
            else {
                Write-Log "SFTP connection test failed: $_" -Level Warning
                return $false
            }
        }
        
        # Try to list files in home directory to verify connection
        try {
            $session.EnumerateRemoteFiles("/", $null, [WinSCP.EnumerationOptions]::None) | Out-Null
        }
        catch {
            # Directory listing failed but connection was successful, that's ok
        }
        $session.Close()
        
        return $true
    }
    catch {
        Write-Log "SFTP connection test failed: $_" -Level Warning
        return $false
    }
}

function Sync-FilesViaSftp {
    <#
    .SYNOPSIS
    Syncs files to remote server via SFTP
    
    .DESCRIPTION
    Uploads files from local path to remote server using SFTP
    Supports custom SFTP ports
    Uses WinSCP .NET library if available, otherwise uses Plink/Psftp
    
    .PARAMETER SftpHost
    SFTP server hostname
    
    .PARAMETER SftpPort
    SFTP server port (default: 22)
    
    .PARAMETER SftpUsername
    SFTP username
    
    .PARAMETER SftpPassword
    SFTP password (plain text)
    
    .PARAMETER LocalPath
    Local directory path to upload
    
    .PARAMETER RemotePath
    Remote directory path to upload to (default: /)
    
    .OUTPUTS
    $true if successful, $false otherwise
    #>
    
    param(
        [string]$SftpHost,
        [string]$SftpPort = "22",
        [string]$SftpUsername,
        [System.Security.SecureString]$SftpPassword,
        [string]$LocalPath,
        [string]$RemotePath = "/"
    )
    
    try {
        # Normalize remote path (avoid nesting /home/container inside itself)
        if (-not [string]::IsNullOrWhiteSpace($RemotePath)) {
            $RemotePath = $RemotePath.Replace('\\', '/')
            if ($RemotePath -match '^/home/container(/|$)') {
                $RemotePath = $RemotePath -replace '^/home/container', ''
            }
        }
        if ([string]::IsNullOrWhiteSpace($RemotePath)) {
            $RemotePath = "/"
        }
        if (-not $RemotePath.StartsWith('/')) {
            $RemotePath = '/' + $RemotePath
        }

        # Validate local path
        if (-not (Test-Path $LocalPath)) {
            Write-Log "Local path does not exist: $LocalPath" -Level Error
            return $false
        }
        
        # Try to use WinSCP if available
        $winscp_path = Get-ChildItem -Path "C:\Program Files*" -Filter "WinSCPnet.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName }
        
        if ($winscp_path) {
            Write-Log "Using WinSCP for SFTP sync" -Level Info
            Add-Type -Path $winscp_path
            
            # Convert SecureString to plain text only for WinSCP API call
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
            
            # Try to open connection; if key not set, scan and prompt user
            try {
                Write-Log "Connecting to SFTP server..." -Level Info
                $session.Open($sessionOptions)
            }
            catch {
                if ($_ -match "SshHostKeyFingerprint is not set" -or $_ -match "does not match") {
                    Write-Log "SSH host key not yet saved. Scanning server..." -Level Info
                    
                    try {
                        $fingerprint = $session.ScanFingerprint($sessionOptions, "SHA-256")
                        Write-Host ""
                        Write-Host "SSH Host Key Fingerprint (SHA-256):" -ForegroundColor Cyan
                        Write-Host "$fingerprint" -ForegroundColor Yellow
                        Write-Host ""
                        $accept = Read-Host "Accept this SSH key? (yes/no)"
                        
                        if ($accept -eq "yes" -or $accept -eq "y") {
                            $sessionOptions.SshHostKeyFingerprint = $fingerprint
                            $session.Open($sessionOptions)
                            if (Set-SshHostKeyFingerprint -SftpHost $SftpHost -SftpPort $SftpPort -Fingerprint $fingerprint) {
                                Write-Log "SSH key accepted and saved for future syncs" -Level Success
                            }
                            else {
                                Write-Log "SSH key accepted for this session (unable to store fingerprint)" -Level Warning
                            }
                        }
                        else {
                            Write-Log "SSH key rejected by user" -Level Warning
                            return $false
                        }
                    }
                    catch {
                        Write-Log "Failed to scan SSH host key: $_" -Level Error
                        return $false
                    }
                }
                else {
                    throw $_
                }
            }
            
            # Use synchronization for fast, reliable recursive directory sync
            $transferOptions = New-Object WinSCP.TransferOptions
            $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
            $transferOptions.PreserveTimestamp = $false
            $transferOptions.ResumeSupport.State = [WinSCP.TransferResumeSupportState]::Off
            
            # Ensure remote directory exists
            try {
                $session.CreateDirectory($RemotePath) | Out-Null
            }
            catch {
                # Directory might already exist
            }

            # Use SynchronizeDirectories for fast bulk transfer
            Write-Log "Starting directory synchronization..." -Level Info
            
            # Get total file count for progress bar
            $localFiles = Get-ChildItem -Path $LocalPath -Recurse -File
            $totalFiles = $localFiles.Count
            
            if ($totalFiles -eq 0) {
                Write-Log "No files to sync" -Level Warning
                $session.Close()
                return $true
            }
            
            # Setup progress event handler
            $script:uploadedCount = 0
            $eventHandler = {
                param($sender, $e)
                $script:uploadedCount++
                $percentComplete = [int](($script:uploadedCount / $totalFiles) * 100)
                Write-Progress -Activity "Uploading files to $RemotePath" -Status "$($script:uploadedCount)/$totalFiles files" -PercentComplete $percentComplete
            }
            
            $session.add_FileTransferred($eventHandler)
            
            # Perform synchronization
            $synchronizationResult = $session.SynchronizeDirectories(
                [WinSCP.SynchronizationMode]::Remote,
                $LocalPath,
                $RemotePath,
                $false,  # Don't delete files
                $false,  # Mirror mode off
                [WinSCP.SynchronizationCriteria]::Time,
                $transferOptions
            )
            
            # Complete progress bar
            Write-Progress -Activity "Uploading files to $RemotePath" -Completed
            
            $synchronizationResult.Check()
            
            $session.Close()
            Write-Log "SFTP sync complete: $($synchronizationResult.Uploads.Count) files uploaded" -Level Success
            return $true
        }
        else {
            # Try to use Psftp (PuTTY) if available
            $psftp_path = "C:\Program Files\PuTTY\psftp.exe"
            if (-not (Test-Path $psftp_path)) {
                $psftp_path = "C:\Program Files (x86)\PuTTY\psftp.exe"
            }
            
            if (Test-Path $psftp_path) {
                Write-Log "Using Psftp for SFTP sync" -Level Info
                
                # Create batch script for psftp
                $batchFile = New-TemporaryFile
                $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($SftpPassword)
                )

                $batchScript = @"
open sftp://$SftpUsername@$SftpHost`:$SftpPort
$plainPassword
cd $RemotePath
lcd "$LocalPath"
mput *
exit
"@
                Set-Content -Path $batchFile -Value $batchScript -Encoding ASCII
                
                # Execute psftp with batch file
                & $psftp_path -b $batchFile 2>&1 | Write-Log -Level Info
                Remove-Item $batchFile -Force
                
                Write-Log "SFTP sync complete via Psftp" -Level Success
                return $true
            }
            else {
                Write-Log "Neither WinSCP nor PuTTY (psftp) found. Cannot sync files." -Level Error
                Write-Log "Install WinSCP or PuTTY for SFTP support." -Level Error
                return $false
            }
        }
    }
    catch {
        Write-Log "SFTP sync failed: $_" -Level Error
        return $false
    }
}

function Invoke-LogCleanup {
    param(
        [string]$LogDir,
        [string]$LogTag,
        [int]$MaxFiles
    )

    if ($MaxFiles -le 0 -or [string]::IsNullOrWhiteSpace($LogDir)) {
        return
    }

    $filter = "$LogTag`_*.log"
    $logFiles = Get-ChildItem -Path $LogDir -Filter $filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($logFiles.Count -gt $MaxFiles) {
        $logFiles | Select-Object -Skip $MaxFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Set-LogPath {
    <#
    .SYNOPSIS
    Sets up logging path and returns path for current log file
    
    .DESCRIPTION
    Creates CS2 logs directory if it doesn't exist
    Returns timestamp-based log file path
    
    .OUTPUTS
    String path to log file (e.g., Documents/CS2/<ServerUUID>/logs/update_2026-01-25_14-30-45.log)
    #>
    
    param(
        [string]$BaseDir = $PSScriptRoot,
        [string]$ServerUuid,
        [string]$LogTag = "script",
        [int]$MaxFiles = 5
    )
    
    if (-not [string]::IsNullOrWhiteSpace($ServerUuid)) {
        $logDir = Join-Path $env:USERPROFILE "Documents\CS2\$ServerUuid\logs"
    }
    else {
        $logDir = Join-Path $env:USERPROFILE "Documents\CS2\logs"
    }
    
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    $logTagSafe = $LogTag -replace "[^a-zA-Z0-9_-]", "_"
    if ([string]::IsNullOrWhiteSpace($logTagSafe)) {
        $logTagSafe = "script"
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logFile = Join-Path $logDir "$logTagSafe`_$timestamp.log"

    if (-not (Test-Path $logFile)) {
        New-Item -ItemType File -Path $logFile -Force | Out-Null
    }

    Invoke-LogCleanup -LogDir $logDir -LogTag $logTagSafe -MaxFiles $MaxFiles
    
    return $logFile
}

function Write-Log {
    <#
    .SYNOPSIS
    Writes log message to both console and log file
    
    .DESCRIPTION
    Appends timestamped message to log file and displays on console
    Supports different log levels (Info, Warning, Error, Success)
    
    .PARAMETER Message
    The message to log
    
    .PARAMETER Level
    Log level: Info, Warning, Error, Success (default: Info)
    
    .PARAMETER LogFile
    Path to log file (optional, can be set globally)
    #>
    
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info",
        [string]$LogFile
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to console with color
    switch ($Level) {
        "Info"    { Write-Host $logMessage -ForegroundColor Gray }
        "Warning" { Write-Host $logMessage -ForegroundColor Yellow }
        "Error"   { Write-Host $logMessage -ForegroundColor Red }
        "Success" { Write-Host $logMessage -ForegroundColor Green }
    }
    
    # Write to log file if specified
    if ($LogFile -and (Test-Path (Split-Path $LogFile))) {
        Add-Content -Path $LogFile -Value $logMessage -Encoding UTF8
    }
}

function Read-ServerConfig {
    <#
    .SYNOPSIS
    Reads and parses servers-config.json
    
    .DESCRIPTION
    Loads servers-config.json from script root directory
    Validates JSON structure
    Returns array of server objects
    
    .OUTPUTS
    Array of PSCustomObject with properties: name, uuid, schedule, day, time
    #>
    
    param([string]$ConfigPath)
    
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $PSScriptRoot "../servers-config.json"
    }
    
    if (-not (Test-Path $ConfigPath)) {
        return $null
    }
    
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        return $config.servers
    }
    catch {
        Write-Log "Failed to parse servers-config.json: $_" -Level Error
        return $null
    }
}

function Test-ServerConfig {
    <#
    .SYNOPSIS
    Validates servers-config.json structure and content
    
    .DESCRIPTION
    Checks if file exists, is valid JSON, and has required fields
    Validates each server has: name, uuid, schedule, day, time
    Optional: logRetention (non-negative integer)
    
    .PARAMETER ConfigPath
    Path to servers-config.json
    
    .OUTPUTS
    PSCustomObject with IsValid (bool), Message (string), ServerCount (int)
    #>
    
    param([string]$ConfigPath)
    
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $PSScriptRoot "../servers-config.json"
    }
    
    $result = @{
        IsValid = $false
        Message = ""
        ServerCount = 0
    }
    
    # Check if file exists
    if (-not (Test-Path $ConfigPath)) {
        $result.Message = "servers-config.json not found at $ConfigPath"
        return $result
    }
    
    # Try to parse JSON
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $result.Message = "Invalid JSON format: $_"
        return $result
    }
    
    # Check if servers array exists
    if (-not $config.servers -or $config.servers.Count -eq 0) {
        $result.Message = "No servers defined in config"
        return $result
    }
    
    # Validate each server
    $requiredFields = @("name", "uuid", "schedule", "day", "time")
    $serverCount = 0
    
    foreach ($server in $config.servers) {
        $serverCount++
        foreach ($field in $requiredFields) {
            if (-not $server.$field) {
                $result.Message = "Server '$($server.name)' missing required field: $field"
                return $result
            }
        }

        $parsedUuid = [Guid]::Empty
        if (-not [Guid]::TryParse($server.uuid, [ref]$parsedUuid)) {
            $result.Message = "Server '$($server.name)' has invalid UUID format. Use the full UUID from the Bisect panel."
            return $result
        }
        
        # Validate schedule value
        if ($server.schedule -notmatch "^(Weekly|Monthly|Daily)$") {
            $result.Message = "Server '$($server.name)' has invalid schedule: $($server.schedule). Must be Weekly, Monthly, or Daily"
            return $result
        }
        
        # Validate time format
        if ($server.time -notmatch "^\d{2}:\d{2}$") {
            $result.Message = "Server '$($server.name)' has invalid time format: $($server.time). Use HH:MM"
            return $result
        }

        if ($null -ne $server.logRetention) {
            $parsedRetention = 0
            if (-not [int]::TryParse($server.logRetention.ToString(), [ref]$parsedRetention)) {
                $result.Message = "Server '$($server.name)' has invalid logRetention: $($server.logRetention). Use a non-negative integer"
                return $result
            }
            if ($parsedRetention -lt 0) {
                $result.Message = "Server '$($server.name)' has invalid logRetention: $($server.logRetention). Must be 0 or greater"
                return $result
            }
        }
    }
    
    $result.IsValid = $true
    $result.Message = "Config valid with $serverCount server(s)"
    $result.ServerCount = $serverCount
    
    return $result
}

function Get-ConfigTemplate {
    <#
    .SYNOPSIS
    Returns example servers-config.json template
    
    .OUTPUTS
    String containing JSON template
    #>
    
        return @'
{
    "servers": [
        {
            "name": "Production",
            "uuid": "your-production-uuid-here",
            "schedule": "Weekly",
            "day": "Monday",
            "time": "02:00",
            "logRetention": 5
        },
        {
            "name": "Staging",
            "uuid": "your-staging-uuid-here",
            "schedule": "Weekly",
            "day": "Tuesday",
            "time": "02:00",
            "logRetention": 5
        },
        {
            "name": "Testing",
            "uuid": "your-testing-uuid-here",
            "schedule": "Weekly",
            "day": "Wednesday",
            "time": "02:00",
            "logRetention": 5
        }
    ]
}
'@
}

function Get-SshHostKeyFingerprint {
    <#
    .SYNOPSIS
    Retrieves stored SSH host key fingerprint for an SFTP host
    .DESCRIPTION
    Checks file-based storage first (~/.ssh/known_hosts_bisect), then Credential Manager
    #>

    param(
        [string]$SftpHost,
        [string]$SftpPort = "22"
    )

    # Try file-based storage first (more portable, survives credential changes)
    $knownHostsFile = Join-Path $env:USERPROFILE ".ssh\known_hosts"
    if (Test-Path $knownHostsFile) {
        try {
            $content = Get-Content $knownHostsFile -ErrorAction Stop
            $hostKey = "${SftpHost}:${SftpPort}"
            
            foreach ($line in $content) {
                if ($line -match "^([^\s]+)\s+(.+)$") {
                    if ($matches[1] -eq $hostKey) {
                        return $matches[2]
                    }
                }
            }
        }
        catch {
            # File read failed, continue to Credential Manager
        }
    }

    # Fallback to Credential Manager
    try {
        $vault = New-PasswordVault
        if (-not $vault) {
            return $null
        }

        $resource = "sftp://${SftpHost}:${SftpPort}"
        return $vault.Retrieve($resource, "SshHostKeyFingerprint").Password
    }
    catch {
        return $null
    }
}

function Set-SshHostKeyFingerprint {
    <#
    .SYNOPSIS
    Stores SSH host key fingerprint for an SFTP host
    .DESCRIPTION
    Stores in file-based storage (~/.ssh/known_hosts_bisect) for portability,
    also stores in Credential Manager as backup
    #>

    param(
        [string]$SftpHost,
        [string]$SftpPort = "22",
        [string]$Fingerprint
    )

    $success = $false

    # Store in file-based known_hosts format (primary method)
    try {
        $sshDir = Join-Path $env:USERPROFILE ".ssh"
        if (-not (Test-Path $sshDir)) {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        }

        $knownHostsFile = Join-Path $sshDir "known_hosts"
        $hostKey = "${SftpHost}:${SftpPort}"
        $entry = "$hostKey $Fingerprint"

        # Read existing entries, remove duplicates for this host
        $existingLines = @()
        if (Test-Path $knownHostsFile) {
            $existingLines = Get-Content $knownHostsFile | Where-Object { $_ -notmatch "^${hostKey}\s" }
        }

        # Append new entry
        $existingLines += $entry
        Set-Content -Path $knownHostsFile -Value $existingLines -Encoding UTF8
        $success = $true
    }
    catch {
        # File storage failed, but continue to try Credential Manager
    }

    # Also store in Credential Manager as backup
    try {
        $vault = New-PasswordVault
        if ($vault) {
            $resource = "sftp://${SftpHost}:${SftpPort}"

            try {
                $existing = $vault.Retrieve($resource, "SshHostKeyFingerprint")
                if ($existing) { $vault.Remove($existing) }
            }
            catch { }

            $vault.Add([Windows.Security.Credentials.PasswordCredential]::new($resource, "SshHostKeyFingerprint", $Fingerprint))
            $success = $true
        }
    }
    catch {
        # Credential Manager failed, but we might have succeeded with file storage
    }

    return $success
}

function Get-DefaultServerUuid {
    <#
    .SYNOPSIS
    Retrieves stored default server UUID for single-server mode
    #>

    try {
        $vault = New-PasswordVault
        if (-not $vault) {
            return $null
        }

        return $vault.Retrieve("https://games.bisecthosting.com/api", "DefaultServerUuid").Password
    }
    catch {
        return $null
    }
}

function Set-DefaultServerUuid {
    <#
    .SYNOPSIS
    Stores default server UUID for single-server mode
    #>

    param(
        [string]$ServerUuid
    )

    if ([string]::IsNullOrWhiteSpace($ServerUuid)) {
        return $false
    }

    try {
        $vault = New-PasswordVault
        if (-not $vault) {
            return $false
        }

        try {
            $existing = $vault.Retrieve("https://games.bisecthosting.com/api", "DefaultServerUuid")
            if ($existing) { $vault.Remove($existing) }
        }
        catch { }

        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new("https://games.bisecthosting.com/api", "DefaultServerUuid", $ServerUuid))
        return $true
    }
    catch {
        return $false
    }
}