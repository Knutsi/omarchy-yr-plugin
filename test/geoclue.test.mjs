import { test } from "node:test"
import assert from "node:assert/strict"
import { Model } from "./helpers/load.mjs"

test("GeoClue where-am-i output parsing and states", () => {
  // Real output (geoclue 2.8.2) carries a degree sign after the coordinates.
  const two = "New location:\nLatitude:    59.913900°\nLongitude:   10.752200°\nAccuracy:    25000 meters\nDescription: ipf fallback (from WiFi data)\nTimestamp:   x\n"
    + "New location:\nLatitude:    59.927300°\nLongitude:   10.738100°\nAccuracy:    64 meters\nDescription: Wi-Fi\nTimestamp:   y\n"
  const fix = Model.parseWhereAmI(two)
  assert.equal(fix.latitude, 59.9273)
  assert.equal(fix.longitude, 10.7381)
  assert.equal(fix.accuracy, 64)
  assert.equal(fix.denied, false)
  assert.equal(Model.fixQuality(fix.accuracy), "precise")
  assert.equal(Model.fixQuality(1500), "approx")
  assert.equal(Model.fixQuality(25000), "coarse")
  assert.equal(Model.fixQuality(null), "unknown")
  assert.match(Model.gpsFixMessage(fix), /±64 m/)
  assert.match(Model.gpsFixMessage({ latitude: 1, longitude: 1, accuracy: 25000 }), /±25 km/)
  assert.equal(Model.gpsFixMessage(null), "")

  const denied = Model.parseWhereAmI("Failed to connect to GeoClue2 service: GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: 'geoclue-where-am-i' disallowed, no agent for UID 1000")
  assert.equal(denied.latitude, null)
  assert.equal(denied.denied, true)
  const deniedLater = Model.parseWhereAmI("Latitude: 1°\nLongitude: 2°\nAccuracy: 5 meters\nAccessDenied afterwards")
  assert.equal(deniedLater.latitude, 1, "coordinates win over a later denial string")
  assert.equal(deniedLater.denied, false)
  assert.equal(Model.parseWhereAmI("").latitude, null)

  assert.match(Model.gpsStateHelp("missing"), /geoclue package/)
  assert.match(Model.gpsStateHelp("no-agent"), /autostart\.lua/)
  assert.equal(Model.gpsStateHelp("ok"), "")
  assert.match(Model.gpsStateSummary("ok"), /GeoClue/)
  assert.deepEqual(Model.GEOCLUE_PROBE_COMMAND.slice(0, 3), ["timeout", String(Model.CHILD_TIMEOUT_S), "sh"])
  assert.ok(Model.whereAmICommand().join(" ").includes("where-am-i -t 12"))
})

test("where-am-i output is bounded and its text is plain", () => {
  const fix = "Latitude: 1°\nLongitude: 2°\nAccuracy: 5 meters\nDescription: <img src=x> Wi-Fi\n"
  assert.equal(Model.parseWhereAmI(fix).description, "img src=x Wi-Fi")
  const huge = Model.parseWhereAmI(fix + "#".repeat(Model.MAX_BYTES_LOOKUP))
  assert.equal(huge.latitude, null, "oversized stdout is refused, not parsed")
  assert.equal(huge.denied, false)
})
