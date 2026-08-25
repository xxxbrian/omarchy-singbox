import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Shown until the panel has something real to drive: sing-box not installed,
// or installed with no core running and no unit to start. Each state names
// the one command that moves it forward, with a copy button so the terminal
// trip is a paste. The panel itself never installs and never escalates.
Rectangle {
  id: root

  required property color textColor
  required property string panelFontFamily
  property string stateKey: "binary_missing"
  property bool hasCursor: false

  signal docsRequested()

  readonly property bool missingBinary: stateKey === "binary_missing"

  readonly property string command: missingBinary
    ? "sudo pacman -S sing-box"
    : "systemctl --user status sing-box.service"

  width: parent ? parent.width : 0
  implicitHeight: body.implicitHeight + Style.space(26)
  radius: Style.cornerRadius
  color: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.04)
  border.width: 1
  border.color: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.12)

  function copyCommand() {
    Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy", "copy", root.command])
  }

  Column {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(14)
    anchors.rightMargin: Style.space(14)
    spacing: Style.space(8)

    Text {
      width: parent.width
      text: root.missingBinary ? "Install sing-box" : "No core detected"
      color: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      text: root.missingBinary
        ? "The panel drives a sing-box core you run yourself. Install it from the official repositories:"
        : "sing-box is installed but nothing is running. Start your own service, or check what happened to it:"
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.58)
      font.family: root.panelFontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Rectangle {
      width: parent.width
      implicitHeight: commandText.implicitHeight + Style.space(14)
      radius: Style.cornerRadius
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.06)

      Text {
        id: commandText
        anchors.left: parent.left
        anchors.right: copyButton.left
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: root.command
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Button {
        id: copyButton
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        text: "Copy"
        foreground: root.textColor
        bordered: false
        fontSize: Style.font.caption
        onClicked: root.copyCommand()
      }
    }

    Text {
      width: parent.width
      visible: !root.missingBinary
      text: "The panel finds a running core on its own. If yours hides — a "
        + "custom unit name, an unreadable config — point it there in "
        + "~/.config/omarchy-singbox/config with unit=, config=, endpoint= "
        + "and secret= lines."
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.58)
      font.family: root.panelFontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Button {
      text: "sing-box documentation..."
      foreground: root.textColor
      bordered: true
      fontSize: Style.font.bodySmall
      hasCursor: root.hasCursor
      onClicked: root.docsRequested()
    }
  }
}
