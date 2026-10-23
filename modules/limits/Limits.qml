import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "betterlife.limits"
  ipcTarget: "betterlife.limits"
  manageIpc: false

  // The BetterLife bar wrapper this panel sits in. The bar only knows the
  // wrapper, so switching to a neighbouring popout has to start from it.
  property Item host: null
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(root.host || root, direction)
    return false
  }

  property var snapshot: ({ ok: false, agents: [] })
  property string selectedId: "grok"
  property bool cursorActive: false
  property double nowMs: Date.now()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 120)), 10)
    if (!isFinite(n)) n = 120
    return Math.max(30, Math.min(3600, n))
  }
  readonly property bool lightSurface: colorLuminance(surface) >= 0.5
  readonly property var agents: snapshot.agents || []
  readonly property int agentIndex: {
    for (var i = 0; i < agents.length; i++)
      if (agents[i] && agents[i].id === selectedId) return i
    return 0
  }
  readonly property var agent: agents.length > 0 ? agents[agentIndex] : null
  readonly property var days: agent && agent.days ? agent.days : []
  readonly property var limits: agent && agent.limits ? agent.limits : []
  readonly property int peakDayTokens: {
    var peak = 1
    for (var i = 0; i < days.length; i++)
      peak = Math.max(peak, Number(days[i].tokens) || 0)
    return peak
  }
  readonly property bool alarming: {
    for (var i = 0; i < agents.length; i++) {
      var list = agents[i] && agents[i].limits ? agents[i].limits : []
      for (var j = 0; j < list.length; j++)
        if (Number(list[j].percent) >= 0.9) return true
    }
    return false
  }
  readonly property url markUrl: markUrlFor(agent ? agent.id : "grok")
  readonly property var bindingLimit: {
    if (!limits || limits.length === 0) return null
    var best = null
    for (var i = 0; i < limits.length; i++) {
      var title = String(limits[i].title || limits[i].label || "").toLowerCase()
      if (title.indexOf("week") >= 0 || title.indexOf("month") >= 0)
        return limits[i]
      if (!best || Number(limits[i].percent) > Number(best.percent)) best = limits[i]
    }
    return best
  }
  readonly property string barLimitText: {
    if (!bindingLimit || Number(bindingLimit.percent) < 0) return ""
    return Math.round(Number(bindingLimit.percent) * 100) + "%"
  }
  readonly property string heroTitle: {
    if (!agent) return "Limits"
    return agent.title || agent.name || "Limits"
  }
  readonly property string heroMeta: {
    if (!agent) return ""
    if (String(agent.usageStatusText || "") !== "") return agent.usageStatusText
    if (!agent.authenticated) return agent.authHint || ""
    var plan = agent.plan ? agent.plan : agent.name
    if (bindingLimit && Number(bindingLimit.percent) >= 0)
      return plan + " · " + Math.round(Number(bindingLimit.percent) * 100) + "% used"
    return plan + " · " + formatTokens(agent.weekTokens) + " this week"
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function colorChannelLuminance(channel) {
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  function formatTokens(value) {
    var n = Number(value) || 0
    if (n >= 1000000) return (n / 1000000).toFixed(n >= 10000000 ? 0 : 1) + "M"
    if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k"
    return String(Math.round(n))
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var daysLeft = Math.floor(hours / 24)
    if (daysLeft > 0) return daysLeft + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  function resetMsFor(window) {
    if (!window || !window.resetsAt) return -1
    var ms = new Date(window.resetsAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function limitTitle(entry) {
    if (!entry) return "Limit"
    if (String(entry.title || "") !== "") return entry.title
    var text = String(entry.label || "").toLowerCase()
    if (text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0) return "Weekly"
    if (text.indexOf("month") >= 0) return "Monthly"
    if (text.indexOf("session") >= 0 || text.indexOf("hour") >= 0 || text.indexOf("window") >= 0)
      return "Session"
    var plain = String(entry.label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  function markUrlFor(id) {
    if (id === "claude") return Qt.resolvedUrl("../../shared/assets/claude.svg")
    if (id === "codex")
      return Qt.resolvedUrl(root.lightSurface ? "../../shared/assets/codex-light.svg" : "../../shared/assets/codex.svg")
    return Qt.resolvedUrl(root.lightSurface ? "../../shared/assets/grok-light.svg" : "../../shared/assets/grok.svg")
  }

  function collectPath() {
    var url = Qt.resolvedUrl("collect.py").toString()
    if (url.indexOf("file://") === 0) url = decodeURIComponent(url.substring(7))
    return url
  }

  function selectAgent(index) {
    if (agents.length === 0) return
    var wrapped = ((index % agents.length) + agents.length) % agents.length
    selectedId = agents[wrapped].id
  }

  function refreshNow() {
    if (collectProcess.running) return
    collectProcess.command = ["/usr/bin/python3", collectPath()]
    collectProcess.running = true
  }

  function applyCollect(text) {
    try {
      var parsed = JSON.parse(String(text || "").trim())
      if (parsed && parsed.ok && parsed.agents) snapshot = parsed
    } catch (e) {
      console.warn("betterlife.limits", e)
    }
  }

  function launchCommand(id) {
    var home = Quickshell.env("HOME") || ""
    var prefix = "[ -d " + "'" + home + "/Work' ] && cd " + "'" + home + "/Work'; "
    if (id === "claude")
      return prefix + "omarchy-launch-tui --app-id=org.omarchy.agent claude --permission-mode auto"
    if (id === "codex")
      return prefix + "omarchy-launch-tui --app-id=org.omarchy.agent codex --approve-for-me"
    if (id === "grok")
      return prefix + "omarchy-launch-tui --app-id=org.omarchy.agent grok --permission-mode bypassPermissions"
    return "omarchy-agent"
  }

  function launchAgent() {
    var id = agent ? agent.id : "grok"
    if (root.bar) root.bar.run(root.launchCommand(id))
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refreshNow()
  onAgentIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    refreshNow()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refreshNow()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: collectProcess
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("betterlife.limits", "collect exited", exitCode)
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCollect(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("betterlife.limits", text.trim())
    }
  }

  IpcHandler {
    enabled: true
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectAgent(root.agentIndex + 1); return "ok" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.alarming
    fontSize: Style.font.caption
    horizontalMargin: 7
    text: {
      var glyph = root.agent && root.agent.id === "claude" ? "✶"
        : (root.agent && root.agent.id === "codex" ? "⌬" : "✦")
      return root.barLimitText !== "" ? glyph + " " + root.barLimitText : glyph
    }
    tooltipText: root.heroTitle + (root.heroMeta ? " · " + root.heroMeta : "")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectAgent(root.agentIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectAgent(root.agentIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (t === "a" || t === "A") root.launchAgent()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            visible: !!root.agent
            width: parent.width
            title: root.heroTitle
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Image {
                source: root.markUrl
                sourceSize.width: Style.font.display
                sourceSize.height: Style.font.display
                width: Style.font.display
                height: Style.font.display
                fillMode: Image.PreserveAspectFit
                smooth: true
              }
            }
          }

          Row {
            id: agentSwitch
            visible: root.agents.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.agents.length > 0
              ? (width - spacing * (root.agents.length - 1)) / root.agents.length
              : 0

            Repeater {
              model: root.agents

              Button {
                required property var modelData
                required property int index

                width: agentSwitch.cellWidth
                text: modelData && modelData.id === "claude" ? "Claude"
                  : (modelData && modelData.name ? modelData.name : "")
                selected: index === root.agentIndex
                hasCursor: root.cursorActive && index === root.agentIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectAgent(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          BorderSurface {
            visible: !!root.agent && String(root.agent.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.agent ? String(root.agent.authHint || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits
              delegate: LimitRow {
                width: column.width
                window: modelData
              }
            }
          }

          Column {
            visible: !!root.agent
            width: parent.width
            spacing: Style.space(8)

            MeterBlock {
              width: parent.width
              title: "Today"
              valueText: root.formatTokens(root.agent ? root.agent.todayTokens : 0)
              ratio: root.peakDayTokens > 0 && root.agent
                ? root.agent.todayTokens / root.peakDayTokens : 0
            }

            MeterBlock {
              width: parent.width
              title: "This week"
              valueText: root.formatTokens(root.agent ? root.agent.weekTokens : 0)
                + " · " + (root.agent ? root.agent.sessionCount : 0) + " sessions"
              ratio: root.agent && root.agent.weekTokens > 0 ? 1 : 0
            }
          }

          Column {
            visible: root.days.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.days
              delegate: DayRow {
                width: column.width
                day: modelData
                ratio: root.peakDayTokens > 0 ? (Number(modelData.tokens) || 0) / root.peakDayTokens : 0
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            text: root.agent
              ? "Right-click the icon to launch " + (root.agent.id === "claude" ? "Claude" : root.agent.name)
              : "Right-click the icon to launch an agent"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component LimitRow: Column {
    id: limitRow
    property var window: null
    readonly property bool alarming: window && Number(window.percent) >= 0.9
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        text: root.limitTitle(limitRow.window)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && Number(limitRow.window.percent) >= 0
          ? Math.round(Number(limitRow.window.percent) * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? Number(limitRow.window.percent) : 0
      alarming: limitRow.alarming
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: text !== ""
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component MeterBlock: Column {
    id: block
    property string title: ""
    property string valueText: ""
    property real ratio: 0
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(label.implicitHeight, value.implicitHeight)

      Text {
        id: label
        textFormat: Text.PlainText
        text: block.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.left: parent.left
        anchors.right: value.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
      }

      Text {
        id: value
        textFormat: Text.PlainText
        text: block.valueText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: block.ratio
    }
  }

  component Meter: Item {
    id: meter
    property real value: 0
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground
      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: dayRow.day ? dayRow.day.label : ""
      color: dayRow.day && dayRow.day.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: !!(dayRow.day && dayRow.day.today)
      width: Style.space(36)
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Meter {
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      value: dayRow.ratio
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: root.formatTokens(dayRow.day ? dayRow.day.tokens : 0)
      color: dayRow.day && dayRow.day.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
