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

function Test-BisectServerId {
    <#
    .SYNOPSIS
    Checks a value is a server ID the Bisect API accepts: the full UUID or the 8-character short identifier
    #>

    param([string]$Id)

    $parsed = [Guid]::Empty
    return [Guid]::TryParse($Id, [ref]$parsed) -or ($Id -match '^[0-9a-fA-F]{8}$')
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

    .PARAMETER RepoRoot
    Repository root. When set (WinSCP only): files removed from the repo since the deployed commit are deleted on the
    server before the upload, and the deployed commit is recorded after it (see Invoke-DeployDeletions).

    .PARAMETER SinceCommit
    Baseline commit for deletions instead of the one recorded on the server.

    .PARAMETER AllowLargeDelete
    Allow deleting more than 25% of the tracked files.

    .PARAMETER PlanDeletions
    Only list the files that would be deleted; upload nothing.

    .OUTPUTS
    $true if successful, $false otherwise
    #>

    param(
        [string]$SftpHost,
        [string]$SftpPort = "22",
        [string]$SftpUsername,
        [System.Security.SecureString]$SftpPassword,
        [string]$LocalPath,
        [string]$RemotePath = "/",
        [string]$RepoRoot,
        [string]$SinceCommit,
        [switch]$AllowLargeDelete,
        [switch]$PlanDeletions
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

            # Delete files removed from the repo since the deployed commit (before uploading).
            $deletions = $null
            if ($RepoRoot) {
                $deletions = Invoke-DeployDeletions -Session $session -RepoRoot $RepoRoot -RemoteRoot $RemotePath `
                                                    -SinceCommit $SinceCommit -AllowLargeDelete:$AllowLargeDelete -PlanOnly:$PlanDeletions
                if ($PlanDeletions -or -not $deletions.Ok) {
                    $session.Close()
                    return [bool]$deletions.Ok
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

            # Record what is now on the server, so the next deploy knows what to delete.
            if ($RepoRoot) {
                if ($deletions -and $deletions.RecordCommit) {
                    $git = Resolve-GitExe
                    $head = ("$(& $git -C $RepoRoot rev-parse HEAD)").Trim()
                    $dirty = [bool](& $git -C $RepoRoot status --porcelain -- game/csgo)
                    Write-DeployedCommit -Session $session -Commit $head -Dirty $dirty
                    Write-Log "Recorded deployed commit $($head.Substring(0,7)) on the server" -Level Info
                }
                else {
                    Write-Log "Deployed commit not recorded (see the warning above); the next deploy works from the same baseline" -Level Warning
                }
            }

            Update-RemoteGameinfo -Session $session -RemoteRoot $RemotePath

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
                if ($RepoRoot) {
                    Write-Log "Psftp can't delete files removed from the repo; install WinSCP for that. Files deleted from the repo stay on the server." -Level Warning
                    if ($PlanDeletions) { return $false }
                }
                
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
    Array of PSCustomObject with properties: name, uuid, role, schedule, day, time
    #>

    param([string]$ConfigPath)

    if (-not $ConfigPath) {
        $ConfigPath = Get-ServersConfigPath
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
    Validates each server has: name (letters, digits, - _; unique), uuid
    Optional: role (production | test, default production), schedule (Weekly | Monthly | Daily | Manual,
    default Manual; Weekly/Monthly need day, all but Manual need time), logRetention (non-negative integer)

    .PARAMETER ConfigPath
    Path to servers-config.json

    .OUTPUTS
    PSCustomObject with IsValid (bool), Message (string), ServerCount (int)
    #>

    param([string]$ConfigPath)

    if (-not $ConfigPath) {
        $ConfigPath = Get-ServersConfigPath
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
    $requiredFields = @("name", "uuid")
    $serverCount = 0
    $names = @{}

    foreach ($server in $config.servers) {
        $serverCount++
        foreach ($field in $requiredFields) {
            if (-not $server.$field) {
                $result.Message = "Server '$($server.name)' missing required field: $field"
                return $result
            }
        }

        # The name is used for the Credential Manager entry and task names
        if ("$($server.name)" -notmatch '^[A-Za-z0-9_-]+$') {
            $result.Message = "Server name '$($server.name)' may only contain letters, digits, - and _"
            return $result
        }
        if ($names.ContainsKey("$($server.name)".ToLowerInvariant())) {
            $result.Message = "Server name '$($server.name)' is used twice"
            return $result
        }
        $names["$($server.name)".ToLowerInvariant()] = $true

        if (-not (Test-BisectServerId $server.uuid)) {
            $result.Message = "Server '$($server.name)' has an invalid server ID. Use the server UUID or the 8-character short ID from the Bisect panel."
            return $result
        }

        if ($server.role -and "$($server.role)" -notmatch '^(production|test)$') {
            $result.Message = "Server '$($server.name)' has invalid role: $($server.role). Must be production or test"
            return $result
        }

        # Validate schedule value
        $schedule = if ($server.schedule) { "$($server.schedule)" } else { "Manual" }
        if ($schedule -notmatch "^(Weekly|Monthly|Daily|Manual)$") {
            $result.Message = "Server '$($server.name)' has invalid schedule: $($server.schedule). Must be Weekly, Monthly, Daily or Manual"
            return $result
        }
        if ($schedule -in @("Weekly", "Monthly") -and -not $server.day) {
            $result.Message = "Server '$($server.name)' needs a day for a $schedule schedule"
            return $result
        }

        # Validate time format
        if ($schedule -ne "Manual" -and "$($server.time)" -notmatch "^\d{2}:\d{2}$") {
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
            "name": "production",
            "uuid": "00000000-0000-0000-0000-000000000000",
            "role": "production",
            "schedule": "Manual",
            "logRetention": 5
        },
        {
            "name": "test",
            "uuid": "00000000-0000-0000-0000-000000000000",
            "role": "test",
            "schedule": "Manual",
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

function Read-SingleServerUuid {
    <#
    .SYNOPSIS
    Asks which server single-server mode should use, offering the saved default so it is never reused silently
    #>

    $saved = Get-DefaultServerUuid
    if ([string]::IsNullOrWhiteSpace($saved)) {
        $uuid = Read-Host "Enter Server UUID"
    }
    else {
        $uuid = Read-Host "Server UUID (press Enter to keep the saved one, $saved)"
        if ([string]::IsNullOrWhiteSpace($uuid)) { return $saved }
    }
    while (-not (Test-BisectServerId $uuid)) {
        Write-Host "Invalid server ID. Paste the server UUID or the 8-character short ID from the Bisect panel." -ForegroundColor Yellow
        $uuid = Read-Host "Enter Server UUID"
    }
    return $uuid
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

# ---------------------------------------------------------------------------
# Deploy deletions
#
# Sync-FilesViaSftp only uploads, so a file removed from the repo used to stay on the server forever.
# These helpers remove exactly the files git tracked under game/csgo at the last deployed commit that are
# no longer in the local folder. Files that were never in git (logs, databases, custom_files, workshop
# downloads) are never touched. The deployed commit is recorded on the server after a successful sync.
# ---------------------------------------------------------------------------

# Remote file (relative to the SFTP root, /home/container) holding the last deployed commit.
$script:DeployedCommitMarker = "/.cs2-deployed-commit"

function Resolve-GitExe {
    <#
    .SYNOPSIS
    Finds git: PATH first, then the copy bundled with GitHub Desktop.
    #>
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $desktop = Get-ChildItem "$env:LOCALAPPDATA\GitHubDesktop" -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "resources\app\git\cmd\git.exe" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    return $desktop
}

function Get-DeploymentDeletions {
    <#
    .SYNOPSIS
    Lists files to delete on the server: tracked under GameDir at Baseline, missing locally now.

    .PARAMETER RepoRoot
    Local repository root (folder containing game/csgo).

    .PARAMETER Baseline
    Commit (or ref) that is currently deployed on the server.

    .PARAMETER GameDir
    Repo-relative folder that is uploaded to /game/csgo.

    .OUTPUTS
    PSCustomObject: Baseline (full SHA), Head, Dirty, Tracked (count at baseline), Files (paths relative to GameDir)
    #>
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$Baseline,
        [string]$GameDir = "game/csgo"
    )

    $git = Resolve-GitExe
    if (-not $git) { throw "git not found (install Git or GitHub Desktop)" }

    # Windows PowerShell decodes native output with the console code page; git writes UTF-8 paths.
    $previousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try {

    $sha = (& $git -C $RepoRoot rev-parse --verify --quiet "$Baseline^{commit}") 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $sha) {
        throw "Commit '$Baseline' is not in the local repository. Fetch it, or pass -SinceCommit with the commit that is on the server."
    }
    $sha = "$sha".Trim()
    $head = ("$(& $git -C $RepoRoot rev-parse HEAD)").Trim()
    $dirty = [bool](& $git -C $RepoRoot status --porcelain -- $GameDir)

    # -z: NUL separated, so names with spaces or unicode come through unquoted.
    $raw = & $git -C $RepoRoot -c core.quotepath=off ls-tree -r -z --name-only $sha -- $GameDir
    if ($LASTEXITCODE -ne 0) { throw "git ls-tree failed for $sha" }
    $tracked = @(("$raw" -split "`0") | Where-Object { $_ })

    $prefix = $GameDir.TrimEnd('/') + '/'
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($path in $tracked) {
        $local = Join-Path $RepoRoot ($path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $local)) {
            $missing.Add($path.Substring($prefix.Length))
        }
    }

    return [PSCustomObject]@{
        Baseline = $sha
        Head     = $head
        Dirty    = $dirty
        Tracked  = $tracked.Count
        Files    = $missing.ToArray()
    }

    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }
}

