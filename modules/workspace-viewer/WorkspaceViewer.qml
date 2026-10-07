import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "../../shared"

// Mission Control-style workspace overview.
//
// Top: a Spaces bar with one group per display (laptop, external monitor),
// each a row of desktop miniatures plus "+", a swap button between displays,
// and a trash icon on the right. Middle: the windows of the selected desktop,
// laid out large. Opening zooms the current desktop's windows out of their
// real positions into that layout; closing zooms them back.
//
//   desktop card   click: switch · drag: reorder / move to the other display /
//                  drop on a desktop there: swap · drag to trash: close all
//   "+"            new empty desktop on that display (stays in the overview)
//   ⇄              swap the desktops shown on the two displays
//   window         click: focus · drag onto a desktop: move it there ·
//                  onto "+": its own new desktop · into trash: close ·
//                  middle click / ✕: close
//
// Keys: ←/→ select desktop, ↑/↓ other display, Enter open, Shift+←/→ move the
// desktop (across displays at the ends), Del twice to close, Esc.
//
// Opened from Hyprland (bindings.lua): omarchy-shell -q betterlife.workspace-viewer toggle
//
// Hyprland side:
// - The model is read straight from `hyprctl -j` after every Hyprland event,
//   not from Quickshell's Hyprland.workspaces/toplevels, which can go stale
//   (it drops refresh requests while one is in flight).
// - Hyprland orders desktops by id, so moving a desktop means giving it
//   another id. That's done by moving its *windows* (see applyLayout), never
//   with workspace.change_id: that sends an event Quickshell doesn't know,
//   which left the bar and this overview with stale and duplicate
//   workspaces. After every change the desktops are numbered 1..n left to
//   right across the displays, like the bar and SUPER+n count them.
// - Every change goes out as one `hyprctl --batch`. Until the snapshot after
//   it arrives, `pending` shows the result already, so nothing jumps.
Item {
  id: root

  // Layer surface mapped: true from open() until the close animation is done.
  property bool opened: false
  // Drives the open/close animations; goes true one frame after `opened`.
  property bool shown: false
  // open() was called and waits for the first snapshot.
  property bool opening: false

  property int revision: 0
  property var targetScreen: null
  property string hostMon: ""
  property int selectedWsId: -1
  property int hoverWsId: -1
  property int pendingDelete: -1
  // Last pointer position in overlay coordinates (to put the cursor back
  // after Hyprland had to focus another monitor).
  property point lastPointer: Qt.point(0, 0)

  // Drag: kind "" | "ws" | "win"
  property string dragKind: ""
  property int dragWsId: -1
  property string dragAddr: ""
  property point dragPos: Qt.point(0, 0)
  property point dragGrab: Qt.point(0.5, 0.5)
  property real dragW: 0
  property real dragH: 0
  // Drop target: "" | "none" | "insert" | "swap" | "into" | "new" | "trash"
  property string dropKind: ""
  property string dropMon: ""
  property int dropIndex: -1
  property int dropWsId: -1

  readonly property string uiFont: "Adwaita Sans"
  readonly property string wallpaper: "file://" + Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  readonly property string parkName: "special:betterlife-wv-park"

  // For the component files, which can't see this file's ids.
  readonly property Item overlayContent: content
  readonly property var icons: appIcons
  readonly property var wsModel: wsListModel

  AppIcons { id: appIcons }

  // ---------------------------------------------------------------- model
  //
  // Everything below comes from the last `hyprctl -j` snapshot. The maps and
  // arrays are only replaced when their content changed, so bindings (and
  // the Repeaters built on them) don't churn on every title change.

  property var monByName: ({})
  // Monitor names, left to right.
  property var monitorsList: []
  property var wsById: ({})
  // monName -> [workspace id, ascending]
  property var wsOrder: ({})
  // workspace id -> [window address]
  property var winsByWs: ({})
  property var clientByAddr: ({})
  property int focusedWsId: -1
  readonly property var none: []

  // Between sending a batch and the snapshot after it: the layout the batch
  // will produce, keyed by the ids desktops have now ("content" ids).
  //   order:     monName -> [content id] as the display will show them
  //   newId:     content id -> id it will have
  //   contentAt: id -> content id that will be there
  property var pending: null
  // True for a moment while `pending` is swapped for the real snapshot, so
  // cards take their new place without sliding.
  property bool noAnim: false

  ListModel { id: wsListModel }

  function same(a, b) {
    if (a === b) return true
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
  }

  function sameMap(a, b) {
    var ka = Object.keys(a), kb = Object.keys(b)
    if (ka.length !== kb.length) return false
    for (var i = 0; i < ka.length; i++) if (!root.same(a[ka[i]], b[ka[i]])) return false
    return true
  }

  // Keeps each array of `next` that equals the one in `prev`, so bindings
  // on a single entry see the same object.
  function keepArrays(prev, next) {
    for (var k in next) if (prev[k] && root.same(prev[k], next[k])) next[k] = prev[k]
    return next
  }

  function applySnapshot(text) {
    var s
    try { s = JSON.parse(text) } catch (e) { console.warn("workspace-viewer: bad snapshot:", e); return }
    // A batch ran while this was taken: it may show a state halfway through.
    if (batchProc.running) return
    if (snapProc.seq !== root.batchSeq) { root.refresh(); return }

    var mons = {}, names = []
    for (var i = 0; i < s.m.length; i++) {
      var m = s.m[i]
      if (m.disabled) continue
      mons[m.name] = m
      names.push(m.name)
    }
    names.sort(function(a, b) { return mons[a].x !== mons[b].x ? mons[a].x - mons[b].x : mons[a].y - mons[b].y })

    var ws = {}, order = {}
    for (var j = 0; j < s.w.length; j++) {
      var w = s.w[j]
      if (w.id <= 0 || !mons[w.monitor]) continue
      ws[w.id] = w
      if (!order[w.monitor]) order[w.monitor] = []
      order[w.monitor].push(w.id)
    }
    for (var mn in order) order[mn].sort(function(a, b) { return a - b })

    var clients = {}, wins = {}
    for (var c = 0; c < s.c.length; c++) {
      var cl = s.c[c]
      if (!cl.mapped || cl.hidden || !cl.workspace || !ws[cl.workspace.id]) continue
      clients[cl.address] = cl
      if (!wins[cl.workspace.id]) wins[cl.workspace.id] = []
      wins[cl.workspace.id].push(cl.address)
    }
    for (var wk in wins) wins[wk].sort()

    var focused = -1
    for (var n = 0; n < names.length; n++) {
      if (mons[names[n]].focused && mons[names[n]].activeWorkspace) focused = mons[names[n]].activeWorkspace.id
    }

    if (!root.same(names, root.monitorsList)) root.monitorsList = names
    if (!root.sameMap(order, root.wsOrder)) root.wsOrder = root.keepArrays(root.wsOrder, order)
    if (!root.sameMap(wins, root.winsByWs)) root.winsByWs = root.keepArrays(root.winsByWs, wins)
    root.monByName = mons
    root.wsById = ws
    root.clientByAddr = clients
    root.focusedWsId = focused
    root.syncWsModel()

    if (s.p && root.dragKind === "") {
      var g = root.monGeom(root.hostMon)
      root.lastPointer = Qt.point(s.p.x - g.x, s.p.y - g.y)
    }

    if (root.pending) {
      root.noAnim = true
      root.pending = null
      Qt.callLater(function() { root.noAnim = false })
    }
    if (root.selectedWsId > 0 && !ws[root.selectedWsId] && root.dragKind === "") root.selectedWsId = root.focusedWsId
    root.revision++

    if (root.opening) root.finishOpen()
  }

  // Delegates are per workspace id and stay alive across snapshots; each
  // display group shows the ones on its display.
  function syncWsModel() {
    var ids = Object.keys(root.wsById).map(Number)
    for (var i = wsListModel.count - 1; i >= 0; i--) {
      if (ids.indexOf(wsListModel.get(i).wid) === -1) wsListModel.remove(i)
    }
    var have = []
    for (var j = 0; j < wsListModel.count; j++) have.push(wsListModel.get(j).wid)
    for (var k = 0; k < ids.length; k++) if (have.indexOf(ids[k]) === -1) wsListModel.append({ wid: ids[k] })
  }

  Process {
    id: snapProc
    property bool again: false
    command: ["sh", "-c",
      "printf '{\"m\":'; hyprctl -j monitors; printf ',\"w\":'; hyprctl -j workspaces;"
      + " printf ',\"c\":'; hyprctl -j clients; printf ',\"p\":'; hyprctl -j cursorpos; printf '}'"]
    // batchSeq when this snapshot started.
    property int seq: 0
    stdout: StdioCollector { onStreamFinished: root.applySnapshot(this.text) }
    onExited: if (again) { again = false; root.startSnap() }
  }

  function startSnap() {
    snapProc.seq = root.batchSeq
    snapProc.running = true
  }

  function refresh() {
    if (snapProc.running) snapProc.again = true
    else root.startSnap()
  }

  // Events come in bursts (a batch sends dozens); one snapshot per burst.
  Timer {
    id: refreshTimer
    interval: 30
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { if (root.opened || root.opening) refreshTimer.restart() }
  }

  function monGeom(name) {
    var mon = root.monByName[name]
    if (!mon) return { x: 0, y: 0, w: 1920, h: 1080 }
    var s = mon.scale || 1
    var rot = (mon.transform % 2) === 1
    return {
      x: mon.x, y: mon.y,
      w: (rot ? mon.height : mon.width) / s,
      h: (rot ? mon.width : mon.height) / s
    }
  }

  function displayLabel(name) {
    if (/^(eDP|LVDS|DSI)/.test(name)) return "Laptop"
    var mon = root.monByName[name]
    var model = mon && mon.model ? String(mon.model).trim() : ""
    return model !== "" ? model : name
  }

  function activeOn(monName) {
    var mon = root.monByName[monName]
    return mon && mon.activeWorkspace ? mon.activeWorkspace.id : -1
  }

  function monitorOf(wsId) {
    var ws = root.wsById[wsId]
    return ws ? String(ws.monitor) : ""
  }

  // Desktops on a display, as shown (content ids, see `pending`).
  function workspacesOn(monName) {
    if (root.pending && root.pending.order[monName]) return root.pending.order[monName]
    return root.wsOrder[monName] || root.none
  }

  function slotOf(contentId) {
    if (root.pending && root.pending.newId[contentId] !== undefined) return root.pending.newId[contentId]
    return contentId
  }

  function contentAt(id) {
    if (root.pending && root.pending.contentAt[id] !== undefined) return root.pending.contentAt[id]
    return id
  }

  function winsOf(wsId) { return root.winsByWs[wsId] || root.none }

  function inUse(id) { return root.winsOf(id).length > 0 || root.focusedWsId === id }

  // Same number the workspaces module shows in the bar (which has slots 1-10):
  // position among the desktops in use, so "Schreibtisch 3" here is "3" up top.
  function displayNumber(id) {
    if (id > 10 || !root.inUse(id)) return id
    var n = 0
    for (var i = 1; i <= id; i++) if (root.inUse(i)) n++
    return n
  }

  function allWorkspaceIdsOrdered() {
    var out = []
    for (var i = 0; i < root.monitorsList.length; i++) out = out.concat(root.workspacesOn(root.monitorsList[i]))
    return out
  }

  // Quickshell's toplevels, only for their Wayland handle (live previews).
  readonly property var tlByAddr: {
    root.revision
    var m = {}
    var v = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < v.length; i++) m[root.addrOf(v[i])] = v[i]
    return m
  }

  function waylandOf(addr) {
    var tl = root.tlByAddr[addr]
    return tl && tl.wayland ? tl.wayland : null
  }

  function addrOf(tl) {
    var a = String(tl && tl.address ? tl.address : "")
    if (a === "") return ""
    return a.indexOf("0x") === 0 ? a : "0x" + a
  }

  // ------------------------------------------------------------- hyprland

  property var queue: []
  property int batchSeq: 0

  Process {
    id: batchProc
    property string lastCmd: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var bad = this.text.split("\n").filter(function(l) { var t = l.trim(); return t !== "" && t !== "ok" })
        if (bad.length) console.warn("workspace-viewer: hyprctl:", bad.join(" | "), "for", batchProc.lastCmd)
      }
    }
    onExited: {
      if (root.queue.length) root.startBatch()
      else root.refresh()
    }
  }

  function startBatch() {
    var cmds = root.queue[0]
    root.queue = root.queue.slice(1)
    root.batchSeq++
    batchProc.lastCmd = cmds.join(" ; ")
    batchProc.command = ["hyprctl", "--batch", cmds.map(function(c) { return "dispatch " + c }).join(" ; ")]
    batchProc.running = true
  }

  function run(cmds, pendingView) {
    if (!cmds || cmds.length === 0) return
    if (pendingView) root.pending = pendingView
    root.queue = root.queue.concat([cmds])
    if (!batchProc.running) root.startBatch()
  }

  // Something is in flight: desktop moves would be computed from a layout
  // that's about to change.
  readonly property bool busy: root.pending !== null || batchProc.running

  function q(s) { return "\"" + String(s).replace(/["\\]/g, "") + "\"" }
  function cmdFocusWs(id) { return "hl.dsp.focus({ workspace = " + root.q(id) + " })" }
  function cmdFocusMon(mon) { return "hl.dsp.focus({ monitor = " + root.q(mon) + " })" }
  function cmdMoveWin(addr, ws) {
    return "hl.dsp.window.move({ workspace = " + root.q(ws) + ", window = " + root.q("address:" + addr) + ", follow = false })"
  }

  // Focusing a monitor warps the cursor. Put focus and pointer back where
  // the user is.
  function cmdsBackToPointer() {
    var g = root.monGeom(root.hostMon)
    return [
      root.cmdFocusMon(root.hostMon),
      "hl.dsp.cursor.move({ x = " + Math.round(g.x + root.lastPointer.x) + ", y = " + Math.round(g.y + root.lastPointer.y) + " })"
    ]
  }

  function notePointer(p) { root.lastPointer = p }

  // --------------------------------------------------------------- layout
  //
  // Every change to the desktops is written as the layout wanted afterwards:
  // for each display, left to right, the desktops it shows, as "keys" (the
  // id a desktop has now, or a negative number for a new one). applyLayout
  // then numbers them 1..n left to right across the displays, so the number
  // in the overview, in the bar and for SUPER+n is always the same, and
  // moves the windows to get there.

  function currentLayout() {
    var out = {}
    for (var i = 0; i < root.monitorsList.length; i++) {
      var m = root.monitorsList[i]
      out[m] = (root.wsOrder[m] || []).slice()
    }
    return out
  }

  // What a display shows afterwards: what it showed, if that's still there;
  // else whatever took that place.
  function shownAfter(layout, mon) {
    var list = layout[mon]
    var a = root.activeOn(mon)
    if (list.indexOf(a) !== -1) return a
    var at = (root.wsOrder[mon] || []).indexOf(a)
    return list[Math.max(0, Math.min(at, list.length - 1))]
  }

  // layout:  monName -> [key]         (every display, every desktop)
  // winsFor: key -> [window address]  (defaults to the desktop's windows)
  // shown:   monName -> key to show   (defaults to shownAfter)
  // Returns key -> id afterwards.
  //
  // Hyprland creates a missing workspace on the focused monitor and removes
  // one that's empty and not shown. So: displays whose shown desktop gets
  // renumbered first switch to a named placeholder; the windows that move
  // wait on a special workspace; then each display is focused in turn while
  // its windows land (creating their workspaces there); last, each display
  // is switched to what it should show.
  function applyLayout(layout, winsFor, shown) {
    winsFor = winsFor || root.winsOf
    shown = shown || {}
    var mons = root.monitorsList
    var target = {}, monOf = {}, n = 1
    for (var i = 0; i < mons.length; i++) {
      var list = layout[mons[i]]
      // A display always shows a desktop.
      if (list.length === 0) list.push(-100 - i)
      for (var j = 0; j < list.length; j++) {
        target[list[j]] = n++
        monOf[list[j]] = mons[i]
      }
      if (shown[mons[i]] === undefined) shown[mons[i]] = root.shownAfter(layout, mons[i])
    }
    // Keeps its id and display: its windows can stay where they are.
    var kept = function(key) { return key > 0 && target[key] === key && root.monitorOf(key) === monOf[key] }

    var hold = [], park = [], land = [], show = []
    for (i = 0; i < mons.length; i++) {
      var m = mons[i]
      var a = root.activeOn(m)
      if (!kept(a)) hold.push(root.cmdFocusMon(m), root.cmdFocusWs("name:betterlife-wv-hold-" + m))
      land.push(root.cmdFocusMon(m))
      list = layout[m]
      for (j = 0; j < list.length; j++) {
        var key = list[j], wins = winsFor(key)
        for (var w = 0; w < wins.length; w++) {
          var c = root.clientByAddr[wins[w]]
          if (c && c.workspace && c.workspace.id === target[key] && kept(key)) continue
          park.push(root.cmdMoveWin(wins[w], root.parkName))
          land.push(root.cmdMoveWin(wins[w], target[key]))
        }
      }
      if (!kept(a) || shown[m] !== a) show.push(root.cmdFocusMon(m), root.cmdFocusWs(target[shown[m]]))
    }
    if (park.length === 0 && show.length === 0) return target

    // Only the displays that got windows need focusing while they land.
    var landing = []
    for (var k = 0; k < land.length; k++) {
      if (land[k].indexOf("hl.dsp.focus") === 0 && (k + 1 >= land.length || land[k + 1].indexOf("hl.dsp.focus") === 0)) continue
      landing.push(land[k])
    }
    var cmds = hold.concat(park, landing, show, root.cmdsBackToPointer())

    // Until the snapshot after this: cards (keyed by the ids they have now)
    // already stand where they're going.
    var order = {}, newId = {}, contentAt = {}
    for (i = 0; i < mons.length; i++) {
      order[mons[i]] = layout[mons[i]].filter(function(key) { return key > 0 })
    }
    for (var key2 in target) {
      if (Number(key2) <= 0) continue
      newId[key2] = target[key2]
      contentAt[target[key2]] = Number(key2)
    }
    root.run(cmds, { order: order, newId: newId, contentAt: contentAt })
    if (target[root.selectedWsId] !== undefined) root.selectedWsId = target[root.selectedWsId]
    return target
  }

  // Put desktop `wsId` at `index` (counted without it) on display `monName`.
  function placeWorkspace(wsId, monName, index) {
    if (root.busy || !root.wsById[wsId] || !root.monByName[monName]) return
    var layout = root.currentLayout()
    var from = root.monitorOf(wsId)
    layout[from] = layout[from].filter(function(id) { return id !== wsId })
    index = Math.max(0, Math.min(index, layout[monName].length))
    layout[monName].splice(index, 0, wsId)
    var t = root.applyLayout(layout)
    root.selectedWsId = t[wsId]
  }

  // Swap two desktops' places (display and position).
  function swapWorkspaces(aId, bId) {
    if (root.busy || aId === bId || !root.wsById[aId] || !root.wsById[bId]) return
    var layout = root.currentLayout()
    var ma = root.monitorOf(aId), mb = root.monitorOf(bId)
    var ia = layout[ma].indexOf(aId), ib = layout[mb].indexOf(bId)
    layout[ma][ia] = bId
    layout[mb][ib] = aId
    root.applyLayout(layout)
  }

  function swapShown(monA, monB) {
    var a = root.activeOn(monA), b = root.activeOn(monB)
    if (a > 0 && b > 0) root.swapWorkspaces(a, b)
  }

  // New empty desktop at the end of display `monName`, shown there; the
  // overview stays open with it selected.
  function newDesktop(monName) {
    if (root.busy || !root.monByName[monName]) return
    var layout = root.currentLayout()
    layout[monName].push(-1)
    var shown = {}
    shown[monName] = -1
    var t = root.applyLayout(layout, null, shown)
    root.selectedWsId = t[-1]
  }

  // Take window `addr` off its desktop; `into` gets it. A desktop left empty
  // goes away, unless it's the only one on its display.
  function moveWindowCommon(addr, layout, into) {
    var c = root.clientByAddr[addr]
    if (!c || !c.workspace) return
    var src = c.workspace.id
    var srcMon = root.monitorOf(src)
    var rest = root.winsOf(src).filter(function(a) { return a !== addr })
    if (rest.length === 0 && layout[srcMon].length > 1) layout[srcMon] = layout[srcMon].filter(function(id) { return id !== src })
    root.applyLayout(layout, function(key) {
      if (key === into) return root.winsOf(key).concat([addr])
      if (key === src) return rest
      return root.winsOf(key)
    })
  }

  function moveWindow(addr, wsId) {
    if (addr === "" || root.busy || !root.wsById[wsId]) return
    var c = root.clientByAddr[addr]
    if (!c || !c.workspace || c.workspace.id === wsId) return
    root.moveWindowCommon(addr, root.currentLayout(), wsId)
  }

  // Pull a window out onto a desktop of its own at the end of `monName`.
  function moveWindowToNewWorkspace(addr, monName) {
    if (addr === "" || root.busy || !root.monByName[monName]) return
    var layout = root.currentLayout()
    layout[monName].push(-1)
    root.moveWindowCommon(addr, layout, -1)
  }

  function closeWindow(addr) {
    if (addr !== "") root.run(["hl.dsp.window.close({ window = " + root.q("address:" + addr) + " })"])
  }

  // Close every window on a desktop. An empty desktop that's still shown is
  // left by switching its display to a neighbour, which removes it.
  function trashWorkspace(wsId) {
    var mon = root.monitorOf(wsId)
    if (mon === "") return
    var cmds = []
    var wins = root.winsOf(wsId)
    for (var i = 0; i < wins.length; i++) cmds.push("hl.dsp.window.close({ window = " + root.q("address:" + wins[i]) + " })")
    if (wins.length === 0 && root.activeOn(mon) === wsId) {
      var list = root.workspacesOn(mon)
      var i2 = list.indexOf(wsId)
      var other = list[i2 > 0 ? i2 - 1 : i2 + 1]
      if (other) cmds = cmds.concat([root.cmdFocusMon(mon), root.cmdFocusWs(other)]).concat(root.cmdsBackToPointer())
    }
    if (root.selectedWsId === wsId) {
      var flat = root.allWorkspaceIdsOrdered()
      var k = flat.indexOf(wsId)
      root.selectedWsId = flat[k > 0 ? k - 1 : k + 1] || -1
    }
    root.run(cmds)
  }

  // First call arms, second call on the same desktop closes it.
  function requestDelete(wsId) {
    if (wsId <= 0) return
    if (root.pendingDelete !== wsId) {
      root.pendingDelete = wsId
      return
    }
    root.pendingDelete = -1
    root.trashWorkspace(wsId)
  }

  function focusWorkspace(id) {
    root.run([root.cmdFocusWs(id)])
    root.close()
  }

  function focusWindow(addr) {
    if (addr === "") return
    root.run(["hl.dsp.focus({ window = " + root.q("address:" + addr) + " })"])
    root.close()
  }

  // ------------------------------------------------------------ open/close

  function open() {
    root.pendingDelete = -1
    root.dragCancel()
    closeTimer.stop()
    root.opening = true
    Hyprland.refreshToplevels()
    root.refresh()
    openFallback.restart()
  }

  // Runs once the first snapshot is in, so the first frame is current.
  function finishOpen() {
    root.opening = false
    openFallback.stop()
    var fm = ""
    for (var n in root.monByName) if (root.monByName[n].focused) fm = n
    var screens = Quickshell.screens
    root.targetScreen = screens.length > 0 ? screens[0] : null
    for (var i = 0; i < screens.length; i++) if (screens[i].name === fm) root.targetScreen = screens[i]
    root.hostMon = root.targetScreen ? String(root.targetScreen.name) : fm
    root.selectedWsId = root.focusedWsId
    root.revision++
    root.shown = false
    root.opened = true
    showTimer.restart()
  }

  Timer {
    id: openFallback
    interval: 400
    onTriggered: if (root.opening) root.finishOpen()
  }

  function close() {
    root.opening = false
    if (!root.opened) return
    root.dragCancel()
    root.pendingDelete = -1
    root.shown = false
    closeTimer.restart()
  }

  function toggle() { (root.opened && root.shown) || root.opening ? root.close() : root.open() }

  // One frame at the start positions (windows where they really are), then
  // everything animates into the overview.
  Timer {
    id: showTimer
    interval: 16
    onTriggered: { root.revision++; root.shown = true }
  }

  Timer {
    id: closeTimer
    interval: 330
    onTriggered: root.opened = false
  }

  IpcHandler {
    target: "betterlife.workspace-viewer"
    function toggle(): string { root.toggle(); return root.shown ? "open" : "closed" }
    function open(): string { root.open(); return "open" }
    function close(): string { root.close(); return "closed" }
    function status(): string { return root.opened ? "open, selected " + root.selectedWsId : "closed" }
    // For testing the Hyprland side without the mouse.
    function dump(): string {
      var out = []
      for (var i = 0; i < root.monitorsList.length; i++) {
        var m = root.monitorsList[i]
        out.push(m + " [shows " + root.activeOn(m) + "]: " + root.workspacesOn(m).map(function(id) {
          return id + "(" + root.winsOf(id).length + ")"
        }).join(" "))
      }
      return out.join("\n") + "\nselected " + root.selectedWsId + (root.busy ? " (busy)" : "")
    }
    function place(ws: int, mon: string, index: int): string { root.placeWorkspace(ws, mon, index); return "ok" }
    function swap(a: int, b: int): string { root.swapWorkspaces(a, b); return "ok" }
    function newDesk(mon: string): string { root.newDesktop(mon); return "ok" }
    function winToNew(addr: string, mon: string): string { root.moveWindowToNewWorkspace(addr, mon); return "ok" }
    function winTo(addr: string, ws: int): string { root.moveWindow(addr, ws); return "ok" }
  }

  // ------------------------------------------------------------ selection

  Timer {
    id: hoverTimer
    interval: 110
    onTriggered: if (root.dragKind === "" && root.hoverWsId > 0) root.selectedWsId = root.hoverWsId
  }

  function hoverSelect(id) {
    // While a change goes out the cards slide under a resting pointer; that
    // isn't the user pointing at them.
    if (root.dragKind !== "" || root.busy) return
    root.hoverWsId = id
    hoverTimer.restart()
  }

  function hoverCancel(id) {
    if (root.hoverWsId !== id) return
    root.hoverWsId = -1
    hoverTimer.stop()
  }

  // ------------------------------------------------------------------ drag

  function dragStart(kind, info, pos) {
    // Desktops can't be moved while the last move is still going out.
    if (kind === "ws" && root.busy) return
    hoverTimer.stop()
    root.pendingDelete = -1
    root.dragWsId = info.wsId !== undefined ? info.wsId : -1
    root.dragAddr = info.addr || ""
    root.dragW = info.w || 100
    root.dragH = info.h || 60
    root.dragGrab = Qt.point(info.grabX !== undefined ? info.grabX : 0.5, info.grabY !== undefined ? info.grabY : 0.5)
    root.dragPos = pos
    // Last, so bindings on dragKind see a complete drag.
    root.dragKind = kind
    root.dragMove(pos)
  }

  function dragMove(pos) {
    root.dragPos = pos
    root.lastPointer = pos
    var kind = "", mon = "", index = -1, wsId = -1

    var t = trash.mapFromItem(content, pos.x, pos.y)
    if (t.x >= -32 && t.y >= -32 && t.x <= trash.width + 32 && t.y <= trash.height + 32) {
      kind = "trash"
    } else {
      for (var i = 0; i < groupRepeater.count; i++) {
        var holder = groupRepeater.itemAt(i)
        if (!holder) continue
        var hit = holder.group.hitTest(pos, root.dragKind)
        if (!hit) continue
        kind = hit.kind
        mon = holder.group.monName
        index = hit.index !== undefined ? hit.index : -1
        wsId = hit.wsId !== undefined ? hit.wsId : -1
        break
      }
    }
    root.dropKind = kind
    root.dropMon = mon
    root.dropIndex = index
    root.dropWsId = wsId
  }

  // Ends the drag before acting: the action can hide the dragged card (it
  // moves to the other display), which cancels its MouseArea mid-drop.
  function dragEnd() {
    var kind = root.dragKind, wsId = root.dragWsId, addr = root.dragAddr
    var drop = root.dropKind, mon = root.dropMon, index = root.dropIndex, target = root.dropWsId
    root.dragCancel()
    switch (drop) {
    case "insert":
      if (kind === "ws") root.placeWorkspace(wsId, mon, index)
      break
    case "swap":
      if (kind === "ws") root.swapWorkspaces(wsId, target)
      break
    case "into":
      if (kind === "win") root.moveWindow(addr, target)
      break
    case "new":
      if (kind === "win") root.moveWindowToNewWorkspace(addr, mon)
      break
    case "trash":
      if (kind === "ws") root.trashWorkspace(wsId)
      else root.closeWindow(addr)
      break
    }
  }

  function dragCancel() {
    root.dragKind = ""
    root.dragWsId = -1
    root.dragAddr = ""
    root.dropKind = ""
    root.dropMon = ""
    root.dropIndex = -1
    root.dropWsId = -1
  }

  // ------------------------------------------------------------------ keys

  function selectedPlace() {
    var mons = root.monitorsList
    for (var g = 0; g < mons.length; g++) {
      var list = root.workspacesOn(mons[g])
      var i = list.indexOf(root.selectedWsId)
      if (i !== -1) return { group: g, index: i, list: list, id: root.selectedWsId }
    }
    return null
  }

  function handleKey(event) {
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var here = root.selectedPlace()
    var mons = root.monitorsList

    switch (event.key) {
    case Qt.Key_Escape:
      if (root.pendingDelete !== -1) root.pendingDelete = -1
      else root.close()
      break

    case Qt.Key_Left:
    case Qt.Key_Right: {
      var d = event.key === Qt.Key_Left ? -1 : 1
      root.pendingDelete = -1
      if (!here) {
        var flat0 = root.allWorkspaceIdsOrdered()
        if (flat0.length) root.selectedWsId = flat0[0]
        break
      }
      if (shift) {
        var to = here.index + d
        if (to >= 0 && to < here.list.length) {
          root.placeWorkspace(here.id, mons[here.group], to)
        } else {
          var g2 = here.group + d
          if (g2 >= 0 && g2 < mons.length) {
            var target = root.workspacesOn(mons[g2])
            root.placeWorkspace(here.id, mons[g2], d > 0 ? 0 : target.length)
          }
        }
      } else {
        var flat = root.allWorkspaceIdsOrdered()
        var k = flat.indexOf(root.selectedWsId) + d
        if (k >= 0 && k < flat.length) root.selectedWsId = flat[k]
      }
      break
    }

    case Qt.Key_Up:
    case Qt.Key_Down: {
      if (!here) break
      var gd = here.group + (event.key === Qt.Key_Up ? -1 : 1)
      if (gd < 0 || gd >= mons.length) break
      var other = root.workspacesOn(mons[gd])
      if (other.length) root.selectedWsId = other[Math.min(here.index, other.length - 1)]
      root.pendingDelete = -1
      break
    }

    case Qt.Key_Return:
    case Qt.Key_Enter:
    case Qt.Key_Space:
      if (root.selectedWsId > 0) root.focusWorkspace(root.selectedWsId)
      break

    case Qt.Key_Delete:
    case Qt.Key_Backspace:
      root.requestDelete(root.selectedWsId)
      break

    default:
      return
    }
    event.accepted = true
  }

  // ----------------------------------------------------------- exposé grid

  // Fit the windows (client objects) into W×H: try every column count, keep
  // the one that shows the most window area, then center each row.
  function exposeLayout(wins, W, H) {
    var n = wins.length
    if (n === 0 || W <= 0 || H <= 0) return []
    var gap = 44
    var maxScale = 0.9
    var s = []
    for (var i = 0; i < n; i++) {
      var c = wins[i]
      var ok = c && c.size && c.at
      s.push({
        i: i,
        w: ok ? Math.max(120, c.size[0]) : 1200,
        h: ok ? Math.max(90, c.size[1]) : 800,
        x: ok ? c.at[0] : i * 100,
        y: ok ? c.at[1] : 0
      })
    }
    // Keep the on-screen order: left to right, top to bottom.
    s.sort(function(a, b) { return (a.y - b.y) * 0.35 + (a.x - b.x) })

    var best = null
    for (var cols = 1; cols <= n; cols++) {
      var rows = Math.ceil(n / cols)
      var cw = (W - gap * (cols - 1)) / cols
      var ch = (H - gap * (rows - 1)) / rows
      if (cw <= 0 || ch <= 0) continue
      var area = 0
      for (var j = 0; j < n; j++) {
        var sc = Math.min(cw / s[j].w, ch / s[j].h, maxScale)
        area += s[j].w * s[j].h * sc * sc
      }
      if (!best || area > best.area) best = { cols: cols, rows: rows, cw: cw, ch: ch, area: area }
    }
    if (!best) return []

    var rects = []
    var rowsOut = []
    var totalH = 0
    for (var r = 0; r < best.rows; r++) {
      var items = s.slice(r * best.cols, (r + 1) * best.cols)
      var rowW = 0, rowH = 0
      var sized = items.map(function(it) {
        var k = Math.min(best.cw / it.w, best.ch / it.h, maxScale)
        var w = it.w * k, h = it.h * k
        rowW += w
        rowH = Math.max(rowH, h)
        return { i: it.i, w: w, h: h }
      })
      rowW += gap * (sized.length - 1)
      rowsOut.push({ items: sized, w: rowW, h: rowH })
      totalH += rowH
    }
    totalH += gap * (rowsOut.length - 1)

    var y = (H - totalH) / 2
    for (var rr = 0; rr < rowsOut.length; rr++) {
      var row = rowsOut[rr]
      var x = (W - row.w) / 2
      for (var cc = 0; cc < row.items.length; cc++) {
        var it2 = row.items[cc]
        rects[it2.i] = { x: x, y: y + (row.h - it2.h) / 2, w: it2.w, h: it2.h }
        x += it2.w + gap
      }
      y += row.h + gap
    }
    return rects
  }

  // ----------------------------------------------------------------- view

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "betterlife-workspace-viewer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Item {
      id: content
      anchors.fill: parent
      focus: root.opened
      Keys.onPressed: function(event) { root.handleKey(event) }

      // Blurred, dimmed wallpaper.
      Item {
        id: backdrop
        anchors.fill: parent
        opacity: root.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

        Image {
          id: wall
          anchors.fill: parent
          source: root.wallpaper
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: 1280
          asynchronous: true
          visible: false
        }

        MultiEffect {
          anchors.fill: parent
          source: wall
          blurEnabled: true
          blur: 1.0
          blurMax: 64
          saturation: -0.15
        }

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(0, 0, 0, 0.38)
        }

        // Click on empty space closes.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: {
            if (root.pendingDelete !== -1) root.pendingDelete = -1
            else root.close()
          }
        }
      }

      // ------------------------------------------------------ Spaces bar
      Item {
        id: bar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 30
        height: 28 + cardH + 30

        readonly property real sidePad: 56
        readonly property real groupSpacing: 26
        readonly property real swapW: 34
        readonly property real maxCardH: Math.min(168, content.height * 0.15)
        readonly property real trashSize: Math.round(Math.max(32, cardH * 0.3))

        // Card height that fits every display's desktops (plus room for the
        // gap a drag opens) into the width.
        property real cardH: {
          var mons = root.monitorsList
          // Trash size from the max card height: using the live one would loop.
          var avail = width - 2 * sidePad - (Math.round(Math.max(32, maxCardH * 0.3)) + 40) - (mons.length - 1) * (2 * groupSpacing + swapW)
          var lin = 0, fixed = 0, maxAsp = 0
          for (var i = 0; i < mons.length; i++) {
            var g = root.monGeom(mons[i])
            var asp = g.w / Math.max(1, g.h)
            var n = root.workspacesOn(mons[i]).length
            lin += n * asp + 0.46
            fixed += n * 18
            maxAsp = Math.max(maxAsp, asp)
          }
          lin += maxAsp
          fixed += 18
          var h = (avail - fixed) / Math.max(0.1, lin)
          return Math.max(54, Math.min(maxCardH, h))
        }
        Behavior on cardH { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        opacity: root.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        transform: Translate {
          y: root.shown ? 0 : -36
          Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }

        Row {
          id: groupsRow
          x: bar.sidePad + Math.max(0, (bar.width - 2 * bar.sidePad - (bar.trashSize + 40) - width) / 2)
          spacing: bar.groupSpacing

          Repeater {
            id: groupRepeater
            model: root.opened ? root.monitorsList : []

            delegate: Row {
              id: holder
              required property var modelData
              required property int index
              property alias group: grp
              spacing: bar.groupSpacing

              // Swap what the two displays show.
              Item {
                visible: holder.index > 0
                width: bar.swapW
                height: grp.height

                Rectangle {
                  id: swapBtn
                  y: grp.headerH + bar.cardH / 2 - height / 2
                  width: bar.swapW
                  height: bar.swapW
                  radius: width / 2
                  color: Qt.rgba(1, 1, 1, swapMouse.containsMouse ? 0.2 : 0.08)
                  border.color: Qt.rgba(1, 1, 1, 0.16)
                  border.width: 1
                  scale: swapMouse.pressed ? 0.9 : (swapMouse.containsMouse ? 1.1 : 1)
                  Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                  Behavior on color { ColorAnimation { duration: 120 } }

                  Text {
                    anchors.centerIn: parent
                    text: "⇄"
                    color: "white"
                    font.family: root.uiFont
                    font.pixelSize: 17
                  }

                  MouseArea {
                    id: swapMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(m) {
                      root.notePointer(mapToItem(content, m.x, m.y))
                      var prev = groupRepeater.itemAt(holder.index - 1)
                      if (prev) root.swapShown(prev.group.monName, grp.monName)
                    }
                  }
                }

                Text {
                  anchors.top: swapBtn.bottom
                  anchors.topMargin: 6
                  anchors.horizontalCenter: swapBtn.horizontalCenter
                  text: "Tauschen"
                  color: Qt.rgba(1, 1, 1, swapMouse.containsMouse ? 0.8 : 0)
                  font.family: root.uiFont
                  font.pixelSize: 11
                  Behavior on color { ColorAnimation { duration: 120 } }
                }
              }

              DisplayGroup {
                id: grp
                viewer: root
                monName: holder.modelData
                cardH: bar.cardH
              }
            }
          }
        }

        Trash {
          id: trash
          viewer: root
          size: bar.trashSize
          anchors.right: parent.right
          anchors.rightMargin: bar.sidePad
          y: 28 + (bar.cardH - size) / 2
        }
      }

      // ---------------------------------------------------------- exposé
      Item {
        id: expose
        anchors.top: bar.bottom
        anchors.topMargin: 44
        anchors.bottom: hint.top
        // Room for the title pill a hovered window shows underneath itself.
        anchors.bottomMargin: 68
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 90
        anchors.rightMargin: 90

        // Windows of the selected desktop (what will be there, while a move
        // is going out).
        readonly property var addrs: root.winsOf(root.contentAt(root.selectedWsId))
        readonly property var wins: addrs.map(function(a) { return root.clientByAddr[a] })
        readonly property var rects: root.exposeLayout(wins, width, height)
        // Only the desktop the host screen is showing can zoom out of its
        // real window positions.
        readonly property bool onHost: root.selectedWsId > 0 && root.monitorOf(root.selectedWsId) === root.hostMon
          && root.activeOn(root.hostMon) === root.selectedWsId && root.pending === null

        function realRect(addr) {
          var c = root.clientByAddr[addr]
          if (!onHost || !c || !c.at || !c.size) return null
          var g = root.monGeom(root.hostMon)
          return { x: c.at[0] - g.x - expose.x, y: c.at[1] - g.y - expose.y, w: c.size[0], h: c.size[1] }
        }

        Repeater {
          model: expose.addrs
          delegate: WindowTile {
            required property string modelData
            required property int index
            viewer: root
            addr: modelData
            targetRect: expose.rects[index] || null
            realRect: expose.realRect(modelData)
          }
        }

        Column {
          anchors.centerIn: parent
          spacing: 8
          opacity: expose.wins.length === 0 && root.shown ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 200 } }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Leerer Schreibtisch"
            color: Qt.rgba(1, 1, 1, 0.7)
            font.family: root.uiFont
            font.pixelSize: 20
            font.weight: Font.Medium
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Klicke oben auf den Schreibtisch, um zu ihm zu wechseln"
            color: Qt.rgba(1, 1, 1, 0.45)
            font.family: root.uiFont
            font.pixelSize: 13
          }
        }
      }

      Text {
        id: hint
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        anchors.horizontalCenter: parent.horizontalCenter
        opacity: root.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 300 } }
        text: "←→ Schreibtisch   ↑↓ Display   ⏎ Öffnen   ⇧←→ Verschieben   ⌫ Schließen   esc"
        color: Qt.rgba(1, 1, 1, 0.38)
        font.family: root.uiFont
        font.pixelSize: 12
        font.wordSpacing: 2
      }

      // ------------------------------------------------ what's being dragged
      Item {
        id: ghost
        visible: root.dragKind !== ""
        z: 1000

        readonly property bool overBar: root.dragPos.y < expose.y - 12
        readonly property real k: root.dropKind === "trash" ? Math.min(0.5, 70 / Math.max(1, root.dragH))
          : (root.dragKind === "win" && overBar ? Math.min(1, bar.cardH * 1.15 / Math.max(1, root.dragH)) : 1)

        width: root.dragW * k
        height: root.dragH * k
        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        x: root.dragPos.x - root.dragGrab.x * width
        y: root.dragPos.y - root.dragGrab.y * height
        opacity: root.dropKind === "trash" ? 0.75 : 1
        Behavior on opacity { NumberAnimation { duration: 140 } }

        RectangularShadow {
          anchors.fill: parent
          radius: 12
          blur: 36
          offset.y: 16
          color: Qt.rgba(0, 0, 0, 0.55)
        }

        SpaceFace {
          anchors.fill: parent
          visible: root.dragKind === "ws"
          viewer: root
          wsId: root.dragKind === "ws" ? root.dragWsId : -1
          geom: root.monGeom(root.monitorOf(wsId))
          radius: 10
        }

        Rounded {
          anchors.fill: parent
          visible: root.dragKind === "win"
          radius: 12

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0.08, 0.08, 0.09, 0.9)
          }
          ScreencopyView {
            anchors.fill: parent
            captureSource: root.dragKind === "win" ? root.waylandOf(root.dragAddr) : null
            live: true
          }
        }

        Rectangle {
          anchors.fill: parent
          anchors.margins: -3
          radius: 14
          color: "transparent"
          border.width: 2
          border.color: Qt.rgba(1, 1, 1, 0.85)
        }
      }
    }
  }
}
