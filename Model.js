.pragma library

// Everything the panel derives rather than displays raw: the one shell probe it
// runs per refresh, the systemctl invocations it schedules, and the formatting
// and state rules the views read. Kept out of QML so it can be tested with
// plain node, without a compositor.
//
// The panel is a control surface for a core the user runs themselves: it never
// writes the sing-box config, never installs the binary, and never escalates.
// Discovery (Model.probe*) finds the core; the Clash API (SingboxApi.js) reads
// and drives it; systemctl --user handles the one unit the user pointed us at.

var PROJECT_URL = "https://github.com/xxxbrian/omarchy-singbox"
var INSTALL_HINT = "sudo pacman -S sing-box"
var DEFAULT_UNIT = "sing-box.service"
var OUTPUT_LIMIT = 262144

// ------------------------------------------------------------------- probe
//
// One probe per refresh instead of six processes. It answers: is the binary on
// PATH, is a core running and under which systemd unit (if any), which config
// files that core was started with, what systemd thinks of the unit we would
// control, and whether a system-scope core is running alongside.
//
// The running process is the primary source of truth for the config path: the
// files named on its command line are, by definition, the files the core is
// using. Only with no process running do the fallbacks apply, in order: the
// override file's `config=`, the path the panel last saw a core use, then the
// conventional locations.
var PROBE_SCRIPT = [
  "unit=\"${1:-sing-box.service}\"",
  "bin=$(command -v sing-box 2>/dev/null || true)",
  "printf 'binary=%s\\n' \"$bin\"",
  "if [ -n \"$bin\" ]; then printf 'binary_version=%s\\n' \"$(\"$bin\" version 2>/dev/null | head -n 1 || true)\"; fi",
  "pid=$(pgrep -x sing-box 2>/dev/null | head -n 1 || true)",
  "printf 'pid=%s\\n' \"$pid\"",
  "if [ -n \"$pid\" ] && [ -r \"/proc/$pid/cgroup\" ]; then",
  "  cg=$(head -n 1 \"/proc/$pid/cgroup\" 2>/dev/null || true)",
  "  case \"$cg\" in",
  "    */user.slice/*) printf 'proc_scope=user\\n' ;;",
  "    */system.slice/*) printf 'proc_scope=system\\n' ;;",
  "  esac",
  "  # The last .service in the path, excluding the user manager itself: a",
  "  # process launched from a shell sits under user@UID.service without being",
  "  # a unit of its own, and claiming that name would have the panel try to",
  "  # control the whole session.",
  "  printf 'proc_unit=%s\\n' \"$(printf '%s' \"$cg\" | grep -oE '[^/]+\\.service' | grep -v '^user@' | tail -n 1 || true)\"",
  "fi",
  "if [ -n \"$pid\" ] && [ -r \"/proc/$pid/cmdline\" ]; then",
  "  prev=''",
  "  while IFS= read -r -d '' arg || [ -n \"$arg\" ]; do",
  "    case \"$prev\" in",
  "      -c|--config) printf 'config_arg=%s\\n' \"$arg\" ;;",
  "      -C|--config-directory) printf 'config_dir=%s\\n' \"$arg\" ;;",
  "    esac",
  "    prev=\"$arg\"",
  "  done < \"/proc/$pid/cmdline\"",
  "fi",
  "systemctl --user show \"$unit\" -p LoadState -p ActiveState -p SubState -p UnitFileState -p MainPID 2>/dev/null | sed 's/^/unit_/' || true",
  "started=$(systemctl --user show \"$unit\" -p ActiveEnterTimestamp --value 2>/dev/null || true)",
  "if [ -n \"$started\" ]; then printf 'active_enter_epoch=%s\\n' \"$(date -d \"$started\" +%s 2>/dev/null || echo 0)\"; fi",
  "# The same unit name at system scope: a core packaged as a system service is",
  "# controlled through systemctl's own polkit path, so its states matter too.",
  "systemctl show \"$unit\" -p LoadState -p ActiveState -p SubState -p UnitFileState 2>/dev/null | sed 's/^/sys_/' || true",
  "sys_started=$(systemctl show \"$unit\" -p ActiveEnterTimestamp --value 2>/dev/null || true)",
  "if [ -n \"$sys_started\" ]; then printf 'sys_active_enter_epoch=%s\\n' \"$(date -d \"$sys_started\" +%s 2>/dev/null || echo 0)\"; fi",
  "for cand in \"${2:-}\" \"${3:-}\" \"$HOME/.config/sing-box/config.json\" \"/etc/sing-box/config.json\"; do",
  "  if [ -n \"$cand\" ] && [ -e \"$cand\" ]; then printf 'config_fallback=%s\\n' \"$cand\"; break; fi",
  "done",
  "printf 'now=%s\\n' \"$(date +%s)\""
].join("\n")