function Add-MetamodToGameinfo {
    <#
    .SYNOPSIS
    Returns gameinfo.gi text with the Metamod search path added after the Game_LowViolence line (same as
    scripts/patch-gameinfo.sh). $null when it's already there; the same text back when that line can't be found.
    #>
    param([Parameter(Mandatory)] [string]$Text)

    if ($Text -match '(?m)^[ \t]*Game[ \t]+csgo/addons/metamod') { return $null }
    $eol = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    return ([regex]'(?m)^([ \t]*Game_LowViolence[ \t]+csgo_lv[^\r\n]*)(\r?\n)').Replace($Text, {
        param($m) $m.Groups[1].Value + $eol + "`t`t`tGame`tcsgo/addons/metamod" + $m.Groups[2].Value
    }, 1)
}

function Update-RemoteGameinfo {
    <#
    .SYNOPSIS
    Makes sure the server's gameinfo.gi loads Metamod, without which no plugin runs. It isn't part of the repo: a new
    server doesn't have the line, and a CS2 update can remove it. A problem here only warns; the deploy has succeeded.
    #>
    param(
        [Parameter(Mandatory)] $Session,
        [string]$RemoteRoot = "/game/csgo"
    )

    $remote = "$RemoteRoot/gameinfo.gi"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cs2-gameinfo-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        if (-not $Session.FileExists($remote)) {
            Write-Log "$remote not found (is CS2 installed on this server?): Metamod can't load until it's patched" -Level Warning
            return
        }
        $Session.GetFiles($Session.EscapeFileMask($remote), "$tmp\").Check()
        $local = Join-Path $tmp "gameinfo.gi"
        $text = [System.IO.File]::ReadAllText($local)
        $patched = Add-MetamodToGameinfo -Text $text
        if ($null -eq $patched) { return }
        if ($patched -eq $text) {
            Write-Log "gameinfo.gi has no Game_LowViolence line to add Metamod after: add 'Game csgo/addons/metamod' by hand" -Level Warning
            return
        }
        [System.IO.File]::WriteAllText($local, $patched, (New-Object System.Text.UTF8Encoding($false)))
        $Session.PutFiles($Session.EscapeFileMask($local), $remote).Check()
        Write-Log "gameinfo.gi patched to load Metamod" -Level Success
    }
    catch { Write-Log "Could not check gameinfo.gi: $_" -Level Warning }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Read-DeployedCommit {
    <#
    .SYNOPSIS
    Reads the commit recorded on the server by the last successful deploy ($null if none).
    #>
    param([Parameter(Mandatory)] $Session)

    if (-not $Session.FileExists($script:DeployedCommitMarker)) { return $null }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cs2-deployed-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $Session.GetFiles($Session.EscapeFileMask($script:DeployedCommitMarker), "$tmp\").Check()
        $text = Get-Content -LiteralPath (Join-Path $tmp (Split-Path $script:DeployedCommitMarker -Leaf)) -Raw
        $line = ($text -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -First 1)
        return $line
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-DeployedCommit {
    <#
    .SYNOPSIS
    Records the deployed commit on the server (first line: SHA; then when and whether the tree had local changes).
    #>
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string]$Commit,
        [bool]$Dirty = $false
    )

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cs2-deployed-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $file = Join-Path $tmp (Split-Path $script:DeployedCommitMarker -Leaf)
        $body = "$Commit`ndeployed $(Get-Date -Format o) from $env:COMPUTERNAME`nuncommitted changes: $Dirty`n"
        [System.IO.File]::WriteAllText($file, $body)
        $Session.PutFiles($Session.EscapeFileMask($file), $script:DeployedCommitMarker).Check()
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-RemoteFiles {
    <#
    .SYNOPSIS
    Deletes files under RemoteRoot, then folders the deletion left empty. Files already gone are not errors.

    .OUTPUTS
    PSCustomObject: Removed, Missing, Failed (list of "path: reason"), FoldersRemoved
    #>
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string]$RemoteRoot,
        [Parameter(Mandatory)] [string[]]$Files
    )

    $root = $RemoteRoot.TrimEnd('/')
    $removed = 0; $missing = 0; $foldersRemoved = 0
    $failed = New-Object System.Collections.Generic.List[string]
    $folders = New-Object System.Collections.Generic.HashSet[string]
    $i = 0

    foreach ($rel in $Files) {
        $i++
        Write-Progress -Activity "Removing deleted files from $root" -Status "$i/$($Files.Count)" -PercentComplete ([int](($i / $Files.Count) * 100))
        $remote = "$root/$rel"
        $parent = $remote.Substring(0, $remote.LastIndexOf('/'))
        [void]$folders.Add($parent)
        try {
            if (-not $Session.FileExists($remote)) { $missing++; continue }
            $result = $Session.RemoveFiles($Session.EscapeFileMask($remote))
            if ($result.IsSuccess) { $removed++ }
            else { $failed.Add("${rel}: $($result.Failures[0].Message)") }
        }
        catch {
            $failed.Add("${rel}: $_")
        }
    }
    Write-Progress -Activity "Removing deleted files from $root" -Completed

    # Deepest folders first; stop climbing at the first folder that still has content.
    $sorted = $folders | Sort-Object { ($_ -split '/').Count } -Descending
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($dir in $sorted) {
        $d = $dir
        while ($d.Length -gt $root.Length -and $seen.Add($d)) {
            try {
                if (-not $Session.FileExists($d)) { $d = $d.Substring(0, $d.LastIndexOf('/')); continue }
                $entries = @($Session.ListDirectory($d).Files | Where-Object { $_.Name -ne '.' -and $_.Name -ne '..' })
                if ($entries.Count -gt 0) { break }
                $Session.RemoveFiles($Session.EscapeFileMask($d)).Check()
                $foldersRemoved++
            }
            catch { break }
            $d = $d.Substring(0, $d.LastIndexOf('/'))
        }
    }

    return [PSCustomObject]@{
        Removed        = $removed
        Missing        = $missing
        Failed         = $failed.ToArray()
        FoldersRemoved = $foldersRemoved
    }
}

