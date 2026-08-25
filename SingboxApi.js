.pragma library

// sing-box's Clash API compatibility layer — the same surface metacubexd
// talks to. Everything the panel reads live comes from here: the running
// mode and the modes the config defines, the version actually serving,
// traffic, open connections, and the proxy groups. The mode switch and the
// proxy selection also go through it, because both take effect on the
// running core without a restart — the only kind of write sing-box offers.
//
// Requests go through curl rather than XMLHttpRequest because that is the
// shell's established way of reaching the network from a plugin, and it gives
// the panel an exit code and a stderr to classify failures with.
//
// `-w '\n%{http_code}'` appends the status to the body instead of using `-f`,
// so a 401 from a wrong secret stays distinguishable from a core that is not
// listening at all. Those two need different things said to the user.
//
// Where this differs from mihomo, verified against sing-box 1.13:
//   - `/configs` carries `mode-list`, the clash_mode values the config's route
//     rules actually use. A config with no clash_mode rules lists exactly one
//     mode, and there is nothing to switch.
//   - Mode names are whatever the config says. The panel reads them and does
//     not switch them: the groups are the controls, sing-box style.
//   - GLOBAL appears in `/proxies` but PUT to it is a 404: sing-box has no
//     selectable global group. Only `Selector` groups accept a selection.
//   - There is no config reload and no runtime TUN toggle. Config changes go
//     through systemd, not through here.

var TIMEOUT_SECONDS = "4"

function isWildcardHost(host) {
  var text = String(host || "").trim()
  return text === "" || text === "*" || text === "0.0.0.0" || text === "::" || text === "[::]"
}

