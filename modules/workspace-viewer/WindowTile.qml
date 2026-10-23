import QtQuick
import QtQuick.Effects
import Quickshell.Wayland
import qs.Commons
import "../../shared"

// One window in the exposé. Starts at the window's real place on screen and
// glides into the grid when the overview opens (and back when it closes), so
// opening feels like the desktop zooming out.
Item {
  id: tile

  property var viewer: null
  property string addr: ""
  // Grid slot and real on-screen rect, both in the exposé's coordinates.
  // realRect is null when the window isn't visible on this screen.
  property var targetRect: null
  property var realRect: null

  readonly property var client: viewer ? viewer.clientByAddr[addr] : null
  readonly property string appId: client ? String(client.class || "") : ""
  readonly property bool atReal: !!realRect && !(viewer && viewer.shown)
  readonly property bool isDragged: viewer ? viewer.dragKind === "win" && viewer.dragAddr === addr : false
  readonly property bool dragging: viewer ? viewer.dragKind !== "" : false
  readonly property bool hovered: (mouse.containsMouse || closeMouse.containsMouse) && !dragging
  readonly property var rect: atReal ? realRect : (targetRect || { x: 0, y: 0, w: 0, h: 0 })

  x: rect.x
  y: rect.y
  width: rect.w
  height: rect.h
  z: hovered ? 10 : 1

  Behavior on x { NumberAnimation { duration: 360; easing.type: Easing.OutQuint } }
  Behavior on y { NumberAnimation { duration: 360; easing.type: Easing.OutQuint } }
  Behavior on width { NumberAnimation { duration: 360; easing.type: Easing.OutQuint } }
  Behavior on height { NumberAnimation { duration: 360; easing.type: Easing.OutQuint } }

  // Windows that don't start from a real rect fade/scale in instead.
  property real appear: 0
  Component.onCompleted: appear = 1
  Behavior on appear { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

  opacity: isDragged ? 0 : (realRect ? 1 : (viewer && viewer.shown ? appear : 0))
  Behavior on opacity { NumberAnimation { duration: 180 } }
  scale: (hovered ? 1.02 : 1) * (realRect ? 1 : 0.94 + 0.06 * appear)
  Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

  RectangularShadow {
    anchors.fill: parent
    radius: 12
    blur: 34
    offset.y: 12
    color: Qt.rgba(0, 0, 0, 0.5)
    opacity: tile.atReal ? 0 : 1
    Behavior on opacity { NumberAnimation { duration: 300 } }
  }

  Rounded {
    id: face
    anchors.fill: parent
    radius: 12

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0.08, 0.08, 0.09, 0.9)
    }

    ScreencopyView {
      id: shot
      anchors.fill: parent
      captureSource: tile.viewer && tile.viewer.opened ? tile.viewer.waylandOf(tile.addr) : null
      live: tile.viewer ? tile.viewer.opened : false
    }

    AppIcon {
      anchors.centerIn: parent
      visible: !shot.hasContent
      icons: tile.viewer ? tile.viewer.icons : null
      appId: tile.appId
      address: tile.client ? String(tile.client.address || "") : ""
      size: Math.max(24, Math.min(parent.width, parent.height) * 0.3)
    }
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: -4
    radius: 16
    color: "transparent"
    border.width: 3
    border.color: Qt.rgba(1, 1, 1, 0.92)
    opacity: tile.hovered ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 140 } }
  }

  // App icon + title under the window on hover.
  Rectangle {
    anchors.top: parent.bottom
    anchors.topMargin: 12
    anchors.horizontalCenter: parent.horizontalCenter
    height: 30
    width: Math.min(captionRow.implicitWidth + 24, Math.max(220, tile.width * 1.1))
    radius: 15
    color: Qt.rgba(0.1, 0.1, 0.11, 0.82)
    border.color: Qt.rgba(1, 1, 1, 0.12)
    border.width: 1
    opacity: tile.hovered ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 140 } }

    Row {
      id: captionRow
      anchors.centerIn: parent
      spacing: 8
      width: Math.min(implicitWidth, parent.width - 24)

      AppIcon {
        anchors.verticalCenter: parent.verticalCenter
        icons: tile.viewer ? tile.viewer.icons : null
        appId: tile.appId
        address: tile.client ? String(tile.client.address || "") : ""
        size: 18
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, captionRow.parent.width - 24 - 26)
        elide: Text.ElideRight
        text: tile.client ? String(tile.client.title || "") : ""
        color: "white"
        font.family: tile.viewer ? tile.viewer.uiFont : ""
        font.pixelSize: 13
        font.weight: Font.Medium
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    preventStealing: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: tile.isDragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    property point pressAt

    onPressed: function(m) { pressAt = Qt.point(m.x, m.y) }
    onPositionChanged: function(m) {
      if (!(pressedButtons & Qt.LeftButton) || !tile.viewer) return
      var p = mapToItem(tile.viewer.overlayContent, m.x, m.y)
      if (tile.viewer.dragKind === "" && Math.abs(m.x - pressAt.x) + Math.abs(m.y - pressAt.y) > 6) {
        tile.viewer.dragStart("win", {
          addr: tile.addr,
          wsId: tile.client && tile.client.workspace ? tile.client.workspace.id : -1,
          w: width, h: height,
          grabX: pressAt.x / width, grabY: pressAt.y / height
        }, p)
      }
      if (tile.viewer.dragKind === "win") tile.viewer.dragMove(p)
    }
    onReleased: function(m) {
      if (!tile.viewer) return
      if (tile.viewer.dragKind !== "") { tile.viewer.dragEnd(); return }
      if (!containsMouse) return
      if (m.button === Qt.MiddleButton) tile.viewer.closeWindow(tile.addr)
      else tile.viewer.focusWindow(tile.addr)
    }
    onCanceled: if (tile.viewer && tile.isDragged) tile.viewer.dragCancel()
  }

  // Close button, top-left.
  Rectangle {
    x: -10
    y: -10
    width: 26
    height: 26
    radius: 13
    color: closeMouse.containsMouse ? "#ff5f57" : Qt.rgba(0.13, 0.13, 0.14, 0.94)
    border.color: Qt.rgba(1, 1, 1, 0.22)
    border.width: 1
    opacity: tile.hovered ? 1 : 0
    visible: opacity > 0.01
    scale: 0.7 + 0.3 * opacity
    Behavior on opacity { NumberAnimation { duration: 140 } }
    Behavior on color { ColorAnimation { duration: 120 } }

    Text {
      anchors.centerIn: parent
      text: "✕"
      color: "white"
      font.family: tile.viewer ? tile.viewer.uiFont : ""
      font.pixelSize: 12
      font.weight: Font.DemiBold
    }

    MouseArea {
      id: closeMouse
      anchors.fill: parent
      anchors.margins: -4
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (tile.viewer) tile.viewer.closeWindow(tile.addr)
    }
  }
}