function Invoke-DeployDeletions {
    <#
    .SYNOPSIS
    Plans (and unless PlanOnly, applies) deploy deletions on an open WinSCP session.

    .PARAMETER SinceCommit
    Baseline to use instead of the commit recorded on the server (needed for the first deploy with this feature:
    pass the commit that is on the server now, usually the branch you last deployed, e.g. master).

    .PARAMETER AllowLargeDelete
    Allow deleting more than 25% of the files tracked at the baseline.

    .OUTPUTS
    PSCustomObject: Ok (bool), Plan (from Get-DeploymentDeletions or $null)
    #>
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string]$RemoteRoot = "/game/csgo",
        [string]$SinceCommit,
        [switch]$AllowLargeDelete,
        [switch]$PlanOnly
    )

    $baseline = $SinceCommit
    if (-not $baseline) {
        $baseline = Read-DeployedCommit -Session $Session
        if (-not $baseline) {
            Write-Log "No deployed commit recorded on the server yet: nothing is deleted and no commit is recorded. Run once with -SinceCommit <commit that is on the server now> (e.g. master) to start tracking." -Level Warning
            return [PSCustomObject]@{ Ok = $true; Plan = $null; RecordCommit = $false }
        }
        Write-Log "Server was last deployed from $baseline" -Level Info
    }

    try { $plan = Get-DeploymentDeletions -RepoRoot $RepoRoot -Baseline $baseline }
    catch {
        Write-Log "Cannot work out deleted files: $_" -Level Error
        return [PSCustomObject]@{ Ok = $false; Plan = $null }
    }

    if ($plan.Dirty) {
        Write-Log "game/csgo has uncommitted changes: they are deployed as they are on disk. Commit before deploying so the server matches a commit." -Level Warning
    }
    Write-Log "$($plan.Files.Count) file(s) removed since $($plan.Baseline.Substring(0,7)) (of $($plan.Tracked) tracked then)" -Level Info

    if ($plan.Files.Count -gt 0 -and $plan.Tracked -gt 0 -and ($plan.Files.Count / $plan.Tracked) -gt 0.25 -and -not $AllowLargeDelete) {
        Write-Log "Refusing to delete $($plan.Files.Count) of $($plan.Tracked) files (over 25%). Check the list with -PlanDeletions, then re-run with -AllowLargeDelete." -Level Error
        return [PSCustomObject]@{ Ok = $false; Plan = $plan }
    }

    if ($PlanOnly) {
        foreach ($f in $plan.Files) { Write-Host "  delete $RemoteRoot/$f" }
        return [PSCustomObject]@{ Ok = $true; Plan = $plan }
    }
    if ($plan.Files.Count -eq 0) { return [PSCustomObject]@{ Ok = $true; Plan = $plan; RecordCommit = $true } }

    $result = Remove-RemoteFiles -Session $Session -RemoteRoot $RemoteRoot -Files $plan.Files
    Write-Log "Deleted $($result.Removed) file(s) and $($result.FoldersRemoved) empty folder(s); $($result.Missing) were already gone" -Level Success
    if ($result.Failed.Count -gt 0) {
        foreach ($f in $result.Failed) { Write-Log "Could not delete $f" -Level Warning }
        Write-Log "$($result.Failed.Count) file(s) could not be deleted. The deployed commit is NOT updated, so the next deploy retries them." -Level Warning
    }
    return [PSCustomObject]@{ Ok = $true; Plan = $plan; RecordCommit = ($result.Failed.Count -eq 0) }
}


