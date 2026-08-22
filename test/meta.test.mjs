import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import { Model } from "./helpers/load.mjs"

const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"))
const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"))

test("one version everywhere (the MET User-Agent carries it)", () => {
  assert.equal(manifest.version, Model.VERSION)
  assert.equal(pkg.version, Model.VERSION)
  assert.ok(Model.USER_AGENT.includes(Model.VERSION) && /github\.com/.test(Model.USER_AGENT))
})

test("manifest defaults and bounds match the model", () => {
  const bw = manifest.barWidget
  for (const key of Object.keys(Model.DEFAULTS)) assert.deepEqual(bw.defaults[key], Model.DEFAULTS[key], key)
  const schema = Object.fromEntries(bw.schema.map(s => [s.key, s]))
  assert.equal(schema.refreshMinutes.min, Model.REFRESH_MINUTES_MIN)
  assert.equal(schema.refreshMinutes.max, Model.REFRESH_MINUTES_MAX)
  assert.equal(schema.graphHours.min, Model.GRAPH_HOURS_MIN)
  assert.equal(schema.graphHours.max, Model.GRAPH_HOURS_MAX)
  for (const key of Object.keys(schema)) assert.deepEqual(schema[key].defaultValue, Model.DEFAULTS[key], key)
})

test("manifest shape for the marketplace", () => {
  assert.equal(manifest.schemaVersion, 1)
  assert.match(manifest.id, /^io\.github\.[a-z0-9-]+\.[a-z0-9-]+$/)
  assert.ok(!manifest.id.startsWith("omarchy."))
  assert.deepEqual(manifest.kinds, ["service", "bar-widget"])
  assert.equal(manifest.entryPoints.service, "Service.qml")
  assert.equal(manifest.entryPoints.barWidget, "BarWidget.qml")
  for (const field of ["name", "author", "description", "license"]) assert.ok(manifest[field], field)
  assert.ok(manifest.name.length <= 120 && manifest.description.length <= 500)
})

test("every curl invocation carries a time bound and a size ceiling", () => {
  // Tripwire: network requests must go through curlCommand()/metCommand()
  // (CLAUDE.md "Engineering invariants"). A new `["curl"` literal in
  // Model.js means a new builder — give it --max-time and --max-filesize
  // and add its output to the list below.
  const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  assert.equal((source.match(/\["curl"/g) || []).length, 2, "curl argv literals beyond curlCommand/metCommand")

  const commands = [
    Model.curlCommand("https://example.test/"),
    Model.metCommand("https://example.test/", "", 10),
    Model.metCommand("https://example.test/", "Fri, 21 Aug 2026 19:19:53 GMT", 15),
    Model.reverseCommand(60.8274, 9.139),
    Model.kartverketPointCommand(60.8274, 9.139),
    ...Model.geocodeRequests("Sanderstølen").map(r => r.command),
    ...Model.IP_LOCATION_URLS.map(url => Model.curlCommand(url)),
    Model.yrSearchCommand("Oslo"),
    Model.yrNearbyCommand(59.9127, 10.7461)
  ]
  assert.ok(commands.length >= 8, "the builder list above went stale")
  for (const argv of commands) {
    const cmd = argv.join(" ")
    assert.equal(argv[0], "curl", cmd)
    assert.ok(parseFloat(argv[argv.indexOf("--max-time") + 1]) > 0, "time bound: " + cmd)
    const size = parseInt(argv[argv.indexOf("--max-filesize") + 1], 10)
    assert.ok(size > 0 && size <= Model.MAX_BYTES_MET, "size ceiling: " + cmd)
  }
})

test("every child process is an argv array from a Model.js builder, bounded in time", () => {
  // Tripwire (CLAUDE.md "Engineering invariants"): no QML file builds a
  // command line; nothing goes through bar.run / bash -c; every helper the
  // plugin waits for runs under coreutils timeout.
  const dir = new URL("../", import.meta.url)
  for (const file of readdirSync(dir).filter(f => f.endsWith(".qml"))) {
    const qml = readFileSync(new URL(file, dir), "utf8")
    assert.ok(!/\bbar\.run\(|\bUtil\.execDetached\(|shellQuote\(|"bash"|"sh",\s*"-c"/.test(qml), file + ": builds a shell command line")
    assert.ok(!/\[\s*"(omarchy|omarchy-[a-z-]+|curl|timeout|sh)"/.test(qml), file + ": argv literal outside Model.js")
  }
  const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  assert.equal((source.match(/\["omarchy-launch-browser"/g) || []).length, 1)
  assert.equal((source.match(/\["omarchy-notification-send"/g) || []).length, 1)
  assert.equal((source.match(/\["timeout"/g) || []).length, 4, "settingCommand, persistCommand, clearLocationCommand, GEOCLUE_PROBE_COMMAND")

  const timed = [
    Model.settingCommand("io.github.knutsi.yr", "unit", "metric", false),
    Model.settingCommand("io.github.knutsi.yr", "textForecast", "true", true),   // scalars only: arrays cannot cross qs ipc
    Model.persistCommand("Oslo", 59.91273, 10.74609),
    Model.clearLocationCommand(),
    Model.GEOCLUE_PROBE_COMMAND
  ]
  for (const argv of timed) {
    assert.equal(argv[0], "timeout", argv.join(" "))
    assert.equal(parseInt(argv[1], 10), Model.CHILD_TIMEOUT_S)
  }
  assert.ok(Model.whereAmICommand()[2].startsWith("timeout "), "where-am-i has its own timeout inside sh -c")
  // A positional that starts with "-" would be read as an option by the helper.
  const hostile = ["--exec rm -rf ~", "-g x", " - -x", "--private"]
  for (const h of hostile) {
    for (const argv of [Model.persistCommand(h, 1, 2), Model.notificationCommand("", h, h)]) {
      for (const arg of argv.slice(argv.indexOf("--set") === -1 ? 3 : 4)) assert.ok(!arg.startsWith("-") || arg === "--set", argv.join(" | "))
    }
  }
})

test("settings parsing and clamps", () => {
  assert.equal(Model.refreshMinutes("3"), 10)
  assert.equal(Model.refreshMinutes(999), 180)
  assert.equal(Model.refreshMinutes("abc"), 15)
  assert.equal(Model.graphHours(100), 48)
  assert.equal(Model.graphHours(undefined), 24)
  assert.equal(Model.settingBool(undefined, true), true)
  assert.equal(Model.settingBool("false", true), false)
  assert.equal(Model.settingBool(false, true), false)
  assert.equal(Model.settingBool("TRUE", false), true)
  assert.equal(Model.settingBool("maybe", true), true)
})