function probeCommand(unit, overrideConfigPath, lastKnownConfigPath) {
  return ["bash", "-c", PROBE_SCRIPT, "omarchy-singbox-probe",
    String(unit || ""), String(overrideConfigPath || ""), String(lastKnownConfigPath || "")]
}

function emptyProbe() {
  return {
    binaryPath: "",
    binaryVersion: "",
    pid: 0,
    procScope: "",        // "" | user | system — how the running core is hosted
    procUnit: "",         // unit name derived from the running core's cgroup
    configArgs: [],       // -c paths the running core was started with
    configDirs: [],       // -C dirs the running core was started with
    unitLoaded: false,    // the user-scope unit the panel would control
    activeState: "unknown",
    subState: "",
    unitFileState: "",
    mainPid: 0,
    startedAt: 0,
    sysUnitLoaded: false, // the same unit name, at system scope
    sysActiveState: "unknown",
    sysSubState: "",
    sysUnitFileState: "",
    sysStartedAt: 0,
    configFallback: "",
    now: 0
  }
}

function parseProbe(text) {
  var probe = emptyProbe()
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var eq = line.indexOf("=")
    if (eq < 0) continue
    var key = line.substring(0, eq).trim()
    var value = line.substring(eq + 1).trim()
    if (key === "binary") probe.binaryPath = value
    else if (key === "binary_version") probe.binaryVersion = parseBinaryVersion(value)
    else if (key === "pid") probe.pid = Number(value) || 0
    else if (key === "proc_scope") probe.procScope = value
    else if (key === "proc_unit") probe.procUnit = value
    else if (key === "config_arg") { if (value !== "") probe.configArgs.push(value) }
    else if (key === "config_dir") { if (value !== "") probe.configDirs.push(value) }
    else if (key === "unit_LoadState") probe.unitLoaded = value === "loaded"
    else if (key === "unit_ActiveState") probe.activeState = value || "unknown"
    else if (key === "unit_SubState") probe.subState = value
    else if (key === "unit_UnitFileState") probe.unitFileState = value
    else if (key === "unit_MainPID") probe.mainPid = Number(value) || 0
    else if (key === "active_enter_epoch") probe.startedAt = Number(value) || 0
    else if (key === "sys_LoadState") probe.sysUnitLoaded = value === "loaded"
    else if (key === "sys_ActiveState") probe.sysActiveState = value || "unknown"
    else if (key === "sys_SubState") probe.sysSubState = value
    else if (key === "sys_UnitFileState") probe.sysUnitFileState = value
    else if (key === "sys_active_enter_epoch") probe.sysStartedAt = Number(value) || 0
    else if (key === "config_fallback") probe.configFallback = value
    else if (key === "now") probe.now = Number(value) || 0
  }
  return probe
}

// `sing-box version` prints "sing-box version 1.13.19" on its first line.
function parseBinaryVersion(line) {
  var text = String(line === undefined || line === null ? "" : line).trim()
  var match = text.match(/sing-box\s+version\s+(\S+)/)
  return match ? match[1] : text
}

// The config specs the panel should read and check: what the running core was
// started with wins; the fallbacks only speak for a core that is not running.
// Each spec is { kind: "file" | "dir", path }.
function configSpecs(probe) {
  var state = probe || emptyProbe()
  var specs = []
  var i
  for (i = 0; i < state.configArgs.length; i++) specs.push({ kind: "file", path: state.configArgs[i] })
  for (i = 0; i < state.configDirs.length; i++) specs.push({ kind: "dir", path: state.configDirs[i] })
  if (specs.length === 0 && state.configFallback !== "")
    specs.push({ kind: "file", path: state.configFallback })
  return specs
}

