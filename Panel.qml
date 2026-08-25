import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "components"

// The panel: a bar button hosting a three-page popup. Page one is the whole
// state at a glance — what the core is doing, live traffic, and the mode
// chips; page two is the proxy groups; page three is the configuration.
// Navigation between pages is explicit — a menu item or a back arrow — and
// every fresh open returns to page one.
Panel {
  id: root
  moduleName: "singbox.omarchy"
  ipcTarget: "singbox.omarchy"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property bool cursorActive: false
  property int cursorIndex: 0
  property int modeCursor: 0
  property int panelPage: 1

  readonly property bool showSetup: singbox.connection.key === "binary_missing"
    || singbox.connection.key === "no_core"

  // One flat list of what the keyboard can reach, rebuilt from the service
  // state. The order here is the order on screen.
  readonly property var targets: {
    if (root.panelPage === 2) {
      var list = []
      var groups = singbox.proxyGroups
      for (var i = 0; i < groups.length; i++) {
        list.push("group:" + groups[i].name)
        if (proxiesSection.expandedGroup !== groups[i].name) continue
        for (var j = 0; j < groups[i].members.length; j++)
          list.push("member:" + groups[i].name + ":" + groups[i].members[j].name)
      }
      return list
    }
    if (root.panelPage === 3) {
      var actions = ["check", "edit"]
      if (singbox.canControl) actions.push("restart")
      return actions
    }
    if (root.showSetup) return ["setup"]
    var page = []
    if (singbox.canControl) page.push("power")
    if (singbox.canSwitchMode) page.push("mode")
    return page
  }

  readonly property string cursorTarget: {
    if (!cursorActive) return ""
    if (cursorIndex < 0 || cursorIndex >= targets.length) return ""
    return targets[cursorIndex]
  }

  readonly property string dashboardUrl: singbox.apiBase !== "" && singbox.config.externalUi !== ""
    ? singbox.apiBase + "/ui"
    : ""

  readonly property string barTooltip: singbox.connection.key === "running"
    ? "sing-box · " + (singbox.mode !== "" ? singbox.mode : "connected")
    : "sing-box · " + singbox.connection.label

  function clampCursor() {
    if (targets.length === 0) { cursorIndex = 0; return }
    if (cursorIndex < 0) cursorIndex = 0
    if (cursorIndex > targets.length - 1) cursorIndex = targets.length - 1
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    clampCursor()
    if (dx !== 0 && cursorTarget === "mode") {
      modeCursor = Math.max(0, Math.min(singbox.modeList.length - 1, modeCursor + dx))
      return
    }
    if (dy !== 0) {
      cursorIndex = Math.max(0, Math.min(targets.length - 1, cursorIndex + dy))
      if (cursorTarget === "mode") modeCursor = Math.max(0, singbox.modeList.indexOf(singbox.mode))
    }
  }

  function activateCursor() {
    clampCursor()
    var target = cursorTarget
    if (target === "power") singbox.toggleService()
    else if (target === "mode") {
      if (modeCursor >= 0 && modeCursor < singbox.modeList.length)
        singbox.setMode(singbox.modeList[modeCursor])
    }
    else if (target === "setup") singbox.openDocumentation()
    else if (target === "check") singbox.runCheck()
    else if (target === "edit") singbox.openEditor()
    else if (target === "restart") singbox.restartService()
    else if (target.indexOf("group:") === 0)
      proxiesSection.toggleGroup(target.substring(6))
    else if (target.indexOf("member:") === 0) {
      var rest = target.substring(7)
      var cut = rest.indexOf(":")
      if (cut > 0) singbox.selectProxy(rest.substring(0, cut), rest.substring(cut + 1))
    }
  }

  function cycleMode(delta) {
    if (!singbox.canSwitchMode || singbox.modeList.length === 0) return
    var current = singbox.modeList.indexOf(singbox.mode)
    if (current < 0) current = 0
    var next = (current + delta + singbox.modeList.length) % singbox.modeList.length
    singbox.setMode(singbox.modeList[next])
  }

  function openPage(page) {
    panelPage = page
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    if (page === 2) singbox.refreshProxies()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: singbox
    settings: root.settings
    panelOpen: root.opened
  }

  onOpenedChanged: if (opened) {
    panelPage = 1
    cursorActive = false
    cursorIndex = 0
    modeCursor = Math.max(0, singbox.modeList.indexOf(singbox.mode))
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onTargetsChanged: clampCursor()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { singbox.refresh(); return "ok" }
    function start(): string { singbox.startService(); return "ok" }
    function stop(): string { singbox.stopService(); return "ok" }
    function restart(): string { singbox.restartService(); return "ok" }
    function mode(value: string): string {
      var list = singbox.modeList
      for (var i = 0; i < list.length; i++) {
        if (String(list[i]).toLowerCase() !== String(value).toLowerCase()) continue
        singbox.setMode(list[i])
        return "ok"
      }
      return list.length > 0 ? "expected one of " + list.join(", ") : "no modes available"
    }
    function status(): string {
      return JSON.stringify({
        state: singbox.connection.key,
        mode: singbox.mode,
        unit: singbox.unit,
        scope: singbox.unitScope,
        service: singbox.unitScope === "system" ? singbox.probe.sysActiveState : singbox.probe.activeState,
        api: singbox.apiState,
        core: singbox.coreVersion,
        connections: singbox.connectionCount,
        config: singbox.configPath
      })
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip

    // Read from inside `iconComponent`: both BarIconButton and PanelHero name
    // their own root object `root`, so nothing inside a Component declared
    // here refers to `root` — it would be ambiguous about which one it meant.
    readonly property color glyphColor: singbox.active
      ? root.barForeground
      : Qt.darker(root.barForeground, 1.55)

    iconComponent: Component {
      Item {
        SingboxIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: button.glyphColor
          badgeColor: Color.urgent
          crossed: !singbox.active
          warning: singbox.connection.tone === "urgent"
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) singbox.toggleService()
      else if (buttonCode === Qt.MiddleButton) singbox.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.panelPage !== 1) root.openPage(1)
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var key = String(text || "").toLowerCase()
        if (key === "r") singbox.refresh()
        else if (root.panelPage === 1 && key === "t") singbox.toggleService()
        else if (root.panelPage === 1 && key === "p") root.openPage(2)
        else if (root.panelPage === 1 && key === "c") root.openPage(3)
        else if (root.panelPage === 1 && key === "m") root.cycleMode(1)
        else if (root.panelPage === 1 && key >= "1" && key <= "9") {
          var wanted = Number(key) - 1
          if (singbox.canSwitchMode && wanted < singbox.modeList.length)
            singbox.setMode(singbox.modeList[wanted])
        }
        else if (root.panelPage === 3 && key === "k") singbox.runCheck()
        else if (root.panelPage === 3 && key === "e") singbox.openEditor()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            visible: root.panelPage === 1
            width: parent.width
            implicitHeight: Math.max(hero.implicitHeight, headerControls.implicitHeight)

            PanelHero {
              id: hero
              anchors.left: parent.left
              anchors.right: headerControls.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              title: "sing-box"
              meta: singbox.connection.key === "running"
                ? (singbox.mode !== "" ? singbox.mode + " mode" : "connected")
                : singbox.connection.label
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: singbox.active ? 1.0 : 0.5
              iconComponent: Component {
                SingboxIcon {
                  iconSize: Style.font.display
                  color: hero.foreground
                  badgeColor: Color.urgent
                  crossed: !singbox.active
                  warning: singbox.connection.tone === "urgent"
                }
              }
            }

            Row {
              id: headerControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              ToggleSwitch {
                id: powerSwitch
                anchors.verticalCenter: parent.verticalCenter
                visible: singbox.canControl
                checked: singbox.active
                busy: singbox.actionRunning
                cursorRing: false
                foreground: root.foreground
                onHovered: function(on) {
                  if (!on) return
                  root.cursorActive = true
                  root.cursorIndex = root.targets.indexOf("power")
                }
                onToggled: singbox.toggleService()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: "Current status: " + singbox.connection.label
                  fontFamily: root.fontFamily
                }
              }

              PanelMenu {
                anchors.verticalCenter: parent.verticalCenter
                textColor: root.foreground
                panelFontFamily: root.fontFamily
                dashboardUrl: root.dashboardUrl
                canOpenProxies: singbox.coreRunning && singbox.apiState === "ok"
                canRestart: singbox.canControl
                onRestartRequested: singbox.restartService()
                onProxiesRequested: root.openPage(2)
                onConfigRequested: root.openPage(3)
              }
            }
          }

          // One line for whatever the panel most needs to say: what it is
          // doing, what went wrong, or why the proxy is not connected. Every
          // page shows it: a refused action must report on the page it
          // happened on, or the panel appears to ignore the click.
          Item {
            id: noticeBlock
            visible: text !== ""
            width: parent.width
            implicitHeight: Math.max(noticeText.implicitHeight,
                noticeClose.visible ? noticeClose.implicitHeight : 0)
              + (offersDiagnosis ? noticeDiagnose.implicitHeight + Style.space(4) : 0)
            property alias text: noticeText.text

            // One condition, read by both the button and this block's height.
            readonly property bool offersDiagnosis: singbox.actionStatus === ""
              && Model.canDiagnose(singbox.lastErrorKind, singbox.defaultAgent)

            Text {
              id: noticeText
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.right: noticeClose.visible ? noticeClose.left : parent.right
              anchors.rightMargin: noticeClose.visible ? Style.space(6) : 0
              text: singbox.actionStatus !== "" ? singbox.actionStatus
                : (singbox.lastError !== "" ? singbox.lastError
                  : (root.panelPage === 1 ? singbox.connection.detail : ""))
              color: singbox.lastError !== "" && singbox.actionStatus === "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              // Three lines is what a failure gets before the panel is more
              // error than panel. The message is already shortened and
              // redacted upstream, so the clamp can only ever drop wording.
              maximumLineCount: 3
              elide: Text.ElideRight
            }

            Button {
              id: noticeClose
              visible: singbox.lastError !== "" && singbox.actionStatus === ""
              anchors.right: parent.right
              anchors.top: parent.top
              text: "×"
              foreground: root.urgent
              bordered: false
              fontSize: Style.font.bodySmall
              onClicked: singbox.clearNotice()
            }

            // Three lines cannot hold why a check or a restart failed, and
            // the journal it would take to find out lives outside the panel.
            // Offered as a button, never opened on its own.
            Button {
              id: noticeDiagnose
              visible: noticeBlock.offersDiagnosis
              anchors.left: parent.left
              anchors.top: noticeText.bottom
              anchors.topMargin: Style.space(4)
              text: "Diagnose..."
              foreground: root.foreground
              bordered: true
              fontSize: Style.font.bodySmall
              onClicked: singbox.diagnose()
            }
          }

          SetupCard {
            visible: root.panelPage === 1 && root.showSetup
            width: parent.width
            textColor: root.foreground
            panelFontFamily: root.fontFamily
            stateKey: singbox.connection.key
            hasCursor: root.cursorTarget === "setup"
            onDocsRequested: singbox.openDocumentation()
          }

          PanelSeparator {
            visible: root.panelPage === 1 && !root.showSetup && singbox.canSwitchMode
            foreground: root.foreground
          }

          ModeSection {
            visible: root.panelPage === 1 && !root.showSetup && singbox.canSwitchMode
            width: parent.width
            textColor: root.foreground
            panelFontFamily: root.fontFamily
            mode: singbox.mode
            modeList: singbox.modeList
            switchable: singbox.canSwitchMode
            pending: singbox.pendingMode !== ""
            cursorIndex: root.cursorTarget === "mode" ? root.modeCursor : -1
            onModeRequested: function(value) { singbox.setMode(value) }
            onChipHovered: function(index, isHovered) {
              if (!isHovered) {
                if (root.cursorTarget === "mode") root.cursorActive = false
                return
              }
              if (!singbox.canSwitchMode) return
              root.cursorActive = true
              root.cursorIndex = root.targets.indexOf("mode")
              root.modeCursor = index
            }
          }

          PanelSeparator {
            visible: root.panelPage === 1 && !root.showSetup
            foreground: root.foreground
          }

          ConnectionSection {
            visible: root.panelPage === 1 && !root.showSetup
            width: parent.width
            service: singbox
            textColor: root.foreground
            panelFontFamily: root.fontFamily
          }

          ProxiesSection {
            id: proxiesSection
            visible: root.panelPage === 2
            width: parent.width
            service: singbox
            textColor: root.foreground
            panelFontFamily: root.fontFamily
            cursorTarget: root.cursorTarget
            onBackRequested: root.openPage(1)
            onRowHovered: function(target, isHovered) {
              if (!isHovered) {
                root.cursorActive = false
                return
              }
              root.cursorActive = true
              root.cursorIndex = root.targets.indexOf(target)
            }
          }

          ConfigSection {
            visible: root.panelPage === 3
            width: parent.width
            service: singbox
            textColor: root.foreground
            panelFontFamily: root.fontFamily
            cursorTarget: root.cursorTarget
            onBackRequested: root.openPage(1)
          }
        }
      }
    }
  }
}
