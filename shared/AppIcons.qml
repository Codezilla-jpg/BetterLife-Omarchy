import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons

// Resolves a Wayland app_id (window class) to an icon the same way Omarchy's
// own AppLibrary (shell/services/AppLibrary.qml) resolves launcher icons:
// desktop entry Icon= → app/device icon index → themed lookup. Panel plugins
// don't get the shell's appLibrary injected (only `menu` plugins do), so the
// index scan is mirrored here. Returns "" when nothing matches; AppIcon then
// draws a theme-colored monogram instead of the grey generic icon.
//
// Some windows carry a class no app declares, typically a terminal started
// with its own class to run one program (Omarchy's agents are
// `kitty --class org.omarchy.agent -- claude`). For those the window's address
// leads to what actually runs in it, and that program's icon is used, then the
// terminal's, before falling back to the monogram.
Item {
  id: root
  visible: false

  property var iconIndex: ({})
  property var pendingIconIndex: ({})

  // "0x…" window address -> { cls, args: [...], children: [[...], ...] }: the
  // window's class, and the command line of its process and of its direct
  // children.
  property var windowProcs: ({})
  property var pendingWindowProcs: ({})

  // Agents whose marks ship with the plugin; dark/light pick like Limits.
  readonly property var bundledMarks: ({ claude: "claude", codex: "codex", grok: "grok" })
  readonly property bool lightTheme:
    0.299 * Color.background.r + 0.587 * Color.background.g + 0.114 * Color.background.b >= 0.5

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

  function entryIcon(entry) {
    return entry && entry.icon ? lookupName(String(entry.icon), true) : ""
  }

  // address is optional ("0x…" or bare hex); it only matters for classes no
  // desktop entry claims. Without one, any open window of the class is used.
  function sourceFor(appId, address) {
    var entry = entryFor(appId)
    var fromEntry = entryIcon(entry)
    if (fromEntry) return fromEntry
    if (!entry) {
      var fromProcess = processIcon(appId, address)
      if (fromProcess) return fromProcess
    }
    var raw = String(appId || "")
    return lookupName(raw, true) || lookupName(norm(raw), true) || lookupName(lastSegment(raw), false)
  }

  function nameFor(appId, address) {
    var entry = entryFor(appId)
    if (entry && entry.name) return String(entry.name)
    var s = entry ? "" : programFor(appId, address)
    if (s.length === 0) s = lastSegment(appId)
    return s.length > 0 ? s.charAt(0).toUpperCase() + s.slice(1) : "?"
  }

  // ------------------------------------------------- program in the window

  function baseName(path) {
    var s = String(path || "")
    return s.slice(s.lastIndexOf("/") + 1)
  }

  function procFor(appId, address) {
    var addr = String(address || "")
    if (addr.length > 0) {
      if (addr.indexOf("0x") !== 0) addr = "0x" + addr
      if (root.windowProcs[addr]) return root.windowProcs[addr]
    }
    var cls = String(appId || "")
    for (var key in root.windowProcs) {
      if (root.windowProcs[key].cls === cls) return root.windowProcs[key]
    }
    return null
  }

  // What runs in the window: the command after "--" or "-e" (how terminals
  // are told what to run), else the first child that isn't a shell.
  // Interpreters are skipped, so `node …/claude` still reads as claude.
  function programFor(appId, address) {
    var proc = procFor(appId, address)
    if (!proc) return ""
    var args = proc.args
    var cmd = null
    var at = args.indexOf("--")
    if (at < 0) at = args.indexOf("-e")
    if (at >= 0 && at + 1 < args.length) cmd = args.slice(at + 1)
    if (!cmd) {
      for (var i = 0; i < proc.children.length; i++) {
        var child = proc.children[i]
        if (child.length && !/^(-?(ba|z|fi|da)?sh|kitten)$/.test(baseName(child[0]))) { cmd = child; break }
      }
    }
    if (!cmd || cmd.length === 0) return ""
    var name = baseName(cmd[0])
    if (/^(node|bun|deno|python[0-9.]*|env|uv|uvx|npx)$/.test(name) && cmd.length > 1) name = baseName(cmd[1])
    return name.toLowerCase()
  }

  function processIcon(appId, address) {
    var program = programFor(appId, address)
    if (program.length > 0) {
      var mark = root.bundledMarks[program]
      if (mark) {
        var variant = root.lightTheme && mark !== "claude" ? mark + "-light" : mark
        return Qt.resolvedUrl("assets/" + variant + ".svg")
      }
      var found = root.iconIndex["__agent:" + program]
      if (found) return Util.fileUrl(found)
      var fromEntry = entryIcon(entryFor(program))
      if (fromEntry) return fromEntry
      var themed = lookupName(program, false)
      if (themed) return themed
    }
    // Nothing for the program itself: show the terminal it runs in.
    var proc = procFor(appId, address)
    return proc && proc.args.length ? entryIcon(entryFor(baseName(proc.args[0]))) : ""
  }

  function indexWindowLine(line) {
    var parts = String(line).split("\t")
    if (parts.length < 3 || parts[0].indexOf("0x") !== 0) return
    var split = function(cmdline) {
      return cmdline.split("\u001f").filter(function(arg) { return arg.length > 0 })
    }
    var children = (parts[3] || "").split("\u001e").map(split).filter(function(c) { return c.length > 0 })
    root.pendingWindowProcs[parts[0]] = { cls: parts[1], args: split(parts[2]), children: children }
  }

  // One line per window: address, class, its command line, its children's
  // command lines (args split by \x1f, children by \x1e).
  Process {
    id: windowScan
    property bool again: false
    command: ["bash", "-c", [
      'hyprctl -j clients | jq -r \'.[] | [.address, (.pid | tostring), .class] | @tsv\' | while IFS=$\'\\t\' read -r addr pid cls; do',
      '  printf "%s\\t%s\\t" "$addr" "$cls";',
      '  tr "\\0" "\\037" <"/proc/$pid/cmdline" 2>/dev/null;',
      '  printf "\\t";',
      '  for child in $(cat /proc/$pid/task/*/children 2>/dev/null); do',
      '    tr "\\0" "\\037" <"/proc/$child/cmdline" 2>/dev/null; printf "\\036";',
      '  done;',
      '  echo;',
      'done'
    ].join(' ')]
    stdout: SplitParser { onRead: function(line) { root.indexWindowLine(line) } }
    onStarted: root.pendingWindowProcs = ({})
    onExited: {
      root.windowProcs = root.pendingWindowProcs
      if (again) { again = false; running = true }
    }
  }

  function refreshWindows() {
    if (windowScan.running) windowScan.again = true
    else windowScan.running = true
  }

  Timer {
    id: windowScanDebounce
    interval: 300
    onTriggered: root.refreshWindows()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event.name
      if (name === "openwindow" || name === "closewindow" || name === "windowtitlev2")
        windowScanDebounce.restart()
    }
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
    if (value.indexOf("__agent:") === 0) {
      // Omarchy's own agent marks, kept apart from the icon theme's names.
      value = value.slice(8)
      root.pendingIconIndex["__agent:" + baseName(value).replace(/\.svg$/, "")] = value
      return
    }
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
      'done;',
      'for f in "${OMARCHY_PATH:-/usr/share/omarchy}"/shell/plugins/agents/assets/*.svg; do',
      '  [[ -f $f ]] && printf "__agent:%s\\n" "$f";',
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

  Component.onCompleted: {
    refreshIcons()
    refreshWindows()
  }
}
