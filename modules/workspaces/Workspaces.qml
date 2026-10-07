import QtQuick
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Only workspaces that are in use (have windows, or are focused) are shown.
// Slots for workspaces 1-10 always exist; unused ones collapse to zero size,
// so a workspace appearing/disappearing grows/shrinks in place with a fade.
// Labels are renumbered to their position among the shown workspaces, so
// closing workspace 3 out of 1,2,3,4 leaves the labels reading 1,2,3.
BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  readonly property var slotIds: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  function isShown(id) {
    var workspace = root.workspaceById(id)
    if (workspace !== null && workspace.toplevels.values.length > 0) return true

    return Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === id
  }

  // Position of a workspace among the shown ones, 1-based.
  function displayNumber(id) {
    var position = 0
    for (var i = 0; i < root.slotIds.length; i++) {
      var slotId = root.slotIds[i]
      if (slotId > id) break
      if (root.isShown(slotId)) position++
    }

    return position
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)
  readonly property real slotWidth: root.vertical ? root.barSize : Style.space(20) + Style.space(1)
  readonly property real slotHeight: root.vertical ? root.barSize + Style.space(2) : root.barSize

  implicitWidth: (root.vertical ? column.implicitWidth : row.implicitWidth) + trailingGap
  implicitHeight: root.vertical ? column.implicitHeight : row.implicitHeight

  Component {
    id: slot

    Item {
      id: slotItem
      required property int modelData

      readonly property var workspace: root.workspaceById(modelData)
      readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
      readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
      readonly property bool shown: occupied || focused

      // Keep the last label while collapsing, so a closing workspace fades out
      // with its own number instead of flickering to the one below it.
      readonly property int liveNumber: root.displayNumber(modelData)
      property int label: 0
      function syncLabel() {
        if (shown) slotItem.label = slotItem.liveNumber
      }
      onLiveNumberChanged: syncLabel()
      onShownChanged: syncLabel()
      Component.onCompleted: syncLabel()

      property real reveal: shown ? 1 : 0
      Behavior on reveal {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
      }

      visible: reveal > 0.001
      opacity: reveal
      clip: true
      implicitWidth: root.vertical ? root.slotWidth : root.slotWidth * reveal
      implicitHeight: root.vertical ? root.slotHeight * reveal : root.slotHeight

      WidgetButton {
        anchors.centerIn: parent
        bar: root.bar
        text: slotItem.focused ? "󱓻" : (slotItem.label === 10 ? "0" : String(slotItem.label))
        interactive: slotItem.shown
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        scale: 0.6 + 0.4 * slotItem.reveal
        onPressed: function() { root.focusWorkspace(slotItem.modelData) }
      }
    }
  }

  Row {
    id: row
    visible: !root.vertical
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    Repeater {
      model: root.vertical ? [] : root.slotIds
      delegate: slot
    }
  }

  Column {
    id: column
    visible: root.vertical
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
    Repeater {
      model: root.vertical ? root.slotIds : []
      delegate: slot
    }
  }
}
