import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// The configuration page: where the config lives, when it last changed, and
// the two things the panel can honestly do about it — validate it with
// `sing-box check`, and restart the service so a changed file takes effect.
// The file itself is the user's; the panel opens an editor and never writes.
//
// `check` is a gate, not a guarantee: sing-box resolves outbound references
// at start, so a config that checks clean can still fail to come up. The
// restart path reports through the journal when that happens.
Column {
  id: root

  required property var service
  required property color textColor
  required property string panelFontFamily
  property string cursorTarget: ""

  signal backRequested()

  spacing: Style.space(10)

  Item {
    width: parent.width
    implicitHeight: Math.max(backButton.implicitHeight, configHeader.implicitHeight)

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
      id: configHeader
      anchors.left: backButton.right
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: "CONFIGURATION"
      foreground: root.textColor
      fontFamily: root.panelFontFamily
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(6)

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Config"
      value: root.service.configPath !== "" ? root.service.configPath : "not found"
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Modified"
      value: root.service.configStat.present
        ? Model.formatAgo(root.service.configStat.mtime, root.service.probe.now)
          + " · " + Model.formatBytes(root.service.configStat.size)
        : "—"
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Readable"
      value: !root.service.configStat.present ? "—"
        : (root.service.configStat.readable ? "yes" : "no — the panel cannot parse it")
      valueColor: root.service.configStat.present && !root.service.configStat.readable
        ? Color.urgent : root.textColor
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Unit"
      value: {
        var probe = root.service.probe
        var scope = root.service.unitScope
        if (scope === "system") return root.service.unit + " (system)"
        if (probe.pid > 0 && scope === "") return "none — running by hand"
        return root.service.unit + (scope !== "" ? "" : " (not found)")
      }
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Override file"
      value: root.service.overridePath.replace(root.service.home, "~")
    }
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)

    Button {
      text: root.service.checking ? "Checking…" : "Check config"
      foreground: root.textColor
      bordered: true
      fontSize: Style.font.bodySmall
      enabled: !root.service.checking && root.service.probe.binaryPath !== ""
        && root.service.configSpecs.length > 0
      hasCursor: root.cursorTarget === "check"
      onClicked: root.service.runCheck()
    }

    Button {
      // `...` because it opens an editor rather than finishing here.
      text: "Open in editor..."
      foreground: root.textColor
      bordered: true
      fontSize: Style.font.bodySmall
      enabled: root.service.primaryConfigPath !== ""
      hasCursor: root.cursorTarget === "edit"
      onClicked: root.service.openEditor()
    }

    Button {
      text: "Restart to apply"
      foreground: root.textColor
      bordered: true
      fontSize: Style.font.bodySmall
      enabled: root.service.canControl && !root.service.actionRunning
      hasCursor: root.cursorTarget === "restart"
      onClicked: root.service.restartService()
    }
  }

  Text {
    width: parent.width
    visible: root.service.checkStatus === "ok"
    text: "✓ Configuration is valid."
    color: Style.selectedStateColor(root.textColor, Color.accent)
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // The check's own words, shown only on failure and clamped: past a few
  // lines the panel is more error than panel, and the Diagnose offer on the
  // notice line carries the whole of it to an agent.
  Text {
    width: parent.width
    visible: root.service.checkStatus === "failed" && root.service.checkOutput !== ""
    text: root.service.checkOutput
    color: Color.urgent
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WrapAnywhere
    maximumLineCount: 6
    elide: Text.ElideRight
  }

  Text {
    width: parent.width
    visible: root.service.serviceHint !== ""
    text: root.service.serviceHint
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
