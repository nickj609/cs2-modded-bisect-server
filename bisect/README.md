# CS2 Modded Server (Bisect Hosting)

All credit goes to [Kus](https://github.com/kus/) for the original project: [cs2-modded-server](https://github.com/kus/cs2-modded-server).

## What this does
This repository automates install/update of [cs2-modded-server](https://github.com/kus/cs2-modded-server) on Bisect Hosting using PowerShell:
- Syncs mod files to `/game/csgo`
- Applies **remote** custom overrides from `/home/container/custom_files` into `/home/container`
- Supports single server and multi‑server deployments
- Optionally creates Task Scheduler update tasks

## Requirements
- Windows host (PowerShell)
- WinSCP (recommended) or PuTTY `psftp` (fallback)
- Bisect Hosting API key + SFTP credentials

## Documentation
- Quick Start: [QUICK_START.md](QUICK_START.md)
- Troubleshooting: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## Core scripts
- **install.ps1** – initial deployment (single or multi)
- **update.ps1** – manual update (single) or sync custom files only
- **start.ps1** – start a server via API
- **stop.ps1** – stop a server via API
- **uninstall.ps1** – remove scheduled tasks and optionally clear credentials

## Remote custom files (important)
Custom overrides live **on the server** at:
```
/home/container/custom_files
```
During install/update, contents are copied into:
```
/home/container
```
This means a file at:
```
/home/container/custom_files/game/csgo/cfg/comp.cfg
```
overrides:
```
/home/container/game/csgo/cfg/comp.cfg
```

## Local backups + logs
- Custom files backup (from remote):
  %USERPROFILE%\Documents\CS2\<SERVERUUID>\custom_files\<timestamp>
- Logs:
  %USERPROFILE%\Documents\CS2\<SERVERUUID>\logs\<timestamp>.log

## Script Parameters

### install.ps1 & update.ps1
```powershell
# Provide credentials non-interactively
.\install.ps1 -ApiKey "key" -SftpHost "host" -SftpPort "22" -SftpUsername "user" -SftpPassword "pass"

# Update only stored credentials (prompts interactively)
.\install.ps1 -UpdateCredentials

# Update only the API key
.\install.ps1 -UpdateApiKeyOnly

# Multi-server mode
.\install.ps1 -MultiServer
```

### update.ps1
```powershell
# Full update (stop, sync files, sync custom files, start)
.\update.ps1 -ServerUuid "uuid"

# Sync custom files only (stops/starts server)
.\update.ps1 -ServerUuid "uuid" -CustomFilesOnly

# Update credentials and sync
.\update.ps1 -UpdateCredentials

# Provide credentials directly
.\update.ps1 -ApiKey "key" -SftpHost "host" -SftpPort "22" -SftpUsername "user" -SftpPassword "pass"
```

### start.ps1 & stop.ps1
```powershell
# Uses default server UUID if available
.\start.ps1
.\stop.ps1

# Specify server UUID
.\start.ps1 -ServerUuid "uuid"
.\stop.ps1 -ServerUuid "uuid"

# Provide API key directly
.\start.ps1 -ServerUuid "uuid" -ApiKey "key"
```

## Notes
- Credentials are stored securely in Windows Credential Manager (DPAPI-encrypted)
- Default server UUID is automatically stored after first install
- All scripts support parameter-driven, non-interactive operation
- Custom files on the remote server persist across updates
