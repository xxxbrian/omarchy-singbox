const assert = require("assert")
// Objects built inside the vm context carry that realm's prototypes, which
// deepStrictEqual refuses; comparing the JSON shape is what the tests mean.
function eq(actual, expected) {
  assert.strictEqual(JSON.stringify(actual), JSON.stringify(expected))
}
const { load } = require("./load")

const Model = load("Model.js")

// ---------------------------------------------------------------- probe parse

{
  const probe = Model.parseProbe([
    "binary=/usr/bin/sing-box",
    "binary_version=sing-box version 1.13.19",
    "pid=1234",
    "proc_scope=user",
    "proc_unit=sing-box.service",
    "config_arg=/home/u/.config/sing-box/config.json",
    "config_dir=/home/u/.config/sing-box/conf.d",
    "unit_LoadState=loaded",
    "unit_ActiveState=active",
    "unit_SubState=running",
    "unit_UnitFileState=enabled",
    "unit_MainPID=1234",
    "active_enter_epoch=1700000000",
    "sys_LoadState=loaded",
    "sys_ActiveState=inactive",
    "sys_SubState=dead",
    "sys_UnitFileState=disabled",
    "sys_active_enter_epoch=0",
    "config_fallback=/etc/sing-box/config.json",
    "now=1700000100"
  ].join("\n"))
  assert.strictEqual(probe.binaryPath, "/usr/bin/sing-box")
  assert.strictEqual(probe.binaryVersion, "1.13.19")
  assert.strictEqual(probe.pid, 1234)
  assert.strictEqual(probe.procScope, "user")
  assert.strictEqual(probe.procUnit, "sing-box.service")
  eq(probe.configArgs, ["/home/u/.config/sing-box/config.json"])
  eq(probe.configDirs, ["/home/u/.config/sing-box/conf.d"])
  assert.strictEqual(probe.unitLoaded, true)
  assert.strictEqual(probe.activeState, "active")
  assert.strictEqual(probe.unitFileState, "enabled")
  assert.strictEqual(probe.startedAt, 1700000000)
  assert.strictEqual(probe.sysUnitLoaded, true)
  assert.strictEqual(probe.sysActiveState, "inactive")
  assert.strictEqual(probe.sysUnitFileState, "disabled")
  assert.strictEqual(probe.now, 1700000100)
}

// Empty and garbage input parse to the empty probe rather than throwing.
{
  assert.strictEqual(Model.parseProbe("").pid, 0)
  assert.strictEqual(Model.parseProbe(null).binaryPath, "")
  assert.strictEqual(Model.parseProbe("no equals here\n===\n").now, 0)
}

// The probe script never claims the user manager as the core's unit.
{
  assert.ok(Model.PROBE_SCRIPT.indexOf("grep -v '^user@'") >= 0,
    "probe must exclude user@UID.service from unit discovery")
}

// ---------------------------------------------------------------- config specs

{
  // The running core's command line wins over every fallback.
  const probe = Model.emptyProbe()
  probe.configArgs = ["/a.json"]
  probe.configDirs = ["/b"]
  probe.configFallback = "/etc/sing-box/config.json"
  eq(Model.configSpecs(probe), [
    { kind: "file", path: "/a.json" },
    { kind: "dir", path: "/b" }
  ])
  assert.strictEqual(Model.configDisplayPath(probe), "/a.json + /b/")
}

{
  // With no process, the fallback is the config.
  const probe = Model.emptyProbe()
  probe.configFallback = "/etc/sing-box/config.json"
  eq(Model.configSpecs(probe), [
    { kind: "file", path: "/etc/sing-box/config.json" }
  ])
}

{
  // With nothing at all, there is no config to name.
  eq(Model.configSpecs(Model.emptyProbe()), [])
  assert.strictEqual(Model.configDisplayPath(Model.emptyProbe()), "")
}

// ------------------------------------------------------------------- commands

