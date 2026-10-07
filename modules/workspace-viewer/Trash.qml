import QtQuick
import qs.Commons

// Drop target that closes whatever lands on it: a window, or every window
// of a desktop. Just the icon; it wakes up while something is being dragged
// and turns red once a drop would close.
Item {
  id: trash

  property var viewer: null
  property real size: 44

  readonly property bool dragging: viewer ? viewer.dragKind !== "" : false
  readonly property bool armed: viewer ? viewer.dropKind === "trash" : false

  width: size
  height: size

  // Nerd-font trash can (the UI font has no such glyph).
  Text {
    anchors.centerIn: parent
    text: trash.armed ? "󰩺" : "󰩹"
    color: trash.armed ? "#ff5f57" : Qt.rgba(1, 1, 1, trash.dragging ? 0.9 : 0.5)
    font.family: Style.font.family
    font.pixelSize: Math.round(trash.size * 0.7)
    scale: trash.armed ? 1.3 : (trash.dragging ? 1.1 : 1)
    rotation: trash.armed ? -8 : 0
    Behavior on color { ColorAnimation { duration: 160 } }
    Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
    Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
  }
}
