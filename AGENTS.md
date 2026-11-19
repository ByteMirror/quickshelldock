# quickshelldock

Hyprland dock panel built with Quickshell (QML). No build step — loaded directly by the Quickshell runtime.

## Structure

- `shell.qml` — entrypoint, instantiates `DockPanel` per screen via `Variants`
- `DockPanel.qml` — the dock UI: auto-hide, bounce-on-launch, Hyprland toplevel matching, window focus
- `config/DockApps.qml` — singleton defining the ordered app list (name, icon, cmd, optional `match`)
- `config/Theme.qml` — singleton mirroring the desktop's look into the dock
- `AppLibrary.qml` — COSMIC-style app library (search + groups), one overlay window per dock, opened by the grid
  button left of the icons or `qs -c quickshelldock ipc call applibrary toggle`. Groups persist in
  `$XDG_STATE_HOME/quickshelldock/applibrary.json` (`{name, categories, apps, exclude}`); hides match Omarchy's launcher
- `GridGlyph.qml` — the drawn 3x3 library mark, shared by the dock button and the Library Home tile

## Theming

- The dock carries no colors or radii of its own; everything reads `Theme`
- Colors come from the active Omarchy theme's `colors.toml`
  (`$XDG_STATE_HOME/omarchy/current/theme/colors.toml`). The Catppuccin Mocha values the dock was drawn with
  remain as fallbacks, so it still looks right with no Omarchy theme applied
- A theme switch replaces the whole `current/theme` directory, which can take the `colors.toml` watch down with it.
  `current/theme.name` is rewritten in place afterwards, so that is the reliable "a theme landed" signal — it is
  what triggers the reload
- Corner rounding comes from Hyprland's `decoration:rounding`, the same number `omarchy-shell` reads into
  `Style.cornerRadius`. `omarchy-display-corner-rounding` is the setter; the dock watches the flag file it writes
  (`toggles/hypr/corner-rounding.lua`) and re-asks `hyprctl` a beat later, because Hyprland has to reload before the
  new value is readable
- `Theme.radiusLarge/Medium/Small` are calibrated so `rounding = 10` reproduces the 18/10/6 the dock was drawn with;
  `rounding = 0` squares everything off. Wrap a radius in `Theme.fit(radius, height)` so a box can never round past
  its own half-height
- Things that must stay circular regardless (the running dot, the unread badge) use `width / 2`, not a Theme radius
- Nested corners must be **concentric**: an inset box only looks evenly padded when its radius is the surrounding
  radius minus the inset. `Theme.inner(outerRadius, inset, height)` is that subtraction — use it for anything drawn
  inside another rounded box (the icon hover tile inside the dock bar, a context-menu row inside the card), and
  `Theme.fit` only for the outermost box. A larger inner radius keeps the gap right along the flats but pinches it
  shut at the corners, which is what "the padding looks uneven" actually is
- Insets live on the root as `barPadding` / `menuPadding` / `menuTextPadding` and are applied on one box, never split
  across two nested ones — a tile with both a row padding and its own `anchors.margins` has no single inset for
  `Theme.inner` to subtract
- Gaps between siblings are half the padding around them (`itemSpacing: barPadding / 2`): a seam is shared by two
  tiles, the padding to the bar edge is owned by one, so equal numbers read as a loose row instead of one cluster
- Elevation is `RectangularShadow` (QtQuick.Effects 6.9+), not `MultiEffect`: it rasterizes a rounded rect straight
  into the scene graph, where MultiEffect would push the bar *and every icon* through an offscreen layer just to blur
  an outline whose shape is already known. The window reserves `shadowMargin` of headroom above the bar for it to
  fall into — the surface claims no exclusive zone, so the extra height is free
