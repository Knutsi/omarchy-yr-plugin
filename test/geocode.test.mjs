import { test } from "node:test"
import assert from "node:assert/strict"
import { Model, fixture } from "./helpers/load.mjs"

test("location file parsing matches omarchy-weather-location", () => {
  assert.deepEqual(Model.parseLocationFile('{"name":"Bergen","latitude":60.39,"longitude":5.32}'), { name: "Bergen", latitude: 60.39, longitude: 5.32 })
  assert.deepEqual(Model.parseLocationFile('{"name":" Malibu "}'), { name: "Malibu", latitude: null, longitude: null })
  assert.deepEqual(Model.parseLocationFile(""), Model.emptyLocation())
  assert.equal(Model.hasCoordinates({ latitude: "59.9", longitude: "10.7" }), true)
  assert.equal(Model.hasCoordinates({ name: "Oslo" }), false)
})

test("parseIpLocation accepts ipwho.is and geojs shapes", () => {
  assert.deepEqual(Model.parseIpLocation('{"success":true,"city":"Oslo","country_code":"NO","latitude":59.9126738,"longitude":10.7461747}'),
    { name: "Oslo", latitude: 59.9126738, longitude: 10.7461747 })
  assert.deepEqual(Model.parseIpLocation('{"city":"Oslo","latitude":"59.9133","longitude":"10.7389","accuracy":500}'),
    { name: "Oslo", latitude: 59.9133, longitude: 10.7389 })
  assert.equal(Model.parseIpLocation('{"success":false,"message":"rate limited"}').latitude, null)
  assert.equal(Model.parseIpLocation("not json").latitude, null)
  assert.equal(Model.IP_LOCATION_URLS.length, 2)
})

test("Open-Meteo results: populated places with region", () => {
  const rows = Model.parseOpenMeteoResults(fixture("open-meteo-oslo.json"))
  assert.ok(rows.length >= 3)
  assert.equal(rows[0].name, "Oslo")
  assert.equal(rows[0].description, "Oslo, Norway")
  assert.equal(rows[0].source, "open-meteo")
  assert.ok(Math.abs(rows[0].latitude - 59.9127) < 0.01)
  assert.deepEqual(Model.parseOpenMeteoResults('{"generationtime_ms":0.5}'), [], "no results key")
  assert.deepEqual(Model.parseOpenMeteoResults("garbage"), [])
})

test("Kartverket finds Sanderstølen (Nord-Aurdal); Photon too; merged without duplicates", () => {
  const kv = Model.parseKartverketResults(fixture("kartverket-sanderstolen.json"), "Sanderstølen")
  assert.ok(kv.length >= 2)
  const hotel = kv.find(r => /Nord-Aurdal/.test(r.description))
  assert.equal(hotel.name, "Sanderstølen")
  assert.equal(hotel.latitude, 60.8274)
  assert.equal(hotel.longitude, 9.13895)
  assert.match(hotel.description, /Hotell/)
  assert.ok(kv.every(r => Model.normalizeName(r.name).startsWith("sanderstølen")), "fuzzy noise filtered out")

  const ph = Model.parsePhotonResults(fixture("photon-sanderstolen.json"))
  assert.equal(ph.length, 2, "farm + hotel kept; bus stop, parking and defibrillator dropped")

  const merged = Model.mergeSuggestions({ "open-meteo": [], kartverket: kv, photon: ph }, 8)
  const nordAurdal = merged.filter(r => r.name === "Sanderstølen" && Math.abs(r.latitude - 60.8274) < 0.02)
  assert.equal(nordAurdal.length, 1, "Kartverket and Photon hits for the same place are merged")
  assert.equal(nordAurdal[0].source, "kartverket")
})

test("merge order, limit and dispatch", () => {
  const om = Model.parseOpenMeteoResults(fixture("open-meteo-oslo.json"))
  const merged = Model.mergeSuggestions({ "open-meteo": om, kartverket: [{ name: "Oslo", description: "Oslo  ·  By", latitude: 59.913, longitude: 10.74, source: "kartverket" }], photon: [] }, 3)
  assert.equal(merged.length, 3, "limit respected")
  assert.equal(merged[0].source, "open-meteo", "Open-Meteo first")
  assert.equal(merged.filter(r => r.name === "Oslo" && Math.abs(r.latitude - 59.913) < 0.02).length, 1, "Kartverket Oslo deduped against Open-Meteo Oslo")
  assert.equal(Model.parseGeocodeResponse("kartverket", fixture("kartverket-sanderstolen.json"), "Sanderstølen")[0].source, "kartverket")
  assert.equal(Model.parseGeocodeResponse("photon", fixture("photon-sanderstolen.json"))[0].source, "photon")
  assert.equal(Model.parseGeocodeResponse("whatever", fixture("open-meteo-oslo.json"))[0].source, "open-meteo")
})

