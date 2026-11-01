# ServerBundleCheck

Checks that what is in `game/csgo` matches `plugins.yaml` and will load on the server. It reads DLL metadata only;
nothing is loaded or run. CI runs it on every PR and push to `master` (`.github/workflows/validate.yml`).

```bash
dotnet build ci/ServerBundleCheck -c Release
dotnet ci/ServerBundleCheck/bin/Release/net10.0/ServerBundleCheck.dll check            # errors fail (exit 1)
dotnet ci/ServerBundleCheck/bin/Release/net10.0/ServerBundleCheck.dll check --strict   # warnings fail too
dotnet ci/ServerBundleCheck/bin/Release/net10.0/ServerBundleCheck.dll check --verbose  # also show info lines
dotnet ci/ServerBundleCheck/bin/Release/net10.0/ServerBundleCheck.dll inventory        # table of installed plugins
```

## Updating plugins

Run `scripts/Update-Plugins.ps1` (Windows PowerShell 5.1 or pwsh). It builds this tool, runs `update`, then `check`.
It writes to the repo only; nothing is committed or deployed.

```powershell
.\scripts\Update-Plugins.ps1 -DryRun -Verbose     # what would change, including old files a release no longer ships
.\scripts\Update-Plugins.ps1 -Component MatchZy   # one component
.\scripts\Update-Plugins.ps1 -Prune               # update all, and delete old files the new releases don't ship
```

How it decides, per component in `plugins.yaml`:

1. **Latest release:** GitHub `releases/latest` (or a download page + `pattern` for Metamod). Versions are compared
   after stripping `v`, `release-`, `build-`. `pin: true` components are reported, not changed.
2. **Release file:** `asset` (glob, or `re:<regex>`), else the only file that isn't Windows/macOS/`with-cssharp`, else
   the `linux` one. Several candidates is an error asking for `asset`.
3. **Where files go:** each entry of `paths` is found in the unpacked archive by the longest matching tail of the path
   (`plugins/disabled/X` matches `plugins/X`; config paths must match from `configs/` or `cfg/`), or by the folder holding
   the plugin's main DLL, or by an `install: [{from, to}]` override. `configs` are copied only if missing. `keep` globs
   are never overwritten or removed.
4. **Never copied into plugin folders:** `CounterStrikeSharp.API.dll` and any DLL that belongs in `shared/`.
5. **Removed:** files the previous release installed (from `plugins.lock.json`) that the new one doesn't ship. Files
   recorded by `lock --init` are only listed, unless `--prune`. Even with `--prune`, native libraries for the server's
   platform (`runtimes/linux-x64`, `linux-musl-x64`) are kept: GG2 1.2.4 dropped them from its release but still needs
   SQLite. Folders left empty are removed.
5a. **Reported, not fatal:** release files no path maps (`!` lines: decide whether to add a path), a single owned file
   the release no longer ships (kept), and a plugin whose ModuleName changed (the manifest `module` is updated; fix
   `css_plugins unload` lines in `cfg/` by hand, the checker then confirms them).
6. **Recorded:** the new version in `plugins.yaml` (in place, comments kept), the file list in `plugins.lock.json`, and
   `server.css_api` when CounterStrikeSharp itself updates.

`plugins.lock.json` is created by `lock --init` from what is in the repo. Commit it with `plugins.yaml`. After
reverting a component's files by hand (e.g. `git checkout HEAD -- <its paths>`), re-record just that entry with
`lock --init --force --component <name>`.

Always review `-DryRun -Verbose` before a real run: check the `!` (not installed) lines and what `--prune` removes.

## Update PR on demand

The weekly check is `scripts/Check-Updates.ps1`, run from the PC by the `plugin-update-review` skill. `.github/workflows/plugin-updates.yml` runs only on demand (Actions > Plugin updates > Run
workflow, optionally one `component` and `prune`). It runs `update` and `check` on a clean checkout of `master`, then
opens or updates **one** PR from the branch `automation/plugin-updates` with the version table, release-note links
and the check results. If the check finds errors the PR is opened as a draft. No updates means no PR. Nothing is merged or
deployed by the workflow.

One-time setup on GitHub:

1. **Settings > Actions > General > Workflow permissions:** tick *Allow GitHub Actions to create and approve pull
   requests* (the default token can't open PRs otherwise).
2. **Optional, recommended:** add a repository secret `PLUGIN_UPDATES_TOKEN`, a fine-grained personal access token
   for this repo with *Contents: read and write* and *Pull requests: read and write*. PRs opened with the default
   `GITHUB_TOKEN` don't trigger other workflows, so without it `validate.yml` doesn't run on the update PR (the
   workflow runs the same check itself and puts the result in the PR description, so this is a convenience).

Reviewing the PR: GitHub Desktop > *Current branch* > `automation/plugin-updates` shows the files. Read the release
notes linked in the table, check the run log for `!` lines (release files nothing installs), merge, then
`bisect\deploy.ps1 -Pull` (test server first). To change what the bot did, push commits to that branch; the next run
updates the PR from a fresh `master` and replaces them, so merge or close it first.

## Inventory

`inventory` prints each plugin's ModuleName, ModuleVersion, MinimumApiVersion, target framework and the
CounterStrikeSharp.API version it was compiled against. Use it when adding a component to `plugins.yaml`.

| Check | Error when | Warning when |
| --- | --- | --- |
| manifest | duplicate names, bad `kind`, a listed path is missing, `requires` names an unknown component | no `source`, plugin without `module` |
| coverage | a folder under `addons/`, `plugins/`, `plugins/disabled/` or `shared/` (or a vdf) is not in `plugins.yaml` | a `configs/plugins/<X>` folder belongs to no component |
| runtime | `server.css_api` ≠ the bundled CounterStrikeSharp.API; CSS targets a newer .NET than the bundled runtime | several .NET runtimes bundled |
| compatibility | a plugin targets a newer .NET than the runtime, needs a newer CSS (`MinimumApiVersion` or compiled-against version), or its ModuleName ≠ `module` | a referenced assembly is nowhere on the server |
| placement | `0Harmony.dll` next to a plugin DLL | a plugin folder carries its own `CounterStrikeSharp.API.dll` / `MenuManagerApi.dll`, or a copy of a DLL that is in `shared/` |
| cfg | `css_plugins load` path missing; `css_plugins unload` of an `always_loaded` plugin; `meta load` target missing | `css_plugins unload/reload` name matches no installed plugin |
| configs | a JSON config doesn't parse; `gamemodes_server.txt` isn't valid VDF; a GameModeManager mode's cfg or map group is missing | — |
| secrets | Discord webhook URL, Steam login token or Steam Web API key in a tracked file | a non-empty password in a JSON config |

"Shared" follows CounterStrikeSharp's loader (`PluginManager.LoadSharedLibraries`): only `shared/<Name>/<Name>.dll` is shared
with plugins. Other DLLs in a shared folder (e.g. AnyBaseLib's Dapper / MySqlConnector) are that library's own dependencies.
A plugin loads a DLL from its own folder before falling back to `shared/`, which is why a local copy of a contract can split
a capability into two incompatible types.

Files OneDrive keeps online-only can't be read; the error says so. Mark the repo folder "Always keep on this device".