# ---------------------------------------------------------------------------
# Per-server credentials
#
# Each server in servers-config.json (by "name") has its own API key and SFTP login in Credential Manager,
# under the resource "cs2-bisect/<name>". The old single (global) credential set is still read for
# -ServerUuid / no-config use, and is copied to a production server the first time it is needed.
# ---------------------------------------------------------------------------

$script:ServerCredentialPrefix = "cs2-bisect/"
$script:ServerCredentialFields = @("ApiKey", "SftpHost", "SftpPort", "SftpUsername", "SftpPassword")

function Get-ServersConfigPath {
    <#
    .SYNOPSIS
    servers-config.json next to these scripts (bisect/), or the repo root for older setups.
    #>
    $here = Join-Path $PSScriptRoot "servers-config.json"
    $root = Join-Path $PSScriptRoot "../servers-config.json"
    if (Test-Path $here) { return $here }
    if (Test-Path $root) { return $root }
    return $here
}

function Get-ServerRole {
    param($Entry)
    if ($Entry.role) { return "$($Entry.role)".ToLowerInvariant() }
    return "production"
}

function Get-ServerEntry {
    <#
    .SYNOPSIS
    Finds a server in servers-config.json by name or UUID ($null if not there).
    #>
    param([string]$Name, [string]$Uuid)

    $servers = @(Read-ServerConfig -ConfigPath (Get-ServersConfigPath))
    foreach ($s in $servers) {
        if (-not $s) { continue }
        if ($Name -and "$($s.name)" -ieq $Name) { return $s }
        if ($Uuid -and "$($s.uuid)" -ieq $Uuid) { return $s }
    }
    return $null
}

