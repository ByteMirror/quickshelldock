import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import qs.config

ShellRoot {
  // Always-show vs hover-only, flipped by `qs -c quickshelldock ipc call dock
  // toggleAutohide` (SUPER+ALT+D, macOS Cmd+Option+D). Survives restarts via this file.
  FileView {
    id: alwaysShowFile
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
      + "/quickshelldock/always-show"
    blockLoading: true
    printErrors: false
    Component.onCompleted: DockApps.alwaysShow = text().trim() === "1"
  }

  IpcHandler {
    target: "dock"
    function toggleAutohide(): void {
      DockApps.alwaysShow = !DockApps.alwaysShow
      alwaysShowFile.setText(DockApps.alwaysShow ? "1\n" : "0\n")
    }
  }

  Variants {
    id: docks
    model: Quickshell.screens

    DockPanel {
      required property var modelData
      screen: modelData
    }
  }

  // `qs -c quickshelldock ipc call applibrary toggle` opens the app library
  // on the focused monitor. One handler for all docks, so no duplicate target.
  IpcHandler {
    target: "applibrary"
    function toggle(): void {
      const name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      const dock = docks.instances.find(d => d.screen && d.screen.name === name) || docks.instances[0]
      if (dock) dock.appLibrary.toggle()
    }
  }
}
