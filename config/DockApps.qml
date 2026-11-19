pragma Singleton
import QtQuick

QtObject {
  id: config

  property bool showOnFloating: true

  // Only reveal on hover at the bottom edge; never stay up on its own
  // because a workspace is empty or only has floating windows.
  property bool hoverOnly: false

  // Runtime override, toggled over IPC (`ipc call dock toggleAutohide`) and
  // persisted by shell.qml: the dock stays up everywhere and reserves its
  // strip of the screen, like macOS with "automatically hide" switched off.
  property bool alwaysShow: false

  // Show apps that are running but not on the dock, to the right of a
  // separator, so every open window is reachable from the dock.
  property bool showRunningApps: true

  // Window classes never shown as running apps: background helpers that keep
  // a window mapped (an overlay, a status pill) but are never clicked.
  property var ignoreApps: []

  property var apps: [
    { name: "Firefox", icon: "firefox", cmd: "firefox", order: 0 },
    { name: "Kitty", icon: "kitty", cmd: "kitty", order: 1 },
    { name: "Dolphin", icon: "system-file-manager", cmd: "dolphin", order: 2 },
    { name: "Code", icon: "code", cmd: "code", order: 3 },
  ]

  Component.onCompleted: {
    var comp = Qt.createComponent("UserConfig.qml")
    if (comp.status === Component.Ready) {
      var obj = comp.createObject(null)
      if (obj) {
        if (obj.showOnFloating !== undefined)
          config.showOnFloating = obj.showOnFloating
        if (obj.hoverOnly !== undefined)
          config.hoverOnly = obj.hoverOnly
        if (obj.showRunningApps !== undefined)
          config.showRunningApps = obj.showRunningApps
        if (obj.ignoreApps !== undefined)
          config.ignoreApps = obj.ignoreApps
        if (obj.apps !== undefined && obj.apps.length > 0)
          config.apps = obj.apps
        obj.destroy()
      }
    }
  }
}