- The shadow only reads as a shadow if Hyprland leaves it alone: `ignore_alpha` for the `quickshelldock` layer has to
  sit **above** the shadow's peak alpha and **below** `[bar] background-alpha`, or blurring the desktop behind a soft
  dark gradient turns it into a frosted halo. Currently 0.4, between a 0.35 shadow and a 0.72 fill
- `Theme.panelBorder` is the theme's own ink at low alpha, which is self-correcting: on dark themes `foreground` is
  light and the hairline reads as a specular top edge, on light themes it is dark and reads as an outline. A fixed
  `surface` border is a drawn box on one of the two
- `Theme.shadow` stays black on light themes. Tinting a cast shadow with the palette is what makes it read as a glow
- Translucency comes from `[bar] background-alpha` in omarchy's `shell.toml` — the same knob that frosts the top
  bar, resolved theme-first with `~/.config/omarchy/shell.toml` overriding, so one edit changes both. `-1` is the
  internal "the file did not say" marker, which keeps an explicit `1.0` distinguishable from an absent key
- Surfaces that sit *over the desktop* use `Theme.panelBackground` (background + alpha); chrome drawn *on* the dock
  (the unread badge and its border) keeps the opaque `Theme.background` or it dissolves into what is behind it
- Translucency alone does nothing without `hl.layer_rule({ match = { namespace = "quickshelldock" }, blur = true,
  ignore_alpha = ... })` in `~/.config/hypr/looknfeel.lua`: layer surfaces are not covered by `decoration:blur`.
  `ignore_alpha` is not optional here — the dock's layer spans the full screen width and is transparent everywhere
  except the dock bar, so without a floor Hyprland blurs the whole empty strip

## Motion and affordances

- Icons carry `mipmap: true` and a 2x `sourceSize`. Icon themes ship whatever size they ship; without both, a 128px
  PNG landing on a 36px box is aliased mush, which is the loudest "this dock is old" tell on a HiDPI screen
- Hover and press are a **tile highlight only** — the icon does not scale, lift, or move. A magnify-on-hover pass was
  tried and removed; don't reintroduce it
- Press is tested before hover in the tile's opacity, because a pointer is always hovering whatever it is pressing —
  test hover first and the press state is unreachable
- Anything that ever does animate an icon must use a render transform, never `x`/`y`/`width` (the Row would reflow
  every neighbour) and never `iconImg.y`, which `bounceAnimation` assigns to directly
- The running indicator is a pill, not a dot, and widens for the focused window. Focus comes from `activewindowv2`,
  whose payload is the same bare hex `Toplevel.address` carries, so the two compare directly with no `0x` juggling
- The tooltip is deliberately **absent from `mask`**: it renders but takes no input, so it can sit over the icon that
  summoned it without stealing the hover keeping it alive. Anything drawn above the bar that must not be clickable
  belongs outside the mask
- On hover-out a delegate only clears the tooltip if `tooltipText` is still its own — sliding between icons fires the
  new item's enter before the old item's leave, and an unguarded clear would blank the label that just appeared

## Pinning

- `bin/quickshelldock-pin` is the only writer of `pins.json`; the dock shells out to it (via `Quickshell.shellDir`)
  rather than editing the file itself, so there is one code path for pin state
- `FileView.reload()` is async — merge pins on `onTextChanged`, not on `onFileChanged`, or you read back stale text
  and the dock silently ignores the change
- Pins merge after config apps and dedupe on name or cmd, so pinning something already in `UserConfig.qml` is a no-op
- Some packaged `.desktop` files ship an unsubstituted `StartupWMClass` placeholder (Chromium's is
  `@@startup_wm_class`); the pin tool drops those so matching falls back to the binary name
- Unpin is two mechanisms behind one verb: pinned apps leave `pins.json`, config apps enter `hidden.json`. The dock
  filters the merged list on both `name` and `entryId`
- The context menu passes `entryId || name` as the unpin key, so config apps (which have no desktop id) key by name
- Desktop ids are stored without the `.desktop` suffix but must not be blindly stripped — `org.telegram.desktop` is a
  real id

