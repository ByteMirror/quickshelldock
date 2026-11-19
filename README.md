# quickshelldock

Hyprland dock panel built with [Quickshell](https://quickshell.outfoxxed.me/). No build step — loaded directly by the Quickshell runtime.

## Usage

```sh
quickshell /path/to/quickshelldock
```

### Install on a new machine

```sh
git clone https://github.com/ByteMirror/quickshelldock ~/.config/quickshell/quickshelldock
cp ~/.config/quickshell/quickshelldock/config/UserConfig.example.qml ~/.config/quickshell/quickshelldock/config/UserConfig.qml
```

Start it with the session (Hyprland, `~/.config/hypr/autostart.lua`):

```lua
o.exec_on_start("quickshell -c quickshelldock")
```

Frosted glass and the app library's motion need two layer rules (`~/.config/hypr/looknfeel.lua`):

```lua
hl.layer_rule({ match = { namespace = "quickshelldock" }, blur = true, ignore_alpha = 0.4 })
hl.layer_rule({ match = { namespace = "quickshelldock-applibrary" }, blur = true, ignore_alpha = 0.4, no_anim = true, animation = "none" })
```

## App library

A COSMIC-style launcher: the grid button at the left end of the dock opens a card with every installed app, a search
field and a row of groups.

- Type to search (name first, then keywords and description); arrows move, Enter launches, Tab/Shift+Tab switch groups,
  Esc clears the search, then closes
- Drag an app onto a group to add it, or onto **New group** to start one; right-click a group to rename or delete it
- Right-click an app for its desktop actions, pin/unpin to the dock, or removal from the current group
- Groups are category filters plus hand-picked apps (`{name, categories, apps, exclude}`), stored in
  `$XDG_STATE_HOME/quickshelldock/applibrary.json`; a fresh install starts with Office, System and Utilities
- Hides the same entries as Omarchy's launcher (`launcher.hides` plus `NoDisplay`/`OnlyShowIn`)

### File search

Typing also searches files through GNOME's LocalSearch index (`localsearch` + `tinysparql`, with Python
GObject bindings): the best-matching apps show as one row, files below — name matches first, then documents
whose text matches. The **Files** tile (or `applibrary files`) searches files only. Right-click a file to open
it, show it in Files, or copy its path. `bin/quickshelldock-find` is the long-lived helper that queries the
index; LocalSearch decides what is indexed (`gsettings ... org.freedesktop.Tracker3.Miner.Files
index-recursive-directories`).

Toggle it from a keybind (opens on the focused monitor):

```lua
o.bind("ALT + SPACE", "App library", "qs -c quickshelldock ipc call applibrary toggle")
o.bind("CTRL + SPACE", "File search", "qs -c quickshelldock ipc call applibrary files")
```

`applibrary search <text>` and `applibrary searchFiles <text>` open it with a query already typed.

## Configuration

App list and options are in [`config/DockApps.qml`](config/DockApps.qml). To override without editing the defaults, create `config/UserConfig.qml` with the same structure:

```js
import QtQuick

QtObject {
  property bool showOnFloating: true

  property var apps: [
    { name: "Firefox", icon: "firefox", cmd: "firefox", order: 0 },
    { name: "Dolphin", icon: "system-file-manager", cmd: "dolphin", order: 1 },
  ]
}
```

### Per-app options

| Field         | Required | Description |
|---------------|----------|-------------|
| `name`        | yes      | Display name |
| `icon`        | yes      | Icon name (looked up via `Quickshell.iconPath`) |
| `cmd`         | yes      | Command to launch, split on whitespace |
| `order`       | yes      | Sort position in the dock |
| `match`       | no       | If set, matches against Hyprland toplevel `title` |
| `appId`       | no       | If set, matches against Wayland `appId` |

### Global options

| Field             | Default | Description |
|-------------------|---------|-------------|
| `showOnFloating`  | `false` | Treat workspaces holding only floating windows as empty, so the dock stays up |
| `showRunningApps` | `true`  | Show running apps that are not on the dock, right of a separator |

## Adding apps

Three ways, in increasing order of convenience.

**Edit the config.** `config/UserConfig.qml` is the declarative base and hot-reloads on save. Fields come straight out
of the app's `.desktop` file: `Icon=` → `icon`, `Exec=` → `cmd`, `StartupWMClass=` → `appId`.

**Pin from the command line.**

```sh
bin/quickshelldock-pin chromium        # pin by desktop entry id
bin/quickshelldock-pin --unpin chromium
bin/quickshelldock-pin --list
```