function Test-ServerCredentials {
    <#
    .SYNOPSIS
    True when Credential Manager holds a credential set for this server name.
    #>
    param([Parameter(Mandatory)] [string]$Name)

    $vault = New-PasswordVault
    if (-not $vault) { return $false }
    try { [void]$vault.Retrieve("$($script:ServerCredentialPrefix)$Name", "ApiKey"); return $true }
    catch { return $false }
}

function Save-ServerCredentials {
    <#
    .SYNOPSIS
    Stores a credential set for one server (replaces any existing one).
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ApiKey,
        [Parameter(Mandatory)] [string]$SftpHost,
        [string]$SftpPort = "22",
        [Parameter(Mandatory)] [string]$SftpUsername,
        [Parameter(Mandatory)] [System.Security.SecureString]$SftpPassword
    )

    $vault = New-PasswordVault
    if (-not $vault) { throw "Windows Credential Manager (PasswordVault) is not available" }

    Remove-ServerCredentials -Name $Name | Out-Null
    $resource = "$($script:ServerCredentialPrefix)$Name"
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($SftpPassword))
    try {
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new($resource, "ApiKey", $ApiKey))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new($resource, "SftpHost", $SftpHost))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new($resource, "SftpPort", $(if ($SftpPort) { $SftpPort } else { "22" })))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new($resource, "SftpUsername", $SftpUsername))
        $vault.Add([Windows.Security.Credentials.PasswordCredential]::new($resource, "SftpPassword", $plain))
    }
    finally {
        $plain = $null
    }
}

