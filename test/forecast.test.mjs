import { test } from "node:test"
import assert from "node:assert/strict"
import { Model, fixture, forecast, firstTime } from "./helpers/load.mjs"

const headers200 = fixture("headers-200.txt")

test("fixture is a Locationforecast compact document", () => {
  assert.equal(forecast.type, "Feature")
  assert.ok(forecast.properties.timeseries.length > 50)
})

test("currentEntry picks the last entry at or before now", () => {
  assert.equal(Model.currentEntry(forecast, firstTime).time, forecast.properties.timeseries[0].time)
  const later = Model.currentEntry(forecast, firstTime + 2 * 3600 * 1000 + 600 * 1000)
  assert.equal(later.time, forecast.properties.timeseries[2].time)
  assert.equal(Model.currentEntry(forecast, firstTime - 86400000).time, forecast.properties.timeseries[0].time, "all in the future → first")
  assert.equal(Model.currentEntry(null), null)
})

test("currentCondition extracts the instant details", () => {
  const c = Model.currentCondition(Model.currentEntry(forecast, firstTime))
  assert.equal(c.tempC, 17.2)
  assert.equal(c.windMs, 3.3)
  assert.equal(Math.round(c.windMph), 7)
  assert.equal(c.humidity, 71.2)
  assert.equal(c.precipMm, 0)
  assert.equal(c.symbolCode, "partlycloudy_night")
  assert.equal(c.isNight, true)
  assert.equal(Model.currentCondition(null), null)
})

test("symbolCodeFor falls back from 1h to 6h to 12h windows", () => {
  const sixHourly = forecast.properties.timeseries.find(e => !e.data.next_1_hours && e.data.next_6_hours)
  assert.ok(sixHourly, "fixture has a 6-hourly entry")
  assert.equal(Model.symbolCodeFor(sixHourly), sixHourly.data.next_6_hours.summary.symbol_code)
  assert.equal(Model.symbolCodeFor({ data: { next_12_hours: { summary: { symbol_code: "fog" } } } }), "fog")
  assert.equal(Model.symbolCodeFor({ data: {} }), "")
})

test("dailyForecast yields future days with min <= max and a day glyph", () => {
  const today = Model.localDateKey(new Date(firstTime))
  const days = Model.dailyForecast(forecast, today, 4)
  assert.equal(days.length, 4)
  for (const day of days) {
    assert.ok(day.date > today)
    assert.ok(day.minC <= day.maxC, `${day.date}: ${day.minC} > ${day.maxC}`)
    assert.equal(day.icon.length, 1)
    assert.ok(day.symbolCode.length > 0 && day.label.length > 0)
  }
  assert.deepEqual(Model.dailyForecast(null, today), [])
  assert.equal(Model.dailyForecast(forecast, today).length, 4, "default is four days")
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
  assert.equal(Model.hourlyForecast(forecast, firstTime + 5 * 3600 * 1000, 6)[0].time, forecast.properties.timeseries[5].time)
  const all = Model.hourlyForecast(forecast, firstTime, 500)
  assert.ok(all.length > 24 && all.length < forecast.properties.timeseries.length)
  assert.deepEqual(Model.hourlyForecast(null, firstTime, 24), [])
  assert.ok(Model.samePoints(points, Model.hourlyForecast(forecast, firstTime, 24)))
  assert.ok(!Model.samePoints(points, Model.hourlyForecast(forecast, firstTime + 3600 * 1000, 24)))
})

