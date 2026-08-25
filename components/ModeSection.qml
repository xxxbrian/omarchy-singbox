import QtQuick
import qs.Commons
import qs.Ui

// The clash modes the running config actually defines, as one
// mutually-exclusive row. sing-box has no built-in Rule/Global/Direct: a mode
// exists only where a route rule names it in `clash_mode`, so the chips come
// from the core's own `mode-list` and the section hides itself when the list
// holds a single entry — with one mode there is nothing to switch.
Column {
  id: root

  required property color textColor
  required property string panelFontFamily
  property color accentColor: Color.accent
  property string mode: ""
  property var modeList: []
  // Not `enabled`: that is an Item property, and shadowing it would also
  // stop the section receiving input events rather than just greying out.
  property bool switchable: true
  property bool pending: false
  property int cursorIndex: -1

  signal modeRequested(string value)
  signal chipHovered(int index, bool isHovered)

  spacing: Style.space(8)

  Item {
    width: parent.width
    implicitHeight: Math.max(sectionHeader.implicitHeight, pendingLabel.implicitHeight)

    PanelSectionHeader {
      id: sectionHeader
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "CLASH MODE"
      foreground: root.textColor
      fontFamily: root.panelFontFamily
    }

    Text {
      id: pendingLabel
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.pending
      text: "switching…"
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
      font.family: root.panelFontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)
    opacity: root.switchable ? 1.0 : 0.45
    enabled: root.switchable

    Repeater {
      model: root.modeList

      delegate: Button {
        id: chip
        required property var modelData
        required property int index
        text: String(modelData)
        selected: String(modelData) === root.mode
        hasCursor: root.cursorIndex === index
        bordered: true
        foreground: root.textColor
        accent: root.accentColor
        fontFamily: root.panelFontFamily
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(14)
        verticalPadding: Style.space(9)
        onHovered: function(isHovered) { root.chipHovered(chip.index, isHovered) }
        onClicked: root.modeRequested(String(chip.modelData))
      }
    }
  }
}