function configDisplayPath(probe) {
  var specs = configSpecs(probe)
  if (specs.length === 0) return ""
  var parts = []
  for (var i = 0; i < specs.length; i++)
    parts.push(specs[i].kind === "dir" ? specs[i].path + "/" : specs[i].path)
  return parts.join(" + ")
}

// -------------------------------------------------------------- config read
//
// The helper opens each path with no-follow and nonblocking flags, then checks
// and reads through that same descriptor. QML only receives clash_api fields.
function configReadCommand(readerPath, specs) {
  var command = ["python3", String(readerPath), "config"]
  var list = specs || []
  for (var i = 0; i < list.length; i++)
    command.push(String(list[i].kind) + ":" + String(list[i].path))
  return command
}

// One stat per refresh for the config page. Only the first spec is statted:
// it is the primary file, and the page names the rest without dating them.
function configStatCommand(readerPath, specs) {
  var list = specs || []
  var path = list.length > 0 ? String(list[0].path) : ""
  return ["python3", String(readerPath), "stat", path]
}

function parseConfigStat(text) {
  var result = { size: 0, mtime: 0, readable: false, present: false }
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var eq = lines[i].indexOf("=")
    if (eq < 0) continue
    var key = lines[i].substring(0, eq).trim()
    var value = lines[i].substring(eq + 1).trim()
    if (key === "size") { result.size = Number(value) || 0; result.present = true }
    else if (key === "mtime") result.mtime = Number(value) || 0
    else if (key === "readable") result.readable = value === "1"
  }
  return result
}

// ---------------------------------------------------------------- commands
//
// Service control runs plain systemctl in the scope that owns the unit. The
// panel itself holds no privileges: at system scope, systemctl asks polkit,
// and the desktop's own agent puts the question to the user. Consent is the
// user's to give per action — never a privileged helper, never silent.

function scopeArgs(scope) {
  return String(scope || "user") === "system" ? ["systemctl"] : ["systemctl", "--user"]
}

function startCommand(unit, scope) { return scopeArgs(scope).concat(["start", String(unit || DEFAULT_UNIT)]) }
function stopCommand(unit, scope) { return scopeArgs(scope).concat(["stop", String(unit || DEFAULT_UNIT)]) }
function restartCommand(unit, scope) { return scopeArgs(scope).concat(["restart", String(unit || DEFAULT_UNIT)]) }

function checkCommand(binaryPath, specs) {
  var args = [String(binaryPath || "sing-box"), "check"]
  var list = specs || []
  for (var i = 0; i < list.length; i++) {
    args.push(list[i].kind === "dir" ? "-C" : "-c")
    args.push(String(list[i].path))
  }
  return ["bash", "-c",
    "set -o pipefail; \"$@\" 2>&1 | head -c 262144; exit ${PIPESTATUS[0]}",
    "omarchy-singbox-check"].concat(args)
}

// Journal tail for a restart that did not come back: `check` passes configs
// that still fail at start (dangling outbound references resolve at run), so
// the journal is where the real error lands. The system journal may refuse a
// user outside the journal groups; an empty tail falls back to the notice.
function journalCommand(unit, scope, lines) {
  var args = String(scope || "user") === "system" ? ["journalctl"] : ["journalctl", "--user"]
  args = args.concat(["-u", String(unit || DEFAULT_UNIT),
    "-n", String(Number(lines) || 40), "--no-pager", "--output", "cat"])
  return ["bash", "-c", "\"$@\" 2>/dev/null | head -c 262144",
    "omarchy-singbox-journal"].concat(args)
}

// Must leave the panel's process group: Quickshell kills the group when the
// Process exits, and an editor spawned from the bar cannot own a TTY.
function openEditorCommand(path) {
  return ["bash", "-c",
    "if command -v omarchy-launch-config-editor >/dev/null 2>&1; then launcher=omarchy-launch-config-editor; " +
    "elif command -v omarchy-launch-editor >/dev/null 2>&1; then launcher=omarchy-launch-editor; " +
    "elif command -v xdg-open >/dev/null 2>&1; then launcher=xdg-open; " +
    "else exit 9; fi; " +
    "setsid \"$launcher\" \"$1\" >/dev/null 2>&1 & exit 0",
    "omarchy-singbox-edit", String(path || "")]
}

