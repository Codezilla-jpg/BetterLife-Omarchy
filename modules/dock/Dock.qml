import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "../../shared"

// Glass dock of running apps at a screen edge. Clicking the thin handle at
// the edge (or right-clicking the dock) opens the settings menu: edge,
// size, visibility, always-visible vs. reveal-on-hover, design style and
// compositor blur. Settings persist in ~/.local/state/omarchy/settings/dock.json,
// which the app switcher also reads for the shared style.
Item {
  id: root

  // ---- Persisted settings
  property string position: "bottom"   // top | bottom | left | right
  property real dockScale: 1.0         // 0.25 … 2.0 in 0.25 steps
  property bool dockVisible: true
  property bool autohide: false        // true = reveal on edge hover
  property string style: "glass"       // glass | tinted | minimal | solid
  property bool blur: false
  property bool settingsLoaded: false

  // ---- Geometry
  readonly property bool horizontal: position === "top" || position === "bottom"
  readonly property int iconSize: Math.max(16, Math.round(56 * dockScale))
  readonly property int dockPadding: Math.max(4, Math.round(iconSize * 0.18))
  readonly property int iconSpacing: Math.max(4, Math.round(iconSize * 0.16))
  readonly property int edgeZone: 12
  readonly property int handleLength: 56
  readonly property int handleThickness: 4
  readonly property int innerPad: Math.max(8, Math.round(iconSize * 0.14))
  readonly property int appCount: Math.max(1, groups.length)
  readonly property int dockThickness: iconSize + dockPadding * 2
  readonly property int dockLength: appCount * iconSize + (appCount - 1) * iconSpacing + dockPadding * 2
  readonly property int crossSize: edgeZone + dockThickness + innerPad
  readonly property int alongSize: Math.max(dockLength, handleLength) + innerPad * 2

  // ---- Runtime state
  property var groups: []
  property bool revealed: false
  property bool suppressReveal: false
  readonly property bool menuOpen: settingsMenu.open
  readonly property bool showDock: dockVisible && (!autohide || revealed || menuOpen)

  function setScale(value) {
    var snapped = Math.round(Number(value) * 4) / 4
    root.dockScale = Math.max(0.25, Math.min(2.0, snapped))
  }

  function setPosition(value) {
    if (["top", "bottom", "left", "right"].indexOf(value) === -1 || value === root.position) return
    // The popup is anchored to the dock window, which moves to another edge;
    // reopen it once the window has re-anchored instead of leaving it floating.
    var reopen = settingsMenu.open
    settingsMenu.open = false
    root.position = value
    if (reopen) reopenMenuTimer.restart()
  }

  // Top-left corner for the settings popup, in dock-window coordinates:
  // centered along the dock, just inside of it (towards the screen center).
  function menuOrigin(w, h) {
    var gap = 10
    var shown = root.showDock
    switch (root.position) {
    case "top":
      return { x: (panel.width - w) / 2, y: (shown ? dockBox.restY + dockBox.height : root.edgeZone) + gap }
    case "left":
      return { x: (shown ? dockBox.restX + dockBox.width : root.edgeZone) + gap, y: (panel.height - h) / 2 }
    case "right":
      return { x: (shown ? dockBox.restX : panel.width - root.edgeZone) - w - gap, y: (panel.height - h) / 2 }
    default:
      return { x: (panel.width - w) / 2, y: (shown ? dockBox.restY : panel.height - root.edgeZone) - h - gap }
    }
  }

  function groupToplevels() {
    var tls = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    var order = []
    var byId = ({})
    for (var i = 0; i < tls.length; i++) {
      var tl = tls[i]
      var id = String(tl.appId || tl.title || "?")
      if (!byId[id]) {
        byId[id] = { appId: id, windows: [] }
        order.push(byId[id])
      }
      byId[id].windows.push(tl)
    }
    return order
  }

  function refreshGroups() { root.groups = root.groupToplevels() }

  // Quickshell's activate() doesn't reliably switch workspaces; Hyprland's
  // own focus dispatcher does (same approach as the app switcher).
  function focusNatively(appId) {
    var escaped = String(appId || "").replace(/["\\]/g, "")
    if (!escaped) return
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"class:^" + escaped + "$\" })"])
  }

  function activateGroup(group) {
    if (!group || group.windows.length === 0) return
    var active = ToplevelManager.activeToplevel
    var activeIdx = active ? group.windows.indexOf(active) : -1
    if (activeIdx !== -1 && group.windows.length > 1) {
      group.windows[(activeIdx + 1) % group.windows.length].activate()
    } else {
      group.windows[0].activate()
      if (group.windows.length === 1) root.focusNatively(group.appId)
    }
    if (root.autohide) {
      // Pick an app, then the dock gets out of the way again even though the
      // pointer is still sitting where the dock was.
      root.suppressReveal = true
      root.revealed = false
    }
  }

  function applyBlur() {
    Quickshell.execDetached(["hyprctl", "eval",
      "hl.config({ decoration = { blur = { enabled = " + (root.blur ? "true" : "false") + ", size = 8, passes = 2 } } })"])
  }

  Component.onCompleted: refreshGroups()

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.refreshGroups() }
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.refreshGroups() }
  }

  AppIcons { id: appIcons }

  // ---- Persistence
  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/dock.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (typeof data.position === "string") root.position = data.position
        if (typeof data.scale === "number") root.setScale(data.scale)
        else if (typeof data.iconSize === "number") root.setScale(data.iconSize / 56)
        if (typeof data.visible === "boolean") root.dockVisible = data.visible
        if (typeof data.autohide === "boolean") root.autohide = data.autohide
        if (typeof data.style === "string") root.style = data.style
        if (typeof data.blur === "boolean") root.blur = data.blur
      } catch (e) {}
      root.settingsLoaded = true
    }
    onLoadFailed: root.settingsLoaded = true
  }

  function saveState() {
    if (!root.settingsLoaded) return
    stateFile.setText(JSON.stringify({
      position: root.position,
      scale: root.dockScale,
      visible: root.dockVisible,
      autohide: root.autohide,
      style: root.style,
      blur: root.blur
    }, null, 2) + "\n")
  }

  onPositionChanged: saveStateDebounce.restart()
  onDockScaleChanged: saveStateDebounce.restart()
  onDockVisibleChanged: saveStateDebounce.restart()
  onAutohideChanged: { root.revealed = false; saveStateDebounce.restart() }
  onStyleChanged: saveStateDebounce.restart()
  onBlurChanged: { if (root.settingsLoaded) root.applyBlur(); saveStateDebounce.restart() }
  onMenuOpenChanged: if (!menuOpen && autohide && !contentHover.hovered) hideTimer.restart()

  Timer {
    id: saveStateDebounce
    interval: 400
    onTriggered: root.saveState()
  }

  Timer {
    id: hideTimer
    interval: 450
    onTriggered: if (!contentHover.hovered && !root.menuOpen) root.revealed = false
  }

  Timer {
    id: reopenMenuTimer
    interval: 200
    onTriggered: settingsMenu.open = true
  }

  IpcHandler {
    target: "betterlife.dock"
    function openSettings(): void { settingsMenu.open = true }
    function toggleSettings(): void { settingsMenu.toggle() }
    function toggleVisible(): void { root.dockVisible = !root.dockVisible }
    function setPosition(value: string): void { root.setPosition(value) }
    function setScale(percent: int): void { root.setScale(percent / 100) }
    function setStyle(value: string): void { root.style = value }
    function setAutohide(enabled: bool): void { root.autohide = enabled }
    function setBlur(enabled: bool): void { root.blur = enabled }
    function iconSource(appId: string): string { return appIcons.sourceFor(appId) || "monogram:" + appIcons.nameFor(appId) }
  }

  PanelWindow {
    id: panel
    anchors {
      top: root.position === "top"
      bottom: root.position === "bottom"
      left: root.position === "left"
      right: root.position === "right"
    }
    implicitWidth: root.horizontal ? root.alongSize : root.crossSize
    implicitHeight: root.horizontal ? root.crossSize : root.alongSize
    color: "transparent"
    WlrLayershell.namespace: "betterlife-dock"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Normal + zone 0: stay clear of the Omarchy bar's reserved strip when
    // docked at the same edge, without reserving any space of our own
    // (Ignore let the dock sit on top of the bar at the top edge).
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0

    // While the dock is hidden only the edge strip takes input, so the
    // transparent rest of this window never swallows clicks meant for apps.
    mask: Region { item: root.showDock ? contentRoot : edgeZoneItem }

    Item {
      id: contentRoot
      anchors.fill: parent

      HoverHandler {
        id: contentHover
        onHoveredChanged: {
          if (hovered) {
            hideTimer.stop()
            if (root.autohide && !root.suppressReveal) root.revealed = true
          } else {
            root.suppressReveal = false
            if (root.autohide) hideTimer.restart()
          }
        }
      }

      // ---- Dock surface
      Item {
        id: dockBox

        width: root.horizontal ? root.dockLength : root.dockThickness
        height: root.horizontal ? root.dockThickness : root.dockLength

        readonly property real restX: root.position === "left" ? root.edgeZone
          : root.position === "right" ? contentRoot.width - root.edgeZone - width
          : (contentRoot.width - width) / 2
        readonly property real restY: root.position === "top" ? root.edgeZone
          : root.position === "bottom" ? contentRoot.height - root.edgeZone - height
          : (contentRoot.height - height) / 2
        readonly property real shift: root.dockThickness + root.edgeZone

        // 0 = shown, 1 = slid out past the screen edge.
        property real slide: root.showDock ? 0 : 1
        Behavior on slide { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        x: restX + (root.position === "left" ? -shift : root.position === "right" ? shift : 0) * slide
        y: restY + (root.position === "top" ? -shift : root.position === "bottom" ? shift : 0) * slide
        opacity: 1 - slide
        visible: slide < 0.99

        GlassSurface {
          anchors.fill: parent
          variant: root.style
          radius: Math.round(root.dockThickness * 0.3)
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.RightButton
          onClicked: settingsMenu.toggle()
          onWheel: function(wheel) {
            if (wheel.angleDelta.y === 0) return
            root.setScale(root.dockScale + (wheel.angleDelta.y > 0 ? 0.25 : -0.25))
            wheel.accepted = true
          }
        }

        Grid {
          anchors.centerIn: parent
          columns: root.horizontal ? root.appCount : 1
          spacing: root.iconSpacing

          Repeater {
            model: root.groups

            delegate: Item {
              id: slot
              required property var modelData
              readonly property bool isActive: ToplevelManager.activeToplevel
                && modelData.windows.indexOf(ToplevelManager.activeToplevel) !== -1
              width: root.iconSize
              height: root.iconSize

              AppIcon {
                anchors.centerIn: parent
                icons: appIcons
                appId: slot.modelData.appId
                size: root.iconSize
                scale: iconMouse.containsMouse ? 1.12 : 1.0
                transformOrigin: root.position === "top" ? Item.Top
                  : root.position === "left" ? Item.Left
                  : root.position === "right" ? Item.Right
                  : Item.Bottom
                Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
              }

              // Running indicator between the icon and the screen edge.
              Rectangle {
                readonly property real gap: root.dockPadding / 2
                width: Math.max(3, Math.round(root.iconSize * 0.07))
                height: width
                radius: width / 2
                color: slot.isActive ? Color.accent : Util.alpha(Color.foreground, 0.35)
                x: root.position === "left" ? -gap - width / 2
                  : root.position === "right" ? parent.width + gap - width / 2
                  : (parent.width - width) / 2
                y: root.position === "top" ? -gap - height / 2
                  : root.position === "bottom" ? parent.height + gap - height / 2
                  : (parent.height - height) / 2
                Behavior on color { ColorAnimation { duration: 150 } }
              }

              MouseArea {
                id: iconMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  if (mouse.button === Qt.LeftButton) root.activateGroup(slot.modelData)
                  else if (mouse.button === Qt.MiddleButton && slot.modelData.windows.length > 0) slot.modelData.windows[0].close()
                  else if (mouse.button === Qt.RightButton) settingsMenu.toggle()
                }
                onWheel: function(wheel) {
                  if (wheel.angleDelta.y === 0) return
                  root.setScale(root.dockScale + (wheel.angleDelta.y > 0 ? 0.25 : -0.25))
                  wheel.accepted = true
                }
              }
            }
          }
        }
      }

      // ---- Edge strip with the handle: click opens settings, hover reveals
      Item {
        id: edgeZoneItem
        x: root.position === "right" ? contentRoot.width - root.edgeZone : 0
        y: root.position === "bottom" ? contentRoot.height - root.edgeZone : 0
        width: root.horizontal ? contentRoot.width : root.edgeZone
        height: root.horizontal ? root.edgeZone : contentRoot.height

        Rectangle {
          anchors.centerIn: parent
          width: root.horizontal ? root.handleLength : root.handleThickness
          height: root.horizontal ? root.handleThickness : root.handleLength
          radius: root.handleThickness / 2
          color: Util.alpha(Color.foreground, handleMouse.containsMouse || root.menuOpen ? 0.65 : (root.showDock ? 0.22 : 0.35))
          Behavior on color { ColorAnimation { duration: 120 } }
        }

        MouseArea {
          id: handleMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: settingsMenu.toggle()
        }
      }
    }
  }

  DockSettingsMenu {
    id: settingsMenu
    dock: root
    anchorWindow: panel
  }
}