test("graphScale pads the temperature range and uses round ticks in every unit", () => {
  const points = Model.hourlyForecast(forecast, firstTime, 24)
  for (const unit of ["metric", "imperial", "kelvin"]) {
    const scale = Model.graphScale(points, unit)
    const temps = points.map(p => Model.convertTemp(p.tempC, unit))
    assert.ok(scale.tempMin < Math.min(...temps), unit)
    assert.ok(scale.tempMax > Math.max(...temps), unit)
    assert.ok(scale.ticks.length >= 2 && scale.ticks.length <= 6, `${unit} ticks: ${scale.ticks}`)
    for (const tick of scale.ticks) assert.ok(tick >= scale.tempMin && tick <= scale.tempMax)
  }
  assert.ok(Model.graphScale(points, "imperial").tempMax - Model.graphScale(points, "imperial").tempMin >= 8)
  assert.equal(Model.graphScale([], "metric").ticks.length, 0)
  const flat = Model.graphScale([{ tempC: 10, precipMm: 0 }, { tempC: 10, precipMm: 0 }], "metric")
  assert.ok(flat.tempMax - flat.tempMin >= 4)
  assert.equal(flat.hasPrecip, false)
  assert.equal(Model.niceStep(9, 3), 5)
  assert.equal(Model.niceStep(4, 3), 2)
  assert.equal(Model.degreeSign("kelvin"), "")
  assert.equal(Model.degreeSign("metric"), "°")
})

test("a broken temperature field cannot size the graph", () => {
  // One out-of-range number used to drive ticksFor to 260 000 ticks (±1e7)
  // or a RangeError (1e308) inside a QML binding. Such entries are dropped.
  for (const bad of [1e7, -1e7, 1e308, -1e308, "NaN", "Infinity", 71, -101, null, "abc"]) {
    assert.equal(Model.validTempC(bad), null, String(bad))
    const entry = { time: "2026-08-22T10:00:00Z", data: { instant: { details: { air_temperature: bad } }, next_1_hours: { summary: { symbol_code: "fog" }, details: {} } } }
    assert.equal(Model.currentCondition(entry), null, String(bad))
    const doc = { properties: { timeseries: [entry] } }
    assert.deepEqual(Model.hourlyForecast(doc, Date.parse(entry.time), 6), [], String(bad))
    assert.deepEqual(Model.dailyForecast(doc, "2026-08-21"), [], String(bad))
  }
  assert.equal(Model.validTempC(-40), -40)
  assert.equal(Model.validTempC("17.2"), 17.2)
  assert.deepEqual(Model.ticksFor(-1e7, 1e7), [])
  assert.deepEqual(Model.ticksFor(NaN, 10), [])
  assert.ok(Model.ticksFor(-100, 70).length >= 2)
  const scale = Model.graphScale([{ tempC: Model.TEMP_C_MIN, precipMm: 0 }, { tempC: Model.TEMP_C_MAX, precipMm: 0 }], "imperial")
  assert.ok(isFinite(scale.tempMin) && isFinite(scale.tempMax) && scale.ticks.length >= 2 && scale.ticks.length <= 12)
})

test("MET requests: URL, User-Agent, If-Modified-Since, 4-decimal coordinates", () => {
  assert.equal(Model.roundCoord(59.912673812), 59.9127)
  assert.equal(Model.roundCoord(-33.86882), -33.8688)
  assert.equal(Model.roundCoord("abc"), null)
  assert.equal(Model.locationKey(59.91273, 10.74617), "59.9127,10.7462")
  assert.equal(Model.locationKey(null, 1), "")
  assert.equal(Model.forecastUrl(59.912673812, 10.7461747), "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=59.9127&lon=10.7462")
  assert.equal(Model.forecastUrl(null, 1), "")
  assert.ok(Model.alertsUrl(59.91273, 10.74617, "no").endsWith("?lat=59.9127&lon=10.7462&lang=no"))
  assert.ok(Model.alertsUrl(59.91273, 10.74617, "xx").endsWith("&lang=en"))
  assert.equal(Model.alertsLanguage("nb_NO.UTF-8"), "no")
  assert.equal(Model.alertsLanguage("nn-NO"), "no")
  assert.equal(Model.alertsLanguage("en_US"), "en")
  const cmd = Model.metCommand(Model.forecastUrl(59.9, 10.7), "Fri, 21 Aug 2026 19:19:53 GMT", 10)
  assert.equal(cmd[0], "curl")
  assert.ok(cmd.includes("--compressed") && cmd.includes("-D"))
  assert.ok(cmd.join(" ").includes("--max-filesize " + Model.MAX_BYTES_MET))
  assert.ok(cmd.includes("User-Agent: " + Model.USER_AGENT))
  assert.ok(cmd.includes("If-Modified-Since: Fri, 21 Aug 2026 19:19:53 GMT"))
  assert.ok(!Model.metCommand(Model.TEXTFORECAST_URL, "", 15).some(a => /If-Modified-Since/.test(a)))
  assert.ok(Model.metCommand("u", "", 15).includes("15"))
})

