const assert = require("assert")
// Objects built inside the vm context carry that realm's prototypes, which
// deepStrictEqual refuses; comparing the JSON shape is what the tests mean.
function eq(actual, expected) {
  assert.strictEqual(JSON.stringify(actual), JSON.stringify(expected))
}
const { load } = require("./load")

const Api = load("SingboxApi.js")

// ------------------------------------------------------------------ base url

{
  assert.strictEqual(Api.baseUrl("127.0.0.1:9090"), "http://127.0.0.1:9090")
  assert.strictEqual(Api.baseUrl("0.0.0.0:9090"), "http://127.0.0.1:9090")
  assert.strictEqual(Api.baseUrl("[::]:9090"), "http://127.0.0.1:9090")
  assert.strictEqual(Api.baseUrl(":9090"), "http://127.0.0.1:9090")
  assert.strictEqual(Api.baseUrl("[::1]:9090"), "http://[::1]:9090")
  assert.strictEqual(Api.baseUrl("http://10.0.0.2:9090/"), "http://10.0.0.2:9090")
  assert.strictEqual(Api.baseUrl("no-port"), "")
  assert.strictEqual(Api.baseUrl(""), "")
  assert.strictEqual(Api.baseUrl("unix:///run/sb.sock"), "")
}

// ------------------------------------------------------------------ commands

{
  const get = Api.versionCommand("http://h:1", "s3cr3t")
  assert.strictEqual(get[0], "curl")
  assert.ok(get.indexOf("Authorization: Bearer s3cr3t") >= 0)
  assert.strictEqual(get[get.length - 1], "http://h:1/version")

  // No secret, no empty Authorization header.
  const bare = Api.versionCommand("http://h:1", "")
  assert.strictEqual(bare.indexOf("-H"), -1)

  const mode = Api.setModeCommand("http://h:1", "", "Global")
  assert.ok(mode.indexOf("PATCH") >= 0)
  assert.ok(mode.indexOf('{"mode":"Global"}') >= 0)

  const select = Api.selectProxyCommand("http://h:1", "", "My Group", "node a")
  assert.strictEqual(select[select.length - 1], "http://h:1/proxies/My%20Group")
  assert.ok(select.indexOf('{"name":"node a"}') >= 0)

  const delay = Api.delayCommand("http://h:1", "", "node a")
  assert.ok(delay[delay.length - 1].indexOf("/proxies/node%20a/delay?") >= 0)

  const traffic = Api.trafficCommand("http://h:1", "")
  assert.ok(traffic.indexOf("--no-buffer") >= 0)
}

// ------------------------------------------------------------------ classify

{
  assert.strictEqual(Api.classify(7, "", "curl: (7) refused").code, "unreachable")
  assert.strictEqual(Api.classify(0, "", "").code, "unreachable")
  assert.strictEqual(Api.classify(0, '{"message":"Unauthorized"}\n401', "").code, "unauthorized")
  assert.strictEqual(Api.classify(0, '{"message":"Must be a Selector"}\n400', "").message,
    "Must be a Selector")
  assert.strictEqual(Api.classify(0, "\n204", "").ok, true)
  const ok = Api.classify(0, '{"version":"sing-box 1.13.19"}\n200', "")
  assert.strictEqual(ok.ok, true)
  assert.strictEqual(ok.body, '{"version":"sing-box 1.13.19"}')
}

// ------------------------------------------------------------------- parsing

{
  const version = Api.parseVersion('{"meta":true,"version":"sing-box 1.13.19"}')
  assert.strictEqual(version.version, "1.13.19")
  assert.strictEqual(version.meta, true)
}

{
  const configs = Api.parseConfigs(JSON.stringify({
    mode: "Rule",
    "mode-list": ["Rule", "Global", "Direct"],
    "mixed-port": 7890,
    port: 0,
    "socks-port": 0,
    "allow-lan": false,
    "log-level": "warn"
  }))
  assert.strictEqual(configs.mode, "Rule")
  eq(configs.modeList, ["Rule", "Global", "Direct"])
  assert.strictEqual(configs.mixedPort, 7890)

  // A config with no clash_mode rules lists one mode.
  const single = Api.parseConfigs('{"mode":"Rule","mode-list":["Rule"]}')
  eq(single.modeList, ["Rule"])
  assert.strictEqual(Api.parseConfigs("not json"), null)
}

