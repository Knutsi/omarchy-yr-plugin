import { test } from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { readFileSync } from "node:fs"

const require = createRequire(import.meta.url)
const Model = require("../Model.js")

const fixtureText = readFileSync(new URL("./fixtures/locationforecast-compact.json", import.meta.url), "utf8")
const headers200 = readFileSync(new URL("./fixtures/headers-200.txt", import.meta.url), "utf8")
const forecast = JSON.parse(fixtureText)
const firstTime = Date.parse(forecast.properties.timeseries[0].time)

// All 83 symbol codes MET currently emits (metno/weathericons, weather/svg).
const VARIANT_BASES = [
  "clearsky", "fair", "partlycloudy",
  "lightrainshowers", "rainshowers", "heavyrainshowers",
  "lightrainshowersandthunder", "rainshowersandthunder", "heavyrainshowersandthunder",
  "lightsleetshowers", "sleetshowers", "heavysleetshowers",
  "lightssleetshowersandthunder", "sleetshowersandthunder", "heavysleetshowersandthunder",
  "lightsnowshowers", "snowshowers", "heavysnowshowers",
  "lightssnowshowersandthunder", "snowshowersandthunder", "heavysnowshowersandthunder"
]
const PLAIN = [
  "cloudy", "fog",
  "lightrain", "rain", "heavyrain", "lightrainandthunder", "rainandthunder", "heavyrainandthunder",
  "lightsleet", "sleet", "heavysleet", "lightsleetandthunder", "sleetandthunder", "heavysleetandthunder",
  "lightsnow", "snow", "heavysnow", "lightsnowandthunder", "snowandthunder", "heavysnowandthunder"
]
const ALL_CODES = [
  ...VARIANT_BASES.flatMap(b => [`${b}_day`, `${b}_night`, `${b}_polartwilight`]),
  ...PLAIN
]

test("fixture is a Locationforecast compact document", () => {
  assert.equal(forecast.type, "Feature")
  assert.ok(forecast.properties.timeseries.length > 50)
})

test("all 83 MET symbol codes map to a glyph and a label", () => {
  assert.equal(ALL_CODES.length, 83)
  for (const code of ALL_CODES) {
    const glyph = Model.iconForSymbol(code)
    assert.equal(typeof glyph, "string", code)
    assert.equal(glyph.length, 1, `${code} → ${JSON.stringify(glyph)}`)
    assert.ok(glyph.codePointAt(0) >= 0xe300, code)
    const label = Model.symbolLabel(code)
    assert.ok(label.length > 0 && !/_/.test(label), `${code} → ${label}`)
  }
  assert.equal(Model.symbolLabel("lightssleetshowersandthunder_day"), "Light sleet showers and thunder")
  assert.equal(Model.symbolLabel("heavysnowshowers_polartwilight"), "Heavy snow showers")
  assert.equal(Model.symbolLabel("clearsky_night"), "Clear sky")
  assert.equal(Model.symbolLabel(""), "")
})

test("day/night variants pick different glyphs; polar twilight renders as day", () => {
  assert.notEqual(Model.iconForSymbol("clearsky_day"), Model.iconForSymbol("clearsky_night"))
  assert.equal(Model.iconForSymbol("fair_polartwilight"), Model.iconForSymbol("fair_day"))
  assert.equal(Model.iconForSymbol("unknown_code_xyz"), Model.iconForSymbol("cloudy"))
  assert.equal(Model.glyphFamily("lightssnowshowersandthunder"), "thunder")
  assert.equal(Model.glyphFamily("heavysleetshowers"), "sleetshowers")
})

test("currentEntry picks the last entry at or before now", () => {
  assert.equal(Model.currentEntry(forecast, firstTime).time, forecast.properties.timeseries[0].time)
  const later = Model.currentEntry(forecast, firstTime + 2 * 3600 * 1000 + 600 * 1000)
  assert.equal(later.time, forecast.properties.timeseries[2].time)
  // Before the series starts → first entry; no forecast → null
  assert.equal(Model.currentEntry(forecast, firstTime - 86400000).time, forecast.properties.timeseries[0].time)
  assert.equal(Model.currentEntry(null), null)
})

