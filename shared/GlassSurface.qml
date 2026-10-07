import QtQuick
import qs.Commons

// Shared card surface for the dock, its settings menu and the app switcher.
// Every color comes from the active Omarchy theme (Color/Style singletons),
// so theme switches restyle it automatically.
//
//   glass    neutral frosted glass with a faint top sheen
//   tinted   glass tinted with the theme accent
//   minimal  barely-there surface, stays out of the way
//   solid    exactly Omarchy's popup surface (like menu/notifications)
//
// `boost` adds opacity for surfaces that carry text (the settings menu), so
// they stay readable over busy windows when compositor blur is off.
Item {
  id: root

  property string variant: "glass"
  property real radius: 16
  property real boost: 0

  readonly property bool solid: variant === "solid"
  readonly property real effectiveRadius: solid ? Style.cornerRadius : radius

  readonly property color fillColor: {
    switch (variant) {
    case "tinted": return Util.alpha(Qt.tint(Color.background, Util.alpha(Color.accent, 0.22)), Math.min(1, 0.55 + boost))
    case "minimal": return Util.alpha(Color.background, Math.min(1, 0.2 + boost))
    case "solid": return Color.popups.background
    default: return Util.alpha(Color.background, Math.min(1, 0.45 + boost))
    }
  }

  readonly property color edgeColor: {
    switch (variant) {
    case "tinted": return Util.alpha(Color.accent, 0.32)
    case "minimal": return Util.alpha(Color.foreground, 0.07)
    case "solid": return Color.popups.border
    default: return Util.alpha(Color.foreground, 0.13)
    }
  }

  // Thin dark outer ring: separates the glass from light wallpapers/windows
  // without a heavy drop shadow.
  Rectangle {
    visible: root.variant === "glass" || root.variant === "tinted"
    anchors.fill: parent
    anchors.margins: -1
    radius: root.effectiveRadius + 1
    color: "transparent"
    border.color: Qt.rgba(0, 0, 0, 0.22)
    border.width: 1
  }

  Rectangle {
    id: body
    anchors.fill: parent
    radius: root.effectiveRadius
    color: root.fillColor
    border.color: root.edgeColor
    border.width: root.solid ? Math.max(1, Style.space(2)) : 1

    Behavior on color { ColorAnimation { duration: 160 } }
  }

  // Top sheen, the "glass" highlight.
  Rectangle {
    visible: root.variant === "glass" || root.variant === "tinted"
    anchors.fill: parent
    anchors.margins: 1
    radius: Math.max(0, root.effectiveRadius - 1)
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, root.variant === "glass" ? 0.09 : 0.07) }
      GradientStop { position: 0.45; color: Qt.rgba(1, 1, 1, 0) }
    }
  }
}
