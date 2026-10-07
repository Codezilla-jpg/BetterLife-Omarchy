import QtQuick
import qs.Commons
import qs.Ui

// The one bar widget this plugin can register. Omarchy gives a plugin a single
// bar-widget entry point, so the actual widgets live in modules/ and this
// wrapper loads the one picked by the "module" setting. Place it once per
// module, e.g. { "id": "codezilla.betterlife", "module": "limits" }.
//
// The bar talks to its widgets directly (size, popout panels), so whatever it
// looks for is passed through to the loaded module.
BarWidget {
  id: root

  readonly property string module: String(root.setting("module", "workspaces"))
  readonly property var sources: ({
    "workspaces": "modules/workspaces/Workspaces.qml",
    "limits": "modules/limits/Limits.qml"
  })

  readonly property Item inner: loader.status === Loader.Ready ? loader.item : null

  implicitWidth: inner ? inner.implicitWidth : 0
  implicitHeight: inner ? inner.implicitHeight : 0

  // Popout panel contract. `opened` stays undefined for modules that are not
  // panels, which is how the bar tells panels from plain widgets.
  readonly property var opened: inner && inner.opened !== undefined ? inner.opened : undefined
  readonly property bool tooltipHovered: !!inner && inner.tooltipHovered === true
  function open() { if (inner && typeof inner.open === "function") inner.open() }
  function close() { if (inner && typeof inner.close === "function") inner.close() }
  function toggle() { if (inner && typeof inner.toggle === "function") inner.toggle() }
  function closeForPopoutSwitch() {
    if (inner && typeof inner.closeForPopoutSwitch === "function") inner.closeForPopoutSwitch()
  }

  Loader {
    id: loader
    anchors.fill: parent
    source: root.sources[root.module] || ""
    onLoaded: if ("host" in item) item.host = root
    onStatusChanged: if (status === Loader.Error) console.warn("BetterLife: unknown bar module", root.module)
  }

  // Inject what the bar would have injected, and keep it current.
  Binding { target: root.inner; property: "bar"; value: root.bar; when: root.inner !== null }
  Binding { target: root.inner; property: "moduleName"; value: root.moduleName; when: root.inner !== null }
  Binding { target: root.inner; property: "settings"; value: root.settings; when: root.inner !== null }
}
