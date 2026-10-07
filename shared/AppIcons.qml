import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Resolves a Wayland app_id (window class) to an icon the same way Omarchy's
// own AppLibrary (shell/services/AppLibrary.qml) resolves launcher icons:
// desktop entry Icon= → app/device icon index → themed lookup. Panel plugins
// don't get the shell's appLibrary injected (only `menu` plugins do), so the
// index scan is mirrored here. Returns "" when nothing matches; AppIcon then
// draws a theme-colored monogram instead of the grey generic icon.
Item {
  id: root
  visible: false

  property var iconIndex: ({})
  property var pendingIconIndex: ({})

  function norm(value) {
    return String(value || "").toLowerCase().replace(/\.desktop$/, "")
  }

  function lastSegment(value) {
    var s = norm(value)
    var i = s.lastIndexOf(".")
    return i >= 0 ? s.slice(i + 1) : s
  }

  // Chromium --app windows (Omarchy web apps) get classes like
  // "brave-app.hey.com__-Default" that no desktop entry declares.
  function isWebAppClass(id) {
    return id.indexOf("__") !== -1 || /^(brave|chrome|chromium|vivaldi|msedge)-/.test(id)
  }

  function entryFor(appId) {
    var id = norm(appId)
    if (id.length === 0) return null
    var apps = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    var seg = lastSegment(id)
    var bySegment = null
    var partial = null
    var byName = null
    var webApp = isWebAppClass(id)

    for (var i = 0; i < apps.length; i++) {
      var e = apps[i]
      var eid = norm(e.id)
      var startup = norm(e.startupClass)
      if (eid === id || startup === id) return e

      if (!bySegment && id.indexOf(".") !== -1 && seg.length >= 3 && lastSegment(eid) === seg) bySegment = e

      if (!partial && id.length >= 4) {
        if ((eid.length >= 4 && (eid.indexOf(id) !== -1 || id.indexOf(eid) !== -1))
            || (startup.length >= 4 && (startup.indexOf(id) !== -1 || id.indexOf(startup) !== -1)))
          partial = e
      }

      if (!byName && webApp) {
        var name = norm(e.name).replace(/\s+/g, "")
        if (name.length >= 2 && id.indexOf(name) !== -1) byName = e
      }
    }
    return bySegment || partial || byName
  }

  // allowThemed=false restricts to the app/device index, so a bare word like
  // "agent" can't resolve to an unrelated action icon from the theme.
  function lookupName(name, allowThemed) {
    var value = String(name || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var found = root.iconIndex[value] || root.iconIndex[value.toLowerCase()]
    if (found) return Util.fileUrl(found)
    if (!allowThemed) return ""
    var themed = Quickshell.iconPath(value, true)
    return (themed && themed.length > 0) ? themed : ""
  }

  function sourceFor(appId) {
    var entry = entryFor(appId)
    if (entry && entry.icon) {
      var fromEntry = lookupName(String(entry.icon), true)
      if (fromEntry) return fromEntry
    }
    var raw = String(appId || "")
    return lookupName(raw, true) || lookupName(norm(raw), true) || lookupName(lastSegment(raw), false)
  }

  function nameFor(appId) {
    var entry = entryFor(appId)
    if (entry && entry.name) return String(entry.name)
    var s = lastSegment(appId)
    return s.length > 0 ? s.charAt(0).toUpperCase() + s.slice(1) : "?"
  }

  function refreshIcons() {
    if (!iconIndexScan.running) iconIndexScan.running = true
  }

  // Pixel size encoded in a hicolor-style path ("…/256x256/apps/…"); 0 when
  // the path carries none (pixmaps, flat dirs).
  function pngSize(path) {
    var m = String(path).match(/\/(\d+)x\d+(?:@\d+)?\//)
    return m ? Number(m[1]) : 0
  }

  // SVGs are listed first and always win. Among PNGs keep the largest size:
  // the first PNG `find` happens to hit is often a 16x16 one (e.g. steam),
  // which looks blurry at dock sizes.
  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length === 0) return
    var existing = root.pendingIconIndex[name]
    if (existing === undefined) {
      root.pendingIconIndex[name] = value
    } else if (/\.png$/.test(existing) && /\.png$/.test(value) && pngSize(value) > pngSize(existing)) {
      root.pendingIconIndex[name] = value
    }
  }

  // Same scan as AppLibrary.iconIndexScanCommand(): app/device icons across
  // the XDG icon dirs plus /usr/share/pixmaps, SVGs first so they win.
  Process {
    id: iconIndexScan
    command: ["bash", "-c", [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root.pendingIconIndex = ({})
    onExited: root.iconIndex = root.pendingIconIndex
  }

  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: root.refreshIcons()
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { iconIndexDebounce.restart() }
  }

  Component.onCompleted: refreshIcons()
}