test("currentCondition extracts the instant details", () => {
  const c = Model.currentCondition(Model.currentEntry(forecast, firstTime))
  assert.equal(c.tempC, 17.2)
  assert.equal(Math.round(c.tempF * 10) / 10, 63)
  assert.equal(c.windMs, 3.3)
  assert.equal(c.humidity, 71.2)
  assert.equal(c.precipMm, 0)
  assert.equal(c.symbolCode, "partlycloudy_night")
  assert.equal(c.isNight, true)
  assert.equal(Model.currentCondition(null), null)
})

test("symbolCodeFor falls back from 1h to 6h to 12h windows", () => {
  // Hourly entries stop after ~2.5 days; later entries only carry 6h/12h windows.
  const sixHourly = forecast.properties.timeseries.find(e => !e.data.next_1_hours && e.data.next_6_hours)
  assert.ok(sixHourly, "fixture has a 6-hourly entry")
  assert.equal(Model.symbolCodeFor(sixHourly), sixHourly.data.next_6_hours.summary.symbol_code)
  assert.equal(Model.symbolCodeFor({ data: { next_12_hours: { summary: { symbol_code: "fog" } } } }), "fog")
  assert.equal(Model.symbolCodeFor({ data: {} }), "")
})

test("dailyForecast yields future days with min <= max and a day glyph", () => {
  const today = Model.localDateKey(new Date(firstTime))
  const days = Model.dailyForecast(forecast, today, 3)
  assert.equal(days.length, 3)
  for (const day of days) {
    assert.ok(day.date > today)
    assert.ok(day.minC <= day.maxC, `${day.date}: ${day.minC} > ${day.maxC}`)
    assert.equal(day.icon.length, 1)
    assert.ok(day.symbolCode.length > 0)
    assert.ok(day.label.length > 0)
  }
  assert.deepEqual(Model.dailyForecast(null, today), [])
})

test("parseCurlResponse handles 200, 304, and redirects", () => {
  const ok = Model.parseCurlResponse(headers200 + fixtureText)
  assert.equal(ok.status, 200)
  assert.equal(ok.lastModified, "Fri, 21 Aug 2026 19:19:53 GMT")
  assert.ok(ok.expires.length > 0)
  assert.ok(Model.parseForecast(ok.body))

  const notModified = Model.parseCurlResponse("HTTP/2 304 \r\nserver: nginx\r\nlast-modified: Fri, 21 Aug 2026 19:19:53 GMT\r\n\r\n")
  assert.equal(notModified.status, 304)
  assert.equal(notModified.body, "")
  assert.equal(Model.parseForecast(notModified.body), null)

  const redirected = Model.parseCurlResponse("HTTP/1.1 301 Moved\r\nlocation: x\r\n\r\nHTTP/2 200 \r\nlast-modified: A\r\n\r\n{\"properties\":{\"timeseries\":[{\"time\":\"2026-01-01T00:00:00Z\"}]}}")
  assert.equal(redirected.status, 200)
  assert.equal(redirected.lastModified, "A")
  assert.ok(Model.parseForecast(redirected.body))

  assert.equal(Model.parseCurlResponse("").status, 0)
  assert.equal(Model.parseCurlResponse("curl: (6) Could not resolve host").status, 0)
})

test("forecast request honours MET's terms", () => {
  assert.equal(Model.roundCoord(59.912673812), 59.9127)
  assert.equal(Model.roundCoord("abc"), null)
  assert.equal(Model.forecastUrl(59.912673812, 10.7461747), "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=59.9127&lon=10.7462")
  assert.equal(Model.forecastUrl(null, 1), "")

  const cmd = Model.forecastCommand(59.9, 10.7, "Fri, 21 Aug 2026 19:19:53 GMT")
  assert.equal(cmd[0], "curl")
  assert.ok(cmd.includes("--compressed"))
  assert.ok(cmd.includes("User-Agent: " + Model.USER_AGENT))
  assert.ok(/github\.com/.test(Model.USER_AGENT))
  assert.ok(cmd.includes("If-Modified-Since: Fri, 21 Aug 2026 19:19:53 GMT"))
  assert.ok(!Model.forecastCommand(59.9, 10.7, "").some(a => /If-Modified-Since/.test(a)))
})

