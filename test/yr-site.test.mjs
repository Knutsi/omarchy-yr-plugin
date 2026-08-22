import { test } from "node:test"
import assert from "node:assert/strict"
import { Model, fixture } from "./helpers/load.mjs"

const honefoss = { lat: 60.1699, lon: 10.2552 }

test("parseYrLocations: ids validated, positions on the globe, text plain, fails closed", () => {
  const rows = Model.parseYrLocations(fixture("yr-search-honefoss.json"))
  assert.ok(rows.length >= 3)
  assert.deepEqual(rows[0], { id: "1-84687", name: "Hønefoss", latitude: 60.1659, longitude: 10.2558, category: "CB09" })
  for (const r of rows) {
    assert.match(r.id, Model.YR_ID)
    assert.ok(Math.abs(r.latitude) <= 90 && Math.abs(r.longitude) <= 180)
  }
  const hostile = JSON.stringify({ _embedded: { location: [
    { id: "1-84687/../x", name: "a", position: { lat: 1, lon: 2 } },
    { id: "abc", name: "b", position: { lat: 1, lon: 2 } },
    { id: 123, name: "c", position: { lat: 1, lon: 2 } },
    { id: "1-1", name: "<img src=x>", position: { lat: "91", lon: 2 } },
    { id: "1-2", name: " <b>ok</b> ", position: { lat: "59.9", lon: "10.7" }, category: { id: "../" } },
    null, "x", 7, { id: "1-3" }, { id: "1-4", position: "59,10" }
  ] } })
  assert.deepEqual(Model.parseYrLocations(hostile), [{ id: "1-2", name: "bok/b", latitude: 59.9, longitude: 10.7, category: "" }])
  assert.deepEqual(Model.parseYrLocations("garbage"), [])
  assert.deepEqual(Model.parseYrLocations("{}"), [])
  assert.deepEqual(Model.parseYrLocations('{"_embedded":{"location":{"id":"1-1"}}}'), [])
  assert.deepEqual(Model.parseYrLocations(fixture("yr-search-honefoss.json") + " ".repeat(Model.MAX_BYTES_LOOKUP)), [], "oversized → refused")
  const many = { _embedded: { location: Array.from({ length: 500 }, (_, i) => ({ id: "1-" + i, name: "n", position: { lat: 1, lon: 1 } })) } }
  assert.equal(Model.parseYrLocations(JSON.stringify(many)).length, 50)
})

test("pickYrLocation: a name hit within 5 km, else the nearest populated place within 2 km, else coordinates", () => {
  const search = Model.parseYrLocations(fixture("yr-search-honefoss.json"))
  assert.equal(Model.pickYrLocation(search, honefoss.lat, honefoss.lon, "Hønefoss"), "1-84687", "the town")
  assert.equal(Model.pickYrLocation(search, 60.70461, 10.17891, "Hønefoss"), "1-115211", "the waterfall, when standing at the waterfall")
  assert.equal(Model.pickYrLocation(search, 52.52, 13.405, "Hønefoss"), "", "nothing near Berlin is Hønefoss")
  const nearbyTown = Model.parseYrLocations(fixture("yr-nearby-honefoss.json"))
  assert.ok(nearbyTown.length >= 5 && nearbyTown.every(r => !/^C/.test(r.category)), "fixture: streets, bridges, a park, a waterfall")
  assert.equal(Model.pickYrLocation(nearbyTown, honefoss.lat, honefoss.lon, ""), "", "streets are not the place → coordinates")
  const nearbyOslo = Model.parseYrLocations(fixture("yr-nearby-oslo.json"))
  assert.equal(Model.pickYrLocation(nearbyOslo, 59.9127, 10.7461, ""), "1-72837")

  const rows = [
    { id: "1-1", name: "Elsewhere", latitude: 60.2, longitude: 10.26, category: "CB09" },    // ~3.4 km, populated, another name
    { id: "1-2", name: "Hønefoss", latitude: 60.175, longitude: 10.26, category: "SQ01" },   // ~0.6 km, exact name, a waterfall
    { id: "1-3", name: "Hønefoss", latitude: 60.17, longitude: 10.255, category: "CB09" },   // ~0 km, exact name and populated
    { id: "1-4", name: "Hønefoss", latitude: 60.23, longitude: 10.26, category: "CB09" }     // ~6.7 km: a different place
  ]
  assert.equal(Model.pickYrLocation(rows, honefoss.lat, honefoss.lon, "Hønefoss"), "1-3")
  assert.equal(Model.pickYrLocation(rows.filter(r => r.id !== "1-3"), honefoss.lat, honefoss.lon, "Hønefoss"), "1-2", "an exact name beats a populated place with another name")
  assert.equal(Model.pickYrLocation(rows.filter(r => r.id === "1-4"), honefoss.lat, honefoss.lon, "Hønefoss"), "", "6 km away is a different place")
  assert.equal(Model.pickYrLocation(rows.filter(r => r.id === "1-1"), honefoss.lat, honefoss.lon, "Hønefoss"), "1-1", "a populated hit within 5 km still counts")
  assert.equal(Model.pickYrLocation(rows, honefoss.lat, honefoss.lon, "hønefoss "), "1-3", "name comparison is normalised")
  assert.equal(Model.pickYrLocation(rows, honefoss.lat, honefoss.lon, ""), "1-3", "nearest search: a populated place within 2 km")
  assert.equal(Model.pickYrLocation([rows[1]], honefoss.lat, honefoss.lon, ""), "", "nearest search never picks a waterfall")
  assert.equal(Model.pickYrLocation([rows[0]], honefoss.lat, honefoss.lon, ""), "", "nearest search: 3 km is too far")
  assert.equal(Model.pickYrLocation([{ id: "1-1/../x", name: "Hønefoss", latitude: honefoss.lat, longitude: honefoss.lon, category: "CB09" }], honefoss.lat, honefoss.lon, "Hønefoss"), "")
  assert.equal(Model.pickYrLocation(rows, "x", 1, "Hønefoss"), "")
  assert.equal(Model.pickYrLocation(null, 1, 1, "x"), "")
  assert.equal(Model.pickYrLocation({ length: 1, 0: rows[2] }, honefoss.lat, honefoss.lon, ""), "1-3", "array-likes work here too")
  assert.ok(Math.abs(Model.distanceKm(59.9127, 10.7461, 60.3913, 5.3221) - 304) < 8, "Oslo–Bergen ≈ 304 km")
})

