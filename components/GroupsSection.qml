import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// The panel's primary control surface, the way Surge's own panel is a list of
// its groups: one expandable section per outbound group, on page one. What a
// Clash client does with a global mode switch, sing-box does here — every
// routing decision the config leaves open is a selection in one of these
// groups, so the groups are the controls and there is nothing global to flip.
//
// Only `Selector` groups take a click — sing-box refuses selection on
// everything else — so URLTest and Fallback groups render their members
// without a pointer and let the core keep choosing. Left-click a member to
// select it; right-click to test its latency. The delay badge is the newest
// entry in the history sing-box already keeps.
Column {
  id: root

  required property var service
  required property color textColor
  required property string panelFontFamily
  property string cursorTarget: ""
  property string expandedGroup: ""

  signal rowHovered(string target, bool isHovered)
  // The y of a group block that just expanded, for the panel to scroll into
  // view — the member list unfolds below the fold otherwise.
  signal revealRequested(real blockY)

  readonly property var groups: service.proxyGroups

  spacing: Style.space(6)

  function currentOf(group) {
    if (root.service.pendingSelectGroup === group.name && root.service.pendingSelectName !== "")
      return root.service.pendingSelectName
    return group.now
  }

  function toggleGroup(name) {
    var expanding = expandedGroup !== name
    expandedGroup = expanding ? name : ""
    if (expanding) Qt.callLater(function() { revealGroup(name) })
  }

  function toggleGroupAt(index) {
    if (index < 0 || index >= groups.length) return
    toggleGroup(groups[index].name)
  }

  function revealGroup(name) {
    for (var i = 0; i < groupsRepeater.count; i++) {
      var item = groupsRepeater.itemAt(i)
      if (item && item.modelData.name === name) {
        revealRequested(item.y)
        return
      }
    }
  }

  Item {
    width: parent.width
    implicitHeight: groupsHeader.implicitHeight

    PanelSectionHeader {
      id: groupsHeader
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "GROUPS"
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

  Repeater {
    id: groupsRepeater
    model: root.groups

    delegate: Column {
      id: groupBlock
      required property var modelData
      required property int index

      readonly property bool expanded: root.expandedGroup === modelData.name
      readonly property string current: root.currentOf(modelData)

      width: root.width
      spacing: Style.space(1)

      Rectangle {
        id: groupRow
        width: parent.width
        implicitHeight: Style.space(31)
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
            ? groupBlock.current + (groupBlock.modelData.selectable ? "" : " · auto")
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
            implicitHeight: Style.space(27)
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
}