test("parseIpLocation accepts ipwho.is and geojs shapes", () => {
  const who = Model.parseIpLocation('{"success":true,"city":"Oslo","country_code":"NO","latitude":59.9126738,"longitude":10.7461747}')
  assert.deepEqual(who, { name: "Oslo", latitude: 59.9126738, longitude: 10.7461747, countryCode: "NO" })
  const geojs = Model.parseIpLocation('{"city":"Oslo","country_code":"no","latitude":"59.9133","longitude":"10.7389","accuracy":500}')
  assert.deepEqual(geojs, { name: "Oslo", latitude: 59.9133, longitude: 10.7389, countryCode: "NO" })
  assert.equal(Model.parseIpLocation('{"success":false,"message":"rate limited"}').latitude, null)
  assert.equal(Model.parseIpLocation("not json").latitude, null)
})

test("location file parsing matches omarchy-weather-location", () => {
  assert.deepEqual(Model.parseLocationFile('{"name":"Bergen","latitude":60.39,"longitude":5.32}'), { name: "Bergen", latitude: 60.39, longitude: 5.32 })
  assert.deepEqual(Model.parseLocationFile('{"name":" Malibu "}'), { name: "Malibu", latitude: null, longitude: null })
  assert.deepEqual(Model.parseLocationFile(""), { name: "", latitude: null, longitude: null })
  assert.equal(Model.hasCoordinates({ latitude: "59.9", longitude: "10.7" }), true)
  assert.equal(Model.hasCoordinates({ name: "Oslo" }), false)
})

test("unit systems: metric by default, imperial and kelvin on request", () => {
  assert.equal(Model.unitSystem(""), "metric")
  assert.equal(Model.unitSystem(undefined), "metric")
  assert.equal(Model.unitSystem(" Imperial "), "imperial")
  assert.equal(Model.unitSystem("kelvin"), "kelvin")
  assert.equal(Model.unitSystem("en_US"), "metric", "locale strings are not units")
  assert.equal(Model.nextUnit("metric"), "imperial")
  assert.equal(Model.nextUnit("kelvin"), "metric")
  assert.equal(Model.convertTemp(17.2, "metric"), 17.2)
  assert.equal(Math.round(Model.convertTemp(17.2, "imperial") * 10) / 10, 63)
  assert.equal(Math.round(Model.convertTemp(17.2, "kelvin") * 100) / 100, 290.35)
  assert.equal(Model.convertTemp(null, "metric"), null)
})

test("formatting", () => {
  const c = Model.currentCondition(Model.currentEntry(forecast, firstTime))
  assert.equal(Model.formatTemp(c.tempC, "metric"), "17°C")
  assert.equal(Model.formatTemp(c.tempC, "imperial"), "63°F")
  assert.equal(Model.formatTemp(c.tempC, "kelvin"), "290K")
  assert.equal(Model.bareTemp(c.tempC, "metric"), "17°")
  assert.equal(Model.bareTemp(c.tempC, "kelvin"), "290K")
  assert.equal(Model.formatWind(c, "metric"), "3 m/s")
  assert.equal(Model.formatWind(c, "kelvin"), "3 m/s")
  assert.equal(Model.formatWind(c, "imperial"), "7 mph")
  assert.equal(Model.formatPrecip(0.44, "metric"), "0.4 mm")
  assert.equal(Model.formatPrecip(25.4, "imperial"), "1 in")
  assert.equal(Model.formatPrecip(null, "metric"), "")
  assert.equal(Model.statusLine("Oslo", c, "metric"), "Oslo  ·  17°C  ·  Partly cloudy  ·  Wind 3 m/s")
  assert.equal(Model.statusLine("Oslo", null, "metric"), "Weather unavailable")
  assert.equal(Model.bareTempForDay({ maxC: 21.6, minC: 11.2 }, "max", "metric"), "22°")
  assert.equal(Model.bareTempForDay({ maxC: 21.6, minC: 11.2 }, "min", "imperial"), "52°")
})

