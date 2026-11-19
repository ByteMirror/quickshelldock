pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Mirrors the desktop's look into the dock, so it never drifts from the rest
// of the session:
//
//   colors    the active Omarchy theme's colors.toml
//   rounding  Hyprland's decoration:rounding — the same number omarchy-shell
//             reads into Style.cornerRadius for the bar and its panels
//   alpha     [bar] background-alpha from omarchy's shell.toml — the same
//             knob that makes the top bar translucent
//
// All three are watched, so a theme switch, an `omarchy display corner
// rounding`, or an edited shell.toml lands on the dock live, with no restart.
QtObject {
  id: theme

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy"
  readonly property string colorsPath: stateDir + "/current/theme/colors.toml"
  readonly property string themeNamePath: stateDir + "/current/theme.name"
  readonly property string roundingFlagPath: stateDir + "/toggles/hypr/corner-rounding.lua"
  readonly property string themeShellPath: stateDir + "/current/theme/shell.toml"
  readonly property string userShellPath: (Quickshell.env("XDG_CONFIG_HOME")
    || (Quickshell.env("HOME") + "/.config")) + "/omarchy/shell.toml"

  // ------------------------------------------------------------------ colors
  //
  // Defaults are the Catppuccin Mocha values the dock was drawn with, so it
  // still looks like itself on a machine with no Omarchy theme applied.
  property color background: "#1e1e2e"       // dock bar, context card
  property color surface: "#313244"          // hairline borders, row hover
  property color foreground: "#cdd6f4"       // labels, icon hover wash
  property color brightForeground: "#ffffff"
  property color accent: "#89b4fa"
  property color urgent: "#ea4335"           // unread badge

  // The running dot sits on the dock bar, so it has to separate from
  // `background` in every theme — a white dot vanished on light paper.
  // bright_foreground is the theme's highest-contrast ink and is what this
  // wants, but nothing obliges a theme to make it so; the accent, then plain
  // black or white, are the fallbacks when it does not carry enough contrast.
  readonly property color indicator: {
    if (contrastRatio(brightForeground, background) >= 3) return brightForeground
    if (contrastRatio(foreground, background) >= 3) return foreground
    if (contrastRatio(accent, background) >= 3) return accent
    return relativeLuminance(background) > 0.4 ? "#000000" : "#ffffff"
  }

  // WCAG relative luminance and contrast ratio. QML color channels are already
  // 0..1 floats, so there is no 8-bit round trip to undo first.
  function relativeLuminance(c) {
    function channel(v) {
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
  }

  function contrastRatio(a, b) {
    const la = relativeLuminance(a)
    const lb = relativeLuminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }

  function applyColors(text) {
    var map = {}
    var re = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/gm
    var m
    while ((m = re.exec(String(text || ""))) !== null)
      map[m[1]] = m[2]

    if (!map.background) return   // not a palette we understand; keep the last

    theme.background = map.background
    theme.foreground = map.foreground || theme.foreground
    theme.brightForeground = map.bright_foreground || map.foreground || theme.brightForeground
    theme.accent = map.accent || theme.accent
    theme.urgent = map.red || theme.urgent
    // lighter_background is the theme's "one step off the canvas" surface,
    // which is what the dock's border and row hover want. selection is the
    // closest stand-in when a theme omits it.
    theme.surface = map.lighter_background || map.selection || theme.surface
  }

  // ------------------------------------------------------------ translucency
  //
  // omarchy-shell composes its bar fill from `bar.background` and
  // `bar.background-alpha`; the dock takes the alpha from the same place so
  // one edit frosts both. Omarchy resolves shell.toml as theme-first with
  // ~/.config/omarchy/shell.toml overriding, and so does this: -1 means "the
  // file did not say", which is how a user 1.0 stays distinguishable from an
  // absent key.
  property real themeBackgroundAlpha: -1
  property real userBackgroundAlpha: -1
  readonly property real backgroundAlpha: {
    if (userBackgroundAlpha >= 0) return userBackgroundAlpha
    if (themeBackgroundAlpha >= 0) return themeBackgroundAlpha
    return 1
  }

  // A hairline that reads as a lit glass edge rather than a drawn frame. The
  // theme's own ink at low alpha lands right on dark themes and light ones
  // alike, where a flat `surface` border is a visible drawn box on one of them.
  readonly property color panelBorder: Qt.rgba(foreground.r, foreground.g,
                                               foreground.b, 0.18)

  // Cast shadows are the absence of light, so this stays black on light themes
  // too — tinting it with the palette is what makes a shadow read as a glow.
  readonly property color shadow: Qt.rgba(0, 0, 0, 0.35)

  // The dock bar's fill. Only surfaces that sit over the desktop use this —
  // chrome drawn *on* the dock (the unread badge and its border) keeps the
  // opaque `background`, or it would dissolve into whatever is behind it.
  readonly property color panelBackground: Qt.rgba(background.r, background.g,
                                                   background.b, backgroundAlpha)

  // Minimal TOML walk: the `background-alpha` under [bar], or -1 if absent.
  function barAlpha(text) {
    var lines = String(text || "").split("\n")
    var section = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line || line.charAt(0) === "#") continue
      var head = line.match(/^\[([A-Za-z0-9_-]+)\]/)
      if (head) { section = head[1]; continue }
      if (section !== "bar") continue
      var kv = line.match(/^background-alpha\s*=\s*(-?\d+(?:\.\d+)?)/)
      if (kv) return Math.max(0, Math.min(1, Number(kv[1])))
    }
    return -1
  }

  // ---------------------------------------------------------------- rounding
  //
  // The three radii are calibrated so rounding = 10 reproduces the values the
  // dock was originally drawn with (18 / 10 / 6). rounding = 0 squares
  // everything off, which is what Omarchy ships by default.
  property int rounding: 10
  readonly property int radiusLarge: Math.round(rounding * 1.8)
  readonly property int radiusMedium: rounding
  readonly property int radiusSmall: Math.round(rounding * 0.6)

  // Round a radius down so it can never exceed a box's own half-height, which
  // would otherwise turn a tall card into a lozenge at high rounding values.
  function fit(radius, box) {
    return Math.max(0, Math.min(radius, box / 2))
  }

  // The radius an inset box needs to stay concentric with the one around it.
  // A rounded box inset by an even margin only *looks* evenly inset when its
  // radius is the outer radius minus that margin; give it a larger radius and
  // the gap pinches shut at the corners while staying right along the flats.
  function inner(outerRadius, inset, box) {
    return fit(outerRadius - inset, box)
  }

  function applyRounding(raw) {
    try {
      var n = Number(JSON.parse(raw || "{}").int)
      if (isFinite(n) && n >= 0) theme.rounding = n
    } catch (e) {
      // Hyprland not answering — keep whatever we had.
    }
  }

  function refreshRounding() {
    if (!roundingProc.running) roundingProc.running = true
  }

  property Process roundingProc: Process {
    command: ["hyprctl", "getoption", "decoration:rounding", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: theme.applyRounding(text)
    }
  }

  // ----------------------------------------------------------------- watches

  property FileView colorsFile: FileView {
    path: theme.colorsPath
    printErrors: false
    watchChanges: true
    // reload() is async, so read the palette when the text lands, not on the
    // fileChanged tick — same rule as the dock's pins/order files.
    onFileChanged: reload()
    onTextChanged: theme.applyColors(text())
  }

  // Generated per theme, so it lives inside current/theme and is torn down on
  // a switch along with colors.toml — themeNameFile below reloads it.
  property FileView themeShellFile: FileView {
    path: theme.themeShellPath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onTextChanged: theme.themeBackgroundAlpha = theme.barAlpha(text())
    onLoadFailed: theme.themeBackgroundAlpha = -1
  }

  // Machine-level override; survives theme switches, so it is not reloaded on
  // one. This is where a hand-set alpha belongs.
  property FileView userShellFile: FileView {
    path: theme.userShellPath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onTextChanged: theme.userBackgroundAlpha = theme.barAlpha(text())
    onLoadFailed: theme.userBackgroundAlpha = -1
  }

  // A theme switch tears down and rebuilds current/theme, which can take the
  // colors.toml watch with it; theme.name is rewritten in place afterwards, so
  // it is the reliable "a theme just landed" signal.
  property FileView themeNameFile: FileView {
    path: theme.themeNamePath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onTextChanged: {
      theme.colorsFile.reload()
      theme.themeShellFile.reload()
      theme.refreshRounding()
    }
  }

  property FileView roundingFlagFile: FileView {
    path: theme.roundingFlagPath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    // Hyprland has to reload before the new value is readable, so ask it a
    // beat later rather than racing the compositor.
    onTextChanged: roundingSettle.restart()
    onLoadFailed: theme.refreshRounding()   // flag removed: back to the default
  }

  property Timer roundingSettle: Timer {
    interval: 250
    repeat: false
    onTriggered: theme.refreshRounding()
  }

  Component.onCompleted: {
    applyColors(colorsFile.text())
    themeBackgroundAlpha = barAlpha(themeShellFile.text())
    userBackgroundAlpha = barAlpha(userShellFile.text())
    refreshRounding()
  }
}