function documentationCommand() {
  return ["omarchy", "launch", "browser", "https://sing-box.sagernet.org/configuration/"]
}

// ---------------------------------------------------------- connection state
//
// One place decides what the panel is looking at, so the hero, the bar icon,
// and the enabled state of every control cannot disagree.
//
// `coreRunning` is the process, not the unit: a core started by hand, by a
// system unit, or by anything else still gets a live panel. The unit states
// only decide whether the panel's own controls are offered.

function connectionState(probe, api) {
  var state = probe || emptyProbe()
  var apiState = String(api || "unknown")
  var running = state.pid > 0

  if (state.binaryPath === "" && !running)
    return { key: "binary_missing", label: "sing-box not installed", detail: "Install sing-box to use this panel.", active: false, tone: "idle" }
  if (!running) {
    // The user-scope unit speaks first; the system-scope one only when there
    // is no user unit to speak for the core.
    var unitState = state.unitLoaded ? state.activeState
      : (state.sysUnitLoaded ? state.sysActiveState : "")
    if (unitState === "failed")
      return { key: "failed", label: "Failed", detail: "The service failed to start.", active: false, tone: "urgent" }
    if (unitState === "activating")
      return { key: "starting", label: "Starting…", detail: "The service is coming up.", active: true, tone: "idle" }
    if (unitState !== "")
      return { key: "stopped", label: "Stopped", detail: "sing-box is not running.", active: false, tone: "idle" }
    return { key: "no_core", label: "No core detected", detail: "Run sing-box, or point the panel at your service.", active: false, tone: "idle" }
  }
  if (apiState === "unauthorized")
    return { key: "unauthorized", label: "Running", detail: "Running, but the API secret is rejected.", active: true, tone: "urgent" }
  if (apiState === "disabled")
    return { key: "running_no_api", label: "Running", detail: "Running; no Clash API in the config.", active: true, tone: "idle" }
  if (apiState !== "ok")
    return { key: "running_no_api", label: "Running", detail: "Running; the Clash API is not answering.", active: true, tone: "idle" }
  return { key: "running", label: "Connected", detail: "", active: true, tone: "good" }
}

// Which systemctl scope owns the unit the panel would control, or "" when
// there is nothing controllable. A running core answers with the scope that
// actually owns it; a stopped one with whichever scope has a unit on file,
// the user's first. A core running outside systemd has no unit to restart —
// only that case is watch-only.
function serviceScope(probe) {
  var state = probe || emptyProbe()
  if (state.pid > 0) {
    if (state.procScope === "system") return state.procUnit !== "" ? "system" : ""
    if (state.procScope === "user" && state.procUnit !== "") return "user"
    return state.unitLoaded ? "user" : ""
  }
  if (state.unitLoaded && state.unitFileState !== "") return "user"
  if (state.sysUnitLoaded && state.sysUnitFileState !== "") return "system"
  return ""
}

function canControlService(probe) {
  return serviceScope(probe) !== ""
}

function serviceHint(probe) {
  var state = probe || emptyProbe()
  if (serviceScope(state) === "system")
    return "System service — actions ask for authorization."
  if (state.pid > 0 && state.procUnit === "" && !state.unitLoaded)
    return "Running outside systemd — the panel can watch it, not restart it."
  if (state.pid === 0 && !state.unitLoaded && !state.sysUnitLoaded)
    return "No service found. Set `unit=` in the override file to name yours."
  return ""
}

// Seconds the serving unit has been up, or 0 when nothing systemd-owned is
// active — one place, so the uptime row cannot disagree with the scope.
function uptimeSeconds(probe, nowSeconds) {
  var state = probe || emptyProbe()
  var scope = serviceScope(state)
  var suppliedNow = Number(nowSeconds)
  var now = isFinite(suppliedNow) && suppliedNow > 0 ? suppliedNow : state.now
  if (state.pid === 0 || now <= 0) return 0
  if (scope === "user" && state.activeState === "active" && state.startedAt > 0)
    return Math.max(0, now - state.startedAt)
  if (scope === "system" && state.sysActiveState === "active" && state.sysStartedAt > 0)
    return Math.max(0, now - state.sysStartedAt)
  return 0
}