test("hourlyForecast starts at the current entry and stops at the 6-hourly tail", () => {
  const points = Model.hourlyForecast(forecast, firstTime, 24)
  assert.equal(points.length, 24)
  assert.equal(points[0].time, forecast.properties.timeseries[0].time)
  assert.equal(points[0].tempC, 17.2)
  assert.equal(points[0].icon.length, 1)
  assert.match(points[0].hourLabel, /^[0-2][0-9]$/)
  for (let i = 1; i < points.length; i++) {
    assert.equal(Date.parse(points[i].time) - Date.parse(points[i - 1].time), 3600 * 1000, "consecutive hours")
    assert.ok(points[i].precipMm >= 0)
  }
  const later = Model.hourlyForecast(forecast, firstTime + 5 * 3600 * 1000, 6)
  assert.equal(later[0].time, forecast.properties.timeseries[5].time)
  const all = Model.hourlyForecast(forecast, firstTime, 500)
  assert.ok(all.length > 24 && all.length < forecast.properties.timeseries.length)
  assert.deepEqual(Model.hourlyForecast(null, firstTime, 24), [])
})

test("graphScale pads the temperature range and uses round ticks", () => {
  const points = Model.hourlyForecast(forecast, firstTime, 24)
  const scale = Model.graphScale(points, "metric")
  const temps = points.map(p => p.tempC)
  assert.ok(scale.tempMin < Math.min(...temps))
  assert.ok(scale.tempMax > Math.max(...temps))
  assert.ok(scale.ticks.length >= 2 && scale.ticks.length <= 6, `ticks: ${scale.ticks}`)
  for (const tick of scale.ticks) assert.ok(tick >= scale.tempMin && tick <= scale.tempMax)
  assert.ok(scale.precipMax >= 1)
  assert.equal(Model.graphScale([], "metric").ticks.length, 0)
  const flat = Model.graphScale([{ tempC: 10, precipMm: 0 }, { tempC: 10, precipMm: 0 }], "metric")
  assert.ok(flat.tempMax - flat.tempMin >= 4)
  assert.equal(flat.hasPrecip, false)
  assert.equal(Model.niceStep(9, 3), 5)
  assert.equal(Model.niceStep(4, 3), 2)
})

test("sunTimes: Oslo in August, the equator, and the polar cases", () => {
  // Reference from MET's Sunrise 3.0 API for Oslo 2026-08-21: 05:45 / 20:52 CEST.
  // The simplified solar equations drift a few minutes at high latitudes.
  const oslo = Model.sunTimes(59.9127, 10.7461, new Date("2026-08-21T12:00:00+02:00"))
  assert.ok(oslo.sunrise && oslo.sunset)
  const riseUtc = oslo.sunrise.getUTCHours() * 60 + oslo.sunrise.getUTCMinutes()
  const setUtc = oslo.sunset.getUTCHours() * 60 + oslo.sunset.getUTCMinutes()
  assert.ok(Math.abs(riseUtc - (3 * 60 + 45)) <= 6, `sunrise UTC minutes ${riseUtc}`)
  assert.ok(Math.abs(setUtc - (18 * 60 + 52)) <= 6, `sunset UTC minutes ${setUtc}`)

  const equator = Model.sunTimes(0, 0, new Date("2026-03-20T12:00:00Z"))
  // MET Sunrise 3.0 for 0°N 0°E on 2026-03-20: 06:04 / 18:10 UTC.
  assert.ok(Math.abs(equator.sunrise.getUTCHours() * 60 + equator.sunrise.getUTCMinutes() - (6 * 60 + 4)) <= 6)
  assert.ok(Math.abs(equator.sunset.getUTCHours() * 60 + equator.sunset.getUTCMinutes() - (18 * 60 + 10)) <= 6)

  assert.equal(Model.sunTimes(78.2, 15.6, new Date("2026-06-21T12:00:00Z")).polar, "day")
  assert.equal(Model.sunTimes(78.2, 15.6, new Date("2026-12-21T12:00:00Z")).polar, "night")
  assert.equal(Model.sunTimes(null, 10, new Date()).sunrise, null)
  assert.equal(Model.formatSunTime(null, "day"), "up all day")
  assert.equal(Model.formatSunTime(null, ""), "")
  assert.match(Model.formatSunTime(oslo.sunrise, ""), /^[0-2][0-9]:[0-5][0-9]$/)
})
