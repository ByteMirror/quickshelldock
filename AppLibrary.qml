import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.config

// COSMIC-style app library. Every installed app on one card, a search field on
// top, a row of groups along the bottom. Drag an app onto a group to file it
// there (onto "New group" to start one); right-click a group to rename or
// delete it. One per dock, so it opens on the dock's own monitor.
PanelWindow {
  id: lib

  // The DockPanel that owns this library: launchApp(), shq(), pinTool,
  // pinnedApps and stateDir all come from it.
  required property var dock
  property bool opened: false
  // Surface is fullscreen. Outlives `opened` by the exit animation, so the
  // card can animate out before the surface shrinks back to 1x1.
  property bool expanded: false
  // The compositor has actually resized the surface. The entrance waits for
  // this, or its first frames would play inside a 1x1 window and be lost.
  readonly property bool surfaceReady: expanded && width >= screenW - 1 && height >= screenH - 1
  readonly property bool shown: opened && surfaceReady

  // Motion, matched to Hyprland's workspace switch (looknfeel.lua):
  // easeOutExpo, nearly all the distance covered in the first third.
  // Exit is shorter: the user is already moving on.
  readonly property var easeOutExpo: [0.16, 1, 0.3, 1, 1, 1]
  readonly property var easeOutQuint: [0.23, 1, 0.32, 1, 1, 1]
  property bool motion: true          // false when Hyprland animations are off
  readonly property int enterMs: motion ? 300 : 0
  readonly property int exitMs: motion ? 160 : 0

  // The surface stays mapped for the life of the dock. Mapping a fresh
  // fullscreen layer surface on every open (configure round trip, then every
  // icon decoded for the first frame) cost 150-300 ms before anything showed.
  // Closed, it shrinks to 1x1 with no input region and no keyboard, so it is
  // invisible and inert; the scene graph and icon textures stay warm.
  visible: true
  anchors { top: true; left: true; bottom: expanded; right: expanded }
  implicitWidth: 1
  implicitHeight: 1
  mask: Region { width: lib.opened ? lib.screenW : 0; height: lib.opened ? lib.screenH : 0 }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  // Own layerrule in hypr/looknfeel.lua: blur (frosts the card) and no_anim
  // (Hyprland must not tween the 1x1 <-> fullscreen resize). No backdrop
  // dimming: the rest of the screen stays exactly as it was.
  WlrLayershell.namespace: "quickshelldock-applibrary"
  WlrLayershell.keyboardFocus: opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  readonly property int iconSize: 56
  readonly property int cellWidth: 128
  readonly property int cellHeight: 116
  // One inset for everything that faces the card's edge: the search field's
  // top, the grid's outer cell highlights, the group tiles' sides and bottom.
  // Section gaps use the same number. Highlights inside a grid cell sit `gutter`
  // in from the cell, so the grid itself is offset by pad - gutter.
  readonly property int pad: 12
  readonly property int gutter: 4
  // Concentric corners: anything drawn `pad` inside the card rounds at
  // innerRadius, the card at innerRadius + pad. Rounding 0 squares both.
  readonly property real innerRadius: Theme.radiusMedium
  readonly property real cardRadius: innerRadius > 0 ? innerRadius + pad : 0
  readonly property int searchHeight: 38
  readonly property int tileHeight: 84
  readonly property real tileRadius: Theme.fit(innerRadius, tileHeight)
  readonly property real screenW: screen ? screen.width : width
  readonly property real screenH: screen ? screen.height : height
  readonly property int tileSpacing: gutter * 2      // same seam as between cell highlights
  readonly property real innerWidth: columns * cellWidth - gutter * 2
  // Home, Files, the groups, New group.
  readonly property real tileWidth: Math.min(116, (innerWidth - tileSpacing * (groups.length + 2)) / (groups.length + 3))
  readonly property int columns: Math.max(3, Math.min(7, Math.floor((screenW * 0.8 - pad * 2) / cellWidth)))
  readonly property int rows: Math.max(2, Math.min(4, Math.floor((screenH * 0.8 - searchHeight - tileHeight - pad * 5) / cellHeight)))

  // Default groups are the ones COSMIC ships: plain category filters that
  // dragged apps can be added to and removed from like any other group.
  readonly property var defaultGroups: [
    { name: "Office", categories: ["Office"], apps: [], exclude: [] },
    { name: "System", categories: ["System"], apps: [], exclude: [] },
    { name: "Utilities", categories: ["Utility"], apps: [], exclude: [] },
  ]

  property var groups: []
  property int groupIndex: -1          // -1 = Library Home
  property string query: ""
  // File search (LocalSearch, via bin/quickshelldock-find). filesMode is the
  // "Files" tile / CTRL+SPACE: files only. Otherwise a non-empty query shows
  // the best apps as one row and files below; one selection index runs across
  // both -- 0..appsShown-1 are apps, the rest are files.
  property bool filesMode: false
  property var files: []
  property bool filesPending: false
  property int findSeq: 0
  readonly property string trimmed: query.trim()
  readonly property bool resultsMode: filesMode || trimmed !== ""
  readonly property int appsShown: (!filesMode && trimmed !== "") ? Math.min(apps.length, columns) : 0
  readonly property int resultCount: appsShown + files.length
  property var apps: []                // the entries the grid shows
  property int selected: 0
  // Pointer and keyboard each own the highlight in turn, never both: the cell
  // under the pointer, or -- only while navigating by keys -- the selection.
  // Leaving the grid clears hover, so nothing stays lit behind the groups.
  property int hoverIndex: -1
  property bool keyNav: true
  property var hidden: ({})            // desktop ids Omarchy's launcher hides
  property int renaming: -1
  // Open context menu: { kind: "app"|"group", entry, index, x, y } or null.
  property var menu: null
  // App drag toward the group row.
  property var dragEntry: null
  property point dragPoint
  property int dropTarget: -1          // group index, groups.length = "New group"

  function open(filesOnly) {
    filesMode = !!filesOnly
    groupIndex = -1
    selected = 0
    hoverIndex = -1
    keyNav = true
    menu = null
    renaming = -1
    search.text = ""      // rebuilds through onTextChanged if it had text
    rebuild()             // no-op when the grid already shows this list
    grid.positionViewAtBeginning()
    shrinkTimer.stop()
    expanded = true
    opened = true
    Qt.callLater(() => search.forceActiveFocus())
  }

  function close() {
    opened = false
    shrinkTimer.restart()
    menu = null
    dragEntry = null
    dropTarget = -1
    renaming = -1
  }

  Timer {
    id: shrinkTimer
    interval: lib.exitMs + 20
    onTriggered: if (!lib.opened) lib.expanded = false
  }

  // Respect "animations off" in Hyprland the way every other surface does.
  Process {
    running: true
    command: ["hyprctl", "getoption", "animations:enabled", "-j"]
    stdout: StdioCollector {
      onStreamFinished: { try { lib.motion = JSON.parse(this.text).int !== 0 } catch (e) {} }
    }
  }

  function toggle() { opened ? close() : open() }
  // CTRL+SPACE: open in files mode, switch an open library to it, or close.
  function toggleFiles() {
    if (opened && filesMode) close()
    else if (opened) setFilesMode(true)
    else open(true)
  }

  // IPC `applibrary search <text>`: open with a query already typed.
  function searchFor(text, filesOnly) {
    if (!opened) open(filesOnly)
    else if (filesOnly !== filesMode) setFilesMode(filesOnly)
    search.text = text
  }

  function setFilesMode(on) {
    filesMode = on
    selected = 0
    hoverIndex = -1
    keyNav = true
    rebuild()
    requestFiles()
    search.forceActiveFocus()
  }

  // ---- files ----------------------------------------------------------------

  function requestFiles() {
    if (trimmed.length < 2) {
      findDebounce.stop()
      files = []
      filesPending = false
      return
    }
    filesPending = true
    findDebounce.restart()
  }

  function sendFind() {
    if (!finder.running) { finder.running = true; return }   // onStarted sends
    if (!filesPending || trimmed.length < 2) return
    findSeq++
    finder.write(findSeq + "\t" + trimmed + "\n")
  }

  function onFound(line) {
    let msg = null
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || String(msg.id) !== String(findSeq)) return   // a stale answer
    // "names" arrives in ~5 ms; "content" (names + text matches) right after.
    files = msg.results || []
    filesPending = msg.phase !== "content"
    selected = Math.max(0, Math.min(selected, resultCount - 1))
  }

  function openFile(f) {
    close()
    dock.launchApp("", "xdg-open " + dock.shq(f.path))
  }

  function fileIcon(mime) {
    const m = String(mime || "")
    if (m === "inode/directory") return Quickshell.iconPath("folder", true) || iconFor("")
    const exact = m ? Quickshell.iconPath(m.replace("/", "-"), true) : ""
    if (exact) return exact
    const generic = ({ image: "image-x-generic", audio: "audio-x-generic", video: "video-x-generic" })[m.split("/")[0]]
      || "text-x-generic"
    return Quickshell.iconPath(generic, true) || iconFor("")
  }

  // One long-lived helper, so a keystroke costs a LocalSearch query (tens of
  // ms), not a Python start. Started on first use.
  Process {
    id: finder
    command: [Quickshell.shellDir + "/bin/quickshelldock-find"]
    stdinEnabled: true
    stdout: SplitParser { onRead: data => lib.onFound(data) }
    onStarted: lib.sendFind()
  }

  // Zero: no debounce. Only coalesces keystrokes landing in the same event
  // loop turn; the helper itself skips requests that a newer one overtook.
  Timer { id: findDebounce; interval: 0; onTriggered: lib.sendFind() }

  // The matched characters in a file name, in the accent colour.
  function highlightName(name, ranges) {
    const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    if (!ranges || ranges.length === 0) return esc(name)
    const color = String(Theme.accent)
    let out = "", at = 0
    for (const r of ranges) {
      out += esc(name.slice(at, r[0]))
      out += "<font color=\"" + color + "\"><b>" + esc(name.slice(r[0], r[1])) + "</b></font>"
      at = r[1]
    }
    return out + esc(name.slice(at))
  }
  function focusSearch() { search.forceActiveFocus() }

  // ---- apps ---------------------------------------------------------------

  // Sorted, filtered app list and the group-tile previews, recomputed only
  // when the installed apps, the hide list or the groups change -- never on open.
  property var entries: []
  property var previews: []

  function allEntries() { return entries }

  // Plain JS copies, never the DesktopEntry QObjects themselves: quickshell
  // replaces those during its async startup scan, and a GridView delegate still
  // incubating against a freed one segfaults the whole dock (QQmlModels ->
  // QMetaObject::propertyCount). Nothing here may hold a live entry.
  function refreshEntries() {
    entries = (DesktopEntries.applications.values || [])
      .filter(e => e && !e.noDisplay && !lib.hidden[e.id])
      .map(e => ({
        id: String(e.id),
        name: String(e.name || e.id),
        icon: String(e.icon || ""),
        genericName: String(e.genericName || ""),
        comment: String(e.comment || ""),
        keywords: Array.from(e.keywords || []).map(String),
        categories: Array.from(e.categories || []).map(String),
        runInTerminal: !!e.runInTerminal,
        command: Array.from(e.command || []).map(String),
        actions: Array.from(e.actions || []).map(a => ({ name: String(a.name), command: Array.from(a.command || []).map(String) })),
        startupClass: String(e.startupClass || ""),
      }))
      .sort((a, b) => a.name.localeCompare(b.name))
    updatePreviews()
    rebuild()
  }

  function updatePreviews() {
    previews = groups.map(g => entries.filter(e => inGroup(g, e)).slice(0, 4).map(e => e.icon))
  }

  // How well an app matches the search, 0 = not at all. Higher sorts first.
  // ponytail: plain substring tiers; swap in fuzzy matching if typos matter.
  function score(e, q) {
    const name = e.name.toLowerCase()
    if (name.startsWith(q)) return 4
    if (name.split(/[\s\-_.]+/).some(w => w.startsWith(q))) return 3
    if (name.includes(q)) return 2
    const extra = [e.genericName, e.comment, e.id].concat(Array.from(e.keywords || [])).join(" ").toLowerCase()
    return extra.includes(q) ? 1 : 0
  }

  function inGroup(g, e) {
    if (g.exclude.indexOf(e.id) >= 0) return false
    if (g.apps.indexOf(e.id) >= 0) return true
    const cats = Array.from(e.categories || [])
    return g.categories.some(c => cats.indexOf(c) >= 0)
  }

  // Search always spans the whole library, the way COSMIC's does; the group
  // row only narrows the grid while the field is empty.
  function rebuild() {
    let list = allEntries()
    const q = query.trim().toLowerCase()
    if (q) {
      list = list.map(e => ({ e: e, s: score(e, q) }))
        .filter(x => x.s > 0)
        .sort((a, b) => b.s - a.s)   // stable, so ties stay alphabetical
        .map(x => x.e)
    } else if (groups[groupIndex]) {
      list = list.filter(e => inGroup(groups[groupIndex], e))
    }
    // Same list as on screen: keep the delegates (and their decoded icons).
    if (list.length !== apps.length || list.some((e, i) => e !== apps[i])) apps = list
    selected = Math.max(0, Math.min(selected, list.length - 1))
  }

  function iconFor(name) {
    const v = String(name || "")
    if (v.startsWith("/")) return "file://" + v
    return Quickshell.iconPath(v, true) || Quickshell.iconPath("application-x-executable", true)
  }

  // Exec lines carry field codes (%U, %f) for a launcher to fill; nothing is
  // being opened here, so they go.
  function commandLine(words) {
    return Array.from(words || []).filter(w => !/^%[a-zA-Z]$/.test(w)).map(w => dock.shq(w)).join(" ")
  }

  // Window app ids / classes that belong to this entry. Exact matches only,
  // so one entry can never claim a neighbour whose id merely contains it.
  function windowKeys(e) {
    const keys = [e.id]
    if (e.startupClass) keys.push(e.startupClass)
    const exe = (e.command[0] || "").split("/").pop().replace(/\.(exe|sh|py|AppImage)$/i, "")
    // Omarchy runs TUI entries in a terminal named after the command.
    if (exe) keys.push(e.runInTerminal ? "org.omarchy." + exe : exe)
    const steam = e.command.join(" ").match(/steam:\/\/rungameid\/(\d+)/)
    if (steam) keys.push("steam_app_" + steam[1])
    return keys.map(k => k.toLowerCase())
  }

  function openWindows(e) {
    const keys = windowKeys(e)
    // A reverse-DNS class also matches by its last part: com.t3tools.T3Code
    // belongs to the entry "t3code".
    const hit = id => {
      const v = String(id ?? "").toLowerCase()
      return v !== "" && (keys.indexOf(v) >= 0 || keys.indexOf(v.split(".").pop()) >= 0)
    }
    // Background helpers the dock ignores (an always-mapped status pill) are
    // not "the app is open".
    return Hyprland.toplevels.values
      .filter(tl => dock.toplevelIsLive(tl) && !dock.isIgnoredToplevel(tl)
        && (hit(tl.wayland?.appId) || hit(tl.lastIpcObject?.class)))
      .map(tl => ({ toplevel: tl, pid: tl.lastIpcObject?.pid ?? -1 }))
  }

  // Already open: jump to it (the dock's own focus logic -- prefers a window
  // on this monitor's workspace, un-hides scratchpads). Otherwise launch.
  function launch(e, newWindow) {
    close()
    const open = newWindow ? [] : openWindows(e)
    if (open.length > 0) { dock.activateApp(open); return }
    followLaunch(e)
    if (e.runInTerminal) dock.launchApp("", "omarchy-launch-tui " + commandLine(e.command))
    else dock.launchApp(e.id, "")
  }

  // Window rules can send an app somewhere else on launch -- Signal and
  // Discord go to `special:chat silent`, which parks them out of sight. So
  // after a launch, wait for the app's first *new* window and jump to it the
  // same way as an already-open app (activateApp shows special workspaces).
  // Windows that existed before the launch are ignored, so "New window" on a
  // running app follows the new one. Gives up after followMs.
  readonly property int followMs: 20000
  property var pendingFollow: null     // { entry, known: { address: true } }

  function windowAddress(tl) { return String(tl.address ?? "") }

  function followLaunch(e) {
    const known = {}
    for (const w of openWindows(e)) known[windowAddress(w.toplevel)] = true
    pendingFollow = { entry: e, known: known }
    followExpiry.restart()
  }

  function checkFollow() {
    const p = pendingFollow
    if (!p) return
    const fresh = openWindows(p.entry).filter(w => !p.known[windowAddress(w.toplevel)])
    if (fresh.length === 0) return
    pendingFollow = null
    followExpiry.stop()
    dock.activateApp(fresh)
  }

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { if (lib.pendingFollow) followSettle.restart() }
  }

  // A new toplevel's class and workspace land a beat after it appears; wait
  // for them before matching and choosing where to go.
  Timer { id: followSettle; interval: 250; onTriggered: lib.checkFollow() }
  Timer { id: followExpiry; interval: lib.followMs; onTriggered: lib.pendingFollow = null }

  function isPinned(id) {
    return (dock.pinnedApps || []).some(p => p.id === id)
  }

  // ---- groups -------------------------------------------------------------

  function normalize(g) {
    return {
      name: String(g.name || "Group"),
      categories: Array.isArray(g.categories) ? g.categories : [],
      apps: Array.isArray(g.apps) ? g.apps : [],
      exclude: Array.isArray(g.exclude) ? g.exclude : [],
    }
  }

  function loadGroups(text) {
    let next = null
    try { next = JSON.parse(text).groups } catch (e) {}
    groups = Array.isArray(next) ? next.map(normalize) : JSON.parse(JSON.stringify(defaultGroups))
    if (groupIndex >= groups.length) groupIndex = -1
    updatePreviews()
    rebuild()
  }

  function saveGroups(next) {
    groups = next
    groupsFile.setText(JSON.stringify({ groups: next }, null, 2))
    updatePreviews()
    rebuild()
  }

  function editGroups(fn) {
    const next = JSON.parse(JSON.stringify(groups))
    fn(next)
    saveGroups(next)
  }

  function addToGroup(i, id) {
    editGroups(gs => {
      const g = gs[i]
      g.exclude = g.exclude.filter(x => x !== id)
      if (g.apps.indexOf(id) < 0) g.apps.push(id)
    })
  }

  function removeFromGroup(i, id) {
    editGroups(gs => {
      const g = gs[i]
      g.apps = g.apps.filter(x => x !== id)
      // Still matched by a category: exclude it explicitly.
      const e = lib.entries.find(x => x.id === id)
      if (e && lib.inGroup(g, e)) g.exclude.push(id)
    })
  }

  function newGroup(firstApp) {
    editGroups(gs => gs.push({ name: "New Group", categories: [], apps: firstApp ? [firstApp] : [], exclude: [] }))
    groupIndex = groups.length - 1
    renaming = groupIndex
    rebuild()
  }

  function renameGroup(i, name) {
    renaming = -1
    const n = String(name || "").trim()
    if (n && groups[i] && n !== groups[i].name) editGroups(gs => gs[i].name = n)
    search.forceActiveFocus()
  }

  function deleteGroup(i) {
    groupIndex = -1
    editGroups(gs => gs.splice(i, 1))
  }


  // ---- drag ---------------------------------------------------------------

  function dragMove(entry, point) {
    if (!dragEntry) { menu = null; dragEntry = entry }
    dragPoint = point
    dropTarget = -1
    for (let i = 0; i <= groups.length; i++) {
      const tile = i < groups.length ? groupRepeater.itemAt(i) : newTile
      if (!tile) continue
      const p = tile.mapFromItem(lib.contentItem, point.x, point.y)
      if (tile.contains(p)) { dropTarget = i; break }
    }
  }

  function dragDrop() {
    const id = dragEntry ? dragEntry.id : ""
    const target = dropTarget
    dragEntry = null
    dropTarget = -1
    if (!id || target < 0) return
    if (target === groups.length) newGroup(id)
    else addToGroup(target, id)
  }

  // ---- menus & keys -------------------------------------------------------

  readonly property var menuItems: {
    const m = lib.menu
    if (!m) return []
    if (m.kind === "file") return [
      { label: "Open", act: "openfile" },
      { label: "Show in Files", act: "reveal" },
      { label: "Copy path", act: "copypath" },
    ]
    if (m.kind === "group") return [
      { label: "Rename", act: "rename" },
      { label: "Delete group", act: "delete", destructive: true },
    ]
    const items = lib.openWindows(m.entry).length > 0
      ? [{ label: "Switch to window", act: "open" }, { label: "New window", act: "new" }]
      : [{ label: "Open", act: "open" }]
    const actions = Array.from(m.entry.actions || [])
    for (let i = 0; i < actions.length; i++) items.push({ label: actions[i].name, act: "action", index: i })
    items.push(lib.isPinned(m.entry.id) ? { label: "Unpin from dock", act: "unpin" } : { label: "Pin to dock", act: "pin" })
    if (lib.groupIndex >= 0 && !lib.query && lib.groups[lib.groupIndex])
      items.push({ label: "Remove from " + lib.groups[lib.groupIndex].name, act: "ungroup", destructive: true })
    return items
  }

  function runMenu(item) {
    const m = menu
    menu = null
    if (!m) return
    switch (item.act) {
    case "open": launch(m.entry); break
    case "openfile": openFile(m.file); break
    case "reveal": close(); dock.launchApp("", "nautilus --select " + dock.shq(m.file.path)); break
    case "copypath": Quickshell.execDetached(["wl-copy", m.file.path]); break
    case "new": launch(m.entry, true); break
    case "action":
      close()
      dock.launchApp("", commandLine(m.entry.actions[item.index].command))
      break
    case "pin": Quickshell.execDetached([dock.pinTool, m.entry.id]); break
    case "unpin": Quickshell.execDetached([dock.pinTool, "--unpin", m.entry.id]); break
    case "ungroup": removeFromGroup(groupIndex, m.entry.id); break
    case "rename": groupIndex = m.index; renaming = m.index; break
    case "delete": deleteGroup(m.index); break
    }
  }

  function openMenu(spec, point) {
    spec.x = point.x
    spec.y = point.y
    menu = spec
  }

  function moveSelection(delta) {
    keyNav = true
    hoverIndex = -1
    if (apps.length === 0) return
    selected = Math.max(0, Math.min(apps.length - 1, selected + delta))
    grid.positionViewAtIndex(selected, GridView.Contain)
  }

  function activateSelected() {
    if (!resultsMode) { if (apps[selected]) launch(apps[selected]); return }
    if (selected < appsShown) launch(apps[selected])
    else if (files[selected - appsShown]) openFile(files[selected - appsShown])
  }

  // Results: ←→ walk the app row, ↓ drops into the files, ↑ climbs back.
  function moveResult(key) {
    keyNav = true
    hoverIndex = -1
    const a = appsShown, n = resultCount
    if (n === 0) return
    let s = Math.min(selected, n - 1)
    if (key === Qt.Key_Left) { if (s < a) s = Math.max(0, s - 1) }
    else if (key === Qt.Key_Right) { if (s < a) s = Math.min(a - 1, s + 1) }
    else if (key === Qt.Key_Down) s = s < a ? (files.length ? a : s) : Math.min(n - 1, s + 1)
    else if (key === Qt.Key_Up) s = s > a ? s - 1 : (s === a && a > 0 ? 0 : s)
    selected = s
    if (s >= a) fileList.positionViewAtIndex(s - a, ListView.Contain)
  }

  function cycleGroup(delta) {
    filesMode = false
    const n = groups.length + 1                     // Home + groups
    groupIndex = ((groupIndex + 1 + delta) % n + n) % n - 1
    selected = 0
    search.text = ""
    rebuild()
  }

  function handleKey(event) {
    switch (event.key) {
    case Qt.Key_Escape:
      if (menu) menu = null
      else if (search.text) search.text = ""
      else close()
      break
    case Qt.Key_Return:
    case Qt.Key_Enter: activateSelected(); break
    case Qt.Key_Left: resultsMode ? moveResult(event.key) : moveSelection(-1); break
    case Qt.Key_Right: resultsMode ? moveResult(event.key) : moveSelection(1); break
    case Qt.Key_Up: resultsMode ? moveResult(event.key) : moveSelection(-columns); break
    case Qt.Key_Down: resultsMode ? moveResult(event.key) : moveSelection(columns); break
    case Qt.Key_Tab: cycleGroup(1); break
    case Qt.Key_Backtab: cycleGroup(-1); break
    default: return
    }
    event.accepted = true
  }

  // ---- data sources -------------------------------------------------------

  FileView {
    id: groupsFile
    path: lib.dock.stateDir + "/applibrary.json"
    blockLoading: true
    printErrors: false
    atomicWrites: true
    watchChanges: true                // keeps the other monitor's library in step
    onFileChanged: reload()
    onTextChanged: lib.loadGroups(text())
  }

  // Omarchy's own launcher hides: its static list plus NoDisplay/OnlyShowIn
  // handling from the shell's helper. Same filter the Omarchy menu uses.
  Process {
    id: hideScan
    command: ["bash", "-c",
      'o="${OMARCHY_PATH:-/usr/share/omarchy}"; cat "$o/default/omarchy/launcher.hides" 2>/dev/null; '
      + '"$o/shell/services/hidden-entries.sh" "$XDG_CURRENT_DESKTOP" 2>/dev/null']
    stdout: StdioCollector {
      onStreamFinished: {
        const h = {}
        for (const line of this.text.split("\n")) {
          const id = line.trim().replace(/\.desktop$/, "")
          if (id) h[id] = true
        }
        lib.hidden = h
        lib.refreshEntries()
      }
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { if (!hideScan.running) hideScan.running = true }
  }

  Component.onCompleted: {
    loadGroups(groupsFile.text())
    hideScan.running = true
    finder.running = true      // the file catalog loads (~0.6 s) before anyone types
  }

  // ---- UI -----------------------------------------------------------------

  // Screen-sized regardless of the window, so nothing re-lays out when the
  // surface grows from 1x1 on open. Opacity, not visible, hides it: hidden
  // items drop their scene-graph nodes and would rebuild them on every open.
  Item {
    id: stage
    width: lib.screenW
    height: lib.screenH

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: lib.menu ? (lib.menu = null) : lib.close()
    }

    // Card and shadow move together. Enters rising from the dock side with a
    // slight scale-up, leaves the same way it came. Behaviors, not one-shot
    // animations, so a quick reopen retargets mid-flight instead of jumping.
    Item {
      id: sheet
      // pad | search | pad | cells (gutter-trimmed) | pad | rule | pad | tiles | pad
      width: lib.innerWidth + lib.pad * 2
      height: lib.pad * 5 + lib.searchHeight + lib.rows * lib.cellHeight - lib.gutter * 2 + 1 + lib.tileHeight
      anchors.centerIn: parent
      opacity: lib.shown ? 1 : 0
      scale: lib.shown ? 1 : 0.96
      transform: Translate {
        y: lib.shown ? 0 : 24
        Behavior on y {
          NumberAnimation {
            duration: lib.shown ? lib.enterMs : lib.exitMs
            easing.type: Easing.BezierSpline
            easing.bezierCurve: lib.shown ? lib.easeOutExpo : lib.easeOutQuint
          }
        }
      }

      Behavior on opacity {
        NumberAnimation {
          duration: lib.shown ? lib.enterMs * 0.6 : lib.exitMs
          easing.type: Easing.BezierSpline
          easing.bezierCurve: lib.easeOutQuint
        }
      }
      Behavior on scale {
        NumberAnimation {
          duration: lib.shown ? lib.enterMs : lib.exitMs
          easing.type: Easing.BezierSpline
          easing.bezierCurve: lib.shown ? lib.easeOutExpo : lib.easeOutQuint
        }
      }

    RectangularShadow {
      anchors.fill: card
      radius: card.radius
      blur: 32
      offset: Qt.vector2d(0, 6)
      color: Theme.shadow
    }

    Rectangle {
      id: card
      anchors.fill: parent
      color: Theme.panelBackground
      radius: lib.cardRadius
      border.color: Theme.panelBorder
      border.width: 1

      // Swallows clicks so they do not fall through to the backdrop and close.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: lib.menu = null
      }

      Rectangle {
        id: searchBox
        anchors.top: parent.top
        anchors.topMargin: lib.pad
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(360, parent.width - lib.pad * 2)
        height: lib.searchHeight
        radius: Theme.fit(lib.innerRadius, height)
        color: Qt.rgba(Theme.foreground.r, Theme.foreground.g, Theme.foreground.b, 0.07)
        border.width: 1
        border.color: search.activeFocus ? Theme.accent : Theme.panelBorder

        Text {
          anchors.fill: search
          verticalAlignment: Text.AlignVCenter
          text: lib.filesMode ? "Search files…" : "Search apps and files…"
          color: Theme.foreground
          opacity: 0.45
          font.pixelSize: 14
          visible: !search.text
        }

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: 14
          anchors.rightMargin: 14
          verticalAlignment: TextInput.AlignVCenter
          color: Theme.foreground
          selectionColor: Theme.accent
          font.pixelSize: 14
          clip: true
          onTextChanged: { lib.query = text; lib.selected = 0; lib.keyNav = true; lib.hoverIndex = -1; lib.rebuild(); lib.requestFiles() }
          Keys.onPressed: event => lib.handleKey(event)
        }
      }

      // One app cell, shared by the grid and the search results' app row.
      Component {
        id: appCell
          Item {
            id: cell
            required property var modelData
            required property int index
            readonly property bool isSelected: index === lib.hoverIndex
              || (lib.keyNav && lib.hoverIndex === -1 && index === lib.selected)
            property point pressPoint
            property bool moved: false

            width: lib.cellWidth
            height: lib.cellHeight
            opacity: lib.dragEntry === modelData ? 0.35 : 1

            Rectangle {
              anchors.fill: parent
              anchors.margins: lib.gutter
              radius: Theme.fit(lib.innerRadius, height)
              color: Theme.foreground
              opacity: cellMouse.pressed && !cell.moved ? 0.24 : (cell.isSelected ? 0.15 : 0)
              Behavior on opacity { NumberAnimation { duration: 90 } }
            }

            Image {
              id: icon
              anchors.horizontalCenter: parent.horizontalCenter
              y: 14
              width: lib.iconSize
              height: lib.iconSize
              sourceSize: Qt.size(lib.iconSize * 2, lib.iconSize * 2)
              source: lib.iconFor(cell.modelData.icon)
              fillMode: Image.PreserveAspectFit
              smooth: true
              mipmap: true
            }

            Text {
              anchors.top: icon.bottom
              anchors.topMargin: 8
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width - 16
              text: cell.modelData.name
              textFormat: Text.PlainText
              color: Theme.foreground
              font.pixelSize: 12
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            MouseArea {
              id: cellMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              preventStealing: true   // a dragging press is not a grid scroll
              function claimHover() {
                lib.hoverIndex = cell.index
                lib.selected = cell.index     // Enter still launches what is under the pointer
                lib.keyNav = false
              }
              onContainsMouseChanged: {
                if (containsMouse && !lib.dragEntry) claimHover()
                else if (!containsMouse && lib.hoverIndex === cell.index) lib.hoverIndex = -1
              }
              onPressed: mouse => { cell.moved = false; cell.pressPoint = Qt.point(mouse.x, mouse.y) }
              onPositionChanged: mouse => {
                // Pointer moved again after the keyboard took the highlight.
                if (!pressedButtons && !lib.dragEntry && lib.hoverIndex !== cell.index) claimHover()
                if (!(pressedButtons & Qt.LeftButton)) return
                if (!cell.moved && Math.hypot(mouse.x - cell.pressPoint.x, mouse.y - cell.pressPoint.y) > 6) cell.moved = true
                if (cell.moved) lib.dragMove(cell.modelData, mapToItem(lib.contentItem, mouse.x, mouse.y))
              }
              onReleased: if (lib.dragEntry) lib.dragDrop()
              onCanceled: { lib.dragEntry = null; lib.dropTarget = -1 }
              onClicked: mouse => {
                if (cell.moved) return
                if (mouse.button === Qt.RightButton)
                  lib.openMenu({ kind: "app", entry: cell.modelData }, mapToItem(lib.contentItem, mouse.x, mouse.y))
                else
                  lib.launch(cell.modelData)
              }
            }
          }
      }

      GridView {
        id: grid
        anchors.top: searchBox.bottom
        anchors.topMargin: lib.pad - lib.gutter
        anchors.horizontalCenter: parent.horizontalCenter
        width: lib.columns * lib.cellWidth
        height: lib.rows * lib.cellHeight
        cellWidth: lib.cellWidth
        cellHeight: lib.cellHeight
        model: lib.apps
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: !lib.dragEntry

        delegate: appCell
        visible: !lib.resultsMode

        Text {
          anchors.centerIn: parent
          visible: lib.apps.length === 0
          text: lib.query ? "No apps match “" + lib.query + "”"
            : "Drag apps onto this group to add them"
          color: Theme.foreground
          opacity: 0.6
          font.pixelSize: 15
        }
      }

      // Search results: best apps as one row of cells, files as a list below.
      Item {
        id: results
        anchors.fill: grid
        visible: lib.resultsMode
        clip: true

        Row {
          id: appsRow
          visible: lib.appsShown > 0
          height: visible ? lib.cellHeight : 0
          Repeater {
            model: lib.appsShown > 0 ? lib.apps.slice(0, lib.appsShown) : []
            delegate: appCell
          }
        }

        Text {
          id: filesHeader
          anchors.top: appsRow.bottom
          x: lib.gutter + 10
          height: visible ? 28 : 0
          visible: lib.trimmed.length >= 2
          verticalAlignment: Text.AlignVCenter
          text: lib.files.length ? "Files"
            : lib.filesPending ? "Searching files…" : "No files match"
          color: Theme.foreground
          opacity: 0.55
          font.pixelSize: 12
          font.weight: Font.DemiBold
        }

        ListView {
          id: fileList
          anchors.top: filesHeader.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          model: lib.files
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          delegate: Item {
            id: frow
            required property var modelData
            required property int index
            readonly property int flat: lib.appsShown + index
            readonly property bool isSelected: flat === lib.hoverIndex
              || (lib.keyNav && lib.hoverIndex === -1 && flat === lib.selected)

            width: ListView.view.width
            height: 46

            Rectangle {
              anchors.fill: parent
              anchors.leftMargin: lib.gutter
              anchors.rightMargin: lib.gutter
              anchors.topMargin: 1
              anchors.bottomMargin: 1
              radius: Theme.fit(lib.innerRadius, height)
              color: Theme.foreground
              opacity: frowMouse.pressed ? 0.24 : (frow.isSelected ? 0.15 : 0)
              Behavior on opacity { NumberAnimation { duration: 90 } }
            }

            Image {
              id: ficon
              x: lib.gutter + 10
              anchors.verticalCenter: parent.verticalCenter
              width: 28
              height: 28
              sourceSize: Qt.size(56, 56)
              source: lib.fileIcon(frow.modelData.mime)
              asynchronous: true
              mipmap: true
            }

            Column {
              anchors.left: ficon.right
              anchors.leftMargin: 10
              anchors.right: kindLabel.left
              anchors.rightMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              spacing: 1
              Text {
                width: parent.width
                text: lib.highlightName(frow.modelData.name, frow.modelData.hl)
                textFormat: Text.StyledText
                color: Theme.foreground
                font.pixelSize: 13
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: frow.modelData.dir
                textFormat: Text.PlainText
                color: Theme.foreground
                opacity: 0.55
                font.pixelSize: 11
                elide: Text.ElideMiddle
              }
            }

            Text {
              id: kindLabel
              anchors.right: parent.right
              anchors.rightMargin: lib.gutter + 12
              anchors.verticalCenter: parent.verticalCenter
              text: frow.modelData.kind === "content" ? "match in text" : ""
              color: Theme.foreground
              opacity: 0.45
              font.pixelSize: 11
            }

            MouseArea {
              id: frowMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              function claimHover() {
                lib.hoverIndex = frow.flat
                lib.selected = frow.flat
                lib.keyNav = false
              }
              onContainsMouseChanged: {
                if (containsMouse) claimHover()
                else if (lib.hoverIndex === frow.flat) lib.hoverIndex = -1
              }
              onPositionChanged: if (lib.hoverIndex !== frow.flat) claimHover()
              onClicked: mouse => {
                if (mouse.button === Qt.RightButton)
                  lib.openMenu({ kind: "file", file: frow.modelData }, mapToItem(lib.contentItem, mouse.x, mouse.y))
                else
                  lib.openFile(frow.modelData)
              }
            }
          }
        }

        Column {
          anchors.centerIn: parent
          spacing: 6
          visible: lib.filesMode && lib.trimmed === ""
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Search your files by name or content"
            color: Theme.foreground
            opacity: 0.6
            font.pixelSize: 15
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Documents · Downloads · Desktop · Pictures · Music · Videos · Nextcloud"
            color: Theme.foreground
            opacity: 0.4
            font.pixelSize: 12
          }
        }

        Text {
          anchors.centerIn: parent
          visible: !lib.filesMode && lib.trimmed.length === 1 && lib.appsShown === 0
          text: "Keep typing to search files"
          color: Theme.foreground
          opacity: 0.6
          font.pixelSize: 15
        }
      }

      Rectangle {
        id: divider
        anchors.top: grid.bottom
        anchors.topMargin: lib.pad - lib.gutter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: lib.pad
        anchors.rightMargin: lib.pad
        height: 1
        color: Theme.panelBorder
      }

      Flickable {
        id: groupBar
        anchors.top: divider.bottom
        anchors.topMargin: lib.pad
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(groupRow.width, lib.innerWidth)
        height: lib.tileHeight
        contentWidth: groupRow.width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: !lib.dragEntry

        Row {
          id: groupRow
          spacing: lib.tileSpacing

          GroupTile {
            host: lib
            label: "Home"
            active: lib.groupIndex === -1 && !lib.filesMode
            GridGlyph { anchors.centerIn: parent; size: 26; color: lib.groupIndex === -1 && !lib.filesMode ? Theme.accent : Theme.foreground }
            onTapped: { lib.filesMode = false; lib.groupIndex = -1; lib.selected = 0; search.text = ""; lib.rebuild() }
          }

          GroupTile {
            host: lib
            label: "Files"
            active: lib.filesMode
            Image {
              anchors.centerIn: parent
              width: 32
              height: 32
              sourceSize: Qt.size(64, 64)
              source: Quickshell.iconPath("folder", true) || lib.iconFor("")
              mipmap: true
            }
            onTapped: lib.setFilesMode(true)
          }

          Repeater {
            id: groupRepeater
            model: lib.groups

            GroupTile {
            host: lib
              id: tile
              required property var modelData
              required property int index
              label: modelData.name
              active: lib.groupIndex === index && !lib.filesMode
              dropping: lib.dropTarget === index
              editing: lib.renaming === index
              groupIndex: index

              // 2x2 peek at the group's first apps, like COSMIC's folders.
              Grid {
                anchors.centerIn: parent
                columns: 2
                spacing: 3
                Repeater {
                  model: lib.previews[tile.index] || []
                  Image {
                    required property var modelData
                    width: 15; height: 15
                    sourceSize: Qt.size(32, 32)
                    source: lib.iconFor(modelData)
                    mipmap: true
                  }
                }
              }
              Rectangle {
                anchors.centerIn: parent
                visible: !(lib.previews[tile.index] || []).length
                width: 33; height: 33
                radius: Theme.fit(Theme.radiusSmall, height)
                color: "transparent"
                border.width: 1
                border.color: Theme.panelBorder
              }

              onTapped: { lib.filesMode = false; lib.groupIndex = index; lib.selected = 0; search.text = ""; lib.rebuild() }
              onMenuRequested: point => lib.openMenu({ kind: "group", index: index }, point)
            }
          }

          GroupTile {
            host: lib
            id: newTile
            label: "New group"
            dropping: lib.dropTarget === lib.groups.length
            Text {
              anchors.centerIn: parent
              text: "+"
              color: Theme.foreground
              font.pixelSize: 26
              font.weight: Font.Light
            }
            onTapped: lib.newGroup("")
          }
        }
      }
    }

    }

    // The app under the pointer while it is dragged toward a group.
    Image {
      visible: !!lib.dragEntry
      x: lib.dragPoint.x - width / 2
      y: lib.dragPoint.y - height / 2
      width: lib.iconSize
      height: lib.iconSize
      sourceSize: Qt.size(lib.iconSize * 2, lib.iconSize * 2)
      source: lib.dragEntry ? lib.iconFor(lib.dragEntry.icon) : ""
      mipmap: true
    }

    Rectangle {
      id: menuCard
      visible: !!lib.menu
      x: lib.menu ? Math.min(lib.menu.x, stage.width - width - 8) : 0
      y: lib.menu ? Math.min(lib.menu.y, stage.height - height - 8) : 0
      width: Math.max(170, menuColumn.implicitWidth) + 12
      height: menuColumn.implicitHeight + 12
      color: Theme.background
      radius: Theme.fit(Theme.radiusMedium, height)
      border.color: Theme.panelBorder
      border.width: 1

      MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

      Column {
        id: menuColumn
        x: 6
        y: 6
        width: parent.width - 12
        Repeater {
          model: lib.menuItems
          Rectangle {
            required property var modelData
            width: menuColumn.width
            implicitWidth: rowLabel.implicitWidth + 16
            height: 28
            radius: Theme.inner(menuCard.radius, 6, height)
            color: rowHover.hovered
              ? (modelData.destructive ? Theme.urgent : Qt.rgba(Theme.foreground.r, Theme.foreground.g, Theme.foreground.b, 0.12))
              : "transparent"
            HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: lib.runMenu(parent.modelData) }
            Text {
              id: rowLabel
              anchors.verticalCenter: parent.verticalCenter
              x: 8
              text: parent.modelData.label
              color: parent.modelData.destructive && rowHover.hovered ? Theme.background : Theme.foreground
              font.pixelSize: 13
            }
          }
        }
      }
    }
  }

  component GroupTile: Rectangle {
    id: gt
    required property var host
    property string label: ""
    property bool active: false
    property bool dropping: false
    property bool editing: false
    property int groupIndex: -1
    default property alias content: glyph.data
    signal tapped()
    signal menuRequested(point point)

    width: host.tileWidth
    height: host.tileHeight
    radius: host.tileRadius
    color: active ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, tileHover.hovered ? 0.28 : 0.18)
      : Qt.rgba(Theme.foreground.r, Theme.foreground.g, Theme.foreground.b,
                tileTap.pressed ? 0.24 : (tileHover.hovered ? 0.15 : 0))
    Behavior on color { ColorAnimation { duration: 90 } }
    border.width: dropping ? 2 : 0
    border.color: Theme.accent

    HoverHandler { id: tileHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { id: tileTap; acceptedButtons: Qt.LeftButton; onTapped: gt.tapped() }
    TapHandler {
      acceptedButtons: Qt.RightButton
      onTapped: (ev, button) => {
        if (gt.groupIndex >= 0) gt.menuRequested(gt.mapToItem(host.contentItem, ev.position.x, ev.position.y))
      }
    }

    Item {
      id: glyph
      anchors.horizontalCenter: parent.horizontalCenter
      y: 10
      width: 36
      height: 36
    }

    Text {
      visible: !gt.editing
      anchors.top: glyph.bottom
      anchors.topMargin: 8
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width - 10
      text: gt.label
      textFormat: Text.PlainText
      color: gt.active ? Theme.accent : Theme.foreground
      font.pixelSize: 12
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }

    TextInput {
      id: renameField
      visible: gt.editing
      anchors.top: glyph.bottom
      anchors.topMargin: 8
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width - 10
      color: Theme.foreground
      selectionColor: Theme.accent
      font.pixelSize: 12
      horizontalAlignment: TextInput.AlignHCenter
      clip: true
      function begin() { text = gt.label; selectAll(); forceActiveFocus() }
      onVisibleChanged: if (visible) begin()
      Component.onCompleted: if (visible) Qt.callLater(begin)
      onAccepted: host.renameGroup(gt.groupIndex, text)
      onActiveFocusChanged: if (!activeFocus && gt.editing) host.renameGroup(gt.groupIndex, text)
      Keys.onEscapePressed: { host.renaming = -1; host.focusSearch() }
      Rectangle {
        anchors.fill: parent
        anchors.margins: -3
        z: -1
        radius: 4
        color: "transparent"
        border.width: 1
        border.color: Theme.accent
      }
    }
  }
}
