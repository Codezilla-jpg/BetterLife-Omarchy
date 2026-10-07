import QtQuick
import qs.Commons

// The desktops of one display, left to right, with a "+" at the end.
// Cards are laid out by hand (not a ListView) so every move animates: a gap
// opens where a dragged desktop would land and the rest slide aside.
//
// Delegates come from the viewer's workspace model (one per id), so they
// survive every refresh; each card just hides when its workspace isn't on
// this display.
Item {
  id: group

  property var viewer: null
  property string monName: ""
  property real cardH: 120

  readonly property var geom: viewer ? viewer.monGeom(monName) : ({ x: 0, y: 0, w: 1920, h: 1080 })
  readonly property real cardW: Math.round(cardH * geom.w / Math.max(1, geom.h))
  readonly property real gap: 18
  readonly property real plusW: Math.round(cardH * 0.46)
  readonly property real stride: cardW + gap
  readonly property real headerH: 28
  readonly property real captionH: 30

  // Workspace ids, left to right.
  readonly property var wsList: viewer && viewer.opened ? viewer.workspacesOn(monName) : []
  readonly property int dragged: viewer && viewer.dragKind === "ws" ? viewer.dragWsId : -1
  // Layout without the desktop being dragged: it's "in the air".
  readonly property var layoutList: dragged > 0 ? wsList.filter(function(id) { return id !== dragged }) : wsList
  readonly property int gapIndex: viewer && viewer.dropKind === "insert" && viewer.dropMon === monName ? viewer.dropIndex : -1

  function slotX(i) { return i * stride + (gapIndex >= 0 && i >= gapIndex ? stride : 0) }

  width: layoutList.length * stride + plusW + (gapIndex >= 0 ? stride : 0)
  height: headerH + cardH + captionH
  Behavior on width { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

  // Where a drag at `pos` (overlay coordinates) would land in this display.
  // Uses the resting layout, not the animated one, so an opening gap can't
  // move the target out from under the pointer.
  function hitTest(pos, kind) {
    var p = group.mapFromItem(viewer.overlayContent, pos.x, pos.y)
    if (p.x < -gap * 1.5 || p.x > width + gap * 1.5 || p.y < headerH - 16 || p.y > headerH + cardH + captionH)
      return null
    var list = layoutList

    if (kind === "win") {
      for (var i = 0; i < list.length; i++) {
        var x0 = i * stride
        if (p.x >= x0 - gap / 2 && p.x <= x0 + cardW + gap / 2)
          return list[i] === viewer.dragWsId ? { kind: "none" } : { kind: "into", wsId: list[i] }
      }
      return { kind: "new" }
    }

    // A desktop from the other display, held over the middle of one here:
    // swap the two.
    var from = dragged > 0 ? viewer.monitorOf(dragged) : ""
    if (from !== "" && from !== monName) {
      for (var j = 0; j < list.length; j++) {
        var s0 = j * stride
        if (p.x >= s0 + cardW * 0.22 && p.x <= s0 + cardW * 0.78) return { kind: "swap", wsId: list[j] }
      }
    }

    var idx = 0
    for (var k = 0; k < list.length; k++) if (p.x > k * stride + cardW / 2) idx = k + 1
    return { kind: "insert", index: idx }
  }

  Text {
    x: 2
    height: group.headerH - 8
    verticalAlignment: Text.AlignVCenter
    text: group.viewer ? group.viewer.displayLabel(group.monName) : ""
    color: Qt.rgba(1, 1, 1, 0.55)
    font.family: group.viewer ? group.viewer.uiFont : ""
    font.pixelSize: 12
    font.weight: Font.DemiBold
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 0.8
  }

  Repeater {
    model: group.viewer ? group.viewer.wsModel : null

    delegate: SpaceCard {
      id: sc
      required property int wid

      readonly property int layoutIndex: group.layoutList.indexOf(wid)
      readonly property int restIndex: group.wsList.indexOf(wid)

      viewer: group.viewer
      wsId: wid
      row: group
      // Keyed on the resting list, which a drag doesn't change: the dragged
      // card must stay visible, or its MouseArea loses the pointer grab and
      // the drag is cancelled the moment it starts.
      visible: restIndex >= 0
      x: layoutIndex >= 0 ? group.slotX(layoutIndex) : Math.max(0, restIndex) * group.stride
      y: group.headerH
      width: group.cardW
      height: group.cardH + group.captionH
      faceH: group.cardH
    }
  }

  // "+": new empty desktop on this display. Windows dropped here get one too.
  Item {
    id: plus
    x: group.slotX(group.layoutList.length)
    y: group.headerH
    width: group.plusW
    height: group.cardH
    Behavior on x { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

    readonly property bool dropHere: group.viewer ? group.viewer.dropKind === "new" && group.viewer.dropMon === group.monName : false
    readonly property bool lit: plusMouse.containsMouse || dropHere

    scale: plusMouse.pressed ? 0.93 : (lit ? 1.06 : 1)
    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    Rectangle {
      anchors.fill: parent
      radius: 10
      color: plus.dropHere ? Qt.rgba(1, 1, 1, 0.2) : Qt.rgba(1, 1, 1, plus.lit ? 0.14 : 0.07)
      border.color: plus.dropHere ? Color.accent : Qt.rgba(1, 1, 1, 0.14)
      border.width: plus.dropHere ? 2 : 1
      Behavior on color { ColorAnimation { duration: 140 } }
    }

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -2
      text: "+"
      color: Qt.rgba(1, 1, 1, plus.lit ? 0.95 : 0.7)
      font.family: group.viewer ? group.viewer.uiFont : ""
      font.pixelSize: Math.round(group.cardH * 0.32)
      font.weight: Font.Light
    }

    MouseArea {
      id: plusMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(m) {
        if (!group.viewer) return
        group.viewer.notePointer(mapToItem(group.viewer.overlayContent, m.x, m.y))
        group.viewer.newDesktop(group.monName)
      }
    }
  }
}