{
  eq(Model.startCommand("my.service", "user"),
    ["systemctl", "--user", "start", "my.service"])
  eq(Model.stopCommand("", ""),
    ["systemctl", "--user", "stop", "sing-box.service"])
  // System scope drops --user; systemctl itself asks polkit for consent.
  eq(Model.restartCommand("sing-box.service", "system"),
    ["systemctl", "restart", "sing-box.service"])
  eq(
    Model.checkCommand("/usr/bin/sing-box",
      [{ kind: "file", path: "/a.json" }, { kind: "dir", path: "/b" }]),
    ["/usr/bin/sing-box", "check", "-c", "/a.json", "-C", "/b"])
  const journal = Model.journalCommand("sing-box.service", "user", 40)
  assert.ok(journal.indexOf("--user") >= 0 && journal.indexOf("sing-box.service") >= 0)
  const sysJournal = Model.journalCommand("sing-box.service", "system", 40)
  assert.ok(sysJournal.indexOf("--user") === -1)
}

// The editor must leave the panel's process group: Quickshell kills the group
// when the Process exits.
{
  const command = Model.openEditorCommand("/tmp/x.json")
  assert.strictEqual(command[0], "bash")
  assert.ok(command[2].indexOf("setsid") >= 0)
}

// ------------------------------------------------------------ connection state

function probeWith(overrides) {
  const probe = Model.emptyProbe()
  for (const key in overrides) probe[key] = overrides[key]
  return probe
}

{
  assert.strictEqual(Model.connectionState(Model.emptyProbe(), "unknown").key, "binary_missing")
  assert.strictEqual(
    Model.connectionState(probeWith({ binaryPath: "/usr/bin/sing-box" }), "unknown").key,
    "no_core")
  assert.strictEqual(
    Model.connectionState(probeWith({ binaryPath: "/x", unitLoaded: true, activeState: "inactive" }), "unknown").key,
    "stopped")
  assert.strictEqual(
    Model.connectionState(probeWith({ binaryPath: "/x", unitLoaded: true, activeState: "failed" }), "unknown").key,
    "failed")
  // A stopped system unit reports the same states as a user one.
  assert.strictEqual(
    Model.connectionState(probeWith({ binaryPath: "/x", sysUnitLoaded: true, sysActiveState: "inactive" }), "unknown").key,
    "stopped")
  assert.strictEqual(
    Model.connectionState(probeWith({ binaryPath: "/x", sysUnitLoaded: true, sysActiveState: "failed" }), "unknown").key,
    "failed")
  // A running core is running whoever started it, even with no binary on PATH
  // (a core from a container or a copied binary).
  assert.strictEqual(Model.connectionState(probeWith({ pid: 9 }), "ok").key, "running")
  assert.strictEqual(Model.connectionState(probeWith({ pid: 9 }), "unauthorized").key, "unauthorized")
  assert.strictEqual(Model.connectionState(probeWith({ pid: 9 }), "disabled").key, "running_no_api")
  assert.strictEqual(Model.connectionState(probeWith({ pid: 9 }), "unreachable").key, "running_no_api")
}

// The scope that owns the unit is the scope that controls it. A system-owned
// core is controllable through systemctl's polkit path; only a core running
// outside systemd is watch-only.
{
  assert.strictEqual(Model.serviceScope(
    probeWith({ pid: 9, procScope: "system", procUnit: "sing-box.service" })), "system")
  assert.strictEqual(Model.serviceScope(
    probeWith({ pid: 9, procScope: "user", procUnit: "custom.service" })), "user")
  assert.strictEqual(Model.serviceScope(probeWith({ pid: 9 })), "")
  assert.strictEqual(Model.serviceScope(
    probeWith({ unitLoaded: true, unitFileState: "enabled" })), "user")
  assert.strictEqual(Model.serviceScope(
    probeWith({ sysUnitLoaded: true, sysUnitFileState: "enabled" })), "system")
  // With units on file at both scopes, the user's wins.
  assert.strictEqual(Model.serviceScope(
    probeWith({ unitLoaded: true, unitFileState: "enabled", sysUnitLoaded: true, sysUnitFileState: "enabled" })), "user")
  assert.strictEqual(Model.serviceScope(probeWith({})), "")

  assert.strictEqual(Model.canControlService(
    probeWith({ pid: 9, procScope: "system", procUnit: "sing-box.service" })), true)
  assert.strictEqual(Model.canControlService(
    probeWith({ unitLoaded: true, unitFileState: "enabled" })), true)
  assert.strictEqual(Model.canControlService(probeWith({ pid: 9 })), false)
  assert.strictEqual(Model.canControlService(probeWith({})), false)
}