function Remove-ServerCredentials {
    <#
    .SYNOPSIS
    Deletes the credential set of one server. Returns $true if anything was removed.
    #>
    param([Parameter(Mandatory)] [string]$Name)

    $vault = New-PasswordVault
    if (-not $vault) { return $false }
    $removed = $false
    foreach ($field in $script:ServerCredentialFields) {
        try {
            $cred = $vault.Retrieve("$($script:ServerCredentialPrefix)$Name", $field)
            if ($cred) { $vault.Remove($cred); $removed = $true }
        }
        catch { }
    }
    return $removed
}

function Read-ServerCredentialsInteractive {
    <#
    .SYNOPSIS
    Prompts for a server's API key and SFTP login (values passed in are not asked again).
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$ApiKey,
        [string]$SftpHost,
        [string]$SftpPort,
        [string]$SftpUsername,
        [string]$SftpPassword
    )

    Write-Host ""
    Write-Host "Credentials for server '$Name' (Bisect panel: Account > API, and the server's SFTP details)" -ForegroundColor Yellow
    Write-Host "(stored in Windows Credential Manager, DPAPI-encrypted)" -ForegroundColor Gray
    if (-not $ApiKey) { $ApiKey = Read-Host "Bisect API key" }
    if (-not $SftpHost) { $SftpHost = Read-Host "SFTP host" }
    if (-not $SftpPort) {
        $SftpPort = Read-Host "SFTP port (default: 22)"
        if (-not $SftpPort) { $SftpPort = "22" }
    }
    if (-not $SftpUsername) { $SftpUsername = Read-Host "SFTP username" }
    $secure = if ($SftpPassword) { ConvertTo-SecureString -String $SftpPassword -AsPlainText -Force } else { Read-Host "SFTP password" -AsSecureString }

    return @{
        ApiKey       = $ApiKey
        SftpHost     = $SftpHost
        SftpPort     = $SftpPort
        SftpUsername = $SftpUsername
        SftpPassword = $secure
    }
}

