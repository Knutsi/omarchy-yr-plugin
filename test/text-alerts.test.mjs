import { test } from "node:test"
import assert from "node:assert/strict"
import { Model, fixture } from "./helpers/load.mjs"

test("tekstvarsel: region by point-in-polygon, smallest region wins, today/tomorrow", () => {
  const features = Model.parseTextForecast(fixture("textforecast-landoverview.json"))
  assert.ok(features && features.length === 24)
  const now = Date.parse("2026-08-22T10:00:00Z")
  const oslo = Model.textForecastFor(features, 59.9127, 10.7461, now)
  assert.equal(oslo.area, "Østlandet")
  assert.ok(oslo.today.text.length > 20)
  assert.equal(oslo.today.start, Date.parse("2026-08-22T00:00:00Z"))
  assert.equal(oslo.tomorrow.start, Date.parse("2026-08-23T00:00:00Z"))
  assert.equal(Model.textForecastArea(features, 60.3913, 5.3221), "Hordaland")
  assert.equal(Model.textForecastArea(features, 69.6496, 18.9560), "Troms")
  assert.ok(Model.textForecastArea(features, 61.25, 8.9) !== "", "Valdres resolves to one region")
  assert.equal(Model.textForecastArea(features, 52.52, 13.405), "", "Berlin: outside Norway")
  assert.equal(Model.textForecastFor(features, 52.52, 13.405, now), null)
  assert.equal(Model.textForecastFor(features, 52.52, 13.405, now, "Østlandet").area, "Østlandet", "override")
  assert.equal(Model.textForecastFor(features, 59.9127, 10.7461, now, "Atlantis").area, "Østlandet", "unknown override → own region")
  assert.equal(Model.textForecastFor(features, 59.9127, 10.7461, Date.parse("2026-08-22T23:59:00Z")).today.start, Date.parse("2026-08-22T00:00:00Z"))
  assert.equal(Model.textForecastFor(features, 59.9127, 10.7461, Date.parse("2026-08-24T00:00:00Z")), null, "stale feed")
  assert.equal(Model.parseTextForecast("{}"), null)
  assert.ok(Model.pointInRing(0.5, 0.5, [[0, 0], [1, 0], [1, 1], [0, 1]]))
  assert.ok(!Model.pointInRing(1.5, 0.5, [[0, 0], [1, 0], [1, 1], [0, 1]]))
  assert.equal(Model.ringArea([[0, 0], [2, 0], [2, 2], [0, 2]]), 4)
  assert.equal(Model.textForecastArea([{ area: "", ring: [[0, 0], [1, 0], [1, 1], [0, 1]] }], 0.5, 0.5), "", "nameless feature ignored")
})

test("textforecast fetch gate covers Norway and Svalbard only", () => {
  assert.ok(Model.inTextForecastRegion(59.9127, 10.7461), "Oslo")
  assert.ok(Model.inTextForecastRegion(78.22, 15.63), "Longyearbyen")
  assert.ok(!Model.inTextForecastRegion(52.52, 13.405), "Berlin")
  assert.ok(!Model.inTextForecastRegion(null, 10))
})

test("farevarsel: alerts parsed, sorted by level, labelled in English, coloured", () => {
  const alerts = Model.parseAlerts(fixture("metalerts-oslo.json"))
  assert.equal(alerts.length, 1)
  assert.equal(alerts[0].name, "Skogbrannfare")
  assert.equal(alerts[0].level, "yellow")
  assert.equal(alerts[0].levelLabel, "Yellow level")
  assert.match(alerts[0].area, /Østlandet/)
  assert.ok(alerts[0].id.length > 0)
  assert.ok(alerts[0].description.length > 10 && alerts[0].instruction.length > 10)
  assert.ok(alerts[0].end > alerts[0].start)
  const sorted = Model.parseAlerts(JSON.stringify({ features: [
    { properties: { eventAwarenessName: "A", riskMatrixColor: "Yellow" }, when: { interval: [] } },
    { properties: { eventAwarenessName: "B", riskMatrixColor: "Red" }, when: { interval: [] } },
    { properties: { eventAwarenessName: "C", awareness_level: "3; orange; Severe" }, when: { interval: [] } }
  ] }))
  assert.deepEqual(sorted.map(a => a.name), ["B", "C", "A"])
  assert.equal(Model.alertColor("red"), "#d0473a")
  assert.equal(Model.alertColor("weird"), Model.alertColor("yellow"))
  assert.deepEqual(Model.parseAlerts("garbage"), [])
})
