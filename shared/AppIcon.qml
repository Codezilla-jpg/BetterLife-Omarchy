import QtQuick
import qs.Commons

// One app icon. Falls back to a monogram tile in the theme's accent color
// when AppIcons can't resolve anything, so no app ever shows a blank or
// generic grey placeholder.
Item {
  id: root

  property var icons: null
  property string appId: ""
  // Hyprland address of one window of this app ("0x…"); lets AppIcons look at
  // what runs in a window whose class no app declares. Optional.
  property string address: ""
  property real size: 48

  readonly property string source: icons ? icons.sourceFor(appId, address) : ""
  readonly property bool showMonogram: source.length === 0 || image.status === Image.Error

  width: size
  height: size

  Image {
    id: image
    anchors.fill: parent
    source: root.source
    sourceSize.width: Math.round(root.size * 2)
    sourceSize.height: Math.round(root.size * 2)
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    asynchronous: true
    visible: status === Image.Ready
  }

  Rectangle {
    visible: root.showMonogram
    anchors.fill: parent
    anchors.margins: Math.round(root.size * 0.06)
    radius: width * 0.28
    color: Util.alpha(Color.accent, 0.22)
    border.color: Util.alpha(Color.accent, 0.45)
    border.width: 1

    Text {
      anchors.centerIn: parent
      text: root.icons ? root.icons.nameFor(root.appId, root.address).charAt(0).toUpperCase() : "?"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Math.max(8, Math.round(root.size * 0.44))
      font.weight: Font.DemiBold
    }
  }
}
