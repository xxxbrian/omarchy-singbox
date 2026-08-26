.pragma library

// The panel's two read-only views into configuration.
//
// The override file — ~/.config/omarchy-singbox/config — is the panel's own,
// the only file it will ever create, and entirely optional. It exists for the
// setups discovery cannot see: a config the panel may not read, a unit with an
// unconventional name, a controller bound somewhere surprising. key = value,
// one per line, `#` comments.
//
// The sing-box config is the user's. It is parsed, never written: the panel
// takes `experimental.clash_api` from it and nothing else.

function overridePath(home) {
  return String(home || "") + "/.config/omarchy-singbox/config"
}

function readCommand(readerPath, path) {
  // The same descriptor-level reader protects the panel's optional override.
  return ["python3", String(readerPath), "read", String(path)]
}

function emptyOverride() {
  return { endpoint: "", secret: "", unit: "", config: "" }
}

function parseOverride(text) {
  var result = emptyOverride()
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var hash = line.indexOf("#")
    if (hash >= 0) line = line.substring(0, hash)
    var eq = line.indexOf("=")
    if (eq < 0) continue
    var key = line.substring(0, eq).trim().toLowerCase()
    var value = line.substring(eq + 1).trim()
    // Quotes are tolerated, not required.
    value = value.replace(/^['"]/, "").replace(/['"]$/, "")
    if (key === "endpoint" || key === "address") result.endpoint = value
    else if (key === "secret") result.secret = value
    else if (key === "unit") result.unit = value
    else if (key === "config") result.config = expandHome(value)
  }
  return result
}

function expandHome(path) {
  var text = String(path === undefined || path === null ? "" : path)
  // The caller substitutes the real home; a literal `~` in a Process argv
  // would name a directory called "~".
  return text
}

// ------------------------------------------------------------ sing-box JSON
//
// The merged config the read process emits. Only clash_api matters here; the
// rest of the file stays the user's business.

function emptyConfig() {
  return { externalController: "", secret: "", hasClashApi: false, defaultMode: "", externalUi: "" }
}

function parseConfig(text) {
  var result = emptyConfig()
  var payload
  try {
    payload = JSON.parse(String(text || ""))
  } catch (error) {
    return result
  }
  if (!payload || typeof payload !== "object") return result
  var experimental = payload.experimental
  if (!experimental || typeof experimental !== "object") return result
  var api = experimental.clash_api
  if (!api || typeof api !== "object") return result
  result.hasClashApi = true
  result.externalController = String(api.external_controller || "")
  result.secret = String(api.secret || "")
  result.defaultMode = String(api.default_mode || "")
  result.externalUi = String(api.external_ui || "")
  return result
}

// --------------------------------------------------------------- resolution
//
// Where the panel should point its API calls, and why. The override wins so a
// user can always rescue a setup discovery misreads; the config is the normal
// case; with neither, a running core is still worth one shot at the documented
// default before the panel calls the API disabled.

function resolveController(override, config, coreRunning) {
  var ov = override || emptyOverride()
  var cfg = config || emptyConfig()
  if (ov.endpoint !== "")
    return { controller: ov.endpoint, secret: ov.secret !== "" ? ov.secret : cfg.secret, source: "override" }
  if (cfg.hasClashApi && cfg.externalController !== "")
    return { controller: cfg.externalController, secret: cfg.secret, source: "config" }
  if (coreRunning && !cfg.hasClashApi)
    return { controller: "127.0.0.1:9090", secret: ov.secret, source: "default" }
  return { controller: "", secret: "", source: cfg.hasClashApi ? "config" : "none" }
}

function resolveUnit(override, probe) {
  var ov = override || emptyOverride()
  if (ov.unit !== "") return ov.unit
  // Whichever scope owns the running core named its own unit; the scope to
  // control it in is Model.serviceScope's answer, not this one's.
  if (probe && probe.procUnit !== "" && (probe.procScope === "user" || probe.procScope === "system"))
    return probe.procUnit
  return "sing-box.service"
}
