import QtQuick
import Quickshell.Wayland
import "../../shared"

// Miniature of one workspace: the wallpaper with its windows drawn where they
// really sit on the monitor. Used by the desktop cards and the drag ghost.
Rounded {
  id: face

  property var viewer: null
  property int wsId: -1
  // Logical monitor geometry { x, y, w, h } the window coordinates are in.
  property var geom: null

  radius: 10

  readonly property real sx: width / Math.max(1, geom ? geom.w : 1920)
  readonly property real sy: height / Math.max(1, geom ? geom.h : 1080)

  Image {
    anchors.fill: parent
    source: face.viewer ? face.viewer.wallpaper : ""
    fillMode: Image.PreserveAspectCrop
    sourceSize.width: 480
    asynchronous: true
    smooth: true
  }

  Repeater {
    model: face.viewer && face.wsId > 0 ? face.viewer.winsOf(face.wsId) : []

    delegate: Item {
      id: mini
      required property string modelData

      readonly property var client: face.viewer ? face.viewer.clientByAddr[modelData] : null
      // Each checks what it reads itself: a shared "placed" flag could lag a
      // frame behind when the ghost's workspace goes away at a drag's end.
      x: client && client.at && face.geom ? (client.at[0] - face.geom.x) * face.sx : 6
      y: client && client.at && face.geom ? (client.at[1] - face.geom.y) * face.sy : 6
      width: client && client.size ? Math.max(6, client.size[0] * face.sx) : face.width * 0.4
      height: client && client.size ? Math.max(6, client.size[1] * face.sy) : face.height * 0.4
      z: client && client.floating ? 2 : 1

      Rectangle {
        anchors.fill: parent
        radius: 3
        color: Qt.rgba(0, 0, 0, 0.35)
      }

      ScreencopyView {
        id: shot
        anchors.fill: parent
        captureSource: face.viewer && face.viewer.opened ? face.viewer.waylandOf(mini.modelData) : null
        live: false
      }

      AppIcon {
        anchors.centerIn: parent
        visible: !shot.hasContent
        icons: face.viewer ? face.viewer.icons : null
        appId: mini.client ? String(mini.client.class || "") : ""
        size: Math.max(8, Math.min(parent.width, parent.height) * 0.5)
      }
    }
  }
}
