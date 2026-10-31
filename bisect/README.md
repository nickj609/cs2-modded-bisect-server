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

# Preview which files would be deleted on the server (server keeps running, nothing uploaded)
.\update.ps1 -PlanDeletions

# First deploy with deletions: tell it what is on the server now (the branch/commit you last deployed)
.\update.ps1 -SinceCommit master -PlanDeletions
.\update.ps1 -SinceCommit master -AllowLargeDelete
```

## Several servers (per-server credentials)

Each server has a name in `bisect/servers-config.json` and its **own** API key + SFTP login in Credential Manager
(`cs2-bisect/<name>`), so a test server and production can have different logins or even different Bisect accounts.

```powershell
# Register servers (asks for the UUID and credentials, checks them, saves; no deploy)
.\install.ps1 -AddServer production -Role production   # offers to reuse the credentials you already stored
.\install.ps1 -AddServer test -Role test

# Act on one server
.\update.ps1 -Server test -PlanDeletions
.\update.ps1 -Server test -SinceCommit HEAD     # first deploy to a fresh server (nothing old to delete)
.\start.ps1 -Server test
.\stop.ps1 -Server test
.\update.ps1 -Server test -UpdateCredentials    # change that server's stored login

# Test servers first, production only if they all come up
.\deploy.ps1 -PlanDeletions
.\deploy.ps1
.\deploy.ps1 -RegisterTask -Schedule Weekly -Day Monday -Time 04:00   # one scheduled task, runs with -Pull

# Remove a server (config entry, credentials, its scheduled tasks)
.\uninstall.ps1 -RemoveServer test
```

`servers-config.json` entries: `name` (letters, digits, `-`, `_`), `uuid` (full UUID or 8-character short ID), `role` (`production` | `test`, default
production), optional `schedule` (`Manual` | `Daily` | `Weekly` | `Monthly`, default Manual; Weekly/Monthly need `day`,
all but Manual need `time`) and `logRetention`. It holds no secrets, but it is committed: server names and UUIDs are
visible in the repo.

**Which server a script uses:** `-Server <name>`; else `-ServerUuid <uuid>` (the config entry with that UUID, or the
old single credential set if it isn't in the config); else the only production server in the config; with an empty
config, the old default UUID and single credential set, exactly as before.

**Migrating:** nothing changes until you add servers. The first time a production server needs credentials and has
none of its own, the old single set is copied to it. Test servers never inherit them.

**deploy.ps1** order: optional `git pull --ff-only` (`-Pull`, refuses with local changes) -> `ServerBundleCheck` (if
dotnet is installed; errors stop the deploy) -> each test server: `update.ps1 -Server <name>`, then wait until the
Bisect API reports `running` (`-HealthTimeout`, default 300 s) -> production, only if every test server passed
(`-SkipTest` to override). With no test server configured it warns and deploys production after the checks.

## Testing a local GameModeManager build

`test-build.ps1` goes from local code to a running test server in one command. It builds the sibling `GameModeManager` repo as the same zip a release publishes, installs it into `game/csgo` (uncommitted, version `<version>-test.<commit>` in `plugins.yaml`), runs `ServerBundleCheck`, and deploys to the test server only. It refuses a server with role `production`, and refuses to install on `main` or `master`.

```powershell
.install.ps1 -AddServer test -Role test   # once: asks for the UUID, API key and SFTP login
.	est-build.ps1 -Plan                      # build and show the changes; nothing is written or uploaded
.	est-build.ps1 -FirstDeploy               # first deploy to a new server
.	est-build.ps1                            # every time after that
```

The next real release replaces the test build through the plugin update.

Every deploy also checks the server's `gameinfo.gi` and adds the Metamod line if it's missing (a new server doesn't have it, and a CS2 update can remove it).

## Deleted files (WinSCP)

Uploading never removes anything, so `update.ps1` also deletes files that were removed from the repo:

1. **Baseline:** the commit recorded on the server in `/home/container/.cs2-deployed-commit` by the last
   successful deploy, or `-SinceCommit <ref>`.
2. **Deleted:** files git tracked under `game/csgo` at the baseline that no longer exist in the local
   `game/csgo` (committed or not). Files that were never in git (logs, databases, `custom_files`, workshop
   downloads) are never touched. Folders left empty are removed.
3. **Then** the upload runs, then `custom_files` are applied (so an override of a deleted file comes back).
4. **Recorded:** after a successful upload, the current commit is written to the marker. If any deletion failed,
   or there was no baseline, it is not, so the next deploy works from the same baseline.

Safeguards: more than 25% of the tracked files needs `-AllowLargeDelete`; with no marker and no `-SinceCommit`
nothing is deleted (a warning says so); `-NoDeletions` gives the old upload-only behaviour. `install.ps1` records
`HEAD` for a fresh server. Deploy from a committed tree so the marker matches what's on the server (uncommitted
changes are uploaded too, with a warning). Deletions need WinSCP; the PuTTY fallback only uploads.

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