// ------------------------------------------------------------------ notices
//
// A message from outside is shortened before it is shown, never by the clamp:
// journal lines and check errors can quote URLs and whole payloads.

function stripAnsi(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
}

// Only the host survives: it identifies the endpoint without carrying the
// credential a proxy URL's path or query might be.
function redactUrls(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/https?:\/\/[^\s'"()<>]+/g, function (url) {
      var rest = url.replace(/^https?:\/\//, "")
      var cut = rest.search(/[\/?#]/)
      return cut < 0 ? rest : rest.substring(0, cut) + "/…"
    })
}

function collapseQuoted(text, max) {
  var limit = Number(max) || 60
  return String(text === undefined || text === null ? "" : text)
    .replace(/"([^"]*)"/g, function (whole, inner) {
      return inner.length > limit ? '"…"' : whole
    })
}

// Redact before shortening, always: eliding first could stop halfway through
// a token and leave the front of it on screen.
function noticeMessage(text) {
  return elide(collapseQuoted(redactUrls(stripAnsi(text)), 60), 240)
}

function elide(text, max) {
  var value = String(text === undefined || text === null ? "" : text).replace(/\s+/g, " ").trim()
  var limit = Number(max) || 80
  return value.length > limit ? value.substring(0, limit - 1) + "…" : value
}

// The line worth showing from a failed command's output: the last non-empty
// line, which is where both `sing-box check` and systemctl put the cause.
function failureMessage(output, fallback) {
  var trimmed = stripAnsi(output).trim()
  if (trimmed !== "") {
    var lines = trimmed.split("\n")
    return noticeMessage(lines[lines.length - 1].trim())
  }
  return String(fallback || "The command failed.")
}

// -------------------------------------------------------------- AI diagnosis
//
// Same shape as omarchy-crash-watch and mihoro: check that a default agent has
// been chosen, write the facts to a 0600 file, and point the agent at it. The
// prompt becomes argv, which the process list shows to every user, so it
// carries paths rather than the failure output.

var DIAGNOSABLE = ["check", "restart", "start"]

function canDiagnose(kind, agent) {
  return String(agent || "") !== "" && DIAGNOSABLE.indexOf(String(kind || "")) >= 0
}

function defaultAgentCommand() {
  return ["bash", "-c", "omarchy-default-agent 2>/dev/null | head -c 4096"]
}

function failureLogPath(home) {
  return String(home || "") + "/.local/state/omarchy/singbox/last-failure.log"
}

var FAILURE_LOG_SCRIPT = [
  "set -eu",
  "target=$1",
  "dir=$(dirname -- \"$target\")",
  "mkdir -p -- \"$dir\"",
  "tmp=$(mktemp -- \"$dir/.singbox-failure.XXXXXX\")",
  "trap 'rm -f -- \"$tmp\"' EXIT",
  "cat > \"$tmp\"",
  "chmod 600 -- \"$tmp\"",
  "mv -f -- \"$tmp\" \"$target\"",
  "trap - EXIT"
].join("\n")

function failureLogWriteCommand(path) {
  return ["bash", "-c", FAILURE_LOG_SCRIPT, "omarchy-singbox-failure-log", String(path)]
}

function diagnosePrompt(kind, logPath, configPath, unit) {
  var what = kind === "check" ? "`sing-box check` rejected the configuration"
    : "restarting the sing-box service failed"
  return [
    what + " on this Omarchy machine and I want to know why.",
    "",
    "The command output is in:",
    "  " + String(logPath || ""),
    "",
    "The sing-box configuration in use:",
    "  " + String(configPath || ""),
    "",
    "Proxy configs carry credentials — server addresses, passwords, UUIDs.",
    "Read them if you need to, but do not print them, and do not put them in a",
    "commit, an issue, or a paste.",
    "",
    "Work out what failed and tell me how to fix it. Worth ruling out: a JSON",
    "syntax error, an outbound tag referenced but never defined (check passes",
    "those; they fail at start), and the service failing to come back up",
    "(journalctl --user -u " + String(unit || DEFAULT_UNIT) + " -n 50 --no-pager)."
  ].join("\n")
}

