const assert = require("assert")
// Objects built inside the vm context carry that realm's prototypes, which
// deepStrictEqual refuses; comparing the JSON shape is what the tests mean.
function eq(actual, expected) {
  assert.strictEqual(JSON.stringify(actual), JSON.stringify(expected))
}
const { load } = require("./load")

const Config = load("SingboxConfig.js")

// ------------------------------------------------------------- override file

{
  const override = Config.parseOverride([
    "# where the panel should look",
    "endpoint = 127.0.0.1:9095",
    "secret = 's3cr3t'",
    'unit = "my-singbox.service"',
    "config = /home/u/proxy/config.json",
    "garbage line",
    "unknown = ignored"
  ].join("\n"))
  assert.strictEqual(override.endpoint, "127.0.0.1:9095")
  assert.strictEqual(override.secret, "s3cr3t")
  assert.strictEqual(override.unit, "my-singbox.service")
  assert.strictEqual(override.config, "/home/u/proxy/config.json")
}

{
  // Missing file (empty read), comments only, and null all parse empty.
  eq(Config.parseOverride(""), Config.emptyOverride())
  eq(Config.parseOverride("# just a comment"), Config.emptyOverride())
  eq(Config.parseOverride(null), Config.emptyOverride())
}

// ------------------------------------------------------------ sing-box JSON

{
  const config = Config.parseConfig(JSON.stringify({
    log: { level: "warn" },
    experimental: {
      clash_api: {
        external_controller: "127.0.0.1:9090",
        secret: "abc",
        default_mode: "Rule",
        external_ui: "ui"
      }
    }
  }))
  assert.strictEqual(config.hasClashApi, true)
  assert.strictEqual(config.externalController, "127.0.0.1:9090")
  assert.strictEqual(config.secret, "abc")
  assert.strictEqual(config.defaultMode, "Rule")
  assert.strictEqual(config.externalUi, "ui")
}

{
  // No clash_api section, broken JSON, and empty input all read as disabled.
  assert.strictEqual(Config.parseConfig('{"log":{}}').hasClashApi, false)
  assert.strictEqual(Config.parseConfig("{oops").hasClashApi, false)
  assert.strictEqual(Config.parseConfig("").hasClashApi, false)
}

// --------------------------------------------------------------- resolution

{
  // The override wins over the config.
  const override = Config.parseOverride("endpoint = 1.2.3.4:1\nsecret = ov")
  const config = Config.parseConfig(JSON.stringify({
    experimental: { clash_api: { external_controller: "5.6.7.8:2", secret: "cfg" } }
  }))
  const resolved = Config.resolveController(override, config, true)
  assert.strictEqual(resolved.controller, "1.2.3.4:1")
  assert.strictEqual(resolved.secret, "ov")
  assert.strictEqual(resolved.source, "override")
}

{
  // An override endpoint without a secret still uses the config's secret.
  const override = Config.parseOverride("endpoint = 1.2.3.4:1")
  const config = Config.parseConfig(JSON.stringify({
    experimental: { clash_api: { external_controller: "5.6.7.8:2", secret: "cfg" } }
  }))
  assert.strictEqual(Config.resolveController(override, config, true).secret, "cfg")
}

{
  // The config is the normal case.
  const config = Config.parseConfig(JSON.stringify({
    experimental: { clash_api: { external_controller: "127.0.0.1:9090" } }
  }))
  const resolved = Config.resolveController(Config.emptyOverride(), config, true)
  assert.strictEqual(resolved.controller, "127.0.0.1:9090")
  assert.strictEqual(resolved.source, "config")
}

{
  // A running core whose config the panel could not read gets one shot at the
  // documented default; with nothing running there is nothing to try.
  const empty = Config.emptyConfig()
  assert.strictEqual(Config.resolveController(Config.emptyOverride(), empty, true).controller,
    "127.0.0.1:9090")
  assert.strictEqual(Config.resolveController(Config.emptyOverride(), empty, false).controller, "")
}

// ---------------------------------------------------------------- unit choice

{
  const probe = { procScope: "user", procUnit: "custom.service" }
  assert.strictEqual(Config.resolveUnit(Config.emptyOverride(), probe), "custom.service")
  const override = Config.parseOverride("unit = mine.service")
  assert.strictEqual(Config.resolveUnit(override, probe), "mine.service")
  assert.strictEqual(Config.resolveUnit(Config.emptyOverride(),
    { procScope: "system", procUnit: "sing-box.service" }), "sing-box.service")
  assert.strictEqual(Config.resolveUnit(Config.emptyOverride(),
    { procScope: "", procUnit: "" }), "sing-box.service")
}

console.log("test_singbox_config: ok")