## Running apps

- Everything running that no dock icon already stands for gets a temporary icon right of a separator, so an app the
  dock has never been told about is still visible and closable from it. `showRunningApps` (default `true`) turns the
  section off
- `Hyprland.toplevels` keeps an entry for **every window address it has ever been told about**, closed ones included —
  on a machine that has run a Wine installer it is 150 entries standing for 7 open windows. `toplevelIsLive()` is the
  filter: a live window still has a Wayland handle (`tl.wayland`), the leftovers have neither that nor a workspace.
  Without it the extras section fills with dead installers and the running pill lights under apps that are not running
- One `Component` (`dockItem`) backs both Repeaters, so both models carry the same roles. A docked app and a running
  one differ in what their context menu offers and whether they can be dragged, not in how they draw
- Extras live in their own `ListModel`, not appended to `appModel`: they hold no slot in the saved order, and
  `persistOrder()` would write their names into `order.json` if a drag ever reached them. `DragHandler.enabled` is off
  for them as well
- Matching runs in both directions off one predicate (`appMatchesToplevel`): a dock icon asks which windows are its
  own, and the extras ask which windows no icon has claimed
- Extras carry `exactMatch`, which compares the whole app id rather than a substring. The substring matching the
  configured apps use is a convenience for hand-written config (`zen` standing in for `zen-browser`); applied to an id
  read off a live window it would let one extra swallow a neighbour whose id merely contains it
- The rebuild is skipped when it would produce the same icons (`extrasSignature`). Resetting a ListModel destroys its
  delegates, and doing that on every window event pulls the tile out from under a pointer on its way to clicking it
- It is also debounced: a window opening fires the toplevel, then its app id, then its title, and each can change what
  belongs in the section
- Extras sort by name, so an unrelated window opening never reshuffles the icons already there
- `DesktopEntries.byId` then `heuristicLookup` is what turns `org.gnome.nautilus` into "Files" with the right icon.
  With no entry the raw id is prettified (`prettifyId`), and `Quickshell.iconPath(icon, fallback)` keeps a tile from
  drawing as a hole
- Pinning from the extras passes `--app-id` along with the desktop id: the window's own id is the one the dock just
  matched it by, and it beats the `StartupWMClass` guess. Without it a freshly pinned app can fail to match its own
  window and appear twice, idle on the left and running on the right

## Reordering

- The Repeater is backed by a `ListModel` (`appModel`), not a plain JS array — a `move()` keeps the delegates alive
  mid-drag, whereas reassigning an array model recreates them and kills the active `DragHandler`
- `DockApps.apps` is the baseline order; `order.json` under `Quickshell.env("XDG_STATE_HOME")` (falling back to
  `~/.local/state`) overrides it and is rewritten on drag release
- The dragged icon's `Translate.x` is bound to `dragPointerX - dragGrabOffset - appItem.x`. Reading the live,
  Row-assigned `appItem.x` is what keeps the icon under the cursor when a reorder relayouts the row mid-drag
- Pointer positions are read from `centroid.scenePosition` and mapped with `row.mapFromItem(null, ...)`;
  `centroid.position` is self-referential once the item carries a drag transform
- `TapHandler.gesturePolicy: DragThreshold` is what stops a drag from also launching the app

## Clicking

- A click on a running app always focuses — the dock has no minimize. `activateApp()` picks a window on the current
  workspace if there is one, else the app's first, and hands it to `focusToplevel()`
- Focus cannot land on a window whose `special:` workspace is hidden, so `activateApp()` shows it first with
  `hl.dsp.workspace.toggle_special(<name minus the "special:" prefix>)`, but only when the focused monitor is not
  already showing that one — the dispatcher toggles, so an unguarded call hides it instead
- `special:dock_minimize` is the exception: windows the dock's old minimize-on-click left there are moved back to the
  current workspace rather than switched to
