import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick

ShellRoot {
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