function Get-ServerCredentials {
    <#
    .SYNOPSIS
    Credentials of one server, as the hashtable the other helpers use (ApiKey, SftpHost, SftpPort, SftpUsername,
    SftpPassword as SecureString).

    .DESCRIPTION
    1. The server's own set ("cs2-bisect/<name>").
    2. For a production server with no set yet: the old single credential set, copied to the server's name.
    3. Otherwise: prompts (unless -NoPrompt) and stores what is entered.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [string]$Role = "production",
        [switch]$NoPrompt
    )

    $vault = New-PasswordVault
    if ($vault -and (Test-ServerCredentials -Name $Name)) {
        $resource = "$($script:ServerCredentialPrefix)$Name"
        $values = @{}
        foreach ($field in $script:ServerCredentialFields) {
            try { $values[$field] = $vault.Retrieve($resource, $field).Password } catch { $values[$field] = $null }
        }
        if (-not $values.SftpPort) { $values.SftpPort = "22" }
        return @{
            ApiKey       = $values.ApiKey
            SftpHost     = $values.SftpHost
            SftpPort     = $values.SftpPort
            SftpUsername = $values.SftpUsername
            SftpPassword = ConvertTo-SecureString -String "$($values.SftpPassword)" -AsPlainText -Force
        }
    }

    if ($Role -eq "production") {
        $global = Get-LegacyCredentials
        if ($global) {
            Save-ServerCredentials -Name $Name -ApiKey $global.ApiKey -SftpHost $global.SftpHost -SftpPort $global.SftpPort `
                                   -SftpUsername $global.SftpUsername -SftpPassword $global.SftpPassword
            Write-Log "Copied the existing (single) credentials to server '$Name'" -Level Info
            return $global
        }
    }

    if ($NoPrompt) { throw "No stored credentials for server '$Name'. Run: .\install.ps1 -AddServer $Name" }
    $entered = Read-ServerCredentialsInteractive -Name $Name
    Save-ServerCredentials -Name $Name @entered
    return $entered
}

function Get-LegacyCredentials {
    <#
    .SYNOPSIS
    The old single credential set, without prompting ($null if there is none).
    #>
    $vault = New-PasswordVault
    if (-not $vault) { return $null }
    try {
        $apiKey = $vault.Retrieve("https://games.bisecthosting.com/api", "ApiKey").Password
        $sftpHost = $vault.Retrieve("https://games.bisecthosting.com/api", "SftpHost").Password
        $sftpPort = $vault.Retrieve("https://games.bisecthosting.com/api", "SftpPort").Password
        $user = $vault.Retrieve("sftp://${sftpHost}:${sftpPort}", "username").Password
        $pass = $vault.Retrieve("sftp://${sftpHost}:${sftpPort}", "password").Password
        return @{
            ApiKey       = $apiKey
            SftpHost     = $sftpHost
            SftpPort     = $sftpPort
            SftpUsername = $user
            SftpPassword = ConvertTo-SecureString -String $pass -AsPlainText -Force
        }
    }
    catch { return $null }
}

function Resolve-TargetServer {
    <#
    .SYNOPSIS
    Works out which server a script acts on, and its credentials.

    .DESCRIPTION
    -Server <name>    : that entry of servers-config.json, with its own credentials.
    -ServerUuid <id>  : the config entry with that UUID (its credentials), else the old single credential set.
    neither           : the only production server in servers-config.json; with no config, the old default UUID
                        and single credential set (prompting as before).

    .OUTPUTS
    Hashtable: Name, Uuid, Role, Credentials, Legacy (bool)
    #>
    param([string]$Server, [string]$ServerUuid, [switch]$NoPrompt)

    if ($Server) {
        $entry = Get-ServerEntry -Name $Server
        if (-not $entry) { throw "No server named '$Server' in $(Get-ServersConfigPath). Add it with: .\install.ps1 -AddServer $Server" }
        $role = Get-ServerRole $entry
        return @{ Name = "$($entry.name)"; Uuid = "$($entry.uuid)"; Role = $role; Legacy = $false
                  Credentials = (Get-ServerCredentials -Name "$($entry.name)" -Role $role -NoPrompt:$NoPrompt) }
    }

    if ($ServerUuid) {
        $entry = Get-ServerEntry -Uuid $ServerUuid
        if ($entry) {
            $role = Get-ServerRole $entry
            return @{ Name = "$($entry.name)"; Uuid = "$($entry.uuid)"; Role = $role; Legacy = $false
                      Credentials = (Get-ServerCredentials -Name "$($entry.name)" -Role $role -NoPrompt:$NoPrompt) }
        }
        return @{ Name = "default"; Uuid = $ServerUuid; Role = "production"; Legacy = $true; Credentials = (Get-BisectCredentials) }
    }

    $production = @(@(Read-ServerConfig -ConfigPath (Get-ServersConfigPath)) | Where-Object { $_ -and (Get-ServerRole $_) -eq "production" })
    if ($production.Count -eq 1) {
        $entry = $production[0]
        return @{ Name = "$($entry.name)"; Uuid = "$($entry.uuid)"; Role = "production"; Legacy = $false
                  Credentials = (Get-ServerCredentials -Name "$($entry.name)" -Role "production" -NoPrompt:$NoPrompt) }
    }
    if ($production.Count -gt 1) {
        throw "servers-config.json has several production servers: pass -Server <name>"
    }

    # No config: the original single-server behaviour.
    $uuid = Get-DefaultServerUuid
    if ([string]::IsNullOrWhiteSpace($uuid)) {
        if ($NoPrompt) { throw "No server configured. Run: .\install.ps1 -AddServer production" }
        $uuid = Read-Host "Enter Server UUID"
        while (-not (Test-BisectServerId $uuid)) {
            Write-Host "Invalid server ID. Paste the server UUID or the 8-character short ID from the Bisect panel." -ForegroundColor Yellow
            $uuid = Read-Host "Enter Server UUID"
        }
    }
    return @{ Name = "default"; Uuid = $uuid; Role = "production"; Legacy = $true; Credentials = (Get-BisectCredentials) }
}

function Save-ServerEntry {
    <#
    .SYNOPSIS
    Adds or replaces a server (by name) in servers-config.json. Placeholder entries (no valid UUID) are dropped.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Uuid,
        [ValidateSet("production", "test")] [string]$Role = "production",
        [string]$Schedule = "Manual",
        [string]$Day,
        [string]$Time,
        [int]$LogRetention = 5
    )

    $path = Get-ServersConfigPath
    $existing = @()
    if (Test-Path $path) {
        try { $existing = @((Get-Content $path -Raw | ConvertFrom-Json).servers) } catch { $existing = @() }
    }

    $list = New-Object System.Collections.ArrayList
    foreach ($s in $existing) {
        if (-not $s) { continue }
        if (-not (Test-BisectServerId "$($s.uuid)")) { continue }   # template placeholder
        if ("$($s.name)" -ieq $Name) { continue }
        [void]$list.Add($s)
    }

    $entry = [ordered]@{ name = $Name; uuid = $Uuid; role = $Role; schedule = $Schedule }
    if ($Day) { $entry.day = $Day }
    if ($Time) { $entry.time = $Time }
    $entry.logRetention = $LogRetention
    [void]$list.Add([PSCustomObject]$entry)

    $json = ConvertTo-Json -InputObject ([ordered]@{ servers = @($list.ToArray()) }) -Depth 5
    [System.IO.File]::WriteAllText($path, $json + "`r`n")
    return $path
}

function Remove-ServerEntry {
    <#
    .SYNOPSIS
    Removes a server (by name) from servers-config.json. Returns $true if it was there.
    #>
    param([Parameter(Mandatory)] [string]$Name)

    $path = Get-ServersConfigPath
    if (-not (Test-Path $path)) { return $false }
    $servers = @((Get-Content $path -Raw | ConvertFrom-Json).servers | Where-Object { $_ })
    $keep = @($servers | Where-Object { "$($_.name)" -ine $Name })
    if ($keep.Count -eq $servers.Count) { return $false }
    $json = ConvertTo-Json -InputObject ([ordered]@{ servers = $keep }) -Depth 5
    [System.IO.File]::WriteAllText($path, $json + "`r`n")
    return $true
}

function Wait-BisectServerRunning {
    <#
    .SYNOPSIS
    Waits until the Bisect API reports the server as running. $true if it did within the timeout.
    #>
    param(
        [Parameter(Mandatory)] [string]$ServerUuid,
        [Parameter(Mandatory)] [string]$ApiKey,
        [int]$TimeoutSeconds = 300
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $state = "unknown"
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 5
        try {
            $resources = Invoke-BisectApi -Endpoint "/servers/$ServerUuid/resources" -ApiKey $ApiKey
            $state = "$($resources.attributes.current_state)"
            if ($state -eq "running") { return $true }
        }
        catch { $state = "error: $_" }
    }
    Write-Log "Server $ServerUuid not running after $TimeoutSeconds s (state: $state)" -Level Warning
    return $false
}
