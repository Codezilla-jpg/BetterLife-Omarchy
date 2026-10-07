import QtQuick
import QtQuick.Effects
import qs.Commons

// One desktop in the Spaces bar: miniature, caption, hover close button.
// Click switches to it; dragging it reorders, moves it to the other display,
// swaps it with a desktop there, or drops it in the trash.
Item {
  id: card

  property var viewer: null
  // The workspace id it has now. While a move is going out it may already
  // stand where it's headed, under the id it will get there (`slot`).
  property int wsId: -1
  property var row: null
  property real faceH: 100

  readonly property int slot: viewer ? viewer.slotOf(wsId) : wsId
  readonly property bool dragging: viewer ? viewer.dragKind !== "" : false
  readonly property bool isDragged: viewer ? viewer.dragKind === "ws" && viewer.dragWsId === wsId : false
  readonly property bool isSelected: viewer ? viewer.selectedWsId === slot : false
  readonly property bool isShownOnDisplay: viewer ? viewer.activeOn(viewer.monitorOf(wsId)) === wsId : false
  readonly property bool isFocused: viewer ? viewer.focusedWsId === wsId : false
  readonly property bool dropInto: viewer ? viewer.dropKind === "into" && viewer.dropWsId === wsId : false
  readonly property bool dropSwap: viewer ? viewer.dropKind === "swap" && viewer.dropWsId === wsId : false
  readonly property bool deleteArmed: viewer ? viewer.pendingDelete === wsId : false
  readonly property bool hovered: mouse.containsMouse || closeMouse.containsMouse

  // No slide-in from x = 0 when a card first shows up; only animate moves.
  property bool animateX: false
  Behavior on x {
    enabled: card.animateX && !(card.viewer && card.viewer.noAnim)
    NumberAnimation { duration: 280; easing.type: Easing.OutCubic }
  }
  Component.onCompleted: Qt.callLater(function() { card.animateX = true })
  onVisibleChanged: {
    card.animateX = false
    if (visible) Qt.callLater(function() { card.animateX = true })
  }

  // The drag ghost stands in for it while it's being dragged. Stays
  // `visible` so its MouseArea keeps the pointer grab.
  opacity: isDragged ? 0 : 1

  Item {
    id: faceBox
    width: card.width
    height: card.faceH

    scale: card.dropInto || card.dropSwap ? 1.08
      : (card.hovered && !card.dragging ? 1.035 : 1)
    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

    RectangularShadow {
      anchors.fill: parent
      radius: 10
      blur: 22
      offset.y: 6
      color: Qt.rgba(0, 0, 0, card.hovered ? 0.55 : 0.4)
    }

    SpaceFace {
      anchors.fill: parent
      viewer: card.viewer
      wsId: card.wsId
      geom: card.row ? card.row.geom : null
      radius: 10
    }

    // Selection / drop / delete ring.
    Rectangle {
      anchors.fill: parent
      anchors.margins: -4
      radius: 14
      color: "transparent"
      border.width: 3
      border.color: card.deleteArmed ? "#ff5f57"
        : (card.dropInto || card.dropSwap ? Color.accent : Qt.rgba(1, 1, 1, 0.92))
      opacity: card.isSelected || card.dropInto || card.dropSwap || card.deleteArmed ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    // "Swap" badge while another display's desktop hovers over this one.
    Rectangle {
      anchors.centerIn: parent
      width: 44
      height: 44
      radius: 22
      color: Color.accent
      opacity: card.dropSwap ? 0.95 : 0
      scale: card.dropSwap ? 1 : 0.6
      Behavior on opacity { NumberAnimation { duration: 140 } }
      Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
      Text {
        anchors.centerIn: parent
        text: "⇄"
        color: Color.background
        font.family: card.viewer ? card.viewer.uiFont : ""
        font.pixelSize: 22
        font.weight: Font.DemiBold
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      preventStealing: true
      cursorShape: card.isDragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
      property point pressAt

      onContainsMouseChanged: {
        if (!card.viewer) return
        if (containsMouse) card.viewer.hoverSelect(card.slot)
        else card.viewer.hoverCancel(card.slot)
      }
      onPressed: function(m) { pressAt = Qt.point(m.x, m.y) }
      onPositionChanged: function(m) {
        if (!pressed || !card.viewer) return
        var p = mapToItem(card.viewer.overlayContent, m.x, m.y)
        if (card.viewer.dragKind === "" && Math.abs(m.x - pressAt.x) + Math.abs(m.y - pressAt.y) > 6) {
          card.viewer.dragStart("ws", {
            wsId: card.wsId,
            w: width, h: height,
            grabX: pressAt.x / width, grabY: pressAt.y / height
          }, p)
        }
        if (card.viewer.dragKind === "ws") card.viewer.dragMove(p)
      }
      onReleased: function(m) {
        if (!card.viewer) return
        if (card.viewer.dragKind !== "") { card.viewer.dragEnd(); return }
        if (!containsMouse) return
        if (card.viewer.pendingDelete !== -1) { card.viewer.pendingDelete = -1; return }
        card.viewer.focusWorkspace(card.slot)
      }
      onCanceled: if (card.viewer && card.isDragged) card.viewer.dragCancel()
    }

    // Close button, top-left like on macOS. First click arms it.
    Rectangle {
      id: closeBtn
      x: -9
      y: -9
      height: 24
      width: card.deleteArmed ? closeLabel.implicitWidth + 22 : 24
      radius: 12
      color: card.deleteArmed || closeMouse.containsMouse ? "#ff5f57" : Qt.rgba(0.13, 0.13, 0.14, 0.94)
      border.color: Qt.rgba(1, 1, 1, 0.22)
      border.width: 1
      opacity: (card.hovered && !card.dragging) || card.deleteArmed ? 1 : 0
      visible: opacity > 0.01
      scale: opacity
      Behavior on opacity { NumberAnimation { duration: 140 } }
      Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 120 } }

      Text {
        id: closeLabel
        anchors.centerIn: parent
        text: card.deleteArmed ? "Schließen" : "✕"
        color: "white"
        font.family: card.viewer ? card.viewer.uiFont : ""
        font.pixelSize: card.deleteArmed ? 12 : 11
        font.weight: Font.DemiBold
      }

      MouseArea {
        id: closeMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (card.viewer) card.viewer.requestDelete(card.wsId)
      }
    }
  }

  Text {
    anchors.top: faceBox.bottom
    anchors.topMargin: 9
    anchors.horizontalCenter: faceBox.horizontalCenter
    width: card.width + 20
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
    text: card.viewer ? "Schreibtisch " + card.viewer.displayNumber(card.slot) : ""
    color: Qt.rgba(1, 1, 1, card.isShownOnDisplay || card.isSelected ? 0.95 : 0.62)
    font.family: card.viewer ? card.viewer.uiFont : ""
    font.pixelSize: 12
    font.weight: card.isFocused ? Font.DemiBold : Font.Medium
  }
}
