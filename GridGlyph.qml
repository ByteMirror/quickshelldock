import QtQuick
import qs.config

// 3x3 dot grid: the app-library mark, drawn rather than looked up so it never
// depends on what the icon theme ships.
Grid {
  property real size: 20
  property color color: Theme.foreground
  columns: 3
  spacing: size / 6
  Repeater {
    model: 9
    Rectangle {
      width: (parent.width - parent.spacing * 2) / 3
      height: width
      radius: width / 3
      color: parent.color
    }
  }
  width: size
  height: size
}
