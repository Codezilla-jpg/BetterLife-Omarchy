import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "../../shared"

// Settings popup for the dock, opened by clicking the edge handle (or
// right-clicking the dock). Every control writes straight to the dock's
// properties, so changes preview live; the dock persists them itself.
PopupWindow {
  id: root

  required property var dock
  required property var anchorWindow

  property bool open: false
  property string tab: "position"

  readonly property int pad: Style.spacing.popupPadding
  readonly property int menuWidth: Style.space(320)
  readonly property var origin: dock.menuOrigin(implicitWidth, implicitHeight)

  function toggle() { open = !open }
  function close() { open = false }

  visible: open
  color: "transparent"
  implicitWidth: menuWidth
  implicitHeight: Math.ceil(content.implicitHeight + pad * 2)

  HyprlandFocusGrab {
    active: root.open
    windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
    onCleared: root.close()
  }

  anchor {
    window: root.anchorWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.x: Math.round(root.origin.x)
    rect.y: Math.round(root.origin.y)
    rect.width: 1
    rect.height: 1
  }

  GlassSurface {
    anchors.fill: parent
    variant: root.dock.style
    radius: 16
    boost: 0.4
  }

  component SectionLabel: Text {
    color: Util.alpha(Color.foreground, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  component Hint: Text {
    width: parent ? parent.width : 0
    wrapMode: Text.WordWrap
    color: Util.alpha(Color.foreground, 0.45)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Column {
    id: content
    x: root.pad
    y: root.pad
    width: root.width - root.pad * 2
    spacing: Style.spacing.xxl
    focus: true
    Keys.onEscapePressed: root.close()

    Text {
      text: "Dock"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.weight: Font.DemiBold
    }

    ButtonGroup {
      options: [
        { value: "position", label: "Position" },
        { value: "size", label: "Größe" },
        { value: "display", label: "Anzeige" },
        { value: "style", label: "Stil" }
      ]
      value: root.tab
      fontSize: Style.font.bodySmall
      onChanged: function(v) { root.tab = v }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Util.alpha(Color.foreground, 0.1)
    }

    // ---- Position
    Column {
      visible: root.tab === "position"
      width: parent.width
      spacing: Style.spacing.md

      SectionLabel { text: "Bildschirmrand" }
      ButtonGroup {
        options: [
          { value: "top", label: "Oben" },
          { value: "bottom", label: "Unten" },
          { value: "left", label: "Links" },
          { value: "right", label: "Rechts" }
        ]
        value: root.dock.position
        onChanged: function(v) { root.dock.setPosition(v) }
      }
    }

    // ---- Size
    Column {
      visible: root.tab === "size"
      width: parent.width
      spacing: Style.spacing.md

      SectionLabel { text: "Größe · " + Math.round(root.dock.dockScale * 100) + " %" }
      ButtonGroup {
        options: [
          { value: "25", label: "25 %" },
          { value: "50", label: "50 %" },
          { value: "75", label: "75 %" },
          { value: "100", label: "100 %" }
        ]
        value: String(Math.round(root.dock.dockScale * 100))
        onChanged: function(v) { root.dock.setScale(Number(v) / 100) }
      }
      ButtonGroup {
        options: [
          { value: "125", label: "125 %" },
          { value: "150", label: "150 %" },
          { value: "175", label: "175 %" },
          { value: "200", label: "200 %" }
        ]
        value: String(Math.round(root.dock.dockScale * 100))
        onChanged: function(v) { root.dock.setScale(Number(v) / 100) }
      }
      Hint { text: "Mausrad über dem Dock ändert die Größe in 25-%-Schritten." }
    }

    // ---- Display
    Column {
      visible: root.tab === "display"
      width: parent.width
      spacing: Style.spacing.md

      Toggle {
        width: parent.width
        label: "Dock anzeigen"
        description: "Aus: nur der Griff am Rand bleibt"
        checked: root.dock.dockVisible
        onClicked: root.dock.dockVisible = !root.dock.dockVisible
      }

      SectionLabel { text: "Verhalten" }
      ButtonGroup {
        options: [
          { value: "always", label: "Immer sichtbar" },
          { value: "hover", label: "Bei Hover" }
        ]
        value: root.dock.autohide ? "hover" : "always"
        onChanged: function(v) { root.dock.autohide = (v === "hover") }
      }
      Hint { text: "Bei Hover: Maus an den Rand bewegen – das Dock erscheint und verschwindet nach der Auswahl wieder." }
    }

    // ---- Style
    Column {
      visible: root.tab === "style"
      width: parent.width
      spacing: Style.spacing.md

      SectionLabel { text: "Design · gilt auch für Super+Tab" }

      Row {
        id: styleRow
        width: parent.width
        spacing: Style.spacing.md

        Repeater {
          model: [
            { value: "glass", label: "Glass" },
            { value: "tinted", label: "Tinted" },
            { value: "minimal", label: "Minimal" },
            { value: "solid", label: "Solid" }
          ]

          delegate: Item {
            id: tile
            required property var modelData
            readonly property bool selected: root.dock.style === modelData.value
            width: Math.floor((styleRow.width - styleRow.spacing * 3) / 4)
            height: preview.height + Style.spacing.sm + tileLabel.implicitHeight

            Item {
              id: preview
              width: parent.width
              height: Style.space(40)

              Rectangle {
                visible: tile.selected || tileMouse.containsMouse
                anchors.fill: parent
                anchors.margins: -3
                radius: 13
                color: "transparent"
                border.color: tile.selected ? Color.accent : Util.alpha(Color.foreground, 0.3)
                border.width: tile.selected ? 2 : 1
              }

              GlassSurface {
                anchors.fill: parent
                variant: tile.modelData.value
                radius: 10
              }

              Row {
                anchors.centerIn: parent
                spacing: 3
                Repeater {
                  model: 3
                  delegate: Rectangle {
                    width: 8
                    height: 8
                    radius: 2.5
                    color: Util.alpha(Color.foreground, 0.55)
                  }
                }
              }
            }

            Text {
              id: tileLabel
              anchors.top: preview.bottom
              anchors.topMargin: Style.spacing.sm
              anchors.horizontalCenter: parent.horizontalCenter
              text: tile.modelData.label
              color: tile.selected ? Color.foreground : Util.alpha(Color.foreground, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: tileMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.dock.style = tile.modelData.value
            }
          }
        }
      }

      Toggle {
        width: parent.width
        label: "Echter Blur"
        description: "Milchglas hinter Dock, Menü und Switcher"
        checked: root.dock.blur
        onClicked: root.dock.blur = !root.dock.blur
      }
    }
  }
}