{
  const connections = Api.parseConnections(JSON.stringify({
    downloadTotal: 100, uploadTotal: 50, memory: 7,
    connections: [{}, {}, {}]
  }))
  assert.strictEqual(connections.count, 3)
  assert.strictEqual(connections.downloadTotal, 100)
  // A null connections list is a count of zero, not a crash.
  assert.strictEqual(Api.parseConnections('{"connections":null}').count, 0)
}

// ------------------------------------------------------------- proxy groups

{
  // Mirrors sing-box's real /proxies shape: GLOBAL is a Fallback holding the
  // groups, and its order is the config's declaration order.
  const groups = Api.parseProxyGroups(JSON.stringify({
    proxies: {
      GLOBAL: { type: "Fallback", now: "PROXY", all: ["PROXY", "AUTO"] },
      AUTO: { type: "URLTest", now: "node-a", all: ["node-a", "node-b"] },
      PROXY: { type: "Selector", now: "node-a", all: ["node-a", "node-b"] },
      direct: { type: "Direct", history: [] },
      "node-a": { type: "Direct", history: [{ delay: 42 }] },
      "node-b": { type: "Direct", history: [] }
    }
  }))
  assert.strictEqual(groups.length, 2)
  // GLOBAL's order wins over object key order.
  assert.strictEqual(groups[0].name, "PROXY")
  assert.strictEqual(groups[0].selectable, true)
  assert.strictEqual(groups[1].name, "AUTO")
  assert.strictEqual(groups[1].selectable, false)
  assert.strictEqual(groups[0].members[0].name, "node-a")
  assert.strictEqual(groups[0].members[0].delay, 42)
  assert.strictEqual(groups[0].members[1].delay, 0)
  // GLOBAL itself is never listed: sing-box refuses selection on it.
  assert.ok(groups.every(function(g) { return g.name !== "GLOBAL" }))
}

{
  // A group GLOBAL does not name is still listed, after the ordered ones.
  const groups = Api.parseProxyGroups(JSON.stringify({
    proxies: {
      GLOBAL: { type: "Fallback", now: "A", all: ["A"] },
      A: { type: "Selector", now: "x", all: ["x"] },
      B: { type: "Selector", now: "x", all: ["x"] },
      x: { type: "Direct" }
    }
  }))
  eq(groups.map(function(g) { return g.name }), ["A", "B"])
}

{
  assert.strictEqual(Api.parseDelay('{"delay":473}'), 473)
  assert.strictEqual(Api.parseDelay("nope"), 0)
}

// -------------------------------------------------------------- traffic rate

{
  // sing-box 1.13 sends only per-interval readings; they pass through as-is.
  const sample = Api.parseTrafficLine('{"up":10,"down":20}')
  assert.strictEqual(sample.hasTotals, false)
  const reading = Api.trafficRate(null, sample, 100)
  eq(reading.rate, { up: 10, down: 20 })
  assert.strictEqual(reading.anchor, null)
}

{
  // Cores that send totals get the exact differenced rate.
  const first = Api.parseTrafficLine('{"up":1,"down":2,"upTotal":100,"downTotal":200}')
  const start = Api.trafficRate(null, first, 100)
  const second = Api.parseTrafficLine('{"up":1,"down":2,"upTotal":110,"downTotal":230}')
  const next = Api.trafficRate(start.anchor, second, 101)
  eq(next.rate, { up: 10, down: 30 })

  // Too soon to divide: the bytes wait for the next reading.
  const tooSoon = Api.trafficRate(start.anchor, second, 100.05)
  assert.strictEqual(tooSoon.rate, null)
  assert.strictEqual(tooSoon.anchor, start.anchor)

  // Counters going backwards mean the core restarted underneath the stream.
  const reset = Api.parseTrafficLine('{"up":1,"down":2,"upTotal":5,"downTotal":5}')
  const restarted = Api.trafficRate(start.anchor, reset, 102)
  eq(restarted.rate, { up: 1, down: 2 })
}

{
  assert.strictEqual(Api.parseTrafficLine("garbage"), null)
  assert.strictEqual(Api.parseTrafficLine('{"up":"x","down":1}'), null)
}

console.log("test_singbox_api: ok")
