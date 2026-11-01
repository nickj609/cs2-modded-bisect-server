# PanoramaMenuManager setup (server + client addon)

PanoramaMenuManager (PMM, `plugins/MenuManagerCore` + `shared/MenuManagerApi`) is in the repo and is deployed like any
other plugin. Its menus are drawn by **panorama files on the players' side**, which reach them through a Steam Workshop
addon loaded by **MultiAddonManager** (MAM). Until both of these are done, PMM loads on the server but players see empty
or no menus.

1. Build and publish the client addon (once, and again whenever its files change).
2. Turn MultiAddonManager on and add the addon's Workshop ID, through `custom_files` on the server.

GameModeManager 2.0+, PMM_GG1MapChooser and PMM_SimpleAdmin all draw on this same addon. Their extra panorama files
(`pmm_mapvote.*`: see `docs/GG1_MAPCHOOSER_SETUP.md`; `pmm_admin.*` later) go into the **same** addon, followed by a
re-upload.

---

## 1. Client addon (CS2 Workshop Tools, on your PC)

Source files: the `Content-addonmanager/` folder of the PMM release zip
(`MenuManagerCS2-1.3.01 zip` from https://github.com/RRimmer/PanoramaMenuManagerCS2/releases). It contains:

```
panorama/layout/custom_game/menu_ui.xml      required: the menu panel
panorama/styles/custom_game/ui.css           required: its look
sounds/pmm/menu_select.wav, menu_back.wav, menu_exit.wav      optional: menu sounds
soundevents/soundevents_addon.vsndevts                         optional: PMM.Menu.* sound events
```

Steps:

1. **Install CS2 Workshop Tools:** in Steam, Counter-Strike 2 > Properties > DLC, tick *Counter-Strike 2 Workshop
   Tools*. Then start CS2 with *Launch CS2 Workshop Tools*.
2. **Create an addon:** in the tools' addon list, *Create New Addon* (e.g. `cs2_modded_menus`). This creates
   `...\steamapps\common\Counter-Strike Global Offensive\content\csgo_addons\cs2_modded_menus\`.
3. **Copy** the contents of `Content-addonmanager/` (the `panorama/` folder; `sounds/` and `soundevents/` if you want
   the menu sounds) into that `content\csgo_addons\cs2_modded_menus\` folder. Keep the folder structure exactly.
   If the addon already has a `soundevents/soundevents_addon.vsndevts`, merge the PMM blocks into it: one file per addon.
4. **Compile:** open the addon in the tools and let the Asset Browser compile the new files. If they show as
   uncompiled, select them and compile. The `.xml`/`.css` become `.vxml_c`/`.vcss_c` under `game\csgo_addons\...`.
5. **Publish:** use the tools' Workshop upload/publish. Set visibility to **Public** or **Unlisted**: Private and
   Friends-only items can't be downloaded by players. Note the Workshop ID (the number in the item's URL,
   `...filedetails/?id=<ID>`).
6. Optional: design your own look with PMM's constructor (https://genesis-cs.space/menuconstructor/index.html). It
   produces a `ui.css` / `menu_ui.xml` pair to use in step 3 instead. Keep the ids and classes of `menu_ui.xml`.

After a change to these files: recompile, publish again (same Workshop item), then players get it on their next
connect. Players already in the server have to rejoin.

## 2. Turn on MultiAddonManager and load the addon

The repo keeps MAM **on**: its vdf is in `addons/metamod/`, where Metamod loads plugins from, so every server deployed
from this repo gets it.

To load the addon, append your Workshop ID to `mm_extra_addons` in `game/csgo/cfg/multiaddonmanager/multiaddonmanager.cfg`
(comma separated, keep the existing entry), then deploy:

```
mm_extra_addons 				"3461824328,<YOUR_ADDON_ID>"
```

`3461824328` is already in the repo's cfg (kus's Quake Sounds addon). Remove it only if you don't use Quake Sounds.

The server must be able to download Workshop items (it does already for workshop maps: Steam game server login
token `STEAM_ACCOUNT`).

## 3. Check it works

Server console (Bisect console):

| Command | Expect |
| --- | --- |
| `meta list` | `MultiAddonManager` listed |
| `mm_extra_addons` | your ID in the value |
| `css_plugins list` | `[FORK] MenuManager` loaded, no errors |

In game:

1. Connect: the client downloads the addon first (one extra reconnect is normal with MAM).
2. Type `!menu` in chat: the PMM settings menu opens as a panorama panel (mouse). Choose your menu type there.
3. Client console `snd_list_soundevents PMM` lists the sound events if you included them.

If `!menu` shows nothing or an empty frame:

- **Addon not loaded:** check `mm_extra_addons`, the item's visibility, and that the files are under
  `panorama/layout/custom_game/` and `panorama/styles/custom_game/` in the addon.
- **Old addon cached:** rejoin, or set `mm_addon_mount_download 1` temporarily.
- **Server log:** `addons/counterstrikesharp/logs/` for MenuManagerCore errors (database / SQLite: it keeps
  `runtimes/` for that).

## Server settings worth knowing

`game/csgo/addons/counterstrikesharp/configs/plugins/MenuManagerCore/MenuManagerCore.json` (added once, then yours:
the updater never overwrites it). To change it on one server only, override it through `custom_files` like the cfg above.

| Key | Meaning |
| --- | --- |
| `DefaultMenu` | `PanoramaMenu` (mouse) or `PanoramaWasdMenu`; players can change theirs with `!menu` |
| `PanoramaPosition` | empty = centre, `left`, `right` |
| `MenuSettingsCommand` | chat commands that open the settings (`!menu`, `!menus`) |
| `PrecacheResources` | add `"soundevents/soundevents_addon.vsndevts"` if your addon has the PMM sounds |
| `CS2MenuManagerCompat` | `true`: the core writes `shared/CS2MenuManager/CS2MenuManager.dll` on start (for plugins made for schwarper's CS2MenuManager). Don't install schwarper's CS2MenuManager. |

## Notes for this repo

- `plugins.yaml` pins PMM (`pin: true`): the Harmony bridges are built against specific PMM versions. Upgrade on
  purpose with `scripts/Update-Plugins.ps1 -Component PanoramaMenuManager`, together with the bridges.
- The PMM release also ships empty `PlayerSettings` / `PlayerSettingsApi` / `AnyBaseLib` stubs. They are deliberately
  **not** installed: SpectatorList uses the real PlayerSettings API.