It reads the `.desktop` file for you, strips launcher field codes (`%U`, `%f`, …) out of `Exec=`, and appends the app
to `$XDG_STATE_HOME/quickshelldock/pins.json`. The dock watches that file, so the icon appears immediately. Symlink
the script into `~/.local/bin` to have it on `PATH`.

**Pin from the Omarchy menu (Super+Space).** Run `integration/install-omarchy-menu-rightclick` once, then right-click
any app in the menu to pin or unpin it. See [`integration/`](integration/) for what that touches and how to undo it.
Without the patch you can still add a `Dock › Pin app to dock` row to `~/.config/omarchy/extensions/omarchy-menu.jsonc`
pointing at `quickshelldock-pin --pick`, which needs no changes to Omarchy at all.

Pins layer on top of `UserConfig.qml` rather than replacing it, and an app already declared there is not duplicated.

## Right-click menu

Right-clicking a dock icon offers the three actions every other dock agrees on — GNOME's dash-to-dock, the macOS Dock
and KDE's task manager all share them:

| Action | Shown |
|--------|-------|
| Open new window | whenever the app has a command to launch |
| Quit | only while the app is running; closes all of its windows |
| Unpin from dock | on dock icons |
| Pin to dock | on running apps that are not on the dock, and have a desktop entry |

Window lists, thumbnails and "App Details" are deliberately absent — they belong to the scope this dock doesn't have.

Unpin works on every icon, wherever it came from. Apps pinned with the tool are dropped from `pins.json`; apps
declared in `UserConfig.qml` are recorded in `hidden.json` instead, because rewriting your hand-written QML isn't the
dock's business. A hidden app isn't on the dock any more, so bring it back with `--restore-pick` (or the
`Dock › Restore removed app` menu row):

```sh
bin/quickshelldock-pin --list-hidden
bin/quickshelldock-pin --restore Obsidian
```

Right-clicking the app in the Super+Space menu also restores it, as long as the dock's display name matches the
desktop entry's `Name=`. Where you renamed it in `UserConfig.qml` — a "foot" entry labelled "Terminal", say — use
`--restore` with the dock's name.

## Running apps

Apps that are running but have no dock icon appear to the right of a separator, one icon per app, sorted by name.
They behave like any other icon — click to focus, right-click for the menu — so a window from an app the dock has
never been told about is still reachable and closable from the dock. Their menu offers **Pin to dock** in place of
unpin, which promotes the app to a real dock icon on the left.

Names and icons come from the app's desktop entry, matched against the window's app id. An app with no entry keeps
its own id (tidied up: `org.omarchy.dropterm` shows as "Dropterm") and a generic icon.

Set `showRunningApps: false` in `config/UserConfig.qml` to turn the section off and leave the dock a plain launcher.

## Reordering

Drag an icon sideways to move it. The remaining icons shuffle out of the way as you go, and the order is written to
`$XDG_STATE_HOME/quickshelldock/order.json` (`~/.local/state/quickshelldock/order.json` by default) on release, so it
survives a restart.

The saved order takes priority over the `order` fields in the config. Apps added to the config afterwards are appended
to the end of the dock; apps removed from the config are dropped. Delete `order.json` to fall back to the config order.

## Show / hide

Show and hide are instant — the bar snaps into place with no slide animation, both when the workspace empties and when
you hover the bottom edge. The only easing left is the 120ms shuffle of icons displaced by a drag; set that
`NumberAnimation` duration to `0` in `DockPanel.qml` if you want reordering to snap too.

### Always show

Like macOS's Cmd+Option+D (Super+Alt+D here), the dock can switch between hiding until hovered and staying up. Always-show keeps the dock
on every workspace and reserves its strip at the bottom, so tiled windows end above it. The choice survives restarts
(`~/.local/state/quickshelldock/always-show`). Bind the toggle in Hyprland:

```lua
o.bind("SUPER + ALT + D", "Toggle dock auto-hide", "qs -c quickshelldock ipc call dock toggleAutohide")
```

## Clicking an icon

An icon with no windows launches its `cmd`. An icon with windows always **focuses** one — the dock never minimizes.

Which window: one on the current workspace if the app has one, otherwise its first. Focusing across workspaces
switches to that workspace. A window parked on a `special:` scratchpad has its special workspace shown first, since
focus cannot land on a hidden one; the sole exception is `special:dock_minimize`, left over from the dock's old
minimize-on-click, whose windows are pulled back to the current workspace instead.

## Running indicator

A dot under an icon means the app has at least one open window. It is drawn in `Theme.indicator`, which is the
theme's `bright_foreground` as long as that clears 3:1 against the dock bar, then `foreground`, then `accent`, and
plain black or white if a theme manages none of those — so the dot stays visible on light palettes as well as dark.