- `toplevelAddress()` is the one place that resolves a Hyprland address: `lastIpcObject.address` when a clients
  refresh has landed, otherwise `"0x" + toplevel.address` — the Wayland address is the same number without the `0x`
  Hyprland's IPC insists on

## Theme colors

- `Theme.indicator` is the running dot's color, and it is derived, not read straight from the palette: the first of
  `bright_foreground` / `foreground` / `accent` that clears 3:1 against the dock bar, falling back to black or white.
  Binding the dot to `brightForeground` directly is what made it invisible on light themes
- `Theme.contrastRatio()` / `Theme.relativeLuminance()` take QML colors, whose channels are already 0..1 floats — no
  8-bit round trip

## Key conventions

- App matching: if `match` is set, matches against Hyprland toplevel `title`; if `appId` is set, matches against the Wayland `appId`; otherwise extracts the binary name from `cmd` and matches against `appId` or `class`
- `Hyprland.toplevels` populates lazily: it is empty until something reads it and a roundtrip completes, so a one-shot
  imperative read at startup sees nothing. Bindings are fine — they re-evaluate as the list fills
- `Quickshell.execDetached(cmdParts)` launches apps — always split `cmd` on whitespace
- The dock uses `WlrLayershell.layer: Top` and `exclusiveZone: -1` (no exclusive zone)
- Show/hide is a plain `anchors.bottomMargin` binding with no Transition, and `hideTimer.interval` is `0` — the timer
  only exists so the triggerStrip/dockBar hover handoff doesn't flicker
- `floatGap` and the shadow's downward reach are one decision. The dock sits close to the screen edge, so the
  **shadow is tuned to fit the gap** (short `offset.y`, moderate `blur`), not the other way round. Widen the cast
  without revisiting `floatGap` and it clips square against the screen edge, which reads as the dock sinking into
  the edge rather than floating above it
- The bar floats `root.floatGap` above the screen edge, and `triggerStrip.height` **is** `floatGap` so the hot strip
  meets the bar's bottom edge. Any unmasked band between them drops the pointer out of `mouseOverDockArea` on its way
  to the icons and the dock hides itself mid-approach
- The window's `implicitHeight` is **constant** and must stay that way. A layer-surface resize takes a frame to reach
  the compositor, and until it lands QML has already laid the content out for the new height inside the old surface —
  which drags the bottom-anchored bar down and half off the screen, then snaps it back. Sizing the window to whatever
  popup is open puts that glitch on every icon hover, so `popupReserve` reserves room for the tallest popup (a
  three-row context menu) permanently. The surface claims no exclusive zone and is masked to the bar, so the reserved
  space costs nothing
- It is derived from the numbers the bar is built from, never from `dockBar.height`: the bar anchors to
  `parent.bottom`, so reading its height there closes a loop through `parent.height` that Qt breaks rather than
  solves — leaving the window zero-tall and the dock invisible with no error printed anywhere
- `menuRowHeight` is shared between `popupReserve` and the row delegates so the reservation cannot drift from what
  the menu actually measures
- Layer namespace is `quickshelldock`
- Anything asking "is this app running" must filter `Hyprland.toplevels` through `toplevelIsLive()` first — see
  **Running apps**

## Dock visibility

- Empty workspace → dock always visible
- Workspace with windows → dock auto-hides (shows on hover at bottom edge)
- `showOnFloating` config flag (default: `false`) — when `true`, floating-only workspaces are treated as empty
- Detection: fast path iterates `Hyprland.toplevels` for the common cases (empty workspace, `showOnFloating` disabled); only falls back to `hyprctl clients -j` when `showOnFloating` is true and there are windows on the workspace
- Relevant Hyprland events: `workspace`, `workspacev2`, `activewindow`, `activewindowv2`, `createworkspace`, `createworkspacev2`, `destroyworkspace`, `destroyworkspacev2`
