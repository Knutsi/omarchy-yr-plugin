import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
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
