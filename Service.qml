import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "SingboxConfig.js" as SingboxConfig
import "SingboxApi.js" as SingboxApi

// Every process the panel runs lives here, so the views stay declarative and
// the ordering rules are in one file.
//
// The split of responsibilities: discovery (the probe) finds the core, the
// config it runs, and the unit that owns it; the Clash API owns everything
// live — mode, version, traffic, connections, proxy selection; systemctl
// --user handles the one unit the user pointed the panel at. The panel never
// writes the sing-box config: `sing-box check` and a service restart are the
// whole of its involvement in configuration changes.
//
// Refresh is a chain, not a fan-out, because each stage feeds the next:
// override file -> probe -> config read -> API. The probe needs the override's
// unit and config path; the config read needs the probe's command-line paths;
// the API needs the config's controller and secret.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  // ---- what the last refresh found
  property var probe: Model.emptyProbe()
  property var override: SingboxConfig.emptyOverride()
  property var config: SingboxConfig.emptyConfig()
  property bool configLoaded: false
  property var configStat: Model.parseConfigStat("")
  // The config path the panel last saw a running core use. Session memory
  // only: it lets the config page keep pointing at the right file after the
  // core stops, when the command line it was read from is gone.
  property string lastKnownConfigPath: ""

  // ---- what the Clash API reports
  property string apiState: "unknown"       // ok | unauthorized | unreachable | disabled | unknown
  property string coreVersion: ""
  property var liveConfigs: null
  property int connectionCount: 0
  property real downloadTotal: 0
  property real uploadTotal: 0
  property real memoryUsage: 0
  property real upSpeed: 0
  property real downSpeed: 0
  // A local clock for values derived from an event timestamp. It ticks only
  // while the panel is visible; uptime should not wait for the next process
  // probe, and updating it does not justify spawning one every second.
  property real nowEpoch: Date.now() / 1000
  property var upHistory: []
  property var downHistory: []
  property real trafficIdleSince: 0
  property var trafficAnchor: null
  property var proxyGroups: []

  // ---- in-flight intent
  //
  // All optimistic overlays: the control moves the instant it is clicked and
  // stops overriding once a refresh confirms the real state. Waiting for
  // systemd makes the panel feel broken.
  property int desiredActive: -1
  property string pendingSelectGroup: ""
  property string pendingSelectName: ""
  property string delayTesting: ""
  property string actionKind: ""
  property string actionStatus: ""
  property string lastError: ""
  property string lastErrorKind: ""
  property string lastFailureOutput: ""

  // ---- config page state
  property string checkStatus: ""           // "" | running | ok | failed
  property string checkOutput: ""

  // Empty until the user picks one; Omarchy ships with no default agent, and
  // there is nothing to offer until there is something to open.
  property string defaultAgent: ""

  onLastErrorChanged: if (lastError === "") lastErrorKind = ""

  // Every error that is not a diagnosable command failure reports through
  // here, so it takes the diagnosis offer down with it.
  function reportError(message) {
    lastErrorKind = ""
    lastError = message
  }

  readonly property int refreshIntervalSec: {
    var raw = settings ? settings.refreshIntervalSec : undefined
    var value = parseInt(String(raw === undefined || raw === null ? 30 : raw), 10)
    if (!isFinite(value)) value = 30
    return Math.max(5, Math.min(3600, value))
  }

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string overridePath: SingboxConfig.overridePath(home)

  readonly property string unit: SingboxConfig.resolveUnit(override, probe)
  readonly property var configSpecs: Model.configSpecs(probe)
  readonly property string configPath: Model.configDisplayPath(probe)
  readonly property string primaryConfigPath: configSpecs.length > 0 ? configSpecs[0].path : ""

  readonly property var controllerInfo: SingboxConfig.resolveController(override, config, probe.pid > 0)
  readonly property string apiBase: SingboxApi.baseUrl(controllerInfo.controller)
  readonly property string apiSecret: controllerInfo.secret

  // Not `state`: QQuickItem already owns that name for its own state machine.
  readonly property var connection: Model.connectionState(probe, apiState)
  readonly property bool coreRunning: probe.pid > 0
  readonly property bool active: desiredActive === -1 ? connection.active : (desiredActive === 1)
  readonly property string unitScope: Model.serviceScope(probe)
  readonly property bool canControl: Model.canControlService(probe)
  readonly property string serviceHint: Model.serviceHint(probe)

  // Read-only: sing-box's clash mode is a compatibility surface for Clash
  // dashboards, not something this panel drives. The groups are the controls;
  // the mode is reported so a switch made elsewhere cannot mislead the stats.
  readonly property var modeList: liveConfigs ? liveConfigs.modeList : []
  readonly property string mode: liveConfigs && liveConfigs.mode !== "" ? liveConfigs.mode : config.defaultMode

  readonly property bool busy: probeProcess.running || overrideReadProcess.running
    || configReadProcess.running || actionProcess.running
    || proxySelectProcess.running || checkProcess.running
  readonly property bool actionRunning: actionProcess.running
  readonly property bool checking: checkProcess.running

  signal actionFinished(string kind, bool ok)

  // ------------------------------------------------------------- refreshing

  function refresh() {
    if (overrideReadProcess.running) return
    overrideReadProcess.command = SingboxConfig.readCommand(overridePath)
    overrideReadProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function refreshProbe() {
    if (probeProcess.running) return
    probeProcess.command = Model.probeCommand(
      SingboxConfig.resolveUnit(override, probe), override.config, lastKnownConfigPath)
    probeProcess.running = true
  }

  function refreshConfig() {
    if (configReadProcess.running) return
    configReadProcess.command = Model.configReadCommand(configSpecs)
    configReadProcess.running = true
    if (!configStatProcess.running) {
      configStatProcess.command = Model.configStatCommand(configSpecs)
      configStatProcess.running = true
    }
  }

  function refreshApi() {
    if (apiBase === "") {
      apiState = config.hasClashApi ? "unreachable" : "disabled"
      liveConfigs = null
      coreVersion = ""
      return
    }
    if (!coreRunning) {
      // Everything live was read from a core that is gone. Leaving it behind
      // would keep a mode and a version on screen as if something served them.
      apiState = "unreachable"
      liveConfigs = null
      coreVersion = ""
      connectionCount = 0
      downloadTotal = 0
      uploadTotal = 0
      memoryUsage = 0
      proxyGroups = []
      return
    }
    if (!versionProcess.running) {
      versionProcess.command = SingboxApi.versionCommand(apiBase, apiSecret !== "")
      runApiProcess(versionProcess)
    }
    if (!configsProcess.running) {
      configsProcess.command = SingboxApi.configsCommand(apiBase, apiSecret !== "")
      runApiProcess(configsProcess)
    }
    refreshProxies()
  }

  function refreshProxies() {
    if (apiBase === "" || !coreRunning || proxiesProcess.running) return
    proxiesProcess.command = SingboxApi.proxiesCommand(apiBase, apiSecret !== "")
    runApiProcess(proxiesProcess)
  }

  function refreshConnections() {
    if (!panelOpen || apiBase === "" || !coreRunning || connectionsProcess.running) return
    connectionsProcess.command = SingboxApi.connectionsCommand(apiBase, apiSecret !== "")
    runApiProcess(connectionsProcess)
  }

  // curl reads the header from stdin and receives EOF immediately after it.
  // The token therefore never appears in the Process argv or a process list.
  function runApiProcess(process) {
    process.stdinEnabled = apiSecret !== ""
    process.running = true
  }

  function writeApiAuth(process) {
    if (apiSecret !== "") process.write("Authorization: Bearer " + apiSecret + "\n")
    process.stdinEnabled = false
  }

  // ---------------------------------------------------------------- actions

  function selectProxy(group, name) {
    var groupName = String(group || "")
    var wanted = String(name || "")
    if (groupName === "" || wanted === "" || proxySelectProcess.running) return
    pendingSelectGroup = groupName
    pendingSelectName = wanted
    lastError = ""
    optimismTimer.restart()
    proxySelectProcess.command = SingboxApi.selectProxyCommand(apiBase, apiSecret !== "", groupName, wanted)
    runApiProcess(proxySelectProcess)
  }

  function testDelay(name) {
    var wanted = String(name || "")
    if (wanted === "" || delayProcess.running || apiBase === "") return
    delayTesting = wanted
    delayProcess.command = SingboxApi.delayCommand(apiBase, apiSecret !== "", wanted)
    runApiProcess(delayProcess)
  }

  function toggleService() {
    if (!canControl) return
    if (active) stopService()
    else startService()
  }

  function startService() {
    if (!canControl) return
    desiredActive = 1
    optimismTimer.restart()
    runAction("start", Model.startCommand(unit, unitScope), "Starting sing-box…")
  }

  function stopService() {
    if (!canControl) return
    desiredActive = 0
    optimismTimer.restart()
    runAction("stop", Model.stopCommand(unit, unitScope), "Stopping sing-box…")
  }

  function restartService() {
    if (!canControl) return
    desiredActive = 1
    optimismTimer.restart()
    runAction("restart", Model.restartCommand(unit, unitScope), "Restarting sing-box…")
  }

  function runCheck() {
    if (checkProcess.running || probe.binaryPath === "" || configSpecs.length === 0) return
    checkStatus = "running"
    checkOutput = ""
    lastError = ""
    checkProcess.command = Model.checkCommand(probe.binaryPath, configSpecs)
    checkProcess.running = true
  }

  function openEditor() {
    if (editorProcess.running || primaryConfigPath === "") return
    lastError = ""
    editorProcess.command = Model.openEditorCommand(primaryConfigPath)
    editorProcess.running = true
  }

  function openDocumentation() {
    if (guideProcess.running) return
    guideProcess.command = Model.documentationCommand()
    guideProcess.running = true
  }

  function clearNotice() {
    lastError = ""
  }

  // Checked per open rather than once at startup, so choosing an agent takes
  // effect without restarting the shell.
  function refreshDefaultAgent() {
    if (defaultAgentProcess.running) return
    defaultAgentProcess.command = Model.defaultAgentCommand()
    defaultAgentProcess.running = true
  }

  // The failure output can quote whole config fragments, so it goes to a 0600
  // file rather than into the prompt: `--prompt` becomes argv, and the
  // process list is world-readable.
  function diagnose() {
    if (!Model.canDiagnose(lastErrorKind, defaultAgent)) return
    if (failureLogWriteProcess.running || diagnoseProcess.running) return
    _pendingFailureLog = lastFailureOutput
    failureLogWriteProcess.command = Model.failureLogWriteCommand(Model.failureLogPath(home))
    failureLogWriteProcess.stdinEnabled = true
    failureLogWriteProcess.running = true
  }

  function runAction(kind, command, label) {
    if (actionProcess.running) return
    actionKind = kind
    actionStatus = label || ""
    lastError = ""
    _actionOutput = ""
    _actionError = ""
    actionProcess.command = command
    actionProcess.running = true
  }

  property string _actionOutput: ""
  property string _actionError: ""
  property string _pendingFailureLog: ""
  // What a failed start/restart printed, held while the journal is fetched to
  // fill in what systemctl's one line does not say.
  property string _failedActionKind: ""
  property string _failedActionOutput: ""

  // --------------------------------------------------------- live traffic
  //
  // `/traffic` holds a socket open and pushes a sample a second, so speeds
  // cost one curl for as long as the panel is on screen rather than a poll
  // loop. It is torn down the moment the panel closes.

  function syncTraffic() {
    var wanted = panelOpen && apiBase !== "" && coreRunning && apiState === "ok"
    if (wanted === trafficProcess.running) return
    if (wanted) trafficProcess.running = true
    else {
      trafficProcess.running = false
      upSpeed = 0
      downSpeed = 0
      trafficAnchor = null
      trafficIdleSince = Date.now() / 1000
    }
  }

  onPanelOpenChanged: {
    if (panelOpen) {
      refresh()
      refreshConnections()
      refreshDefaultAgent()
    }
    syncTraffic()
  }
  onApiStateChanged: syncTraffic()
  onCoreRunningChanged: syncTraffic()
  onApiBaseChanged: {
    trafficProcess.running = false
    syncTraffic()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: connectionsTimer
    interval: 5000
    repeat: true
    running: root.panelOpen
    onTriggered: root.refreshConnections()
  }

  Timer {
    id: clockTimer
    interval: 1000
    repeat: true
    running: root.panelOpen
    triggeredOnStart: true
    onTriggered: root.nowEpoch = Date.now() / 1000
  }

  // A refresh right after an action would race systemd, which reports the old
  // state for a moment after `start` returns.
  Timer {
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: optimismTimer
    interval: 8000
    repeat: false
    onTriggered: {
      root.desiredActive = -1
      root.pendingSelectGroup = ""
      root.pendingSelectName = ""
    }
  }

  Timer {
    id: trafficRetry
    interval: 3000
    repeat: false
    onTriggered: root.syncTraffic()
  }

  // Every poll skips itself while its own process is still running, so one
  // that never exits would stop the panel refreshing for good. Reap anything
  // still alive well inside the shortest refresh interval.
  Timer {
    id: pollWatchdog
    interval: 12000
    repeat: false
    onTriggered: {
      if (overrideReadProcess.running) overrideReadProcess.running = false
      if (probeProcess.running) probeProcess.running = false
      if (configReadProcess.running) configReadProcess.running = false
      if (configStatProcess.running) configStatProcess.running = false
      if (versionProcess.running) versionProcess.running = false
      if (configsProcess.running) configsProcess.running = false
      if (connectionsProcess.running) connectionsProcess.running = false
      if (proxiesProcess.running) proxiesProcess.running = false
    }
  }

  // ------------------------------------------------------------- processes

  Process {
    id: overrideReadProcess
    running: false
    command: []
    stdout: StdioCollector { id: overrideOut; waitForEnd: true }
    onExited: {
      root.override = SingboxConfig.parseOverride(overrideOut.text)
      root.refreshProbe()
    }
  }

  Process {
    id: probeProcess
    running: false
    command: []
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: {
      var next = Model.parseProbe(probeOut.text)
      root.probe = next
      if (next.configArgs.length > 0) root.lastKnownConfigPath = next.configArgs[0]
      if (root.desiredActive !== -1 && (next.pid > 0) === (root.desiredActive === 1))
        root.desiredActive = -1
      root.refreshConfig()
    }
  }

  Process {
    id: configReadProcess
    running: false
    command: []
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    onExited: {
      root.config = SingboxConfig.parseConfig(configOut.text)
      root.configLoaded = true
      root.refreshApi()
      if (root.panelOpen) root.refreshConnections()
    }
  }

  Process {
    id: configStatProcess
    running: false
    command: []
    stdout: StdioCollector { id: configStatOut; waitForEnd: true }
    onExited: root.configStat = Model.parseConfigStat(configStatOut.text)
  }

  Process {
    id: versionProcess
    running: false
    command: []
    stdinEnabled: false
    stdout: StdioCollector { id: versionOut; waitForEnd: true }
    stderr: StdioCollector { id: versionErr; waitForEnd: true }
    onStarted: root.writeApiAuth(versionProcess)
    onExited: function(exitCode) {
      var result = SingboxApi.classify(exitCode, versionOut.text, versionErr.text)
      root.apiState = result.ok ? "ok" : result.code
      root.coreVersion = result.ok ? SingboxApi.parseVersion(result.body).version : ""
      // Everything below is read from a core that just stopped answering.
      // Leaving the numbers behind would keep them on screen as if they were
      // still being updated.
      if (!result.ok) {
        root.liveConfigs = null
        root.connectionCount = 0
        root.downloadTotal = 0
        root.uploadTotal = 0
        root.memoryUsage = 0
        root.proxyGroups = []
      }
    }
  }

  Process {
    id: configsProcess
    running: false
    command: []
    stdinEnabled: false
    stdout: StdioCollector { id: configsOut; waitForEnd: true }
    stderr: StdioCollector { id: configsErr; waitForEnd: true }
    onStarted: root.writeApiAuth(configsProcess)
    onExited: function(exitCode) {
      var result = SingboxApi.classify(exitCode, configsOut.text, configsErr.text)
      if (!result.ok) return
      var parsed = SingboxApi.parseConfigs(result.body)
      if (!parsed) return
      root.liveConfigs = parsed
    }
  }

  Process {
    id: connectionsProcess
    running: false
    command: []
    stdinEnabled: false
    stdout: StdioCollector { id: connectionsOut; waitForEnd: true }
    stderr: StdioCollector { id: connectionsErr; waitForEnd: true }
    onStarted: root.writeApiAuth(connectionsProcess)
    onExited: function(exitCode) {
      var result = SingboxApi.classify(exitCode, connectionsOut.text, connectionsErr.text)
      if (!result.ok) return
      var parsed = SingboxApi.parseConnections(result.body)
      if (!parsed) return
      root.connectionCount = parsed.count
      root.downloadTotal = parsed.downloadTotal
      root.uploadTotal = parsed.uploadTotal
      root.memoryUsage = parsed.memory
    }
  }

  Process {
    id: proxiesProcess
    running: false
    command: []
    stdinEnabled: false
    stdout: StdioCollector { id: proxiesOut; waitForEnd: true }
    stderr: StdioCollector { id: proxiesErr; waitForEnd: true }
    onStarted: root.writeApiAuth(proxiesProcess)
    onExited: function(exitCode) {
      var result = SingboxApi.classify(exitCode, proxiesOut.text, proxiesErr.text)
      if (!result.ok) return
      var parsed = SingboxApi.parseProxyGroups(result.body)
      if (!parsed) return
      root.proxyGroups = parsed
      // Confirmed selections stop overriding.
      if (root.pendingSelectGroup !== "") {
        for (var i = 0; i < parsed.length; i++) {
          if (parsed[i].name !== root.pendingSelectGroup) continue
          if (parsed[i].now === root.pendingSelectName) {
            root.pendingSelectGroup = ""
            root.pendingSelectName = ""
          }
          break
        }
      }
    }
  }

  Process {
    id: proxySelectProcess
    running: false
    command: []
    stdinEnabled: false
    stdout: StdioCollector { id: proxySelectOut; waitForEnd: true }
    stderr: StdioCollector { id: proxySelectErr; waitForEnd: true }
    onStarted: root.writeApiAuth(proxySelectProcess)
    onExited: function(exitCode) {
      var result = SingboxApi.classify(exitCode, proxySelectOut.text, proxySelectErr.text)
      if (!result.ok) {
        root.pendingSelectGroup = ""
        root.pendingSelectName = ""
        root.reportError(result.message)
        return
      }
      root.refreshProxies()
    }
  }

  Process {
    id: delayProcess
    running: false
    command: []
    stdinEnabled: false
    stdout: StdioCollector { id: delayOut; waitForEnd: true }
    stderr: StdioCollector { id: delayErr; waitForEnd: true }
    onStarted: root.writeApiAuth(delayProcess)
    onExited: function(exitCode) {
      var tested = root.delayTesting
      root.delayTesting = ""
      var result = SingboxApi.classify(exitCode, delayOut.text, delayErr.text)
      if (!result.ok) {
        root.reportError(tested + ": " + result.message)
        // The failed test still updates the history sing-box keeps.
      }
      root.refreshProxies()
    }
  }

  Process {
    id: checkProcess
    running: false
    command: []
    stdout: StdioCollector { id: checkOut; waitForEnd: true }
    stderr: StdioCollector { id: checkErr; waitForEnd: true }
    onExited: function(exitCode) {
      var output = String(checkOut.text || "") + String(checkErr.text || "")
      root.checkOutput = Model.stripAnsi(output).trim()
      if (exitCode === 0) {
        // The config page prints its own "valid" line; a notice on top of it
        // would say the same thing twice and reflow the panel doing it.
        root.checkStatus = "ok"
      } else {
        root.checkStatus = "failed"
        root.lastFailureOutput = output
        root.lastError = Model.failureMessage(output, "sing-box check failed.")
        root.lastErrorKind = "check"
      }
    }
  }

  Process {
    id: editorProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode === 9) root.reportError("No editor launcher found.")
      else if (exitCode !== 0) root.reportError("Could not open the editor.")
    }
  }

  Process {
    id: guideProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) root.reportError("Could not open the documentation.")
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) {
        if (root._actionOutput.length >= Model.OUTPUT_LIMIT) return
        var remaining = Model.OUTPUT_LIMIT - root._actionOutput.length
        root._actionOutput += (line + "\n").substring(0, remaining)
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        if (root._actionError.length >= Model.OUTPUT_LIMIT) return
        var remaining = Model.OUTPUT_LIMIT - root._actionError.length
        root._actionError += (line + "\n").substring(0, remaining)
      }
    }
    onExited: function(exitCode) {
      var kind = root.actionKind
      var ok = exitCode === 0
      root.actionKind = ""
      if (ok) {
        root.lastError = ""
        root.actionStatus = kind === "start" ? "sing-box started."
          : kind === "stop" ? "sing-box stopped."
          : kind === "restart" ? "sing-box restarted."
          : ""
        if (root.actionStatus !== "") actionStatusTimer.restart()
      } else {
        root.desiredActive = -1
        root.actionStatus = ""
        // systemctl's one line rarely names the cause; the journal does. The
        // notice and the diagnosis wait for it.
        root._failedActionKind = kind
        root._failedActionOutput = root._actionOutput + "\n" + root._actionError
        if (kind === "start" || kind === "restart") {
          journalProcess.command = Model.journalCommand(root.unit, root.unitScope, 40)
          journalProcess.running = true
        } else {
          root.lastFailureOutput = root._failedActionOutput
          root.lastError = Model.failureMessage(root._failedActionOutput, "systemctl " + kind + " failed.")
          root.lastErrorKind = ""
        }
      }
      root.actionFinished(kind, ok)
      settleTimer.restart()
    }
  }

  Process {
    id: journalProcess
    running: false
    command: []
    stdout: StdioCollector { id: journalOut; waitForEnd: true }
    onExited: {
      var kind = root._failedActionKind
      root._failedActionKind = ""
      root.lastFailureOutput = root._failedActionOutput
        + "\n---- journalctl -u " + root.unit + " (" + root.unitScope + ") ----\n"
        + String(journalOut.text || "")
      root._failedActionOutput = ""
      root.lastError = Model.failureMessage(journalOut.text,
        "sing-box failed to " + (kind === "restart" ? "restart" : "start") + ".")
      root.lastErrorKind = kind
    }
  }

  Process {
    id: defaultAgentProcess
    running: false
    command: []
    stdout: StdioCollector { id: defaultAgentOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.defaultAgent = exitCode === 0 ? String(defaultAgentOut.text || "").trim() : ""
    }
  }

  Process {
    id: failureLogWriteProcess
    running: false
    command: []
    // Set per write, not bound: `onStarted` closes stdin to give `cat` its
    // EOF, and a binding would fight that.
    stdinEnabled: false
    onStarted: {
      failureLogWriteProcess.write(root._pendingFailureLog)
      root._pendingFailureLog = ""
      failureLogWriteProcess.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.reportError("Could not save the failure log.")
        return
      }
      diagnoseProcess.command = Model.diagnoseCommand(
        Model.diagnosePrompt(root.lastErrorKind, Model.failureLogPath(root.home),
          root.configPath, root.unit))
      diagnoseProcess.running = true
    }
  }

  Process {
    id: diagnoseProcess
    running: false
    command: []
    onExited: function(exitCode) {
      // omarchy-agent detaches the terminal, so a non-zero exit is the launch
      // itself failing rather than the agent finishing.
      if (exitCode !== 0) root.reportError("Could not open the diagnosis.")
    }
  }

  Process {
    id: trafficProcess
    running: false
    stdinEnabled: false
    command: root.apiBase === "" ? [] : SingboxApi.trafficCommand(root.apiBase, root.apiSecret !== "")
    onStarted: root.writeApiAuth(trafficProcess)
    stdout: SplitParser {
      onRead: function(line) {
        var sample = SingboxApi.parseTrafficLine(line)
        if (!sample) return
        var now = Date.now() / 1000
        // First sample of a new stream: charge the time it was down to the
        // history before appending to it, so the gap occupies the width it
        // really lasted instead of vanishing between two adjacent points.
        if (root.trafficAnchor === null && root.trafficIdleSince > 0) {
          var gap = now - root.trafficIdleSince
          root.upHistory = Model.padHistory(root.upHistory, gap, Model.HISTORY_LIMIT)
          root.downHistory = Model.padHistory(root.downHistory, gap, Model.HISTORY_LIMIT)
          root.trafficIdleSince = 0
        }
        var reading = SingboxApi.trafficRate(root.trafficAnchor, sample, now)
        if (!reading) return
        root.trafficAnchor = reading.anchor
        if (reading.rate) {
          root.upSpeed = reading.rate.up
          root.downSpeed = reading.rate.down
          root.upHistory = Model.pushHistory(root.upHistory, reading.rate.up, Model.HISTORY_LIMIT)
          root.downHistory = Model.pushHistory(root.downHistory, reading.rate.down, Model.HISTORY_LIMIT)
        }
      }
    }
    onExited: {
      root.upSpeed = 0
      root.downSpeed = 0
      root.trafficAnchor = null
      root.trafficIdleSince = Date.now() / 1000
      // The stream ends whenever the core restarts or the network blips. Come
      // back on a delay rather than spinning on a core that is still booting.
      if (root.panelOpen) trafficRetry.restart()
    }
  }
}