test("yrUrl takes a validated id; anything else is the coordinate page; browserCommand unchanged", () => {
  assert.equal(Model.yrUrl(60.1699, 10.2552, "en", "1-84687"), "https://www.yr.no/en/forecast/daily-table/1-84687")
  assert.equal(Model.yrUrl(60.1699, 10.2552, "nb_NO.UTF-8", "2-2950159"), "https://www.yr.no/nb/v%C3%A6rvarsel/daglig-tabell/2-2950159")
  for (const bad of ["", null, undefined, "abc", "1-84687/../x", "1-1?x=<img>", "123", "1-", "-1", "100-1", "1-12345678901", " 1-84687"]) {
    assert.equal(Model.yrUrl(60.1699, 10.2552, "en", bad), "https://www.yr.no/en/forecast/daily-table/60.1699,10.2552", JSON.stringify(bad))
  }
  assert.equal(Model.yrUrl(null, 1, "en", "1-84687"), "", "no coordinates, no URL — even with an id")
  const url = "https://www.yr.no/en/forecast/daily-table/1-84687"
  assert.deepEqual(Model.browserCommand(url), ["omarchy-launch-browser", url])
  assert.equal(Model.browserCommand("https://www.yr.no/en/forecast/daily-table/1-1?x=<img>"), null)
  for (const bad of ["https://www.yr.no/en/forecast/daily-table/1-1/../../x", "https://www.yr.no/en/forecast/daily-table/--private",
                     "https://www.yr.no/en/forecast/daily-table/1,2/extra", "https://www.yr.no/de/forecast/daily-table/1,2", "https://www.yr.no/en/forecast/1,2"]) {
    assert.equal(Model.browserCommand(bad), null, bad)
  }
  for (const lang of ["nb_NO", "nn_NO", "en_GB"]) assert.ok(Model.browserCommand(Model.yrUrl(60.1, 10.2, lang, "1-84687")), lang + " with id")
})

test("the two yr lookups go through curlCommand and carry only a place name or coordinates", () => {
  const byName = Model.yrSearchCommand("  Hønefoss ")
  assert.equal(byName[0], "curl")
  assert.ok(byName.includes("--max-time") && byName.includes("--max-filesize"))
  assert.equal(byName[byName.length - 1], "https://www.yr.no/api/v0/locations/search?q=H%C3%B8nefoss&language=en")
  assert.equal(Model.yrSearchCommand(""), null)
  assert.equal(Model.yrSearchCommand(null), null)
  assert.equal(Model.yrSearchCommand("59.91, 10.75 (approx.)"), null, "a coordinate 'name' is not a name")
  assert.equal(Model.yrSearchCommand("-5 Street"), null)
  assert.ok(Model.yrSearchCommand("x".repeat(500))[byName.length - 1].length < 200, "capped like the search box")
  assert.ok(Model.yrSearchCommand("a&b=c#d")[byName.length - 1].endsWith("?q=a%26b%3Dc%23d&language=en"))
  const near = Model.yrNearbyCommand(60.16992, 10.25519)
  assert.equal(near[near.length - 1], "https://www.yr.no/api/v0/locations/search?lat=60.1699&lon=10.2552&language=en")
  assert.equal(Model.yrNearbyCommand(91, 0), null)
  assert.equal(Model.yrNearbyCommand("59.9<img>", 10), null)
})
