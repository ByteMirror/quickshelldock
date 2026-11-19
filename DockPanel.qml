import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.config
import Quickshell.Io

PanelWindow {
  id: root

  // PanelWindow already has `screen`; redeclaring it here (as this file used
  // to) shadowed the real property, so neither instance was bound to its
  // output and both docks landed on the primary monitor.
  // The Hyprland monitor this dock lives on. Workspace-empty, special and
  // launch logic follow THIS monitor, not whichever one has focus.
  readonly property var hyprMonitor: screen ? Hyprland.monitorFor(screen) : null
  readonly property int ownWorkspaceId: hyprMonitor?.activeWorkspace?.id ?? -1

  anchors.bottom: true
  anchors.left: true
  anchors.right: true
  WlrLayershell.namespace: "quickshelldock"
  WlrLayershell.layer: WlrLayer.Top
  // Always-show reserves the bar plus its edge gap so windows tile above it.
  exclusiveZone: DockApps.alwaysShow ? root.floatGap + root.barHeight : -1
  color: "transparent"
  focusable: false

  mask: Region {
    Region { item: triggerStrip }
    Region { item: edgeStrip }
    Region { item: dockBar }
    Region { item: contextMenu }
  }

  // CONSTANT. A layer-surface resize takes a frame to reach the compositor,
  // and until it lands QML has already laid the content out for the new height
  // inside the old surface — which drags the bottom-anchored bar down and half
  // off the screen, then snaps it back. Sizing this to whatever popup happens
  // to be open put that glitch on every icon hover, so the tallest popup the
  // dock can show is reserved permanently instead. The surface claims no
  // exclusive zone and is masked to the bar, so the reserved space is free.
  //
  // Derived from the numbers the bar is built from, NOT from dockBar.height:
  // the bar anchors to parent.bottom, so reading its height here closes a loop
  // through parent.height that Qt breaks rather than solves, leaving the
  // window zero-tall and the dock invisible.
  implicitHeight: root.floatGap + root.barHeight + root.shadowMargin
    + root.popupReserve

  // Screen edge -> dock bar. The dock should sit close to the edge, so the
  // shadow below is tuned to fit this gap rather than the gap being opened up
  // to fit the shadow — see the offset and blur on the RectangularShadow.
  // Widen the cast without revisiting this and it clips square against the
  // screen edge, which reads as the dock sinking into the edge.
  readonly property real floatGap: 8
  readonly property real menuGap: 4

  // Headroom above the bar for the drop shadow to fall into. The window is
  // input-masked to the bar itself and claims no exclusive zone, so growing it
  // costs nothing; without the headroom the shadow is cut off square.
  readonly property real shadowMargin: 28
  readonly property real tooltipHeight: 26
  readonly property real menuRowHeight: 28

  // Room for the tallest thing that can ever open above the bar: a three-row
  // context menu (new window / quit / unpin). Shared by the row delegates so
  // the reservation cannot drift from what the menu actually measures.
  readonly property real popupReserve: menuGap + Math.max(
    tooltipHeight,
    menuRowHeight * 3 + 2 + menuPadding * 2)

  readonly property int iconSize: 36
  readonly property int itemSize: 48
  readonly property real barHeight: itemSize + barPadding * 2
  // Half the bar's padding: the seam between two tiles is shared between them,
  // while the padding to the bar edge is owned by one tile alone. Matching the
  // two numbers makes the icons read as loose; halving binds them into a single
  // cluster set inside the frame.
  readonly property real itemSpacing: barPadding / 2
  readonly property real itemPitch: itemSize + itemSpacing

  // Every inset in the dock comes from one of these, because a box only reads
  // as evenly padded when its radius is the surrounding radius minus the inset
  // (Theme.inner). Splitting an inset across two nested boxes is what pinched
  // the corners before, so the icon tile now fills its delegate rather than
  // carrying a margin of its own.
  readonly property real barPadding: 10         // icon row -> dock bar edge
  readonly property real menuPadding: 6         // menu row -> context card edge
  readonly property real menuTextPadding: 8     // label -> menu row edge

  property bool dockVisible: keepUp

  // True while any special workspace is open on this monitor (the chat
  // overlay, Spotify, the scratchpad). Layer-shell has no level that sits
  // below windows but still catches the bottom-edge hover, so the dock stays
  // down while one is up instead of drawing over it. Driven by the
  // activespecial event in the Hyprland Connections block below; if the shell
  // restarts while an overlay is already open this starts out wrong and
  // corrects itself on the next toggle.
  property bool specialActive: false
  property bool mouseOverDockArea: triggerHover.hovered || edgeHover.hovered || dockHover.hovered || contextHover.hovered
  // hoverOnly: never pin the dock open on an empty/floating workspace.
  property bool workspaceEmpty: !DockApps.hoverOnly
  // Reasons the dock stays up without a hover.
  readonly property bool keepUp: workspaceEmpty || DockApps.alwaysShow
  property string clientsJson: ""
  property int _badgeTick: 0

  // Address of the focused window, straight off activewindowv2 — the same bare
  // hex Toplevel.address carries, so the two compare directly. Empty when
  // nothing is focused, which is exactly what the event sends.
  property string activeAddress: ""

  // Hover label state. The tooltip is deliberately outside `mask`: it must
  // never take input, or it would cover the icon that summoned it.
  property bool tooltipShown: false
  property string tooltipText: ""
  property real tooltipAnchorX: 0

  // Drag-to-reorder state. Only one icon can be dragged at a time, so this
  // lives on the root rather than in the delegates.
  property string dragName: ""
  property real dragPointerX: 0
  property real dragGrabOffset: 0
  readonly property bool dragging: dragName !== ""

  // Icon order survives restarts here. Kept out of the config dir so a
  // git pull never fights with it.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/quickshelldock"
  readonly property string orderPath: stateDir + "/order.json"
  readonly property string pinsPath: stateDir + "/pins.json"
  readonly property string hiddenPath: stateDir + "/hidden.json"
  readonly property string pinTool: Quickshell.shellDir + "/bin/quickshelldock-pin"
  property var savedOrder: []
  property var pinnedApps: []
  property var hiddenApps: []

  // Right-click context menu state.
  property bool contextOpen: false
  property string contextKey: ""
  property var contextAppData: null
  property bool contextRunning: false
  // A running app that is not on the dock: it can be pinned, never unpinned,
  // and it is never draggable, since it holds no slot in the saved order.
  property bool contextTransient: false
  property string contextEntryId: ""
  property real contextAnchorX: 0

  // Matches what other docks offer: GNOME's dash-to-dock, the macOS Dock and
  // KDE's task manager all agree on new-window / pin-unpin / quit. Window
  // lists and "App Details" are deliberately left out — out of scope here.
  //
  // Never more than three rows, whichever side of the separator the icon is
  // on, which is what popupReserve is sized against.
  readonly property var contextActions: {
    let actions = []
    // A running app the dock only knows through its window may have no
    // desktop entry to relaunch from.
    if (root.contextAppData && root.contextAppData.cmd)
      actions.push({ label: "Open new window", act: "new" })
    if (root.contextRunning) actions.push({ label: "Quit", act: "quit" })
    if (!root.contextTransient) {
      actions.push({ label: "Unpin from dock", act: "unpin" })
    } else if (root.contextEntryId) {
      // The pin tool keys off the desktop id and has nothing to store
      // without one, so an unidentifiable window is simply not pinnable.
      actions.push({ label: "Pin to dock", act: "pin" })
    }
    return actions
  }

  Process {
    id: clientsProcess
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: { root.clientsJson = this.text }
    }
  }

  Process {
    id: mkdirProcess
    command: ["mkdir", "-p", root.stateDir]
    running: true
  }

  FileView {
    id: orderFile
    path: root.orderPath
    blockLoading: true
    printErrors: false
    atomicWrites: true
  }

  // Config apps removed from the dock. Suppressed here rather than by
  // rewriting UserConfig.qml, which is the user's to own.
  FileView {
    id: hiddenFile
    path: root.hiddenPath
    blockLoading: true
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onTextChanged: {
      root.loadHidden()
      if (!root.dragging) root.rebuildModel()
    }
  }

  // Written by bin/quickshelldock-pin, never by the dock. Watching it is what
  // makes a pin from the Omarchy menu show up without a restart.
  FileView {
    id: pinsFile
    path: root.pinsPath
    blockLoading: true
    printErrors: false
    watchChanges: true
    // reload() is async, so the merge has to wait for the text to actually
    // land rather than reading it back on the fileChanged tick.
    onFileChanged: reload()
    onTextChanged: {
      root.loadPins()
      if (!root.dragging) root.rebuildModel()
    }
  }


  ListModel { id: appModel }

  // The COSMIC-style app library this dock's button opens, on this monitor.
  property AppLibrary appLibrary: AppLibrary { dock: root; screen: root.screen }

  // Apps that are running but have no dock icon of their own. Kept in its own
  // model rather than appended to appModel: these hold no slot in the saved
  // order, and a window closing must not look like a reorder.
  ListModel { id: extraModel }

  // Set of apps the extras section is currently drawn from, so a rebuild that
  // would produce the same icons can be skipped.
  property string extrasSignature: ""

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { extrasTimer.restart() }
  }

  // A window opening fires several events in a row (the toplevel arrives, its
  // app id lands, its title lands), and each one can change what belongs in
  // the extras. Coalesce them into one rebuild.
  Timer {
    id: extrasTimer
    interval: 60
    repeat: false
    onTriggered: root.rebuildExtras()
  }

  function normalizeApp(app, pinned) {
    return {
      // Desktop entry id, only present on pinned apps. It is the key the
      // pin tool unpins by.
      entryId: app.id ?? "",
      pinned: pinned === true,
      // Roles have to line up across both models, because one delegate draws
      // for both. Configured and pinned apps are always the docked kind.
      transientApp: false,
      exactMatch: false,
      name: app.name ?? "",
      icon: app.icon ?? "",
      cmd: app.cmd ?? "",
      // `match` is a reserved-ish name on the QML side, so the role is renamed.
      matchTitle: app.match ?? "",
      appId: app.appId ?? "",
      order: app.order ?? 0,
    }
  }

  function loadHidden() {
    try {
      const raw = hiddenFile.text()
      hiddenApps = raw ? (JSON.parse(raw) || []) : []
    } catch (e) {
      hiddenApps = []
    }
  }

  function loadPins() {
    try {
      const raw = pinsFile.text()
      pinnedApps = raw ? (JSON.parse(raw) || []) : []
    } catch (e) {
      pinnedApps = []
    }
  }

  function loadSavedOrder() {
    try {
      const raw = orderFile.text()
      if (!raw) return
      const parsed = JSON.parse(raw)
      if (Array.isArray(parsed)) savedOrder = parsed
    } catch (e) {}
  }

  // Config order is the baseline; anything the user has dragged wins over it.
  // Apps added to the config after the last drag land at the end.
  function rebuildModel() {
    let apps = []
    for (const app of DockApps.apps) apps.push(normalizeApp(app, false))
    apps.sort((a, b) => a.order - b.order)

    // Pins append after the configured apps. An app already declared in
    // UserConfig.qml wins, so pinning something that is already on the dock
    // is a no-op rather than a duplicate icon.
    for (const pin of pinnedApps) {
      const entry = normalizeApp(pin, true)
      let duplicate = false
      for (const app of apps) {
        if (app.name === entry.name || (app.cmd && app.cmd === entry.cmd)) {
          duplicate = true
          break
        }
      }
      if (!duplicate) apps.push(entry)
    }

    if (savedOrder.length > 0) {
      let byName = {}
      for (const app of apps) byName[app.name] = app
      let sorted = []
      for (const name of savedOrder) {
        if (byName[name]) {
          sorted.push(byName[name])
          delete byName[name]
        }
      }
      for (const app of apps) if (byName[app.name]) sorted.push(app)
      apps = sorted
    }

    appModel.clear()
    for (const app of apps) {
      if (hiddenApps.indexOf(app.name) >= 0) continue
      if (app.entryId && hiddenApps.indexOf(app.entryId) >= 0) continue
      appModel.append(app)
    }

    // What is docked decides what counts as an extra, so the right-hand side
    // is only correct once this list is.
    extrasTimer.restart()
  }

  function persistOrder() {
    let names = []
    for (var i = 0; i < appModel.count; i++) names.push(appModel.get(i).name)
    savedOrder = names
    orderFile.setText(JSON.stringify(names, null, 2) + "\n")
  }

  // Called on every pointer move during a drag: figure out which slot the
  // dragged icon is currently over and shuffle the model if it changed.
  function updateDragTarget(fromIndex) {
    const desiredLeft = dragPointerX - dragGrabOffset
    let target = Math.round(desiredLeft / itemPitch)
    if (target < 0) target = 0
    if (target > appModel.count - 1) target = appModel.count - 1
    if (target !== fromIndex) appModel.move(fromIndex, target, 1)
  }

  function checkWorkspaceEmpty() {
    const wsId = root.ownWorkspaceId >= 0 ? root.ownWorkspaceId : null
    if (wsId == null) return true
    try {
      const clients = JSON.parse(clientsJson)
      for (const c of clients) {
        if (c.workspace?.id !== wsId) continue
        if (DockApps.showOnFloating && c.floating) continue
        return false
      }
    } catch (e) {}
    return true
  }

  function updateWorkspaceEmpty() {
    if (DockApps.hoverOnly) {
      if (workspaceEmpty) workspaceEmpty = false
      return
    }
    const wsId = root.ownWorkspaceId >= 0 ? root.ownWorkspaceId : null
    if (wsId == null) return

    var hasToplevels = false
    for (const tl of Hyprland.toplevels.values) {
      if (tl.workspace?.id === wsId) {
        hasToplevels = true
        break
      }
    }

    if (!hasToplevels) {
      if (workspaceEmpty !== true) workspaceEmpty = true
      return
    }

    if (!DockApps.showOnFloating) {
      if (workspaceEmpty !== false) workspaceEmpty = false
      return
    }

    if (!clientsProcess.running) {
      clientsJson = ""
      clientsProcess.running = true
    }
  }

  onClientsJsonChanged: {
    if (clientsJson.length === 0) return
    const empty = checkWorkspaceEmpty()
    if (empty !== workspaceEmpty) workspaceEmpty = empty
  }

  function getUnreadCount(toplevels) {
    for (const tl of toplevels) {
      const title = tl.toplevel?.title || ""
      const m = title.match(/Inbox \((\d[\d,]*)\)/)
      if (m) {
        const n = parseInt(m[1].replace(/,/g, ""), 10)
        if (!isNaN(n) && n > 0) return n
      }
    }
    return 0
  }

  // Does this window belong to this app? Split out of getToplevelsForApp
  // because the extras section asks the same question in reverse: a window no
  // docked app claims is one that needs an icon of its own.
  function appMatchesToplevel(app, tl) {
    // Extras carry a whole app id and claim exactly that app's windows. The
    // substring matching below is a convenience for hand-written config,
    // where "zen" standing in for "zen-browser" is the point; here it would
    // let one entry swallow a neighbour whose id merely contains it.
    if (app.exact) {
      return app.appId !== "" && root.toplevelKey(tl) === String(app.appId).toLowerCase()
    }
    if (app.match) {
      return String(tl.title ?? "").toLowerCase().includes(String(app.match).toLowerCase())
    }
    if (app.appId) {
      return (tl.wayland?.appId ?? "").toLowerCase().includes(String(app.appId).toLowerCase())
    }
    const exe = String(app.cmd ?? "").split(/\s+/)[0].split("/").pop().replace(/\.[^/.]+$/, "").toLowerCase()
    // Without this an entry carrying no cmd at all would match every window:
    // "".includes("") is true.
    if (!exe) return false
    const appId = (tl.wayland?.appId ?? "").toLowerCase()
    const cls = (tl.lastIpcObject?.class ?? "").toLowerCase()
    return appId.includes(exe) || cls.includes(exe) || (cls !== "" && exe.includes(cls))
  }

  // Hyprland.toplevels keeps an entry for every window address it has ever
  // been told about, including ones that closed hours ago — a Wine installer's
  // hidden helpers, Steam's sign-in dialog, an IME popup. On this machine that
  // is 150 entries standing for 7 open windows. A live one still has a Wayland
  // handle behind it; the leftovers have none, and counting them fills the
  // extras with dead installers and lights the running pill under apps that
  // are not running.
  function toplevelIsLive(tl) {
    return !!tl.wayland
  }

  function getToplevelsForApp(app) {
    let results = []
    for (const tl of Hyprland.toplevels.values) {
      if (!root.toplevelIsLive(tl)) continue
      if (root.appMatchesToplevel(app, tl))
        results.push({ toplevel: tl, pid: tl.lastIpcObject?.pid ?? -1 })
    }
    return results
  }

  // The app id a window groups under. Wayland's appId is the reliable one;
  // the Hyprland class only fills in for a toplevel whose Wayland handle has
  // not reported an id yet.
  function toplevelKey(tl) {
    return String(tl.wayland?.appId || tl.lastIpcObject?.class || "").toLowerCase()
  }

  // An app with no desktop entry falls back to its own id, and a reverse-DNS
  // id is the packager's name for the app rather than anyone else's: the app
  // is the last segment, so "org.omarchy.dropterm" reads as "Dropterm". A
  // trailing file extension is not a name, so "ascension.exe" gives that up
  // and keeps the segment before it.
  readonly property var idSuffixes: ["exe", "sh", "bin", "py", "appimage", "desktop"]

  function shortId(key) {
    let parts = String(key).split(".")
    if (parts.length < 2) return String(key)
    if (root.idSuffixes.indexOf(parts[parts.length - 1].toLowerCase()) >= 0) {
      parts.pop()
      if (parts.length === 0) return String(key)
    }
    return parts[parts.length - 1]
  }

  function prettifyId(key) {
    if (!key) return ""
    const label = root.shortId(key)
    return label.charAt(0).toUpperCase() + label.substring(1)
  }

  // First of these the icon theme actually has. Falling through to the
  // generic executable icon keeps an unrecognised app from drawing as a hole
  // in the dock.
  function pickIcon(candidates) {
    for (const candidate of candidates) {
      if (candidate && Quickshell.iconPath(candidate, true)) return candidate
    }
    return "application-x-executable"
  }

  // Everything a running-but-undocked app needs to render as a dock icon. The
  // desktop entry is what turns "org.gnome.nautilus" into "Files" with the
  // right icon; without one the window keeps its raw id, which still beats a
  // blank tile.
  function describeRunningApp(key, title) {
    let entry = key ? DesktopEntries.byId(key) : null
    if (!entry && key) entry = DesktopEntries.heuristicLookup(key)

    // `command` is the Exec line already split and stripped of launcher field
    // codes; execString is the raw line, so strip them by hand there.
    let cmd = ""
    if (entry) {
      const parts = entry.command
      if (parts && parts.length > 0) cmd = Array.prototype.join.call(parts, " ")
      else cmd = String(entry.execString ?? "").replace(/%[fFuUdDnNickvm]/g, "").trim()
    }

    return {
      entryId: entry ? String(entry.id ?? "") : "",
      pinned: false,
      transientApp: true,
      exactMatch: key !== "",
      name: (entry && entry.name) ? String(entry.name)
                                  : (root.prettifyId(key) || title),
      icon: root.pickIcon([entry ? String(entry.icon ?? "") : "", key,
                           root.shortId(key)]),
      cmd: cmd,
      // A window that reports no id at all can still be found by its title.
      matchTitle: key ? "" : title,
      appId: key,
      order: 0,
    }
  }

  // The right-hand side of the separator: everything running that no dock
  // icon already stands for, one icon per app, sorted by name so an unrelated
  // window opening never shuffles the icons already there.
  //
  // Rebuilt only when the set actually changes. Resetting a ListModel destroys
  // its delegates, and doing that on every window event would pull the tile
  // out from under a pointer that is on its way to clicking it.
  function isIgnoredToplevel(tl) {
    const ignore = DockApps.ignoreApps || []
    if (ignore.length === 0) return false
    const cls = String(tl.lastIpcObject?.class ?? root.toplevelKey(tl) ?? "").toLowerCase()
    for (const id of ignore) if (cls === String(id).toLowerCase()) return true
    return false
  }

  function rebuildExtras() {
    if (!DockApps.showRunningApps) {
      if (extraModel.count > 0) extraModel.clear()
      extrasSignature = ""
      return
    }

    let docked = []
    for (var i = 0; i < appModel.count; i++) {
      const app = appModel.get(i)
      docked.push({ match: app.matchTitle, appId: app.appId,
                    cmd: app.cmd, exact: app.exactMatch })
    }

    let seen = {}
    let extras = []
    for (const tl of Hyprland.toplevels.values) {
      if (!root.toplevelIsLive(tl)) continue
      if (root.isIgnoredToplevel(tl)) continue

      let covered = false
      for (const app of docked) {
        if (root.appMatchesToplevel(app, tl)) { covered = true; break }
      }
      if (covered) continue

      const key = root.toplevelKey(tl)
      const groupKey = key || ("title:" + String(tl.title ?? ""))
      if (seen[groupKey]) continue
      seen[groupKey] = true
      extras.push(root.describeRunningApp(key, String(tl.title ?? "")))
    }

    extras.sort((a, b) => a.name.localeCompare(b.name))

    const signature = extras.map(e => e.appId + "\u001f" + e.matchTitle).join("\u001e")
    if (signature === extrasSignature) return
    extrasSignature = signature

    extraModel.clear()
    for (const extra of extras) extraModel.append(extra)
  }

  // The address Hyprland's IPC accepts for a toplevel. lastIpcObject is only
  // there once a clients refresh has landed, so fall back to the Wayland
  // address, which is the same number without the 0x Hyprland expects.
  function toplevelAddress(tl) {
    let addr = tl.lastIpcObject?.address
    if (!addr || addr === "0") addr = "0x" + tl.address
    return (addr && addr !== "0x0") ? addr : ""
  }

  function focusToplevel(tl) {
    const addr = root.toplevelAddress(tl)
    if (addr) {
      Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })')
      return
    }
    // No address yet: class is a coarser handle, but it beats doing nothing.
    const cls = tl.lastIpcObject?.class
    if (cls) Hyprland.dispatch('hl.dsp.focus({ window = "class:' + cls + '" })')
  }

  // Clicking a running app always focuses it — the dock never minimizes.
  // A window on the current workspace wins over one elsewhere, so an app with
  // several windows raises the nearest one rather than pulling the view away.
  function activateApp(toplevels) {
    if (!toplevels || toplevels.length === 0) return

    const wsId = root.ownWorkspaceId >= 0 ? root.ownWorkspaceId : Hyprland.focusedWorkspace?.id
    let target = null
    for (const t of toplevels) {
      if (t.toplevel.workspace?.id === wsId) {
        target = t.toplevel
        break
      }
    }
    if (!target) target = toplevels[0].toplevel

    const ws = target.workspace
    const wsName = String(ws?.name ?? "")

    // Windows the dock's old minimize-on-click parked on special:dock_minimize
    // come back to the current workspace. That scratchpad is a hiding place,
    // never somewhere to switch the view to.
    if (wsName.indexOf("dock_minimize") >= 0) {
      const addr = root.toplevelAddress(target)
      if (addr) {
        Hyprland.dispatch('hl.dsp.window.move({ workspace = '
          + (wsId ?? 1) + ', window = "address:' + addr + '" })')
      }
      root.focusToplevel(target)
      return
    }

    // A scratchpad window (Spotify on special:spotify, say) can only take
    // focus once its special workspace is actually shown on the monitor.
    if (ws && ws.id < 0 && wsName.indexOf("special:") === 0) {
      const shown = String(Hyprland.focusedMonitor?.lastIpcObject?.specialWorkspace?.name ?? "")
      if (shown !== wsName) {
        Hyprland.dispatch('hl.dsp.workspace.toggle_special("' + wsName.substring(8) + '")')
      }
    }

    root.focusToplevel(target)
  }

  // Launch the way Omarchy's own app library does (Omarchy 4.5): uwsm-app puts
  // the app in its own scope under app-graphical.slice instead of letting it
  // inherit the dock's cgroup (wayland-wm@hyprland.desktop.service), and
  // gtk-launch resolves the desktop entry itself, so Exec lines with quoted
  // paths or flatpak field codes work. Config apps carry no desktop id, so
  // their cmd goes through a login shell: quoting is honoured instead of a
  // naive whitespace split, and PATH matches the rest of the session.
  //
  // New windows open on the focused monitor, and clicking a layer surface does
  // not move monitor focus, so focus this dock's monitor first. That dispatch
  // warps the cursor to the monitor's centre; put it back where it was.
  function launchApp(entryId, cmd) {
    let launch = ""
    if (entryId) launch = "exec uwsm-app -- gtk-launch " + root.shq(entryId + ".desktop")
    else if (cmd) launch = "exec uwsm-app -- " + cmd
    else return
    const mon = root.screen ? String(root.screen.name) : ""
    const focus = mon === "" ? "" :
      "pos=$(hyprctl cursorpos 2>/dev/null); "
      + "hyprctl dispatch " + root.shq('hl.dsp.focus({ monitor = "' + mon + '" })') + " >/dev/null 2>&1; "
      + "if [[ $pos =~ ^(-?[0-9]+),\\ (-?[0-9]+)$ ]]; then hyprctl dispatch "
      + "\"hl.dsp.cursor.move({ x = ${BASH_REMATCH[1]}, y = ${BASH_REMATCH[2]}, absolute = true })\" >/dev/null 2>&1; fi; "
    Quickshell.execDetached(["bash", "-lc", focus + launch])
  }

  function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  function openContextMenu(item) {
    if (root.contextOpen && root.contextKey === (item.entryId || item.name)) {
      root.closeContextMenu()
      return
    }
    // Pinned apps unpin by desktop id; config apps have none, so they unpin by
    // name and the pin tool suppresses them instead of editing UserConfig.qml.
    root.contextKey = item.entryId || item.name
    root.contextAppData = item.appData
    root.contextRunning = item.isRunning
    root.contextTransient = item.transientApp
    root.contextEntryId = item.entryId
    root.contextAnchorX = dockBar.mapFromItem(item, item.width / 2, 0).x
    root.contextOpen = true
  }

  function closeContextMenu() {
    root.contextOpen = false
  }

  function runContextAction(act) {
    const app = root.contextAppData
    const entryId = root.contextEntryId
    root.closeContextMenu()
    if (!app) return

    if (act === "new") {
      root.launchApp(entryId, app.cmd)
    } else if (act === "quit") {
      for (const t of root.getToplevelsForApp(app)) {
        const addr = root.toplevelAddress(t.toplevel)
        if (addr) Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + addr + '" })')
      }
    } else if (act === "unpin" && root.contextKey) {
      // The CLI owns pins.json and hidden.json; the watchers pick the change up.
      Quickshell.execDetached([root.pinTool, "--unpin", root.contextKey])
    } else if (act === "pin" && entryId) {
      // The window's own app id goes along with the desktop id: it is the one
      // the dock just matched this app by, and it beats whatever
      // StartupWMClass the .desktop file guesses. Without it a freshly pinned
      // app can fail to match its own running window and show up twice, once
      // idle on the left and once here on the right.
      Quickshell.execDetached([root.pinTool, entryId, "--app-id", app.appId])
    }
  }

  function showDockBar() {
    if (specialActive) return
    hideTimer.stop()
    dockVisible = true
  }

  function scheduleHide() {
    if (!keepUp || specialActive) hideTimer.restart()
  }

  onOwnWorkspaceIdChanged: updateWorkspaceEmpty()

  onSpecialActiveChanged: {
    if (specialActive) dockVisible = false
    else if (keepUp) showDockBar()
  }

  onMouseOverDockAreaChanged: mouseOverDockArea ? contextCloseTimer.stop() : contextCloseTimer.restart()

  onKeepUpChanged: {
    if (keepUp) showDockBar()
    else scheduleHide()
  }

  Component.onCompleted: {
    loadSavedOrder()
    loadPins()
    loadHidden()
    rebuildModel()
    updateWorkspaceEmpty()
  }

  Connections {
    target: DockApps
    function onAppsChanged() {
      if (!root.dragging) root.rebuildModel()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (["workspace", "workspacev2", "activewindow", "activewindowv2",
           "createworkspace", "createworkspacev2",
           "destroyworkspace", "destroyworkspacev2"].includes(event.name)) {
        updateWorkspaceEmpty()
      }
      if (event.name === "windowtitle") {
        root._badgeTick++
      }
      // Titles matter to title-matched apps, and a window's id and title only
      // land a beat after the toplevel itself does.
      if (["openwindow", "closewindow", "movewindow", "movewindowv2",
           "windowtitle", "windowtitlev2"].includes(event.name)) {
        extrasTimer.restart()
      }
      if (event.name === "activewindowv2") {
        root.activeAddress = (event.data || "").trim()
      }
      // "activespecial>><workspacename>,<monitor>" -- the name is empty when
      // the special workspace is closing. (activespecialv2 puts the id first;
      // this one needs no index juggling.)
      if (event.name === "activespecial") {
        const parts = (event.data || "").split(",")
        if (!root.screen || parts[1] === root.screen.name)
          root.specialActive = (parts[0] || "").length > 0
      }
    }
  }

  // Thin full-width edge trigger: touching the bottom edge anywhere on this
  // monitor, corners included, reveals the dock. 2px so it barely overlaps
  // window content.
  Rectangle {
    id: edgeStrip
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: 2
    color: "transparent"

    HoverHandler {
      id: edgeHover
      onHoveredChanged: hovered ? root.showDockBar() : root.scheduleHide()
    }
  }

  Rectangle {
    id: triggerStrip
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: dockBar.horizontalCenter
    // hot area, plus some fat finger margin on either side
    width: dockBar.width + 80
    // Exactly the float, so the strip meets the bar's bottom edge with nothing
    // between them. A shorter strip leaves an unmasked band under a visible
    // dock: the pointer crossing it on the way to the icons drops out of
    // mouseOverDockArea and the dock hides itself mid-approach.
    height: root.floatGap
    color: "transparent"

    HoverHandler {
      id: triggerHover
      onHoveredChanged: hovered ? root.showDockBar() : root.scheduleHide()
    }
  }

  // An overlay that was already open when the shell started fires no
  // activespecial event, so seed the state once the Hyprland connection has
  // settled. Without this, reloading the dock while the chat overlay is up
  // leaves the dock drawing on top of it until the next toggle.
  Timer {
    running: true
    interval: 500
    repeat: false
    onTriggered: {
      const name = root.hyprMonitor?.lastIpcObject?.specialWorkspace?.name ?? ""
      root.specialActive = String(name).length > 0
    }
  }

  // Zero interval: the hide is immediate, the timer only exists so the
  // handoff between triggerStrip and dockBar hover doesn't flicker.
  Timer {
    id: hideTimer
    interval: 0
    repeat: false
    onTriggered: {
      // An open special workspace outranks every reason to stay up, hover included.
      if (root.specialActive) { root.dockVisible = false; return }
      if (root.keepUp || root.mouseOverDockArea || root.dragging || root.contextOpen) return
      root.dockVisible = false
      root.tooltipShown = false
    }
  }

  // Elevation. RectangularShadow rather than MultiEffect: it draws a rounded
  // rect straight to the scene graph, where MultiEffect would rasterize the
  // bar and every icon into an offscreen layer first, just to blur an outline
  // we already know the shape of.
  RectangularShadow {
    anchors.fill: dockBar
    radius: dockBar.radius
    // Kept short enough that the cast lands inside floatGap. The bulk of it is
    // above and to the sides anyway, which is where it does the lifting.
    blur: 16
    offset: Qt.vector2d(0, 2)
    color: Theme.shadow
    opacity: root.dockVisible ? 1 : 0
  }

  Rectangle {
    id: dockBar
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    // No transition: show/hide snaps to position.
    anchors.bottomMargin: root.dockVisible
      ? root.floatGap
      : -(root.barHeight + 20)

    implicitWidth: outerRow.implicitWidth + root.barPadding * 2
    implicitHeight: root.barHeight

    // Translucent, so the Hyprland layer blur on the `quickshelldock`
    // namespace (hypr/looknfeel.lua) shows through as frosted glass.
    color: Theme.panelBackground
    radius: Theme.fit(Theme.radiusLarge, height)
    border.color: Theme.panelBorder
    border.width: 1

    HoverHandler {
      id: dockHover
      onHoveredChanged: hovered ? hideTimer.stop() : root.scheduleHide()
    }

    Row {
      id: outerRow
      anchors.centerIn: parent
      spacing: root.itemSpacing

      // App library button (COSMIC-style). Kept outside `row` so the
      // drag-reorder maths, which counts slots from row's left edge, is
      // untouched.
      Item {
        id: libraryButton
        width: root.itemSize
        height: root.itemSize

        Rectangle {
          anchors.fill: parent
          radius: Theme.inner(dockBar.radius, root.barPadding, height)
          color: Theme.foreground
          opacity: libTap.pressed ? 0.28 : (libHover.hovered ? 0.15 : 0)
          Behavior on opacity { NumberAnimation { duration: 120 } }
        }

        GridGlyph { anchors.centerIn: parent; size: 22; color: Theme.foreground }

        HoverHandler {
          id: libHover
          onHoveredChanged: {
            if (hovered) {
              root.tooltipText = "Applications"
              root.tooltipAnchorX = dockBar.mapFromItem(libraryButton, libraryButton.width / 2, 0).x
              tooltipTimer.restart()
            } else if (root.tooltipText === "Applications") {
              tooltipTimer.stop()
              root.tooltipShown = false
            }
          }
        }

        TapHandler {
          id: libTap
          onTapped: {
            root.closeContextMenu()
            root.tooltipShown = false
            root.appLibrary.toggle()
          }
        }
      }

    Row {
      id: row
      spacing: root.itemSpacing

      // Icons displaced by a drag slide to their new slot. Set duration to 0
      // for fully instant reordering.
      move: Transition {
        NumberAnimation { properties: "x"; duration: 120; easing.type: Easing.OutCubic }
      }

      Repeater {
        id: appRepeater
        model: appModel
        delegate: dockItem
      }

      // Running apps that are not on the dock live to the right of this rule.
      // Drawn only when there is something after it: a separator with an empty
      // side reads as a mistake rather than a boundary.
      Item {
        id: runningSeparator
        visible: extraModel.count > 0
        // Wider than the seam between two icons, so the rule reads as a break
        // in the row rather than as another gap in it.
        width: root.itemSpacing * 3
        height: root.itemSize

        Rectangle {
          anchors.centerIn: parent
          width: 1
          height: Math.round(parent.height * 0.55)
          radius: width / 2
          color: Theme.foreground
          opacity: 0.22
        }
      }

      Repeater {
        id: extraRepeater
        model: extraModel
        delegate: dockItem
      }
    }
    }
  }

  // One delegate for both sides of the separator: a docked app and a running
  // one differ in what their context menu offers and whether they can be
  // dragged, not in how they draw. Both models carry the same roles so this
  // can back either.
  Component {
    id: dockItem

    Item {
      id: appItem

      required property int index
      required property string entryId
      required property bool pinned
      required property string name
      required property string icon
      required property string cmd
      required property string matchTitle
      required property string appId
      // Running, but not on the dock: drawn right of the separator, never
      // draggable, and pinned rather than unpinned from its context menu.
      required property bool transientApp
      required property bool exactMatch

      readonly property var appData: ({
        name: appItem.name,
        icon: appItem.icon,
        cmd: appItem.cmd,
        match: appItem.matchTitle,
        appId: appItem.appId,
        exact: appItem.exactMatch,
      })

      readonly property bool isDragged: root.dragName === appItem.name

      // One icon in the dock is the focused window's. The pill under it
      // grows to say so, which is the difference between "running" and
      // "this is what you are looking at".
      readonly property bool isFocused: {
        if (!appItem.isRunning) return false
        for (const t of appItem.toplevels)
          if (t.toplevel.address === root.activeAddress) return true
        return false
      }

      width: root.itemSize
      height: root.itemSize
      z: isDragged ? 10 : 0

      // Glued to the pointer while dragged. Because this reads appItem.x,
      // it re-solves whenever the Row re-lays the icon out mid-drag, so
      // the icon stays under the cursor through a reorder.
      transform: Translate {
        x: appItem.isDragged ? root.dragPointerX - root.dragGrabOffset - appItem.x : 0
      }

      property bool busy: false

      // busy only clears when a matching window appears. An app that never
      // maps a window the dock can match (tray-only start, failed launch,
      // window class != appId) would otherwise leave the icon dead until the
      // dock restarts -- the "clicks do nothing" bug.
      Timer {
        running: appItem.busy
        interval: 8000
        onTriggered: {
          appItem.busy = false
          bounceAnimation.stop()
          iconImg.y = 0
        }
      }

      readonly property var toplevels: root.getToplevelsForApp(appItem.appData)
      readonly property bool isRunning: toplevels.length > 0
      readonly property int pid: isRunning ? toplevels[0].pid : 0
      readonly property int unreadCount: {
        var _ = root._badgeTick
        if (!isRunning) return 0
        return root.getUnreadCount(toplevels)
      }

      HoverHandler {
        id: itemHover
        onHoveredChanged: {
          if (hovered) {
            root.tooltipText = appItem.name
            root.tooltipAnchorX = dockBar.mapFromItem(appItem, appItem.width / 2, 0).x
            tooltipTimer.restart()
          } else if (root.tooltipText === appItem.name) {
            tooltipTimer.stop()
            root.tooltipShown = false
          }
        }
      }

      // The only hover/press affordance: the tile lights up, the icon does
      // not move. Press is tested before hover because a pointer is always
      // hovering whatever it is pressing.
      Rectangle {
        anchors.fill: parent
        radius: Theme.inner(dockBar.radius, root.barPadding, height)
        color: Theme.foreground
        opacity: appItem.isDragged ? 0.22
          : (leftTap.pressed ? 0.28 : (itemHover.hovered ? 0.15 : 0))
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      DragHandler {
        id: dragHandler
        target: null
        yAxis.enabled: false
        // Extras hold no slot in the saved order — there is nothing for a
        // drag to persist, and persistOrder() would read their names into it.
        enabled: !appItem.transientApp

        onActiveChanged: {
          if (active) {
            hideTimer.stop()
            const p = row.mapFromItem(null, centroid.scenePosition.x, centroid.scenePosition.y)
            root.dragPointerX = p.x
            root.dragGrabOffset = p.x - appItem.x
            root.dragName = appItem.name
          } else {
            root.dragName = ""
            root.persistOrder()
            if (!root.mouseOverDockArea) root.scheduleHide()
          }
        }

        onCentroidChanged: {
          if (!active) return
          const p = row.mapFromItem(null, centroid.scenePosition.x, centroid.scenePosition.y)
          root.dragPointerX = p.x
          root.updateDragTarget(appItem.index)
        }
      }

      TapHandler {
        acceptedButtons: Qt.RightButton
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onSingleTapped: root.openContextMenu(appItem)
      }

      TapHandler {
        id: leftTap
        acceptedButtons: Qt.LeftButton
        // Releases the press to the DragHandler once the pointer moves
        // past the drag threshold, so a drag never fires a launch.
        gesturePolicy: TapHandler.DragThreshold
        onSingleTapped: {
          if (root.contextOpen) {
            root.closeContextMenu()
            return
          }
          if (appItem.isRunning) {
            root.activateApp(appItem.toplevels)
            if (!root.keepUp) root.dockVisible = false
          } else if (!appItem.busy) {
            appItem.busy = true
            bounceAnimation.start()
            root.launchApp(appItem.entryId, appItem.cmd)
          }
        }
      }

      onIsRunningChanged: {
        if (isRunning) busy = false
        bounceAnimation.stop()
        iconImg.y = 0
      }

      SequentialAnimation {
        id: bounceAnimation
        loops: Animation.Infinite
        NumberAnimation {
          target: iconImg
          property: "y"
          from: 0; to: -24; duration: 0
          easing.type: Easing.OutQuad
        }
        NumberAnimation {
          target: iconImg
          property: "y"
          to: 0; duration: 0
          easing.type: Easing.InQuad
        }
      }

      Image {
        id: iconImg
        anchors.centerIn: parent
        // Fallback form: an icon name the theme does not have would otherwise
        // resolve to an empty source and draw nothing at all.
        source: Quickshell.iconPath(appItem.icon, "application-x-executable")
        width: root.iconSize
        height: root.iconSize
        fillMode: Image.PreserveAspectFit
        opacity: appItem.isDragged ? 0.85 : 1

        // Themed icons arrive at whatever size the theme happens to ship.
        // Rasterizing at 2x and letting mipmapping do the reduction is what
        // stops a 128px PNG landing on a 36px box as aliased mush — the
        // single loudest "this dock is old" tell on a HiDPI screen.
        sourceSize.width: root.iconSize * 2
        sourceSize.height: root.iconSize * 2
        mipmap: true
      }

      // Running indicator: centered under the icon, in whatever ink the
      // theme can actually show against the dock bar. A pill rather than a
      // dot, and it widens for the focused window — the state a dot cannot
      // express, and the one worth knowing at a glance.
      Rectangle {
        visible: appItem.isRunning
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: -6
        width: appItem.isFocused ? 16 : 6
        height: 3
        radius: height / 2
        color: Theme.indicator
        opacity: appItem.isFocused ? 1 : 0.65
        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 180 } }
      }

      Rectangle {
        id: badge
        // Driven by scale rather than visible, so a count arriving pops in
        // instead of blinking into existence; visible only follows it to
        // keep a zero-scale badge out of the scene graph.
        visible: scale > 0.01
        scale: appItem.unreadCount > 0 ? 1 : 0
        Behavior on scale {
          NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
        }

        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.right: parent.right
        anchors.rightMargin: 1
        width: Math.max(16, badgeText.implicitWidth + 9)
        height: 16
        radius: height / 2
        color: Theme.urgent
        // Opaque, not panelBackground: this ring separates the badge from
        // the icon under it, so it has to be the dock's own fill.
        border.color: Theme.background
        border.width: 1.5

        Text {
          id: badgeText
          anchors.centerIn: parent
          text: appItem.unreadCount > 99 ? "99+" : appItem.unreadCount.toString()
          color: Theme.background
          font.pixelSize: 10
          font.bold: true
          // Counts change in place; proportional digits would jiggle the
          // badge's width every time one ticked over.
          font.features: ({ "tnum": 1 })
        }
      }
    }
  }

  // Long enough that sweeping the pointer across the dock stays quiet, short
  // enough that pausing on an icon answers straight away.
  Timer {
    id: tooltipTimer
    interval: 400
    repeat: false
    onTriggered: root.tooltipShown = true
  }

  Timer {
    id: contextCloseTimer
    interval: 180
    repeat: false
    onTriggered: if (!root.mouseOverDockArea) root.closeContextMenu()
  }

  Item {
    id: contextMenu

    // Collapsed to nothing when closed so it contributes no input region.
    width: root.contextOpen ? contextCard.width : 0
    height: root.contextOpen ? contextCard.height : 0
    visible: root.contextOpen

    anchors.bottom: dockBar.top
    anchors.bottomMargin: root.menuGap
    x: Math.max(0, Math.min(dockBar.x + root.contextAnchorX - width / 2, root.width - width))

    HoverHandler { id: contextHover }

    RectangularShadow {
      anchors.fill: contextCard
      radius: contextCard.radius
      blur: 24
      offset: Qt.vector2d(0, 4)
      color: Theme.shadow
    }

    Rectangle {
      id: contextCard

      implicitWidth: Math.max(150, widthProbe.implicitWidth
        + (root.menuPadding + root.menuTextPadding) * 2)
      implicitHeight: contextColumn.implicitHeight + root.menuPadding * 2

      color: Theme.background
      radius: Theme.fit(Theme.radiusMedium, height)
      border.color: Theme.panelBorder
      border.width: 1

      Column {
        id: contextColumn
        anchors.centerIn: parent
        spacing: 1

        Repeater {
          model: root.contextActions

          delegate: Rectangle {
            required property var modelData

            width: contextCard.width - root.menuPadding * 2
            height: root.menuRowHeight
            radius: Theme.inner(contextCard.radius, root.menuPadding, height)
            // Quit closes windows, so its hover reads in the theme's alarm ink
            // rather than the same neutral wash as the harmless rows.
            readonly property bool destructive: modelData.act === "quit"
            color: !rowHover.hovered ? "transparent"
              : (destructive ? Qt.rgba(Theme.urgent.r, Theme.urgent.g, Theme.urgent.b, 0.9)
                             : Theme.surface)
            Behavior on color { ColorAnimation { duration: 120 } }

            HoverHandler { id: rowHover }

            TapHandler {
              acceptedButtons: Qt.LeftButton
              onSingleTapped: root.runContextAction(modelData.act)
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: root.menuTextPadding
              text: modelData.label
              color: (parent.destructive && rowHover.hovered) ? Theme.background
                                                              : Theme.foreground
              font.pixelSize: 13
            }
          }
        }
      }

      // Sizes the card without reading the Column back, which would be a
      // polish loop since the rows take their width from the card.
      Text {
        id: widthProbe
        visible: false
        text: "Open new window"
        font.pixelSize: 13
      }
    }
  }

  // Hover label. Deliberately absent from `mask`: it renders, but takes no
  // input, so it can sit directly over the icon that summoned it without
  // stealing the hover that is keeping it on screen.
  Item {
    id: tooltip

    readonly property bool shown: root.tooltipShown && root.dockVisible
      && !root.contextOpen && !root.dragging

    width: tooltipCard.width
    height: root.tooltipHeight
    visible: opacity > 0.01
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    anchors.bottom: dockBar.top
    anchors.bottomMargin: root.menuGap
    x: Math.max(4, Math.min(dockBar.x + root.tooltipAnchorX - width / 2,
                            root.width - width - 4))

    RectangularShadow {
      anchors.fill: tooltipCard
      radius: tooltipCard.radius
      blur: 18
      offset: Qt.vector2d(0, 3)
      color: Theme.shadow
    }

    Rectangle {
      id: tooltipCard
      width: tooltipLabel.implicitWidth + root.menuTextPadding * 2
      height: root.tooltipHeight
      color: Theme.background
      radius: Theme.fit(Theme.radiusSmall, height)
      border.color: Theme.panelBorder
      border.width: 1

      Text {
        id: tooltipLabel
        anchors.centerIn: parent
        text: root.tooltipText
        color: Theme.foreground
        font.pixelSize: 12
      }
    }
  }
}