// Strip any scheme, honour bracketed IPv6, and split the port off the right.
// A controller with no port is not addressable.
function parseController(controller) {
  var text = String(controller === undefined || controller === null ? "" : controller).trim()
  if (text === "") return null
  if (/^unix:/i.test(text)) return null
  text = text.replace(/^https?:\/\//i, "").replace(/\/+$/, "")

  if (text.charAt(0) === "[") {
    var close = text.indexOf("]")
    if (close < 0) return null
    var rest = text.substring(close + 1)
    if (rest.charAt(0) !== ":") return null
    var bracketPort = rest.substring(1).trim()
    if (bracketPort === "") return null
    return { host: text.substring(0, close + 1), port: bracketPort }
  }

  var split = text.lastIndexOf(":")
  if (split < 0) return null
  var host = text.substring(0, split).trim()
  var port = text.substring(split + 1).trim()
  if (port === "") return null
  return { host: host, port: port }
}

// A controller bound to every interface is still only reachable from here
// over loopback, so `0.0.0.0` and `[::]` become `127.0.0.1`.
function baseUrl(controller) {
  var parsed = parseController(controller)
  if (!parsed) return ""
  var host = isWildcardHost(parsed.host) ? "127.0.0.1" : parsed.host
  if (host.indexOf(":") >= 0 && host.charAt(0) !== "[") host = "[" + host + "]"
  return "http://" + host + ":" + parsed.port
}

function authArgs(secret) {
  var token = String(secret === undefined || secret === null ? "" : secret)
  return token === "" ? [] : ["-H", "Authorization: Bearer " + token]
}

function getCommand(base, secret, path) {
  return ["curl", "-sS", "--max-time", TIMEOUT_SECONDS, "-w", "\\n%{http_code}"]
    .concat(authArgs(secret))
    .concat([String(base) + String(path)])
}

function versionCommand(base, secret) { return getCommand(base, secret, "/version") }
function configsCommand(base, secret) { return getCommand(base, secret, "/configs") }
function connectionsCommand(base, secret) { return getCommand(base, secret, "/connections") }
function proxiesCommand(base, secret) { return getCommand(base, secret, "/proxies") }

function selectProxyCommand(base, secret, group, name) {
  return ["curl", "-sS", "--max-time", TIMEOUT_SECONDS, "-w", "\\n%{http_code}",
          "-X", "PUT", "-H", "Content-Type: application/json",
          "-d", JSON.stringify({ name: String(name || "") })]
    .concat(authArgs(secret))
    .concat([String(base) + "/proxies/" + encodeURIComponent(String(group || ""))])
}

// A URL that answers 204 fast; the same one every Clash client defaults to.
var DELAY_TEST_URL = "https://www.gstatic.com/generate_204"
var DELAY_TIMEOUT_MS = 5000

function delayCommand(base, secret, name) {
  return ["curl", "-sS", "--max-time", "8", "-w", "\\n%{http_code}"]
    .concat(authArgs(secret))
    .concat([String(base) + "/proxies/" + encodeURIComponent(String(name || ""))
      + "/delay?timeout=" + DELAY_TIMEOUT_MS
      + "&url=" + encodeURIComponent(DELAY_TEST_URL)])
}

// `/traffic` pushes one JSON object per second for as long as the socket is
// held open, so live speeds cost one long-lived curl while the panel is open
// instead of a poll loop. `--no-buffer` is what makes each line arrive as it
// is written rather than in 4KB chunks.
function trafficCommand(base, secret) {
  return ["curl", "-sS", "-N", "--no-buffer"]
    .concat(authArgs(secret))
    .concat([String(base) + "/traffic"])
}

function splitResponse(text) {
  var raw = String(text === undefined || text === null ? "" : text)
  var cut = raw.lastIndexOf("\n")
  if (cut < 0) return { status: parseInt(raw, 10) || 0, body: "" }
  return { status: parseInt(raw.substring(cut + 1), 10) || 0, body: raw.substring(0, cut) }
}

// One classifier for every call, so "unreachable", "wrong secret", and "the
// core answered with an error" are never collapsed into a single failure.
function classify(exitCode, stdout, stderr) {
  var response = splitResponse(stdout)
  if (Number(exitCode) !== 0 || response.status === 0) {
    return {
      ok: false,
      code: "unreachable",
      status: response.status,
      body: response.body,
      message: "The Clash API is not answering."
    }
  }
  if (response.status === 401 || response.status === 403) {
    return {
      ok: false,
      code: "unauthorized",
      status: response.status,
      body: response.body,
      message: "sing-box rejected the API secret."
    }
  }
  if (response.status >= 400) {
    return {
      ok: false,
      code: "http_error",
      status: response.status,
      body: response.body,
      message: apiErrorMessage(response.body, "The Clash API returned HTTP " + response.status + ".")
    }
  }
  return { ok: true, code: "ok", status: response.status, body: response.body, message: "" }
}

// Error bodies are `{"message": "..."}` — "Must be a Selector", "Resource not
// found" — and quoting them beats quoting a status code.
function apiErrorMessage(body, fallback) {
  var payload = parseJson(body)
  if (payload && typeof payload.message === "string" && payload.message !== "")
    return payload.message
  return String(fallback || "")
}

function parseJson(text) {
  try {
    var value = JSON.parse(String(text || ""))
    return (value && typeof value === "object") ? value : null
  } catch (error) {
    return null
  }
}

// `/version` answers `{"meta":true,"version":"sing-box 1.13.19"}` — the
// binary's own name is in the string, and repeating it under a sing-box
// heading says nothing.
function parseVersion(body) {
  var payload = parseJson(body)
  if (!payload) return { version: "", meta: false }
  var version = String(payload.version || "").replace(/^sing-box\s+/, "")
  return { version: version, meta: payload.meta === true }
}

function parseConfigs(body) {
  var payload = parseJson(body)
  if (!payload) return null
  var rawList = payload["mode-list"]
  var modeList = []
  if (Array.isArray(rawList)) {
    for (var i = 0; i < rawList.length; i++) {
      var entry = String(rawList[i] || "")
      if (entry !== "") modeList.push(entry)
    }
  }
  return {
    mode: String(payload.mode || ""),
    modeList: modeList,
    mixedPort: Number(payload["mixed-port"]) || 0,
    port: Number(payload.port) || 0,
    socksPort: Number(payload["socks-port"]) || 0,
    allowLan: payload["allow-lan"] === true,
    logLevel: String(payload["log-level"] || "")
  }
}

// Only the totals and the count are kept. The connections array carries a
// metadata object per entry and can run to hundreds of them; holding that in
// the panel to render two numbers would be the most expensive thing it does.
function parseConnections(body) {
  var payload = parseJson(body)
  if (!payload) return null
  var list = payload.connections
  return {
    count: Array.isArray(list) ? list.length : 0,
    downloadTotal: Number(payload.downloadTotal) || 0,
    uploadTotal: Number(payload.uploadTotal) || 0,
    memory: Number(payload.memory) || 0
  }
}

// The groups worth showing: entries with an `all` list. GLOBAL is excluded —
// sing-box exposes it read-only and refuses selection on it — and `Selector`
// is the only type whose selection sticks, so the rest render without a
// pointer. Order follows GLOBAL's own `all` list when present: that is the
// order the config declared the groups in, where an object's key order is
// whatever the JSON encoder felt like.
function parseProxyGroups(body) {
  var payload = parseJson(body)
  if (!payload) return null
  var proxies = payload.proxies
  if (!proxies || typeof proxies !== "object") return null

  var names = []
  var global = proxies.GLOBAL
  var seen = {}
  var i
  if (global && Array.isArray(global.all)) {
    for (i = 0; i < global.all.length; i++) {
      var candidate = String(global.all[i] || "")
      if (candidate !== "" && proxies[candidate] && Array.isArray(proxies[candidate].all)) {
        names.push(candidate)
        seen[candidate] = true
      }
    }
  }
  for (var key in proxies) {
    if (key === "GLOBAL" || seen[key]) continue
    if (proxies[key] && Array.isArray(proxies[key].all)) names.push(key)
  }

  var groups = []
  for (i = 0; i < names.length; i++) {
    var group = proxies[names[i]]
    var members = []
    for (var j = 0; j < group.all.length; j++) {
      var member = String(group.all[j] || "")
      if (member === "") continue
      var detail = proxies[member]
      members.push({
        name: member,
        type: detail ? String(detail.type || "") : "",
        delay: detail ? latestDelay(detail) : 0
      })
    }
    groups.push({
      name: names[i],
      type: String(group.type || ""),
      now: String(group.now || ""),
      selectable: String(group.type || "") === "Selector",
      members: members
    })
  }
  return groups
}

// The API keeps a short history per proxy; the newest entry is the number
// the dashboards print.
function latestDelay(detail) {
  var history = detail && Array.isArray(detail.history) ? detail.history : []
  if (history.length === 0) return 0
  var last = history[history.length - 1]
  return last ? Number(last.delay) || 0 : 0
}

function parseDelay(body) {
  var payload = parseJson(body)
  if (!payload) return 0
  return Number(payload.delay) || 0
}

// `Number(null)` is 0 and `Number("")` is 0, either of which would pass for a
// counter that is simply absent. A missing field has to stay missing.
function finiteNumber(value) {
  if (value === undefined || value === null || value === "") return NaN
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : NaN
}

// A `/traffic` message carries a per-interval reading (`up`/`down`) and, from
// cores that send them, cumulative counters. sing-box 1.13 sends only the
// per-interval pair; the totals path is kept for the cores that do better,
// because differencing totals is exact where snapshot buffers are not.
function parseTrafficLine(line) {
  var payload = parseJson(line)
  if (!payload) return null
  var up = Number(payload.up)
  var down = Number(payload.down)
  if (!isFinite(up) || !isFinite(down)) return null
  var upTotal = finiteNumber(payload.upTotal)
  var downTotal = finiteNumber(payload.downTotal)
  var hasTotals = isFinite(upTotal) && isFinite(downTotal)
  return {
    up: up,
    down: down,
    upTotal: hasTotals ? upTotal : 0,
    downTotal: hasTotals ? downTotal : 0,
    hasTotals: hasTotals
  }
}

var MIN_RATE_INTERVAL_SECONDS = 0.2

// `anchor` is the last reading a rate was published from, not the previous
// sample. When a sample arrives too soon after it to divide by, the anchor
// stays put: those bytes remain counted and land in the next reading instead
// of being divided by a near-zero interval into a spike.
function trafficRate(anchor, sample, atSeconds) {
  if (!sample) return null
  var now = Number(atSeconds)
  if (!isFinite(now) || now < 0) now = 0

  if (!sample.hasTotals)
    return { rate: { up: sample.up, down: sample.down }, anchor: null }

  var next = { up: sample.upTotal, down: sample.downTotal, at: now }

  if (!anchor || sample.upTotal < anchor.up || sample.downTotal < anchor.down)
    return { rate: { up: sample.up, down: sample.down }, anchor: next }

  var elapsed = now - anchor.at
  if (!(elapsed >= MIN_RATE_INTERVAL_SECONDS))
    return { rate: null, anchor: anchor }

  return {
    rate: {
      up: (sample.upTotal - anchor.up) / elapsed,
      down: (sample.downTotal - anchor.down) / elapsed
    },
    anchor: next
  }
}
