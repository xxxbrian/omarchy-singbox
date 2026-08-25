import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// The proxy groups the running config defines, one expandable section per
// group. Only `Selector` groups take a click — sing-box refuses selection on
// everything else — so URLTest and Fallback groups render their members
// without a pointer and let the core keep choosing.
//
// Left-click a member to select it; right-click to test its latency. The
// delay badge is the newest entry in the history sing-box already keeps.
Column {
  id: root

  required property var service
  required property color textColor
  required property string panelFontFamily
  property string cursorTarget: ""
  property string expandedGroup: ""

  signal backRequested()
  signal rowHovered(string target, bool isHovered)

  readonly property var groups: service.proxyGroups

  spacing: Style.space(8)

  function currentOf(group) {
    if (root.service.pendingSelectGroup === group.name && root.service.pendingSelectName !== "")
      return root.service.pendingSelectName
    return group.now
  }

  function toggleGroup(name) {
    expandedGroup = expandedGroup === name ? "" : name
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(backButton.implicitHeight, proxiesHeader.implicitHeight)

    Button {
      id: backButton
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "←"
      foreground: root.textColor
      bordered: false
      fontSize: Style.font.body
      onClicked: root.backRequested()
    }

    PanelSectionHeader {
      id: proxiesHeader
      anchors.left: backButton.right
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: "PROXIES"
      foreground: root.textColor
      fontFamily: root.panelFontFamily
    }

    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.service.delayTesting !== ""
      text: "testing…"
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
      font.family: root.panelFontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Text {
    width: parent.width
    visible: root.groups.length === 0
    text: root.service.apiState === "ok"
      ? "The running config defines no proxy groups."
      : "Waiting for the core's API."
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  Repeater {
    model: root.groups

    delegate: Column {
      id: groupBlock
      required property var modelData
      required property int index

      readonly property bool expanded: root.expandedGroup === modelData.name
      readonly property string current: root.currentOf(modelData)

      width: root.width
      spacing: Style.space(2)

      Rectangle {
        id: groupRow
        width: parent.width
        implicitHeight: Style.space(36)
        radius: Style.cornerRadius
        color: groupHover.hovered || root.cursorTarget === "group:" + groupBlock.modelData.name
          ? Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.08)
          : "transparent"

        Text {
          id: expandGlyph
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: groupBlock.expanded ? "▾" : "▸"
          color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: groupName
          anchors.left: expandGlyph.right
          anchors.leftMargin: Style.space(8)
          anchors.right: groupMeta.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: groupBlock.modelData.name
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          id: groupMeta
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, groupRow.width * 0.55)
          horizontalAlignment: Text.AlignRight
          text: groupBlock.current !== ""
            ? groupBlock.current + "  · " + groupBlock.modelData.type.toLowerCase()
            : groupBlock.modelData.type.toLowerCase()
          color: groupBlock.current !== ""
            ? Style.selectedStateColor(root.textColor, Color.accent)
            : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }

        HoverHandler {
          id: groupHover
          onHoveredChanged: root.rowHovered("group:" + groupBlock.modelData.name, hovered)
        }
        TapHandler { onTapped: root.toggleGroup(groupBlock.modelData.name) }
      }

      Column {
        width: parent.width
        visible: groupBlock.expanded
        spacing: Style.space(1)

        Repeater {
          model: groupBlock.expanded ? groupBlock.modelData.members : []

          delegate: Rectangle {
            id: memberRow
            required property var modelData
            required property int index

            readonly property bool current: modelData.name === groupBlock.current
            readonly property bool selectable: groupBlock.modelData.selectable

            width: groupBlock.width
            implicitHeight: Style.space(30)
            radius: Style.cornerRadius
            color: memberHover.hovered || root.cursorTarget === "member:" + groupBlock.modelData.name + ":" + modelData.name
              ? Style.hoverFillFor(root.textColor, Color.accent)
              : (current ? Style.selectedFillFor(root.textColor, Color.accent) : "transparent")

            // The filled dot marks the selection alongside the fill: colour
            // alone never carries state.
            Text {
              id: memberDot
              anchors.left: parent.left
              anchors.leftMargin: Style.space(22)
              anchors.verticalCenter: parent.verticalCenter
              text: memberRow.current ? "●" : "○"
              color: memberRow.current
                ? Style.selectedStateColor(root.textColor, Color.accent)
                : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.4)
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.left: memberDot.right
              anchors.leftMargin: Style.space(8)
              anchors.right: delayBadge.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: memberRow.modelData.name
              color: root.textColor
              opacity: memberRow.selectable || memberRow.current ? 1.0 : 0.7
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              id: delayBadge
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.service.delayTesting === memberRow.modelData.name
                ? "…"
                : Model.formatDelay(memberRow.modelData.delay)
              color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.caption
            }

            HoverHandler {
              id: memberHover
              onHoveredChanged: root.rowHovered(
                "member:" + groupBlock.modelData.name + ":" + memberRow.modelData.name, hovered)
            }
            TapHandler {
              acceptedButtons: Qt.LeftButton
              onTapped: {
                if (memberRow.selectable)
                  root.service.selectProxy(groupBlock.modelData.name, memberRow.modelData.name)
              }
            }
            TapHandler {
              acceptedButtons: Qt.RightButton
              onTapped: root.service.testDelay(memberRow.modelData.name)
            }

            PanelToolTip {
              visible: memberHover.hovered && !memberRow.selectable
              text: groupBlock.modelData.type + " groups choose on their own — right-click to test"
              fontFamily: root.panelFontFamily
            }
          }
        }
      }
    }
  }

  Text {
    width: parent.width
    visible: root.groups.length > 0
    text: "Left-click selects · right-click tests latency"
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.4)
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
  }
}
