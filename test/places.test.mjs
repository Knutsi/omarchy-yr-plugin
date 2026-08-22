import { test } from "node:test"
import assert from "node:assert/strict"
import { Model } from "./helpers/load.mjs"

const oslo = { name: "Oslo", description: "Oslo, Norway", latitude: 59.9127, longitude: 10.7461 }
const bergen = { name: "Bergen", description: "Vestland, Norway", latitude: 60.3913, longitude: 5.3221 }
const place = (i, pinned) => ({ name: "Place " + i, description: "", latitude: 10 + (i % 70), longitude: 20 + (i % 150), pinned: pinned === true })

test("parsePlaces treats the stored array as outside input", () => {
  assert.deepEqual(Model.parsePlaces(undefined), [])
  assert.deepEqual(Model.parsePlaces("garbage"), [])
  assert.deepEqual(Model.parsePlaces({ name: "Oslo" }), [])
  assert.deepEqual(Model.parsePlaces([null, 1, "x", {}, { name: "NoCoords" }, { name: "", latitude: 1, longitude: 2 }]), [])
  assert.deepEqual(Model.parsePlaces([{ name: "Off", latitude: 91, longitude: 0 }, { name: "Off", latitude: 0, longitude: -181 }, { name: "Nan", latitude: "x", longitude: 1 }]), [])
  const tainted = Model.parsePlaces([{ name: "<img src=x>Oslo", description: "<b>x</b>", latitude: "59.91273", longitude: 10.74609, pinned: "yes" }])
  assert.deepEqual(tainted, [{ name: "img src=xOslo", description: "bx/b", latitude: 59.9127, longitude: 10.7461, pinned: false }], "strings plain, coordinates rounded, pinned must be boolean true")
  assert.deepEqual(Model.parsePlaces(JSON.stringify([oslo])), [{ ...oslo, pinned: false }], "a JSON string is accepted too")
  // prototype keys on rows are just ignored data
  assert.deepEqual(Model.parsePlaces([{ __proto__: { name: "x" }, constructor: "y", name: "Real", latitude: 1, longitude: 2 }]).map(p => p.name), ["Real"])
  // caps: pinned first, then recents; duplicates dropped; never more than 5 + 5
  const many = [...Array.from({ length: 20 }, (_, i) => place(i, true)), ...Array.from({ length: 20 }, (_, i) => place(100 + i, false))]
  const parsed = Model.parsePlaces(many)
  assert.equal(parsed.length, Model.MAX_PINNED + Model.MAX_RECENT)
  assert.deepEqual(parsed.map(p => p.pinned), [true, true, true, true, true, false, false, false, false, false])
  assert.deepEqual(parsed.map(p => p.name).slice(0, 5), ["Place 0", "Place 1", "Place 2", "Place 3", "Place 4"], "stored order kept")
  assert.deepEqual(Model.parsePlaces([place(1, false), place(1, true), { ...place(1, false), name: "place 1 " }]).length, 1, "same place within 2 km merges")
  assert.equal(Model.parsePlaces([place(2, false), place(2, true)])[0].pinned, true, "a pinned copy wins over a recent one")
  assert.equal(Model.parsePlaces(Array.from({ length: 5000 }, (_, i) => place(i % 7, false))).length, 5, "long arrays are scanned only so far")
})

test("rememberPlace keeps the latest five searches, newest first, behind the pins", () => {
  let list = Model.rememberPlace([], oslo)
  assert.deepEqual(list, [{ ...oslo, pinned: false }])
  list = Model.rememberPlace(list, bergen)
  assert.deepEqual(list.map(p => p.name), ["Bergen", "Oslo"])
  list = Model.rememberPlace(list, oslo)
  assert.deepEqual(list.map(p => p.name), ["Oslo", "Bergen"], "an older copy moves to the front")
  for (let i = 0; i < 10; i++) list = Model.rememberPlace(list, place(i))
  assert.equal(list.length, Model.MAX_RECENT)
  assert.deepEqual(list.map(p => p.name), ["Place 9", "Place 8", "Place 7", "Place 6", "Place 5"])
  const pinned = Model.togglePin(list, list[0])
  assert.equal(pinned[0].pinned, true)
  assert.deepEqual(Model.rememberPlace(pinned, place(9)), pinned, "searching a pinned place changes nothing")
  assert.deepEqual(Model.rememberPlace(pinned, { name: "<x>", latitude: 1, longitude: 2 }).map(p => p.name)[1], "x")
  assert.deepEqual(Model.rememberPlace(pinned, { name: "Bad", latitude: 999, longitude: 2 }), pinned, "garbage is not remembered")
  assert.deepEqual(Model.rememberPlace("not a list", oslo).map(p => p.name), ["Oslo"])
})

test("togglePin: at most five pins, unpinning makes a recent", () => {
  let list = []
  for (let i = 0; i < 7; i++) list = Model.rememberPlace(list, place(i))
  assert.equal(list.length, 5)
  for (let i = 0; i < 5; i++) {
    assert.ok(Model.canPin(list), "pin " + i)
    list = Model.togglePin(list, list.find(p => !p.pinned))
  }
  assert.equal(list.filter(p => p.pinned).length, 5)
  assert.ok(!Model.canPin(list))
  const sixth = Model.rememberPlace(list, bergen)
  assert.equal(sixth.length, 6)
  assert.deepEqual(Model.togglePin(sixth, bergen), sixth, "a sixth pin is refused, list unchanged")
  const unpinned = Model.togglePin(sixth, sixth[0])
  assert.equal(unpinned.filter(p => p.pinned).length, 4)
  assert.equal(unpinned[4].pinned, false)
  assert.equal(unpinned[4].name, sixth[0].name, "the unpinned place is the newest recent")
  assert.ok(Model.canPin(unpinned))
  assert.deepEqual(Model.togglePin(unpinned, { name: "Unknown", latitude: 0, longitude: 0 }), unpinned, "unknown row → unchanged")
  assert.deepEqual(Model.togglePin(unpinned, null), unpinned)
})