test("geocode request fan-out and commit rules", () => {
  assert.equal(Model.geocodeRequests("O").length, 0)
  assert.equal(Model.geocodeRequests("Os").length, 1)
  const three = Model.geocodeRequests("Sanderstølen")
  assert.deepEqual(three.map(r => r.source), ["open-meteo", "kartverket", "photon"])
  assert.ok(three[1].command.join(" ").includes("sok=Sanderst%C3%B8len"))
  assert.ok(three.every(r => r.command.includes("User-Agent: " + Model.USER_AGENT)))
  assert.ok(three.every(r => r.command.join(" ").includes("--max-filesize " + Model.MAX_BYTES_LOOKUP)))
  assert.equal(Model.locationCommit("Nowhere", [], 0), null, "no match → nothing to save")
  assert.equal(Model.locationCommit("", [], 0), null, "an empty box commits nothing — never 'back to auto' by accident")
  assert.equal(Model.locationCommit("   ", [{ name: "A", latitude: 1, longitude: 2 }], 0), null)
  const long = Model.geocodeRequests("Oslo" + "x".repeat(5000))
  assert.equal(long.length, 3)
  for (const r of long) assert.ok(r.command[r.command.length - 1].length < 400, "query is capped before it becomes a URL")
  const choices = [{ name: "A", latitude: 1, longitude: 2 }, { name: "B", latitude: 3, longitude: 4 }]
  assert.equal(Model.locationCommit("san", choices, 1).name, "B")
  assert.equal(Model.locationCommit("san", choices, 99).name, "B", "index clamped")
  assert.equal(Model.locationCommit("san", choices, NaN).name, "A", "NaN → first")
})

test("keyboard selection follows the place, not the row, when sources arrive late", () => {
  const a = { name: "Berg", latitude: 1, longitude: 1 }, b = { name: "Bergen", latitude: 60.39, longitude: 5.32 }
  assert.equal(Model.suggestionIndexFor([a, b], b, 0), 1)
  assert.equal(Model.suggestionIndexFor([{ name: "X", latitude: 0, longitude: 0 }, a, b], b, 0), 2, "rows inserted above")
  assert.equal(Model.suggestionIndexFor([a, b], { name: "Gone", latitude: 9, longitude: 9 }, 1), 1, "vanished → keep index")
  assert.equal(Model.suggestionIndexFor([a], null, 5), 0, "clamped")
  assert.equal(Model.suggestionIndexFor([], null, 2), 0)
})

test("oversized lookup responses are refused, not parsed", () => {
  // Trailing whitespace keeps each fixture valid JSON, so only the size cap
  // can be what rejects it.
  const pad = " ".repeat(Model.MAX_BYTES_LOOKUP)
  assert.deepEqual(Model.parseGeocodeResponse("photon", fixture("photon-sanderstolen.json") + pad), [])
  assert.deepEqual(Model.parseGeocodeResponse("kartverket", fixture("kartverket-sanderstolen.json") + pad, "Sanderstølen"), [])
  assert.equal(Model.parsePhotonReverse(fixture("photon-reverse.json") + pad), null)
  assert.equal(Model.parseKartverketPoint(fixture("kartverket-punkt.json") + pad), "")
  assert.deepEqual(Model.parseIpLocation('{"city":"Oslo","latitude":59.9,"longitude":10.7}' + pad), Model.emptyLocation())
  assert.equal(Model.parseIpLocation('{"city":"Oslo","latitude":59.9,"longitude":10.7}').name, "Oslo", "same body under the cap parses")
  assert.ok(Model.curlCommand("https://ipwho.is/").join(" ").includes("--max-filesize " + Model.MAX_BYTES_LOOKUP))
  assert.deepEqual(Model.parseLocationFile('{"name":"Oslo","latitude":59.9,"longitude":10.7}' + pad), Model.emptyLocation(), "weather.json is a file: same ceiling")
})

test("reverse lookup names a GPS fix", () => {
  const rev = Model.parsePhotonReverse(fixture("photon-reverse.json"))
  assert.equal(rev.name, "Sanderstølen")
  assert.equal(rev.countryCode, "NO")
  assert.match(rev.description, /Nord-Aurdal/)
  assert.equal(Model.parseKartverketPoint(fixture("kartverket-punkt.json")), "Sanderstølen", "nearest non-street name")
  assert.equal(Model.parsePhotonReverse("{}"), null)
  assert.equal(Model.parseKartverketPoint("nope"), "")
  assert.ok(Model.reverseCommand(60.82739, 9.138954).join(" ").includes("lat=60.8274&lon=9.139"))
  assert.ok(Model.kartverketPointCommand(60.8274, 9.13895).join(" ").includes("nord=60.8274&ost=9.139"))
})
