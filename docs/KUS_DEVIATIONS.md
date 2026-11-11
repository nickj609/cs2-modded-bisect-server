# Where this server differs from Kus's repo

`master` is an exact copy of [kus/cs2-modded-server](https://github.com/kus/cs2-modded-server). Changes to **Kus's own files**
live in `custom_files/game/`, so `game/` stays Kus's and his updates merge cleanly. The deploy uploads `custom_files/game`
over `game` (`bisect/bisect.ps1`, `Sync-CustomFiles`), so the server runs our version.

`custom_files` is **git-ignored** (it holds admins and database settings), so this file is the record of what's in it and why.
Keep a copy of `custom_files` somewhere safe.

To see one change: compare `custom_files/game/csgo/<file>` with `git show master:game/csgo/<file>`.

## Possible pull requests to Kus

| Change | Files (in `custom_files/game/csgo/cfg/`) | Notes |
| --- | --- | --- |
| **Remove needless `sv_cheats 1` ... `sv_cheats 0` wrappers.** The ConVars inside aren't cheat-protected, and a cheat ConVar set that way doesn't stay set anyway: CS2 resets cheat ConVars when `sv_cheats` goes back to 0. | `1v1_settings`, `Casual-1.6_settings`, `aim_settings`, `awp_settings`, `battle_settings`, `br_settings`, `comp_settings`, `ctf_settings`, `deathmatch_settings`, `executes_settings`, `hns_settings`, `minigames_settings`, `oitc_settings`, `prefire_settings`, `retake_settings`, `rush_settings`, `scoutzknivez_settings`, `soccer_settings`, the `valve-*_settings`, `wingman_settings`, and `settings/disable_bhop`, `disable_dice`, `disable_fun`, `disable_map_voting`, `disable_warcraft`, `disable_weapon_speed` (the `enable_` ones are below) | Kept as they were: `MatchZy/prac.cfg`, `MatchZy/warmup.cfg`, `practice_settings.cfg` (they need cheats). |
| **SharpTimer 0.4.2 needs cs2-tags; ST-Fixes 1.0.5 is broken.** cs2-tags (`plugins/disabled/cs2-tags`) loads just before SharpTimer, and ST-Fixes isn't loaded: it calls `CBaseEntity.Speed`, which CounterStrikeSharp 1.0.379 removed, and unloading it crashed the server. | `bhop.cfg`, `course.cfg`, `kz.cfg`, `surf.cfg`, `unload_plugins.cfg` (unloads "Tags") | Goes with the plugin updates in `plugins.yaml`. |
| **`unload_plugins.cfg`: Deathmatch's name.** The plugin's name is "Deathmatch", not "Deathmatch Core", so it was never unloaded. | `unload_plugins.cfg` | Bug fix. |
| **`45.cfg` runs `custom_45.cfg`**, not `custom_comp.cfg`. | `45.cfg` | Bug fix. |
| **FixRandomSpawn: reload, not load.** It only finds the game rules on a reload or map start; disabling unloads it. | `settings/enable_random_spawns.cfg`, `settings/disable_random_spawns.cfg` | Bug fix. |
| **Practice mode starts by itself.** MatchZy's `config.cfg` sets `matchzy_autostart_mode 1` when it loads, after `practice.cfg`'s 2, so practice never started. GameModeManager runs `prac_settings.cfg` half a second after a practice map starts; it sets 2 there. | `prac_settings.cfg` | Ours (not in Kus's repo). |

## GameModeManager 2.x, for Kus only if he moves to it

| Change | Files | Notes |
| --- | --- | --- |
| **Map votes are GG1MapChooser's.** RockTheVote's `css_rtv_*` become `css_mapvote_*` and `ggmc_*`. | `server.cfg`, `bhop_settings`, `course_settings`, `deathrun_settings`, `gg_settings`, `kz_settings`, `surf_settings`, `gungame/gungame.gameend.cfg`, `gungame/gungame.mapvote.cfg` | Needs GameModeManager 2 and GG1MapChooser. |
| **Setting headers** (`// name:`, `// group:`, `// conflicts:` ...) so the settings menus show a name and a group. Also without the sv_cheats wrappers. | `settings/enable_bhop`, `enable_course`, `enable_course_settings`, `enable_custom_player_models`, `enable_dice`, `enable_fun`, `enable_one_round`, `enable_random_spawns`, `enable_revive`, `enable_scoutz`, `enable_surf`, `enable_teleport_kill`, `enable_warcraft`, `enable_weapon_speed` | Comments: harmless for GameModeManager 1. |

`GameModeManager.json` (in `game/`) hides `course`, `course_settings`, `surf` and `scoutz` from the settings menus
(`Settings.Hidden`): they're modes, not settings.

## This server only (not for Kus)

- `custom_*.cfg`: our per-mode settings (server name and so on).
- `MatchZy/config.cfg`: red chat prefixes.
- `admins.json`, `admin_groups.json`, `MatchZy/database.json`, `SharpTimer/*Config.json`, CS2-SimpleAdmin, PlayerModelChanger,
  Deathmatch, K4-Arenas, MenuManagerCore, PlayerSettings and K4ryuuDamageInfo configs: admins and database settings.
- `multiaddonmanager/multiaddonmanager.cfg`: the Workshop addons the server mounts.
- `sv_server_graphic1.png`, `sv_server_graphic2.png`.

## In `game/` itself

These stay in `game/`, because an override can only add or replace a file, or because something else installs them:

- **Plugin files and their configs** are `plugins.yaml`'s (`cfg/SharpTimer/`, `cfg/GGMCmaps*.json`, plugin folders). The
  checker installs them; a sync with Kus keeps ours.
- **GameModeManager's own settings, actions and warmups** come from its release (`settings/`, `actions/`, `warmup/`).
- **Removed or renamed:**
  - `settings/enable_random_skills.cfg` and `disable_random_skills.cfg` became `enable_random_round.cfg` and `disable_random_round.cfg`.
  - `settings/enable_spectator_list.cfg` and `disable_spectator_list.cfg` are removed with SpectatorList, which was broken.
  - `SharpTimer/MapData/surf_hearth.json` is removed, from the SharpTimer update.