test("yr.no link: a URL from numbers and literals only, opened as argv", () => {
  assert.equal(Model.yrUrl(59.91273, 10.74609, "nb_NO.UTF-8"), "https://www.yr.no/nb/v%C3%A6rvarsel/daglig-tabell/59.9127,10.7461")
  assert.equal(Model.yrUrl(59.91273, 10.74609, "nn_NO"), "https://www.yr.no/nn/v%C3%AArvarsel/dagleg-tabell/59.9127,10.7461")
  assert.equal(Model.yrUrl(-33.8688, 151.2093, "en_AU"), "https://www.yr.no/en/forecast/daily-table/-33.8688,151.2093")
  assert.equal(Model.yrUrl(52.52, 13.405, undefined), "https://www.yr.no/en/forecast/daily-table/52.52,13.405")
  assert.equal(Model.yrLanguage("no_NO"), "nb")
  assert.equal(Model.yrLanguage("sv_SE"), "en")
  const shape = /^https:\/\/www\.yr\.no\/[a-z]{2}\/[A-Za-z0-9%\-\/]+\/-?\d+(\.\d+)?,-?\d+(\.\d+)?$/
  for (const [lat, lon] of [[0, 0], [-90, -180], [90, 180], [0.00001, -0.00001], ["59.9", "10.7"]]) {
    const url = Model.yrUrl(lat, lon, "en")
    assert.match(url, shape, `${lat},${lon}`)
    assert.deepEqual(Model.browserCommand(url), ["omarchy-launch-browser", url])
  }
  for (const [lat, lon] of [[null, 1], [NaN, 1], [1e308, 1], [91, 0], [0, 181], ["59.9<img src=x>", 10], ["a", "b"], [{}, []]]) {
    assert.equal(Model.yrUrl(lat, lon, "en"), "", JSON.stringify([lat, lon]))
  }
  for (const bad of ["", "https://evil.test/", "https://www.yr.no.evil.test/x", "http://www.yr.no/en/forecast/daily-table/1,2",
                     "https://www.yr.no/en/forecast/daily-table/1,2?x=<img>", "https://www.yr.no/en/forecast/daily-table/1,2 --private", "file:///etc/passwd"]) {
    assert.equal(Model.browserCommand(bad), null, bad)
  }
})

test("argv builders: timeouts, coordinate format, no positional starts with a dash", () => {
  const set = Model.settingCommand("io.github.knutsi.yr", "places", '[{"name":"Oslo"}]', true)
  assert.deepEqual(set, ["timeout", "10", "omarchy", "bar", "set", "io.github.knutsi.yr", "places", '[{"name":"Oslo"}]', "--json"])
  assert.deepEqual(Model.settingCommand("id", "unit", "metric", false).slice(-2), ["unit", "metric"])

  assert.deepEqual(Model.persistCommand("Sanderstølen", 60.82739, 9.138954), ["timeout", "10", "omarchy-weather-location", "--set", "Sanderstølen", "60.8274,9.1390"])
  const pattern = /^(-?[0-9]+(\.[0-9]+)?),(-?[0-9]+(\.[0-9]+)?)$/   // omarchy-weather-location's COORDS_PATTERN
  for (const [lat, lon] of [[0.00001, 1e-7], [-0.00004, 1e-5], [90, -180], [59.9, 10.7]]) {
    assert.match(Model.persistCommand("X", lat, lon)[5], pattern, `${lat},${lon}`)
  }
  assert.equal(Model.persistCommand("", 1, 2), null)
  assert.equal(Model.persistCommand("X", 91, 2), null)
  assert.equal(Model.persistCommand("X", "abc", 2), null)
  assert.equal(Model.persistCommand("  --exec rm -rf /", 1, 2)[4], "exec rm -rf /")
  assert.equal(Model.persistCommand("<b>Oslo</b>", 1, 2)[4], "bOslo/b")
  assert.deepEqual(Model.clearLocationCommand(), ["timeout", "10", "omarchy-weather-location", "--clear"])

  assert.deepEqual(Model.notificationCommand("", "Oslo  21°", "Fair  ·  Wind 3 m/s"), ["omarchy-notification-send", "-g", "", "Oslo  21°", "Fair  ·  Wind 3 m/s"])
  assert.deepEqual(Model.notificationCommand("x", "   ", ""), ["omarchy-notification-send", "-g", "x", "Weather unavailable", ""])
  assert.equal(Model.notificationCommand("x", "--exec rm", "-g y")[3], "exec rm")
  assert.equal(Model.notificationCommand("x", "h", "--exec rm")[4], "exec rm")
  assert.equal(Model.notificationCommand("x", "h", "-")[4], "")
  // A headline is always led by a name, so a negative temperature keeps its sign.
  assert.equal(Model.notificationHeadline("Oslo", "-5°C"), "Oslo  -5°C")
  assert.equal(Model.notificationHeadline("", "-5°C"), "Weather  -5°C")
  assert.equal(Model.notificationCommand("x", Model.notificationHeadline("", "-5°C"), "")[3], "Weather  -5°C")
  assert.equal(Model.notificationHeadline("", ""), "Weather")
  assert.equal(Model.notificationHeadline("--exec", "1°"), "--exec  1°", "the builder, not the headline, strips the dash")
  assert.equal(Model.notificationCommand("x", Model.notificationHeadline("--exec", "1°"), "")[3], "exec  1°")
})