function diagnoseCommand(prompt) {
  return ["omarchy-agent", "--prompt", String(prompt || "")]
}

// ------------------------------------------------------------------ history
//
// Throughput is sampled from the `/traffic` stream that already feeds the two
// speed readouts, so the curve behind each one is drawn from the very numbers
// printed on top of it and cannot drift from them. See omarchy-mihoro, whose
// implementation this is.

var HISTORY_LIMIT = 60

function pushHistory(history, sample, limit) {
  var cap = Math.max(1, Math.floor(Number(limit) || 0) || 1)
  var list = Array.isArray(history) ? history : []
  var next = list.slice(Math.max(0, list.length - cap + 1))
  var reading = Number(sample)
  next.push(isFinite(reading) && reading > 0 ? reading : 0)
  return next
}

function padHistory(history, slots, limit) {
  var list = Array.isArray(history) ? history : []
  var count = Math.floor(Number(slots))
  if (!isFinite(count) || count <= 0) return list
  var cap = Math.max(1, Math.floor(Number(limit) || 0) || 1)
  var next = list
  var fill = Math.min(count, cap)
  for (var i = 0; i < fill; i++) next = pushHistory(next, 0, cap)
  return next
}

function peakOf(history) {
  var list = Array.isArray(history) ? history : []
  var peak = 0
  for (var i = 0; i < list.length; i++) {
    var seen = Number(list[i])
    if (isFinite(seen) && seen > peak) peak = seen
  }
  return peak
}

function sparkline(history, capacity, scalePeak) {
  var list = Array.isArray(history) ? history : []
  var span = Math.max(2, Math.floor(Number(capacity) || 0) || 2) - 1
  var forced = Number(scalePeak)
  var peak = (isFinite(forced) && forced > 0) ? forced : peakOf(list)
  var points = []
  var i
  var newest = list.length - 1
  for (i = 0; i < list.length; i++) {
    var reading = Number(list[i])
    if (!isFinite(reading) || reading < 0) reading = 0
    points.push({
      x: Math.max(0, 1 - (newest - i) / span),
      y: peak > 0 ? Math.min(1, reading / peak) : 0
    })
  }
  var lead = []
  var firstX = points.length > 0 ? points[0].x : 1
  if (firstX > 0) {
    lead.push({ x: 0, y: 0 })
    lead.push({ x: firstX, y: 0 })
  }
  return { points: points, lead: lead, peak: peak }
}

// ---------------------------------------------------------------- formatting

var UNITS = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

function formatBytes(bytes) {
  var value = Number(bytes)
  if (!isFinite(value) || value <= 0) return "0 B"
  var unit = 0
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024
    unit++
  }
  var digits = unit === 0 ? 0 : (value < 10 ? 1 : 0)
  return value.toFixed(digits) + " " + UNITS[unit]
}

function formatSpeed(bytesPerSecond) {
  return formatBytes(bytesPerSecond) + "/s"
}

function formatDuration(seconds) {
  var total = Math.floor(Number(seconds))
  if (!isFinite(total) || total < 0) return "—"
  if (total < 60) return total + "s"
  var minutes = Math.floor(total / 60)
  if (minutes < 60) return minutes + "m " + (total % 60) + "s"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h " + (minutes % 60) + "m"
  return Math.floor(hours / 24) + "d " + (hours % 24) + "h"
}

function formatAgo(epochSeconds, nowSeconds) {
  var then = Number(epochSeconds)
  var now = Number(nowSeconds)
  if (!isFinite(then) || then <= 0 || !isFinite(now) || now <= 0) return "—"
  var delta = now - then
  if (delta < 60) return "just now"
  return formatDuration(delta).split(" ")[0] + " ago"
}

function formatDelay(ms) {
  var value = Number(ms)
  if (!isFinite(value) || value <= 0) return ""
  return Math.round(value) + " ms"
}
