import QtQuick
import Quickshell
import Quickshell.Io

// Always-loaded host for the BetterLife modules that live outside the bar:
// the dock, the Super+Tab app switcher and the workspace viewer. Each one is
// self-contained in modules/<name>/ and brings its own windows and IPC target.
//
// setup.sh picks the modules and writes ~/.local/state/omarchy/settings/betterlife.json:
//   { "modules": { "dock": false } }
// Anything not listed there stays on.
Item {
  id: root

  property var enabledModules: ({})

  function moduleOn(name) {
    return root.enabledModules[name] !== false
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/betterlife.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        root.enabledModules = data && typeof data.modules === "object" && data.modules ? data.modules : {}
      } catch (e) {
        root.enabledModules = {}
      }
    }
    onLoadFailed: root.enabledModules = {}
    onFileChanged: reload()
  }

  Loader {
    active: root.moduleOn("dock")
    source: "modules/dock/Dock.qml"
  }

  Loader {
    active: root.moduleOn("appSwitcher")
    source: "modules/app-switcher/AppSwitcher.qml"
  }

  Loader {
    active: root.moduleOn("workspaceViewer")
    source: "modules/workspace-viewer/WorkspaceViewer.qml"
  }
}
