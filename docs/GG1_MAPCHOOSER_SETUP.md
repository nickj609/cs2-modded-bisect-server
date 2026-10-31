# GG1MapChooser + PMM_GG1MapChooser

| | Version | Where | Loaded? |
| --- | --- | --- | --- |
| GG1MapChooser (ssypchenko) | 1.8.1 | `plugins/GG1MapChooser/`, API in `shared/ggmcAPI/` | Yes |
| PMM_GG1MapChooser (RRimmer bridge) | 0.1.0 | `plugins/PMM_GG1MapChooser/` (Harmony in `harmony/`) | Yes |

Both are pinned in `plugins.yaml`: the bridge Harmony-patches GG1 1.8.1 exactly. Upgrade them together, on purpose:
`scripts/Update-Plugins.ps1 -Component GG1MapChooser` and `-Component PMM_GG1MapChooser`.

GameModeManager 2.0 requires GG1: it has no RTV, nominate, end-of-map vote, `!map`, `!changemap` or `timeleft` of its
own. `!maps` is GameModeManager's menu: it removes GG1's `css_maps` at start-up. Don't deploy these with GameModeManager 1.0.x, which would run its RTV and map changes next to GG1's.

## Checks after a deploy

`cfg/GGMCmaps.tuning.json` in the repo holds the generated pools: 32 modes, from `gamemodes_server.txt` and the modes in
`GameModeManager.json`. **Tune `weight` / `minplayers` / `maxplayers` there**; GameModeManager keeps them
(`MapChooser.GeneratePools`). A deploy uploads the repo copy when it's newer, and edits made only on the server can be replaced.

GG1 only reads `cfg/GGMCmaps.json`. GameModeManager writes the current mode's pool to it on every mode change and runs
`reloadmaps`, so **don't edit that file**. GG1's pool vote and pool switching can't be used, since it only sees one pool.

**Full restart** after a deploy: the bridge uses Harmony, and `css_plugins reload` doesn't unload it.

`css_plugins list` shows `GG1_MapChooser` and `PMM_GG1MapChooser`; `css_pmm_gg1` (server console) reports the patches
applied; `!rtv`, `!nominate` and the end-of-map vote open as panorama panels; `!nominate` lists only the current mode's maps.

## Per-mode vote settings

GG1 has these only in its config. GameModeManager's server commands set them per mode, and `server.cfg` resets them on every map:

| Command | Used in | Effect |
| --- | --- | --- |
| `css_mapvote_extend true` | surf, KZ, bhop, course | "Extend map" in map votes (15 minutes, up to 5 times: `ExtendMapTimeMinutes`, `MaxExtendMapCount`) |
| `css_mapvote_auto false` | GunGame | No automatic end-of-map vote. GunGame starts its own at the win: `ggmc_mapvote_with_change 20` in `cfg/gungame/gungame.mapvote.cfg` |

## GG1 config (`configs/plugins/GG1MapChooser/GG1MapChooser.json`)

Written for this server (GG1's release has no config; CSS would generate defaults). Changes from GG1's defaults:

| Setting | Value | Why |
| --- | --- | --- |
| `VoteSettings.NominationsMenuMode`, `EndMapVoteMenuMode`, `PoolVoteSettings.MenuMode` | `wasd` | Required by the bridge: it takes over GG1's WASD menus and draws them on PanoramaMenu |
| `WinDrawSettings.TriggerRoundsBeforeEndVoteAtRoundStart` | `true` | Bridge requirement (the vote starts in freeze time, which the bridge extends) |
| `WinDrawSettings.TriggerVoteAtRoundStartSecondsFromStart` | `0` | Bridge requirement |
| `WinDrawSettings.VoteDependsOnRoundWins` | `true` | GG1 needs exactly one trigger (rounds or time limit), otherwise there's no automatic vote; rounds suit the bridge's freeze-time vote |
| `WinDrawSettings.ChangeMapAfterWinDraw` | `false` | GameModeManager changes the map at match end (after its countdown) with `ggmc_change_nextmap`; GG1 changing it too would mean two map changes. Same for `ChangeMapAfterTimeLimit` (already `false`) |
| `OtherSettings.RandomMapOnStart` | `false` | Default `true` changes to a random map 40 s after boot, overriding GameModeManager's default mode/map |
| `OtherSettings.LastDisconnectedChangeMap` | `false` | Default `true` changes map whenever the server empties; GameModeManager owns empty-server rotation |
| `DiscordSettings.DiscordWebhook` | empty | A webhook URL is a secret: put it in `custom_files` on the server, not the repo |

**Who does what (GameModeManager 2.0 with GG1):**

| | GameModeManager | GG1MapChooser |
| --- | --- | --- |
| Which maps can be picked | Keeps one pool per mode, gives GG1 the current mode's pool on every mode change | Votes, RTV, nominate, random picks: only from the active pool |
| End-of-map vote, round-limited matches | — | Starts it (`VoteDependsOnRoundWins`) |
| End-of-map vote, time-limited matches (surf, KZ, deathmatch …) and arms race | Starts it with `ggmc_mapvote_start` (`MapChooser.TriggerSecondsBeforeEnd`, default 60 s; `TriggerKillsBeforeEnd`, 13) | Runs it |
| Changing the map at match end / time limit / empty server | Countdown, then `ggmc_change_nextmap` (the voted map, else random from the pool) | Changes the map when told |
| Mode rotation and schedules | As before (`Rotation.ModeRotation`, `ModeSchedules`) | Pool follows the new mode |

A match with both a round and a time limit can reach either trigger first. GameModeManager doesn't start a vote while
one runs or after GG1 has picked a map.

GG1 reads `Newtonsoft.Json` from its own folder: the release put it in `shared/`, which CounterStrikeSharp would share
with every plugin, so `plugins.yaml` installs it next to GG1 instead.

## Bridge config (`configs/plugins/PMM_GG1MapChooser/PMM_GG1MapChooser.json`)

The release default. Useful keys: `Vote.DefaultMode` (`mouse` | `wasd` | `digits` | `chat`), `Vote.Position`,
`Maps` (title, picture, badge per map key). Official maps use CS2's own screenshots. For a workshop map, put a PNG into
the client addon at `panorama/images/custom_game/maps/<name>.png`, set `"Image": "maps/<name>.png"`, then run
`css_pmm_gg1 css` on the server and copy the generated `pmm_mapvote_maps.css` into the addon.

## Client addon files

Add to the **same** Workshop addon as PanoramaMenu (`docs/PANORAMA_MENU_SETUP.md`), from the bridge release's
`Content-addonmanager/`:

```
panorama/layout/custom_game/pmm_mapvote.xml
panorama/styles/custom_game/pmm_mapvote.css
panorama/styles/custom_game/pmm_mapvote_maps.css
```

Recompile and publish the addon again. Players rejoin to get it.
