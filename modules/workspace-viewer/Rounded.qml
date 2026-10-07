import QtQuick
import QtQuick.Effects

// Clips its children to a rounded rectangle (real per-pixel rounding, not
// the square `clip` of a Rectangle).
Item {
  id: rounded

  property real radius: 10
  default property alias content: inner.data

  Item {
    id: inner
    anchors.fill: parent
    layer.enabled: true
    layer.smooth: true
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: mask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
    }
  }

  Item {
    id: mask
    anchors.fill: parent
    visible: false
    layer.enabled: true
    layer.smooth: true

    Rectangle {
      anchors.fill: parent
      radius: rounded.radius
      antialiasing: true
      color: "black"
    }
  }
}
