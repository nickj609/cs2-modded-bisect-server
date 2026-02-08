# Quick Start

## Prerequisites
- Windows host (PowerShell)
- WinSCP installed (recommended)
- Bisect Hosting API key + SFTP credentials

## Single server
```powershell
cd scripts
.\install.ps1
```
Follow prompts for credentials, UUID, and optional scheduled task.

## Multi‑server
```powershell
Copy-Item scripts\servers-config.json.example servers-config.json
# Edit servers-config.json with your servers

cd scripts
.\install.ps1
```
Select option 2 and follow prompts.

## Manual update
```powershell
cd scripts
.\update.ps1
# or
.\update.ps1 -ServerUuid "your-uuid"
```

## Sync custom files only
```powershell
# Updates custom files without syncing mod files
.\update.ps1 -CustomFilesOnly
```

## Start/stop server
```powershell
# Start server
.\start.ps1
# or
.\start.ps1 -ServerUuid "your-uuid"

# Stop server
.\stop.ps1
# or
.\stop.ps1 -ServerUuid "your-uuid"
```

## Non-interactive mode (CI/automation)
```powershell
# Install with provided credentials
.\install.ps1 -ApiKey "your-key" -SftpHost "host" -SftpPort "22" -SftpUsername "user" -SftpPassword "pass" -ServerUuid "uuid"

# Update with new credentials
.\update.ps1 -ServerUuid "uuid" -ApiKey "new-key" -SftpHost "host" -SftpPort "22" -SftpUsername "user" -SftpPassword "pass"

# Start/stop with API key
.\start.ps1 -ServerUuid "uuid" -ApiKey "key"
.\stop.ps1 -ServerUuid "uuid" -ApiKey "key"
```

## Credential management
```powershell
# Update all stored credentials interactively
.\install.ps1 -UpdateCredentials

# Update only API key
.\install.ps1 -UpdateApiKeyOnly
```

## Logs
```
%USERPROFILE%\Documents\CS2\<SERVERUUID>\logs\
```
