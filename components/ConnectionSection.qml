import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// The full picture of what the proxy is doing right now: live throughput from
// the core's `/traffic` stream, then the facts that only change on an event —
// what systemd thinks, which core is serving, where its API is, which ports
// are open.
//
// Live speeds sit on top as the two large numbers because they are the one
// thing worth glancing at; everything below is reference.
Column {
  id: root

  required property var service
  required property color textColor
  required property string panelFontFamily

  readonly property bool live: service.apiState === "ok" && service.coreRunning

  spacing: Style.space(10)

  PanelSectionHeader {
    text: "CONNECTION"
    foreground: root.textColor
    fontFamily: root.panelFontFamily
  }

  // Both directions in one chart across the full width, with the two readouts
  // laid over it: one box puts the curves on a common time axis, where the
  // shape of a transfer — upload spike, download answering it — is visible.
  Item {
    id: trafficPanel
    width: parent.width
    implicitHeight: trafficRow.implicitHeight + Style.space(12)
    height: implicitHeight
    opacity: root.live ? 1.0 : 0.45

    // One scale for both curves: overlaid in one box they are compared by
    // height whether or not that was intended.
    readonly property real seriesPeak: Math.max(Model.peakOf(root.service.downHistory),
                                                Model.peakOf(root.service.upHistory))

    Sparkline {
      anchors.fill: parent
      history: root.service.downHistory
      scalePeak: trafficPanel.seriesPeak
      curveColor: Color.accent
    }

    Sparkline {
      anchors.fill: parent
      history: root.service.upHistory
      scalePeak: trafficPanel.seriesPeak
      curveColor: Color.urgent
    }

    Row {
      id: trafficRow
      width: parent.width
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Speed {
        width: (trafficRow.width - trafficRow.spacing) / 2
        glyph: "↓"
        label: "DOWNLOAD"
        metricColor: Color.accent
        value: Model.formatSpeed(root.service.downSpeed)
      }

      Speed {
        width: (trafficRow.width - trafficRow.spacing) / 2
        glyph: "↑"
        label: "UPLOAD"
        metricColor: Color.urgent
        value: Model.formatSpeed(root.service.upSpeed)
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(6)

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Connections"
      value: root.live ? String(root.service.connectionCount) : "—"
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Transferred"
      value: root.live
        ? "↓ " + Model.formatBytes(root.service.downloadTotal) + "   ↑ " + Model.formatBytes(root.service.uploadTotal)
        : "—"
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Service"
      value: {
        var probe = root.service.probe
        var scope = root.service.unitScope
        if (scope === "system") {
          var sysAuto = probe.sysUnitFileState === "enabled" ? "enabled" : "not enabled"
          return probe.sysActiveState + " · system · " + sysAuto
        }
        if (probe.pid > 0 && probe.procUnit === "" && !probe.unitLoaded) return "outside systemd"
        if (scope === "") return "no unit"
        var autostart = probe.unitFileState === "enabled" ? "enabled" : "not enabled"
        return probe.activeState + " · " + autostart
      }
      valueColor: (root.service.unitScope === "system"
          ? root.service.probe.sysActiveState === "failed"
          : root.service.probe.activeState === "failed")
        ? Color.urgent : root.textColor
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Uptime"
      value: Model.uptimeSeconds(root.service.probe, root.service.nowEpoch) > 0
        ? Model.formatDuration(Model.uptimeSeconds(root.service.probe, root.service.nowEpoch))
        : "—"
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Core"
      value: root.service.coreVersion !== ""
        ? "sing-box " + root.service.coreVersion
        : (root.service.probe.binaryVersion !== ""
          ? "sing-box " + root.service.probe.binaryVersion
          : (root.service.probe.binaryPath !== "" ? "installed" : "not installed"))
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "API"
      value: {
        if (root.service.apiBase === "")
          return root.service.config.hasClashApi ? "—" : "clash_api unset"
        if (root.service.apiState === "ok")
          return root.service.apiBase.replace(/^https?:\/\//, "")
        if (root.service.apiState === "unauthorized") return "secret rejected"
        if (!root.service.coreRunning) return "—"
        return "unreachable"
      }
      valueColor: root.service.apiState === "unauthorized" ? Color.urgent : root.textColor
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Ports"
      value: {
        var live = root.service.liveConfigs
        if (!live) return "—"
        var parts = []
        if (live.mixedPort > 0) parts.push("mixed " + live.mixedPort)
        if (live.port > 0) parts.push("http " + live.port)
        if (live.socksPort > 0) parts.push("socks " + live.socksPort)
        return parts.length > 0 ? parts.join(" · ") : "—"
      }
    }

    // Read-only, and only when the config defines clash modes at all: the
    // groups above are the controls, but a mode flipped from an external
    // dashboard changes where everything routes, and hiding that would let
    // the stats lie.
    StatRow {
      visible: root.service.modeList.length > 1
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Mode"
      value: root.service.mode !== "" ? root.service.mode : "—"
    }

    StatRow {
      width: parent.width
      textColor: root.textColor
      panelFontFamily: root.panelFontFamily
      label: "Memory"
      value: root.live && root.service.memoryUsage > 0
        ? Model.formatBytes(root.service.memoryUsage)
        : "—"
    }
  }

  component Speed: Item {
    id: speed
    required property string glyph
    required property string label
    required property string value
    required property color metricColor

    implicitHeight: metricContent.implicitHeight + Style.space(20)

    Column {
      id: metricContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: speed.glyph + "  " + speed.label
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: parent.width
        text: speed.value
        color: speed.metricColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }
}
