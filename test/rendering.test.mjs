import { test } from "node:test"
import assert from "node:assert/strict"
import { readdirSync, readFileSync } from "node:fs"
import { Model, fixture } from "./helpers/load.mjs"

// Tripwires for the rendering invariant (CLAUDE.md "Engineering invariants"):
// strings from outside never reach a QML sink as markup. Two layers — every
// Text the plugin owns is PlainText, and every parser strips markup at the
// source, which is the only layer that covers the shell-owned sinks (bar
// tooltip, notifications) the plugin feeds but cannot configure.

const root = new URL("../", import.meta.url)
const qmlFiles = readdirSync(root).filter(f => f.endsWith(".qml")).sort()

// The block's own lines only: a nested Text that is PlainText must not vouch
// for an enclosing one that is not.
function ownLines(source, open) {
  let depth = 0, out = ""
  for (let i = open; i < source.length; i++) {
    const c = source[i]
    if (c === "{") depth++
    if (depth === 1) out += c
    if (c === "}" && --depth === 0) return out
  }
  throw new Error("unbalanced braces")
}

test("every Text and PanelSectionHeader in plugin QML is textFormat: Text.PlainText", () => {
  assert.ok(qmlFiles.length >= 10, "qml file list went stale")
  let blocks = 0
  for (const file of qmlFiles) {
    const source = readFileSync(new URL(file, root), "utf8")
    assert.ok(!/Text\.(AutoText|RichText|StyledText)/.test(source), `${file}: rich-text format in plugin QML`)
    const opener = /\b(Text|PanelSectionHeader)\s*\{/g
    let m
    while ((m = opener.exec(source))) {
      const line = source.slice(0, m.index).split("\n").length
      const block = ownLines(source, m.index + m[0].length - 1)
      assert.ok(/\btextFormat:\s*Text\.PlainText\b/.test(block), `${file}:${line}: ${m[1]} without textFormat: Text.PlainText`)
      blocks++
    }
  }
  assert.ok(blocks >= 30, `only ${blocks} Text blocks found — the scan went stale`)
})

// Built from char codes so no raw control byte sits in this source file.
const chr = String.fromCharCode
const NUL = chr(0), ESC = chr(27), NEL = chr(0x85)
const CONTROL_CLASS = [[0, 8], [11, 31], [127, 159]].map(([a, b]) => chr(a) + "-" + chr(b)).join("")
const DIRTY = new RegExp("[<>" + CONTROL_CLASS + "]")

// What a markup-shaped field would do in an AutoText sink: load a remote
// image, link to a local file, flip the whole string into rich text, or
// smuggle terminal/control bytes.
const PAYLOADS = [
  '<img src="http://203.0.113.1/x.png" width="99999" height="99999">',
  '<a href="file:///etc/passwd">see</a>',
  "<!DOCTYPE html><b>bold</b>",
  NUL + ESC + "[31m" + NEL
]

// Every string in the body is tainted except GeoJSON's structural "type"
// ("Feature", "Polygon"), which is matched, never shown — tainting it would
// make the parser drop every feature and the probe check nothing.
function taint(value, payload) {
  if (typeof value === "string") return payload + value + payload
  if (Array.isArray(value)) return value.map(v => taint(v, payload))
  if (value && typeof value === "object") {
    const out = {}
    for (const key of Object.keys(value)) out[key] = key === "type" ? value[key] : taint(value[key], payload)
    return out
  }
  return value
}

function stringLeaves(value, path = "$", out = []) {
  if (typeof value === "string") out.push([path, value])
  else if (Array.isArray(value)) value.forEach((v, i) => stringLeaves(v, `${path}[${i}]`, out))
  else if (value && typeof value === "object") for (const key of Object.keys(value)) stringLeaves(value[key], `${path}.${key}`, out)
  return out
}

function assertClean(result, label) {
  const leaves = stringLeaves(result)
  assert.ok(leaves.length > 0, `${label}: parser returned no strings — the probe is vacuous`)
  for (const [path, text] of leaves) {
    assert.ok(!DIRTY.test(text), `${label} ${path}: ${JSON.stringify(text).slice(0, 100)}`)
    assert.ok(text.length <= Model.MAX_TEXT_CHARS, `${label} ${path}: ${text.length} chars`)
  }
}

test("no parser lets markup or control characters through to a rendered string", () => {
  const weatherJson = { name: "Bergen", latitude: 60.39, longitude: 5.32 }
  const ipBody = { success: true, city: "Oslo", region: "Oslo", country: "Norway", latitude: 59.91, longitude: 10.75 }
  const probes = [
    ["parseAlerts", "metalerts-oslo.json", raw => Model.parseAlerts(raw), r => r.length === 1],
    ["parseTextForecast", "textforecast-landoverview.json", raw => Model.parseTextForecast(raw), r => r && r.length === 24],
    ["parseOpenMeteoResults", "open-meteo-oslo.json", raw => Model.parseOpenMeteoResults(raw), r => r.length >= 3],
    ["parseKartverketResults", "kartverket-sanderstolen.json", raw => Model.parseKartverketResults(raw, ""), r => r.length >= 2],
    ["parsePhotonResults", "photon-sanderstolen.json", raw => Model.parsePhotonResults(raw), r => r.length >= 1],
    ["parsePhotonReverse", "photon-reverse.json", raw => Model.parsePhotonReverse(raw), r => r && r.name.length > 0],
    ["parseKartverketPoint", "kartverket-punkt.json", raw => Model.parseKartverketPoint(raw), r => r.length > 0],
    ["parseIpLocation", JSON.stringify(ipBody), raw => Model.parseIpLocation(raw), r => r.latitude !== null],
    ["parseLocationFile", JSON.stringify(weatherJson), raw => Model.parseLocationFile(raw), r => r.latitude !== null]
  ]
  for (const [label, body, parse, populated] of probes) {
    const clean = body.endsWith(".json") ? fixture(body) : body
    for (const payload of PAYLOADS) {
      const result = parse(JSON.stringify(taint(JSON.parse(clean), payload)))
      assert.ok(populated(result), `${label}: tainted body was rejected outright, so nothing was checked`)
      assertClean(result, label)
    }
  }

  // The text-forecast override comes from settings and lands in the same header.
  const features = Model.parseTextForecast(fixture("textforecast-landoverview.json"))
  const now = Date.parse("2026-08-22T10:00:00Z")
  for (const payload of PAYLOADS) {
    assertClean(Model.textForecastFor(features, 59.9127, 10.7461, now, payload + "Østlandet"), "textForecastFor override")
  }

  // An unknown MET symbol id is rendered only if it is shaped like one.
  for (const payload of PAYLOADS) {
    assert.equal(Model.symbolLabel(payload + "_day"), "")
    assert.equal(Model.iconForSymbol(payload + "_day").length, 1)
  }
  assert.equal(Model.symbolLabel("drizzle_day"), "drizzle", "a plausible new id still shows")
  assert.equal(Model.symbolLabel("a".repeat(65)), "")
})

test("plainText: strips angle brackets and control bytes, bounds length, keeps real text", () => {
  assert.equal(Model.plainText(null), "")
  assert.equal(Model.plainText(undefined), "")
  assert.equal(Model.plainText(42), "42")
  assert.equal(Model.plainText("a <b>b</b> > c"), "a bb/b  c")
  assert.equal(Model.plainText("x" + NUL + "y" + ESC + "[0mz" + NEL + "w"), "xy[0mzw")
  assert.equal(Model.plainText("x".repeat(10000)).length, Model.MAX_TEXT_CHARS)
  const warning = "Kraftige vindkast, opp mot 25 m/s.\nSikre løse gjenstander – æøå ÆØÅ.\tTab beholdes."
  assert.equal(Model.plainText(warning), warning)
  assert.equal(Model.plainText("&lt;not-a-tag&gt; &amp;"), "&lt;not-a-tag&gt; &amp;", "entities are harmless without a tag and stay literal")
})

test("every parser that yields a rendered string calls plainText (chokepoint count)", () => {
  // Tripwire: a new parser that builds a displayable string must route it
  // through plainText(). If this count drops, a call was removed; if a parser
  // was added, wrap its strings and raise the floor.
  const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  const calls = (source.match(/\bplainText\(/g) || []).length
  assert.ok(calls >= 22, `plainText( appears ${calls} times in Model.js; expected at least 22`)
})