test("parseCurlResponse handles 200, 304, redirects, 100-continue, 429 bodies, transport errors", () => {
  const ok = Model.parseCurlResponse(headers200 + fixture("locationforecast-compact.json"))
  assert.equal(ok.status, 200)
  assert.equal(ok.lastModified, "Fri, 21 Aug 2026 19:19:53 GMT")
  assert.ok(Model.parseForecast(ok.body))

  const notModified = Model.parseCurlResponse("HTTP/2 304 \r\nserver: nginx\r\nlast-modified: Fri, 21 Aug 2026 19:19:53 GMT\r\n\r\n")
  assert.equal(notModified.status, 304)
  assert.equal(notModified.body, "")
  assert.equal(Model.parseForecast(notModified.body), null)

  const redirected = Model.parseCurlResponse("HTTP/1.1 301 Moved\r\nlocation: x\r\n\r\nHTTP/2 200 \r\nlast-modified: Sat, 22 Aug 2026 08:00:00 GMT\r\n\r\n{\"properties\":{\"timeseries\":[{\"time\":\"2026-01-01T00:00:00Z\"}]}}")
  assert.equal(redirected.status, 200)
  assert.equal(redirected.lastModified, "Sat, 22 Aug 2026 08:00:00 GMT")

  const cont = Model.parseCurlResponse("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nLast-Modified: Sun, 23 Aug 2026 09:00:00 GMT\r\n\r\n{\"properties\":{\"timeseries\":[{\"time\":\"t\"}]}}")
  assert.equal(cont.status, 200)
  assert.equal(cont.lastModified, "Sun, 23 Aug 2026 09:00:00 GMT")

  // The validator is echoed back as a request header, so only an HTTP date
  // is kept: anything else from the server is dropped, not forwarded.
  for (const bad of ["A", "<img src=x>", "Fri, 21 Aug 2026 19:19:53 GMT\tX-Injected: 1", "x".repeat(5000), "Fri, 21 Aug 2026 19:19:53 UTC"]) {
    assert.equal(Model.parseCurlResponse("HTTP/2 200 \r\nlast-modified: " + bad + "\r\n\r\n{}").lastModified, "", JSON.stringify(bad.slice(0, 40)))
  }

  const limited = Model.parseCurlResponse("HTTP/2 429 \r\ncontent-type: application/json\r\n\r\n{\"error\":\"too many\"}")
  assert.equal(limited.status, 429)
  assert.equal(Model.parseForecast(limited.body), null)

  const noLm = Model.parseCurlResponse("HTTP/2 200 \r\n\r\n{}")
  assert.equal(noLm.lastModified, "", "no validator → next fetch is unconditional")

  assert.equal(Model.parseCurlResponse("").status, 0)
  assert.equal(Model.parseCurlResponse("curl: (6) Could not resolve host").status, 0)

  // Oversized dumps are refused before any header or JSON work — the guard
  // behind curl's own --max-filesize (which curl < 8.4 cannot apply to
  // chunked/compressed bodies). Padding keeps the dump otherwise valid.
  const oversize = Model.parseCurlResponse(headers200 + fixture("locationforecast-compact.json") + " ".repeat(Model.MAX_BYTES_MET))
  assert.equal(oversize.status, 0)
  assert.equal(oversize.body, "")
  assert.ok(Model.responseTooLarge("x".repeat(Model.MAX_BYTES_MET + 1), Model.MAX_BYTES_MET))
  assert.ok(!Model.responseTooLarge("x".repeat(Model.MAX_BYTES_MET), Model.MAX_BYTES_MET), "exactly at the cap still parses")
  assert.equal(Model.fetchErrorText(0), "no response")
  assert.match(Model.fetchErrorText(429), /rate limited/)
  assert.equal(Model.fetchErrorText(200), "bad response")
})
