import { test } from "node:test"
import assert from "node:assert/strict"
import { Model } from "./helpers/load.mjs"

test("sunTimes: Oslo in August, the equator, and the polar cases", () => {
  // Reference from MET's Sunrise 3.0 API for Oslo 2026-08-21: 05:45 / 20:52 CEST.
  // The simplified solar equations drift a few minutes at high latitudes.
  const oslo = Model.sunTimes(59.9127, 10.7461, new Date("2026-08-21T12:00:00+02:00"))
  assert.ok(oslo.sunrise && oslo.sunset)
  const riseUtc = oslo.sunrise.getUTCHours() * 60 + oslo.sunrise.getUTCMinutes()
  const setUtc = oslo.sunset.getUTCHours() * 60 + oslo.sunset.getUTCMinutes()
  assert.ok(Math.abs(riseUtc - (3 * 60 + 45)) <= 6, `sunrise UTC minutes ${riseUtc}`)
  assert.ok(Math.abs(setUtc - (18 * 60 + 52)) <= 6, `sunset UTC minutes ${setUtc}`)

  // MET Sunrise 3.0 for 0°N 0°E on 2026-03-20: 06:04 / 18:10 UTC.
  const equator = Model.sunTimes(0, 0, new Date("2026-03-20T12:00:00Z"))
  assert.ok(Math.abs(equator.sunrise.getUTCHours() * 60 + equator.sunrise.getUTCMinutes() - (6 * 60 + 4)) <= 6)
  assert.ok(Math.abs(equator.sunset.getUTCHours() * 60 + equator.sunset.getUTCMinutes() - (18 * 60 + 10)) <= 6)

  assert.equal(Model.sunTimes(78.2, 15.6, new Date("2026-06-21T12:00:00Z")).polar, "day")
  assert.equal(Model.sunTimes(78.2, 15.6, new Date("2026-12-21T12:00:00Z")).polar, "night")
  assert.equal(Model.sunTimes(null, 10, new Date()).sunrise, null)
  assert.equal(Model.formatSunTime(null, "day"), "up all day")
  assert.equal(Model.formatSunTime(null, ""), "")
  assert.match(Model.formatSunTime(oslo.sunrise, ""), /^[0-2][0-9]:[0-5][0-9]$/)
})
