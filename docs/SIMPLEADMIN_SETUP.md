# CS2-SimpleAdmin + PMM_SimpleAdmin

| | Version | Where | Loaded? |
| --- | --- | --- | --- |
| CS2-SimpleAdmin (daffyyyy) | build-1.9.1 | `plugins/CS2-SimpleAdmin/`, API in `shared/CS2-SimpleAdminApi/` | Yes |
| CS2-SimpleAdmin_FunCommands (same release) | build-1.9.1 | `plugins/CS2-SimpleAdmin_FunCommands/` | Yes |
| PMM_SimpleAdmin (RRimmer bridge) | 0.1.1 | `plugins/PMM_SimpleAdmin/` (Harmony in `harmony/`) | Yes |

They replace connercsbn's SimpleAdmin 0.1.2, which is removed from the repo. All three are pinned in `plugins.yaml`:
the bridge Harmony-patches SimpleAdmin 1.9.x, and it needs PanoramaMenuManager (already installed). Upgrade them together,
on purpose: `scripts/Update-Plugins.ps1 -Component CS2-SimpleAdmin`, `-Component CS2-SimpleAdmin_FunCommands` and
`-Component PMM_SimpleAdmin`.

The release's third module, `CS2-SimpleAdmin_StealthModule` (hides admins from players), is not installed. The release
also copies `CS2-SimpleAdminApi.dll` into each plugin folder; the updater installs it only in `shared/`.

## Admins

Nothing to migrate. Admins stay in CounterStrikeSharp's own `configs/admins.json` and `admin_groups.json` (`#css/admin`,
`#css/moderator`), and SimpleAdmin checks those same `@css/...` flags. SimpleAdmin can also keep admins in its database
(`css_addadmin`, `css_addgroup`); both sources work together. The old plugin kept no data in the repo.

If the old plugin left a database file on the server, the deploy doesn't remove it (it only deletes files the repo
deleted). Delete `addons/counterstrikesharp/plugins/SimpleAdmin/` on the server by hand if it's still there after the
first deploy.

## Database

`configs/plugins/CS2-SimpleAdmin/CS2-SimpleAdmin.json` is not in the repo: CounterStrikeSharp writes it with defaults on
the first start. The default is **SQLite** (`cs2-simpleadmin.sqlite` in the plugin folder), which is enough for one
server. Bans and mutes then live on that server only.

For MySQL (shared bans across the production and test servers), don't put the password in the repo. Put the whole
config file in the server's `custom_files/addons/counterstrikesharp/configs/plugins/CS2-SimpleAdmin/CS2-SimpleAdmin.json`
with:

```json
"DatabaseConfig": {
  "DatabaseType": "MySQL",
  "DatabaseHost": "...",
  "DatabasePort": 3306,
  "DatabaseUser": "...",
  "DatabasePassword": "...",
  "DatabaseName": "cs2_simpleadmin",
  "DatabaseSSlMode": "preferred"
}
```

Same rule for Discord webhooks (`Discord.DiscordLogWebhook` and the per-penalty `Webhook` values). Other defaults worth a
look after the first start: `EnableMetrics` and `EnableUpdateCheck` (both `true`, they contact the author's servers),
`MultiServerMode` (`true`), `OtherSettings.MaxBanDuration` / `MaxMuteDuration` for non-root admins.

## Commands that clash (`Commands.json`)

`configs/plugins/CS2-SimpleAdmin/Commands.json` is in the repo. Two plugins registering the same command both run it,
so it renames one of SimpleAdmin's commands:

| SimpleAdmin default | Renamed to | Kept by |
| --- | --- | --- |
| `css_rcon` | `css_sa_rcon` | CS2Rcon (`!rcon`) |

Every command not listed in the file keeps its default name. SimpleAdmin owns the admin map commands: `!map` /
`!changemap <map>` and `!wsmap` / `!changewsmap` / `!workshop`. They change only the map; `!mode` (GameModeManager)
changes the mode. SimpleAdmin's admin menu (`!admin`) changes maps through its own code, not the command. See the full
list in the [SimpleAdmin docs](https://github.com/daffyyyy/CS2-SimpleAdmin/tree/main/CS2-SimpleAdmin-docs/docs/user/commands).

This assumes GameModeManager 2.0, which registers neither name. With 1.0.x, `!map` would run twice.

## Bridge config (`configs/plugins/PMM_SimpleAdmin/PMM_SimpleAdmin.json`)

The release default, with two changes: `MapChooser.Menus.pools.Enabled` is `false` (GG1 only ever has the current mode's pool, so
there's nothing to pick) and `MapChooser.RedirectMapsCommand` is `false`.

The `MapChooser` section shows because GG1MapChooser is loaded. `RedirectSimpleAdminChangeMap` makes SimpleAdmin's "Change map"
list GG1's maps (the current mode's pool). `RedirectMapsCommand` is `false`: `!maps` is GameModeManager's menu. Changing the map
from the panel changes only the map, not the mode.

GameModeManager adds its own "Manage game" section (Maps, Modes, Settings, Warmup, Rotation) through SimpleAdmin's API, using SimpleAdmin's
menus so Back works. Nothing is needed in this bridge except the icon in `Items`. Turn the section off with `AdminPanel.Enabled` in
`GameModeManager.json`.

The VIPCore and Store sections appear only when those plugins are installed (they aren't).

## Client addon files

Add to the **same** Workshop addon as PanoramaMenu (`docs/PANORAMA_MENU_SETUP.md`), from the bridge release's
`Content-addonmanager/`:

```
panorama/layout/custom_game/pmm_admin.xml
panorama/styles/custom_game/pmm_admin.css
```

Recompile and publish the addon again. Players (admins) rejoin to get it. Until then the bridge can't draw its panel
(`ForcePanorama: true`).

## Deploy and check

1. Deploy with `bisect/deploy.ps1` (test server first). **Full restart**: the bridge uses Harmony, and
   `css_plugins reload` doesn't unload it.
2. Server console: `css_plugins list` shows `CS2-SimpleAdmin`, `CS2-SimpleAdmin Fun Commands` and `PMM_SimpleAdmin`;
   `css_pmm_sa status` reports the patches applied; SimpleAdmin's log line for `css_rcon` lists only the alias `css_sa_rcon`.
3. In game, as an admin: `!admin` opens the panorama panel; kick / mute a bot; `!map <map>` changes the map once;
   `!maps` opens GameModeManager's menu once, with the current mode's maps; the Game Modes section has the same options, and Back works.
