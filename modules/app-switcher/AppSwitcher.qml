import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "../../shared"

// Apple/macOS-style Cmd+Tab app switcher. Hyprland (see bindings.lua) drives
// the gesture over IPC while SUPER is held; this plugin owns the window list,
// the highlight and the actual switch, so there is only one list to keep
// straight. Left-clicking an icon switches to it right away.
//
// Every IPC call carries the generation of the current SUPER+TAB gesture and
// an absolute step count rather than a "move by one" nudge. omarchy-shell
// spawns a fresh process per call, so calls can arrive out of order or twice;
// an absolute position survives both, and the generation tells a stale call
// from a live one.
//
// Shares icon resolution and the glass surface with the dock module, and uses
// whatever design style is picked in the dock's settings menu.
Item {
  id: root

  property bool opened: false
  property int selectedIndex: 0
  property var windows: []
  property var mru: []
  property string surfaceStyle: "glass"
  readonly property int iconSizePx: 64

  // Displays, numbered 1..n left to right (then top to bottom), and which
  // display each window sits on — for the little "1"/"2" monitor badges and
  // the legend under the title. Read straight from `hyprctl -j`, like the
  // workspace viewer does, since Quickshell's Hyprland model can lag behind.
  property var monitors: []       // [{ id, num, label }]
  property var monNumByAddr: ({}) // "0x…" -> display number
  readonly property bool multiMonitor: root.monitors.length > 1
  property string dmiVendor: ""
  property string dmiProduct: ""

  // Gesture this overlay currently shows, and the last one that was already
  // confirmed or cancelled. Anything arriving for a finished gesture is a
  // late duplicate and gets dropped.
  property int shownGen: -1
  property int finishedGen: -1

  AppIcons { id: appIcons }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/dock.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        if (typeof data.style === "string") root.surfaceStyle = data.style
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  function pruneMru() {
    var alive = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    var next = root.mru.filter(function(tl) { return alive.indexOf(tl) !== -1 })
    for (var i = 0; i < alive.length; i++) {
      if (next.indexOf(alive[i]) === -1) next.push(alive[i])
    }
    root.mru = next
  }

  function promote(tl) {
    if (!tl) return
    var list = root.mru.slice()
    var idx = list.indexOf(tl)
    if (idx === 0) return
    if (idx !== -1) list.splice(idx, 1)
    list.unshift(tl)
    root.mru = list
  }

  // ------------------------------------------------------------- displays

  FileView {
    path: "/sys/class/dmi/id/sys_vendor"
    printErrors: false
    onLoaded: root.dmiVendor = text().trim()
  }

  FileView {
    path: "/sys/class/dmi/id/product_name"
    printErrors: false
    onLoaded: root.dmiProduct = text().trim()
  }

  // "LG ULTRAWIDE" -> "LG Ultrawide": shouting model names read badly as a
  // caption; short all-caps words (brands, "HD", "4K") stay as they are.
  function softenCaps(str) {
    return String(str).split(" ").map(function(w) {
      return (w.length > 3 && w === w.toUpperCase() && /[A-Z]/.test(w))
        ? w.charAt(0) + w.slice(1).toLowerCase() : w
    }).join(" ")
  }

  // What a person would call the display: the laptop's own panel by the
  // laptop's name (its make/model is just the panel supplier, e.g. "Sharp
  // 0x1517"), an external one by brand and model.
  function monitorLabel(m) {
    var name = String(m.name || "")
    if (/^(eDP|LVDS|DSI)/.test(name)) {
      var vendor = root.dmiVendor.split(" ")[0]
      var laptop = (vendor + " " + root.dmiProduct).trim()
      return laptop !== "" ? laptop + " (Laptop)" : "Laptop-Display"
    }
    var brand = String(m.make || "").split(" ")[0]
    var model = String(m.model || "").trim()
    if (model === "" || /^0x[0-9a-f]+$/i.test(model)) {
      // No usable model name: fall back to the description minus its serial.
      var desc = String(m.description || "").replace(/\s+0x[0-9A-Fa-f]+$/, "").trim()
      return desc !== "" ? root.softenCaps(desc) : name
    }
    if (brand !== "" && model.toLowerCase().indexOf(brand.toLowerCase()) !== 0) model = brand + " " + model
    return root.softenCaps(model)
  }

  function applyDisplaySnapshot(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    var mons = (data.m || []).filter(function(m) { return !m.disabled })
    mons.sort(function(a, b) { return a.x !== b.x ? a.x - b.x : a.y - b.y })
    var numById = {}
    var list = []
    for (var i = 0; i < mons.length; i++) {
      numById[mons[i].id] = i + 1
      list.push({ id: mons[i].id, num: i + 1, label: root.monitorLabel(mons[i]) })
    }
    var byAddr = {}
    var clients = data.c || []
    for (var j = 0; j < clients.length; j++) {
      var n = numById[clients[j].monitor]
      if (n) byAddr[String(clients[j].address)] = n
    }
    root.monitors = list
    root.monNumByAddr = byAddr
  }

  Process {
    id: displayProc
    property bool again: false
    command: ["sh", "-c",
      "printf '{\"m\":'; hyprctl -j monitors; printf ',\"c\":'; hyprctl -j clients; printf '}'"]
    stdout: StdioCollector { onStreamFinished: root.applyDisplaySnapshot(this.text) }
    onExited: if (again) { again = false; running = true }
  }

  function refreshDisplays() {
    if (displayProc.running) displayProc.again = true
    else displayProc.running = true
  }

  // Windows move between displays and displays come and go; keep the map
  // current in the background so it is already right when the overlay opens.
  Timer {
    id: displayTimer
    interval: 200
    onTriggered: root.refreshDisplays()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { displayTimer.restart() }
  }

  // Display number (1..n) of a window, or 0 when unknown.
  function monitorNumFor(tl) {
    var addr = root.addressFor(tl)
    if (addr === "") return 0
    if (addr.indexOf("0x") !== 0) addr = "0x" + addr
    return root.monNumByAddr[addr] || 0
  }

  Component.onCompleted: {
    root.refreshDisplays()
    pruneMru()
    promote(ToplevelManager.activeToplevel)
    Hyprland.refreshToplevels()
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.promote(ToplevelManager.activeToplevel) }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() {
      root.pruneMru()
      // Keeps the Wayland toplevel -> Hyprland address mapping current, so a
      // switch never has to wait on a refresh round-trip.
      Hyprland.refreshToplevels()
    }
  }

  // ------------------------------------------------------------ switching

  function addressFor(tl) {
    if (!tl) return ""
    var list = []
    try { list = Hyprland.toplevels ? Hyprland.toplevels.values : [] } catch (e) { return "" }
    for (var i = 0; i < list.length; i++) {
      if (list[i].wayland === tl) return String(list[i].address || "")
    }
    return ""
  }

  // Quickshell's activate() doesn't reliably switch workspaces; Hyprland's own
  // focus dispatcher does. Addressing the window directly also picks the right
  // one when several windows share an app id (two kitty windows, say).
  //
  // This Hyprland takes lua, not the classic dispatcher syntax: plain
  // "focuswindow address:0x..." comes back as a parse error.
  function focusWindow(tl) {
    if (!tl) return
    var selector = ""
    var addr = root.addressFor(tl)
    if (addr !== "") {
      selector = "address:" + (addr.indexOf("0x") === 0 ? addr : "0x" + addr)
    } else {
      // No address yet (toplevel list mid-refresh): fall back to the app id,
      // which picks some window of the right app rather than none at all.
      try { tl.activate() } catch (e) {}
      var appId = String(tl.appId || "")
      if (appId === "") return
      selector = "class:^" + appId.replace(/["\\]/g, "") + "$"
    }
    Hyprland.dispatch("hl.dsp.focus({ window = \"" + selector + "\" })")
  }

  // bindings.lua puts Hyprland into the "app_switcher" submap for the length
  // of the gesture. When the overlay ends the gesture itself (a click),
  // Hyprland has to be let out of it, or every other SUPER shortcut stays
  // dead. Harmless no-op when Hyprland already left.
  function resetHyprSubmap() {
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap(\"reset\")"])
  }

  // ------------------------------------------------------------------ IPC

  // Absolute position within this gesture: 0 is the app you came from, 1 the
  // next one down the MRU list, -1 the last one.
  function applyStep(gen, step) {
    if (gen === root.finishedGen) return

    if (gen !== root.shownGen) {
      pruneMru()
      // The shell restarts independently of the session, and after a restart
      // nothing has changed focus yet, so the recency order is still just the
      // raw toplevel order. Anchor it on whatever is focused right now, so
      // "next app" always means the one before this one.
      promote(ToplevelManager.activeToplevel)
      if (root.mru.length === 0) return
      root.windows = root.mru.slice()
      root.shownGen = gen
      Hyprland.refreshToplevels()
      root.refreshDisplays()
    }

    var n = root.windows.length
    if (n === 0) return
    root.selectedIndex = ((step % n) + n) % n
    root.opened = true
  }

  function confirm(gen) {
    if (gen === root.finishedGen) return
    root.finishedGen = gen
    if (gen !== root.shownGen || !root.opened) {
      root.opened = false
      return
    }
    root.focusWindow(root.windows[root.selectedIndex])
    root.opened = false
  }

  function cancel(gen) {
    if (gen === root.finishedGen) return
    root.finishedGen = gen
    root.opened = false
  }

  // Mouse path: one left click picks the app and switches to it, without
  // waiting for SUPER to come up.
  function confirmAt(index) {
    if (!root.opened || index < 0 || index >= root.windows.length) return
    root.selectedIndex = index
    root.finishedGen = root.shownGen
    root.focusWindow(root.windows[index])
    root.opened = false
    root.resetHyprSubmap()
  }

  function cancelByMouse() {
    if (!root.opened) return
    root.finishedGen = root.shownGen
    root.opened = false
    root.resetHyprSubmap()
  }

  // What the overlay currently has highlighted, for `omarchy-shell
  // betterlife.app-switcher status` and as the reply to every call — the only way to see
  // what the switcher is doing from outside, since it draws on an overlay
  // layer that no screenshot of a window will catch.
  function describe() {
    if (!root.opened) return "closed"
    var tl = root.windows[root.selectedIndex]
    if (!tl) return "open, nothing selected"
    return "open " + (root.selectedIndex + 1) + "/" + root.windows.length
      + " " + String(tl.appId || "?")
      + " [" + root.addressFor(tl) + "]"
      + (root.multiMonitor ? " display " + root.monitorNumFor(tl) : "") + " "
      + String(tl.title || "").substring(0, 40)
  }

  IpcHandler {
    target: "betterlife.app-switcher"
    function step(gen: string, step: string): string {
      root.applyStep(parseInt(gen), parseInt(step))
      return root.describe()
    }
    function confirm(gen: string): string {
      var was = root.describe()
      root.confirm(parseInt(gen))
      return "confirmed " + was
    }
    function cancel(gen: string): string {
      root.cancel(parseInt(gen))
      return "cancelled"
    }
    function status(): string { return root.describe() }
  }

  // ----------------------------------------------------------------- view

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "betterlife-app-switcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Clicking past the card backs out without switching.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      onClicked: root.cancelByMouse()
    }

    Item {
      id: card
      visible: root.opened && root.windows.length > 0
      anchors.centerIn: parent
      width: Math.min(parent.width - 80, Math.max(
        root.windows.length * (root.iconSizePx + 32) + 48,
        root.multiMonitor ? legend.implicitWidth + 48 : 0))
      height: root.iconSizePx + 96 + (root.multiMonitor ? legend.implicitHeight + 12 : 0)

      // Pop-in, like the real Cmd+Tab HUD appearing.
      opacity: visible ? 1 : 0
      scale: visible ? 1 : 0.9
      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }

      // Swallows clicks on the card itself so they don't reach the
      // click-outside-to-cancel area behind it.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
      }

      GlassSurface {
        anchors.fill: parent
        variant: root.surfaceStyle
        radius: 24
        boost: 0.15
      }

      // Sliding highlight behind the selected icon — the switch animation.
      // Sibling of the Row so the Row's layout never fights the animated x.
      Rectangle {
        id: highlight
        radius: 16
        color: Util.alpha(Color.foreground, 0.1)
        border.color: Util.alpha(Color.accent, 0.6)
        border.width: 1
        readonly property var selectedItem: iconRepeater.count > 0 ? iconRepeater.itemAt(root.selectedIndex) : null
        visible: selectedItem !== null
        x: selectedItem ? iconRow.x + selectedItem.x : 0
        y: selectedItem ? iconRow.y + selectedItem.y : 0
        width: selectedItem ? selectedItem.width : 0
        height: selectedItem ? selectedItem.height : 0

        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      }

      Row {
        id: iconRow
        anchors.top: parent.top
        anchors.topMargin: 22
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 16

        Repeater {
          id: iconRepeater
          model: root.windows

          delegate: Item {
            id: slot
            required property int index
            required property var modelData
            readonly property bool selected: index === root.selectedIndex
            width: root.iconSizePx + 16
            height: root.iconSizePx + 16

            AppIcon {
              anchors.centerIn: parent
              icons: appIcons
              appId: String(slot.modelData.appId || "")
              size: root.iconSizePx
              scale: slot.selected ? 1.06 : 1.0
              opacity: slot.selected ? 1.0 : 0.82
              Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
              Behavior on opacity { NumberAnimation { duration: 140 } }
            }

            // Which display this window is on.
            MonitorGlyph {
              readonly property int num: root.multiMonitor ? root.monitorNumFor(slot.modelData) : 0
              visible: num > 0
              number: num
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.rightMargin: 2
              anchors.bottomMargin: 2
              active: slot.selected
            }

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton
              cursorShape: Qt.PointingHandCursor
              onClicked: root.confirmAt(slot.index)
            }
          }
        }
      }

      Text {
        id: titleText
        anchors.top: iconRow.bottom
        anchors.topMargin: 14
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 32
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        text: {
          var w = root.windows[root.selectedIndex]
          return w ? (w.title || appIcons.nameFor(w.appId) || "") : ""
        }
      }

      // Legend: what display 1, 2, … actually is. The one the highlighted
      // window is on stands out.
      Row {
        id: legend
        visible: root.multiMonitor
        anchors.top: titleText.bottom
        anchors.topMargin: 12
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 18

        readonly property int currentNum: {
          var w = root.windows[root.selectedIndex]
          return w ? root.monitorNumFor(w) : 0
        }

        Repeater {
          model: root.monitors
          delegate: Row {
            required property var modelData
            readonly property bool current: modelData.num === legend.currentNum
            spacing: 7
            opacity: current ? 1.0 : 0.55
            Behavior on opacity { NumberAnimation { duration: 140 } }

            MonitorGlyph {
              anchors.verticalCenter: parent.verticalCenter
              number: modelData.num
              active: parent.current
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: modelData.label
            }
          }
        }
      }
    }
  }

  // A tiny display: screen with the number on it, and a stand.
  component MonitorGlyph: Item {
    property int number: 0
    property bool active: false
    width: 24
    height: 20

    Rectangle {
      id: screen
      width: parent.width
      height: 16
      radius: 3
      color: parent.active ? Color.accent : Util.alpha(Color.background, 0.85)
      border.width: 1
      border.color: parent.active ? Color.accent : Util.alpha(Color.foreground, 0.7)

      Text {
        anchors.centerIn: parent
        color: parent.parent.active ? Color.background : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        text: String(parent.parent.number)
      }
    }

    Rectangle {
      anchors.top: screen.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      width: 10
      height: 3
      radius: 1
      color: parent.active ? Color.accent : Util.alpha(Color.foreground, 0.7)
    }
  }
}
