import QtQuick
import qs.Commons

// Label on the left, value on the right, on one baseline. The value takes the
// space it needs and the label gives way, because a truncated port number is
// useless while a truncated label is still readable.
Item {
  id: root

  required property color textColor
  required property string panelFontFamily
  property string label: ""
  property string value: ""
  property color valueColor: textColor
  property bool emphasised: false

  implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

  Text {
    id: labelText
    anchors.left: parent.left
    anchors.right: valueText.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  Text {
    id: valueText
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, root.width * 0.72)
    horizontalAlignment: Text.AlignRight
    text: root.value
    color: root.valueColor
    font.family: root.panelFontFamily
    font.pixelSize: root.emphasised ? Style.font.body : Style.font.bodySmall
    font.bold: root.emphasised
    elide: Text.ElideRight
  }
}