// Uptime follows the scope that is actually serving.
{
  assert.strictEqual(Model.uptimeSeconds(probeWith({
    pid: 9, procScope: "system", procUnit: "sing-box.service",
    sysActiveState: "active", sysStartedAt: 100, now: 160
  })), 60)
  assert.strictEqual(Model.uptimeSeconds(probeWith({
    pid: 9, procScope: "user", procUnit: "sing-box.service",
    unitLoaded: true, activeState: "active", startedAt: 100, now: 130
  })), 30)
  assert.strictEqual(Model.uptimeSeconds(probeWith({ pid: 9 })), 0)
  assert.strictEqual(Model.uptimeSeconds(probeWith({})), 0)
}

// -------------------------------------------------------------------- notices

{
  assert.strictEqual(Model.stripAnsi("\x1b[31mFATAL\x1b[0m fail"), "FATAL fail")
  assert.strictEqual(
    Model.redactUrls("GET https://example.com/token-abc123?k=v failed"),
    "GET example.com/… failed")
  const long = '"' + "x".repeat(100) + '"'
  assert.strictEqual(Model.collapseQuoted("body " + long, 60), 'body "…"')
  assert.ok(Model.noticeMessage("x".repeat(500)).length <= 240)
  assert.strictEqual(
    Model.failureMessage("line one\nthe real cause\n", "fallback"),
    "the real cause")
  assert.strictEqual(Model.failureMessage("", "fallback"), "fallback")
}

// ------------------------------------------------------------------- diagnose

{
  assert.strictEqual(Model.canDiagnose("check", "claude"), true)
  assert.strictEqual(Model.canDiagnose("restart", "claude"), true)
  assert.strictEqual(Model.canDiagnose("check", ""), false)
  assert.strictEqual(Model.canDiagnose("mode", "claude"), false)
  const prompt = Model.diagnosePrompt("check", "/log", "/cfg", "u.service")
  assert.ok(prompt.indexOf("/log") >= 0 && prompt.indexOf("u.service") >= 0)
  // The prompt carries paths, never the failure output.
  assert.ok(prompt.indexOf("credential") >= 0)
}

// -------------------------------------------------------------------- history

{
  let history = []
  for (let i = 0; i < 70; i++) history = Model.pushHistory(history, i, 60)
  assert.strictEqual(history.length, 60)
  assert.strictEqual(history[history.length - 1], 69)

  const padded = Model.padHistory([5], 3, 60)
  eq(padded, [5, 0, 0, 0])

  const spark = Model.sparkline([0, 5, 10], 60, 0)
  assert.strictEqual(spark.peak, 10)
  assert.strictEqual(spark.points[2].x, 1)
  assert.strictEqual(spark.points[2].y, 1)
  assert.ok(spark.lead.length === 2)
}

// ----------------------------------------------------------------- formatting

{
  assert.strictEqual(Model.formatBytes(0), "0 B")
  assert.strictEqual(Model.formatBytes(1024), "1.0 KiB")
  assert.strictEqual(Model.formatSpeed(2048), "2.0 KiB/s")
  assert.strictEqual(Model.formatDuration(30), "30s")
  assert.strictEqual(Model.formatDuration(3700), "1h 1m")
  assert.strictEqual(Model.formatAgo(100, 130), "just now")
  assert.strictEqual(Model.formatDelay(0), "")
  assert.strictEqual(Model.formatDelay(473), "473 ms")
}

console.log("test_model: ok")
