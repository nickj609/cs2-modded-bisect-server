# Troubleshooting

## Credentials
- Re‑enter credentials: `scripts\install.ps1 -UpdateCredentials`
- If Credential Manager fails, run PowerShell as Administrator.

## SFTP / WinSCP
- Install WinSCP: https://winscp.net/eng/download.php
- Verify SFTP host/username/password in Bisect panel.

## API
- 401 Unauthorized → invalid API key (re‑enter credentials).
- Wrong UUID → pass `-ServerUuid` or set default in install.

## Sync issues
- Ensure local `game/csgo` exists.
- Remote path is `/game/csgo`.
- No files synced often means already up‑to‑date.

## Task Scheduler
- Run PowerShell as Administrator to create tasks.
- Verify tasks: `Get-ScheduledTask | Where-Object { $_.TaskName -match "CS2" }`

## Logs
```
%USERPROFILE%\Documents\CS2\<SERVERUUID>\logs\
```
