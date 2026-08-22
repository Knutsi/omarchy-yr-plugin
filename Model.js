// Model.js — pure helpers for the Yr.no (unofficial) Omarchy plugin.
//
// Plain JavaScript with no QML/Quickshell dependencies, so it is loaded both
// by QML (`import "Model.js" as Model`) and by the unit tests (node, CommonJS
// via module.exports). Keep it one file: QML's `.import` pragma is not valid
// JavaScript, so helpers cannot be split across files without breaking one
// of the two loaders.
//
// Consumers: Service.qml / LocationService.qml / WeatherService.qml /
// GeocodeSearch.qml (data), HourlyGraph.qml (symbols, graph scale, units),
// the view components (formatting), BarWidget.qml (units).
//
// Language rule: English for every string the plugin writes; MET's own texts
// (warnings, tekstvarsel) stay in the language they were requested in;
// Norwegian proper nouns (Tekstvarsel, Kartverket, Østlandet) stay as names.
//
// Data terms: https://api.met.no/doc/TermsOfService — identify the app in
// the User-Agent, round coordinates to 4 decimals, poll at most every
// 10 minutes, revalidate with If-Modified-Since, credit "MET Norway".

var VERSION = "0.3.1"
var USER_AGENT = "omarchy-yr-plugin/" + VERSION + " github.com/Knutsi/omarchy-yr-plugin"
var ATTRIBUTION = "Data from MET Norway"

// Settings keys on the widget's shell.json entry, with the same defaults and
// bounds the manifest declares (test/meta.test.mjs keeps them in sync).
var DEFAULTS = { refreshMinutes: 15, unit: "metric", barFormat: "icon-temp", graphHours: 24, textForecast: true, textForecastArea: "" }
var REFRESH_MINUTES_MIN = 10   // MET: desktop clients poll at most every 10 minutes
var REFRESH_MINUTES_MAX = 180
var GRAPH_HOURS_MIN = 6
var GRAPH_HOURS_MAX = 48
var FORCED_REFRESH_FLOOR_MS = 10000

// Network timeouts (seconds) and retry policy.
var TIMEOUT_LOOKUP_S = 5        // geocoders, IP lookup, reverse lookup
var TIMEOUT_FORECAST_S = 10
var TIMEOUT_TEXT_S = 15         // textforecast/metalerts bodies are larger
var RETRY_LIMIT = 3
var RETRY_DELAY_MS = 2500
var TEXTFORECAST_INTERVAL_MS = 3 * 3600 * 1000

function num(value) {
  if (value === undefined || value === null || value === "") return null
  var n = parseFloat(String(value))
  return isNaN(n) ? null : n
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(String(value), 10)
  if (isNaN(n)) n = fallback
  return Math.max(min, Math.min(max, n))
}

function refreshMinutes(value) {
  return clampInt(value, DEFAULTS.refreshMinutes, REFRESH_MINUTES_MIN, REFRESH_MINUTES_MAX)
}

function graphHours(value) {
  return clampInt(value, DEFAULTS.graphHours, GRAPH_HOURS_MIN, GRAPH_HOURS_MAX)
}

// `omarchy bar set` stores strings unless --json is used; accept both.
function settingBool(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback
  if (typeof value === "boolean") return value
  var text = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text === "false" || text === "0" || text === "no" || text === "off") return false
  if (text === "true" || text === "1" || text === "yes" || text === "on") return true
  return fallback
}

// ---------------------------------------------------------------------------
// Units and temperature/wind/precipitation formatting
// ---------------------------------------------------------------------------

// "metric" (°C, m/s, mm) is the default — yr.no is metric-first and the
// system locale is a poor predictor (en_US is common far outside the US).
var UNITS = ["metric", "imperial", "kelvin"]

function unitSystem(value) {
  var unit = String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  return UNITS.indexOf(unit) === -1 ? "metric" : unit
}

function nextUnit(value) {
  return UNITS[(UNITS.indexOf(unitSystem(value)) + 1) % UNITS.length]
}

function convertTemp(tempC, unit) {
  var n = num(tempC)
  if (n === null) return null
  var u = unitSystem(unit)
  if (u === "imperial") return n * 9 / 5 + 32
  if (u === "kelvin") return n + 273.15
  return n
}

function tempSuffix(unit) {
  var u = unitSystem(unit)
  return u === "imperial" ? "°F" : (u === "kelvin" ? "K" : "°C")
}

// Kelvin has no degree sign — used by the bar pill, day cells and graph axis.
function degreeSign(unit) {
  return unitSystem(unit) === "kelvin" ? "" : "°"
}

function roundedTemp(value) {
  var n = num(value)
  return n === null ? "" : String(Math.round(n))
}

// "17°" / "63°" / "290K".
function bareTemp(tempC, unit) {
  var rounded = roundedTemp(convertTemp(tempC, unit))
  if (rounded === "") return ""
  return rounded + (unitSystem(unit) === "kelvin" ? "K" : "°")
}

// "17°C" / "63°F" / "290K".
function formatTemp(tempC, unit) {
  var rounded = roundedTemp(convertTemp(tempC, unit))
  return rounded === "" ? "" : rounded + tempSuffix(unit)
}

function formatWind(current, unit) {
  if (!current || current.windMs === null) return ""
  return unitSystem(unit) === "imperial" ? Math.round(current.windMph) + " mph" : Math.round(current.windMs) + " m/s"
}

function formatPrecip(precipMm, unit) {
  var n = num(precipMm)
  if (n === null) return ""
  if (unitSystem(unit) === "imperial") return (Math.round(n / 25.4 * 100) / 100) + " in"
  return (Math.round(n * 10) / 10) + " mm"
}

function bareTempForDay(day, kind, unit) {
  if (!day) return ""
  return bareTemp(kind === "max" ? day.maxC : day.minC, unit)
}

function formatClock(date) {
  var d = date instanceof Date ? date : new Date(date)
  if (isNaN(d.getTime())) return ""
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function dayName(dateString, formatter) {
  if (!dateString) return ""
  var d = new Date(dateString + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  if (formatter) return formatter(d)
  return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d.getDay()]
}

// ---------------------------------------------------------------------------
// Location: the shared weather.json file and IP auto-detection
// ---------------------------------------------------------------------------

// weather.json holds {"name": ..., "latitude": ..., "longitude": ...} (see
// omarchy-weather-location, which owns the format). Missing, blank, or
// unparseable means the location is auto-detected from the IP address.
// A name without coordinates is legal ("--set Bergen"): the service geocodes
// it once and stores the coordinates.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset
    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude)
    return {
      name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    }
  } catch (e) {
    return unset
  }
}

function hasCoordinates(location) {
  if (!location) return false
  var lat = parseFloat(String(location.latitude))
  var lon = parseFloat(String(location.longitude))
  return !isNaN(lat) && !isNaN(lon)
}

function emptyLocation() {
  return { name: "", latitude: null, longitude: null }
}

// IP geolocation providers tried in order when no coordinates are stored.
// Both are HTTPS, keyless, and answer with city + latitude + longitude.
var IP_LOCATION_URLS = [
  "https://ipwho.is/",
  "https://get.geojs.io/v1/ip/geo.json"
]

// ipwho.is and geojs both answer with city/latitude/longitude; ipwho.is adds
// a `success` flag that is false on rate limiting or private addresses.
function parseIpLocation(raw) {
  var unset = emptyLocation()
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset
    if (data.success === false) return unset
    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    if (isNaN(latitude) || isNaN(longitude)) return unset
    var name = data.city || data.region || data.country || ""
    return { name: String(name), latitude: latitude, longitude: longitude }
  } catch (e) {
    return unset
  }
}

// MET's terms ask for at most 4 decimals (~11 m); more defeats their cache.
function roundCoord(value) {
  var n = num(value)
  if (n === null) return null
  return Math.round(n * 10000) / 10000
}

// "59.9127,10.7461" — identity of a position for request tagging.
function locationKey(latitude, longitude) {
  var lat = roundCoord(latitude), lon = roundCoord(longitude)
  return lat === null || lon === null ? "" : lat + "," + lon
}

function curlCommand(url, maxTimeSec) {
  return ["curl", "-fsS", "--max-time", String(maxTimeSec || TIMEOUT_LOOKUP_S), "-H", "User-Agent: " + USER_AGENT, url]
}

// ---------------------------------------------------------------------------
// Place search: Open-Meteo (world, populated places) + Kartverket (Norway's
// official place-name register, finds farms/hotels/ski areas like
// "Sanderstølen") + Photon (OpenStreetMap, worldwide, typo-tolerant).
// ---------------------------------------------------------------------------

var KARTVERKET_API = "https://api.kartverket.no/stedsnavn/v1"
var PHOTON_API = "https://photon.komoot.io"
var GEOCODE_SOURCES = ["open-meteo", "kartverket", "photon"]
var SUGGESTION_LIMIT = 8

// Requests to fire for a query. Open-Meteo from two characters (its own
// minimum); the fuzzier sources from three so a single keystroke never fans
// out to three services.
function geocodeRequests(query) {
  var q = String(query || "").replace(/^\s+|\s+$/g, "")
  var out = []
  if (q.length < 2) return out
  out.push({ source: "open-meteo", command: curlCommand(
    "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(q) + "&count=5&language=en&format=json") })
  if (q.length >= 3) {
    out.push({ source: "kartverket", command: curlCommand(
      KARTVERKET_API + "/navn?sok=" + encodeURIComponent(q) + "&fuzzy=true&utkoordsys=4258&treffPerSide=10") })
    out.push({ source: "photon", command: curlCommand(
      PHOTON_API + "/api/?q=" + encodeURIComponent(q) + "&limit=5&lang=en") })
  }
  return out
}

function normalizeName(value) {
  var text = String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  return typeof text.normalize === "function" ? text.normalize("NFC") : text
}

function parseOpenMeteoResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []
    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function(part) { return !!part }).join(", ")
      out.push({ name: String(r.name), description: region, latitude: r.latitude, longitude: r.longitude, source: "open-meteo" })
    }
    return out
  } catch (e) {
    return []
  }
}

// Kartverket's fuzzy search is very loose (thousands of hits), so keep only
// names that start with what was typed, and skip street/address objects.
var KARTVERKET_SKIP_TYPES = /^(Adressenavn|Veg|Gate|Vegkryss|Bru|Tunnel|Adressetilleggsnavn|Matrikkeladressenavn)$/

function parseKartverketResults(raw, query) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var rows = data.navn
    if (!rows || !rows.length) return []
    var prefix = normalizeName(query)
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if (!r || !r["skrivemåte"] || !r.representasjonspunkt) continue
      var name = String(r["skrivemåte"])
      if (prefix && normalizeName(name).indexOf(prefix) !== 0) continue
      var type = String(r.navneobjekttype || "")
      if (KARTVERKET_SKIP_TYPES.test(type)) continue
      var lat = num(r.representasjonspunkt.nord)
      var lon = num(r.representasjonspunkt["øst"])
      if (lat === null || lon === null) continue
      var kommune = r.kommuner && r.kommuner[0] ? r.kommuner[0].kommunenavn : ""
      var fylke = r.fylker && r.fylker[0] ? r.fylker[0].fylkesnavn : ""
      var place = [kommune, fylke].filter(function(part) { return !!part }).join(", ")
      out.push({ name: name, description: [place, type].filter(function(part) { return !!part }).join("  ·  "), latitude: lat, longitude: lon, source: "kartverket" })
    }
    return out
  } catch (e) {
    return []
  }
}

// Street furniture is never a weather location.
var PHOTON_SKIP_KEYS = /^(highway|emergency|railway|barrier)$/

function photonDescription(props) {
  var parts = []
  if (props.city && props.city !== props.name) parts.push(props.city)
  if (props.county && props.county !== props.city) parts.push(props.county)
  else if (props.state && props.state !== props.city) parts.push(props.state)
  if (props.country) parts.push(props.country)
  var place = parts.join(", ")
  var kind = props.osm_value ? String(props.osm_value).replace(/_/g, " ") : ""
  return [place, kind].filter(function(part) { return !!part }).join("  ·  ")
}

function parsePhotonResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var features = data.features
    if (!features || !features.length) return []
    var out = []
    for (var i = 0; i < features.length; i++) {
      var f = features[i]
      var props = f && f.properties ? f.properties : null
      var coords = f && f.geometry ? f.geometry.coordinates : null
      if (!props || !props.name || !coords || coords.length < 2) continue
      if (PHOTON_SKIP_KEYS.test(String(props.osm_key || "")) || String(props.osm_value || "") === "parking") continue
      var lat = num(coords[1]), lon = num(coords[0])
      if (lat === null || lon === null) continue
      out.push({ name: String(props.name), description: photonDescription(props), latitude: lat, longitude: lon, source: "photon" })
    }
    return out
  } catch (e) {
    return []
  }
}

function parseGeocodeResponse(source, raw, query) {
  if (source === "kartverket") return parseKartverketResults(raw, query)
  if (source === "photon") return parsePhotonResults(raw)
  return parseOpenMeteoResults(raw)
}

// Same name within ~2 km counts as the same place.
function samePlace(a, b) {
  return normalizeName(a.name) === normalizeName(b.name)
    && Math.abs(a.latitude - b.latitude) < 0.02
    && Math.abs(a.longitude - b.longitude) < 0.04
}

// Open-Meteo's settlements first, then Kartverket's official names, then
// OpenStreetMap — deduplicated, at most `limit` rows.
function mergeSuggestions(bySource, limit) {
  var max = limit || SUGGESTION_LIMIT
  var out = []
  for (var s = 0; s < GEOCODE_SOURCES.length; s++) {
    var rows = (bySource && bySource[GEOCODE_SOURCES[s]]) || []
    for (var i = 0; i < rows.length && out.length < max; i++) {
      var row = rows[i]
      var duplicate = false
      for (var j = 0; j < out.length; j++) {
        if (samePlace(out[j], row)) { duplicate = true; break }
      }
      if (!duplicate) out.push(row)
    }
  }
  return out
}

// Index of a previously highlighted suggestion after the list changed
// (sources arrive at different times), so the keyboard cursor stays on the
// same place rather than the same row number.
function suggestionIndexFor(suggestions, selected, fallbackIndex) {
  var rows = suggestions || []
  if (selected) {
    for (var i = 0; i < rows.length; i++) {
      if (samePlace(rows[i], selected)) return i
    }
  }
  var index = parseInt(String(fallbackIndex), 10)
  if (isNaN(index)) index = 0
  return Math.max(0, Math.min(index, rows.length - 1))
}

// The selected suggestion, or null when nothing matched — a bare name must
// never be saved without coordinates (the forecast would silently come from
// the IP-detected location instead). An empty text means "back to auto".
function locationCommit(text, suggestions, selectedIndex) {
  var name = String(text || "").replace(/^\s+|\s+$/g, "")
  if (name === "") return emptyLocation()
  var choices = suggestions || []
  if (!choices.length) return null
  return choices[suggestionIndexFor(choices, null, selectedIndex)] || null
}

// ---- Reverse lookup (coordinates → a display name) for GPS fixes.

function reverseCommand(latitude, longitude) {
  return curlCommand(PHOTON_API + "/reverse?lat=" + roundCoord(latitude) + "&lon=" + roundCoord(longitude) + "&limit=1")
}

function parsePhotonReverse(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var f = data.features && data.features[0]
    var props = f && f.properties
    if (!props) return null
    var name = props.name || props.city || props.county || props.state || props.country || ""
    if (!name) return null
    return { name: String(name), description: photonDescription(props), countryCode: String(props.countrycode || "").toUpperCase() }
  } catch (e) {
    return null
  }
}

function kartverketPointCommand(latitude, longitude) {
  return curlCommand(KARTVERKET_API + "/punkt?nord=" + roundCoord(latitude) + "&ost=" + roundCoord(longitude) + "&koordsys=4258&radius=500&treffPerSide=5")
}

// Nearest named place (not a street) within the radius, or "".
function parseKartverketPoint(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var rows = data.navn
    if (!rows || !rows.length) return ""
    var best = null
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if (!r || KARTVERKET_SKIP_TYPES.test(String(r.navneobjekttype || ""))) continue
      var name = r.stedsnavn && r.stedsnavn[0] ? r.stedsnavn[0]["skrivemåte"] : ""
      if (!name) continue
      var dist = num(r.meterFraPunkt)
      if (best === null || (dist !== null && dist < best.dist)) best = { name: String(name), dist: dist === null ? Infinity : dist }
    }
    return best ? best.name : ""
  } catch (e) {
    return ""
  }
}

// ---------------------------------------------------------------------------
// GPS via GeoClue (the Linux location service)
// ---------------------------------------------------------------------------

// Three states: "missing" (geoclue not installed), "no-agent" (installed but
// nothing authorises clients: no agent process and no allow-list entry) and
// "ok". Only the filesystem and process table are consulted — a D-Bus call
// would start the daemon as a side effect.
var GEOCLUE_PROBE_COMMAND = ["sh", "-c",
  "test -x /usr/lib/geoclue-2.0/demos/where-am-i || { echo missing; exit 0; }; "
  + "if grep -rqs -e '^\\[geoclue-where-am-i\\]' /etc/geoclue/geoclue.conf /etc/geoclue/conf.d/ 2>/dev/null "
  + "|| pgrep -f /usr/lib/geoclue-2.0/demos/agent >/dev/null 2>&1; then echo ok; else echo no-agent; fi"]

// One fix, one process, one D-Bus connection (separate gdbus calls cannot
// share a GeoClue client). stderr is folded in so a denial can be recognised.
var WHERE_AM_I_TIMEOUT_S = 12
function whereAmICommand() {
  return ["sh", "-c", "timeout " + (WHERE_AM_I_TIMEOUT_S + 2) + " /usr/lib/geoclue-2.0/demos/where-am-i -t " + WHERE_AM_I_TIMEOUT_S + " -a 8 2>&1"]
}

// where-am-i prints a block per update; the last one wins. Coordinates carry
// a degree sign in geoclue ≥ 2.8.
function parseWhereAmI(output) {
  var text = String(output || "")
  var denied = /AccessDenied|disallowed|not authorized|Agent rejected/i.test(text)
  var lat = null, lon = null, acc = null, description = ""
  var lines = text.split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var m = /^(Latitude|Longitude|Accuracy|Description):\s*(.*)$/.exec(lines[i])
    if (!m) continue
    if (m[1] === "Latitude") lat = num(m[2])
    else if (m[1] === "Longitude") lon = num(m[2])
    else if (m[1] === "Accuracy") acc = num(m[2].replace(/[^0-9.\-]/g, ""))
    else description = m[2].replace(/^\s+|\s+$/g, "")
  }
  if (lat === null || lon === null) return { latitude: null, longitude: null, accuracy: null, description: "", denied: denied }
  return { latitude: lat, longitude: lon, accuracy: acc, description: description, denied: false }
}

// Wi-Fi positioning gives tens of metres; when the database has nothing for
// the area it degrades to an IP estimate (kilometres) — worth telling apart.
function fixQuality(accuracyMeters) {
  var acc = num(accuracyMeters)
  if (acc === null) return "unknown"
  if (acc < 200) return "precise"
  if (acc < 2000) return "approx"
  return "coarse"
}

function gpsFixMessage(fix) {
  if (!fix || fix.latitude === null) return ""
  var quality = fixQuality(fix.accuracy)
  if (quality === "coarse") return "Approximate position (±" + Math.round(fix.accuracy / 1000) + " km) — no Wi-Fi data for this area"
  if (quality === "unknown") return "Position found"
  return "Position found (±" + Math.round(fix.accuracy) + " m)"
}

// Short form for tooltips; the long form is shown in the search view.
function gpsStateSummary(state) {
  if (state === "ok") return "Use my position (GeoClue)"
  if (state === "no-agent") return "Location service installed but not authorised — see the search view"
  if (state === "missing") return "GPS not available — the system location service (geoclue) is not installed"
  return "Checking location service…"
}

function gpsStateHelp(state) {
  if (state === "no-agent") return "GeoClue is installed but no authorisation agent is running. Add  o.launch_on_start(\"/usr/lib/geoclue-2.0/demos/agent\")  to ~/.config/hypr/autostart.lua and reload Hyprland."
  if (state === "missing") return "GPS is not available: the system location service is not installed. Install the geoclue package (see the README for setup)."
  return ""
}

// ---------------------------------------------------------------------------
// MET Norway requests
// ---------------------------------------------------------------------------

var FORECAST_URL = "https://api.met.no/weatherapi/locationforecast/2.0/compact"
var TEXTFORECAST_URL = "https://api.met.no/weatherapi/textforecast/3.0/landoverview"
var METALERTS_URL = "https://api.met.no/weatherapi/metalerts/2.0/current.json"

function forecastUrl(latitude, longitude) {
  var key = locationKey(latitude, longitude)
  if (!key) return ""
  return FORECAST_URL + "?lat=" + roundCoord(latitude) + "&lon=" + roundCoord(longitude)
}

// Warnings can be requested in English; MET's land text forecast cannot.
function alertsLanguage(localeName) {
  return /^(nb|nn|no)([_-]|$)/i.test(String(localeName || "")) ? "no" : "en"
}

function alertsUrl(latitude, longitude, lang) {
  var key = locationKey(latitude, longitude)
  if (!key) return ""
  return METALERTS_URL + "?lat=" + roundCoord(latitude) + "&lon=" + roundCoord(longitude) + "&lang=" + (lang === "no" ? "no" : "en")
}

// Builds the curl argv for a MET request. Headers are dumped to stdout ahead
// of the body (-D -) so the caller can see the status code and the
// Last-Modified value to send back as If-Modified-Since next time.
function metCommand(url, lastModified, maxTimeSec) {
  var cmd = ["curl", "-sS", "--compressed", "--max-time", String(maxTimeSec || TIMEOUT_FORECAST_S), "-D", "-",
             "-H", "User-Agent: " + USER_AGENT]
  if (lastModified) cmd.push("-H", "If-Modified-Since: " + lastModified)
  cmd.push(url)
  return cmd
}

// Splits `curl -D -` output into {status, lastModified, body}. Handles
// several header blocks in a row (redirects, 100 Continue) by keeping the
// last one, and a 304 with no body at all. A transport error gives status 0.
function parseCurlResponse(raw) {
  var result = { status: 0, lastModified: "", body: "" }
  var rest = String(raw || "").replace(/^\s+/, "")
  while (/^HTTP\/[0-9.]+ [0-9]{3}/.test(rest)) {
    var end = rest.search(/\r?\n\r?\n/)
    var block = end === -1 ? rest : rest.slice(0, end)
    rest = end === -1 ? "" : rest.slice(end).replace(/^\r?\n\r?\n/, "")
    var lines = block.split(/\r?\n/)
    result.status = parseInt(lines[0].split(/\s+/)[1], 10) || 0
    result.lastModified = ""
    for (var i = 1; i < lines.length; i++) {
      var colon = lines[i].indexOf(":")
      if (colon === -1) continue
      if (lines[i].slice(0, colon).toLowerCase() === "last-modified") result.lastModified = lines[i].slice(colon + 1).replace(/^\s+|\s+$/g, "")
    }
  }
  result.body = rest.replace(/^\s+|\s+$/g, "")
  return result
}

function fetchErrorText(status) {
  if (status === 0) return "no response"
  if (status === 200) return "bad response"
  if (status === 403) return "HTTP 403 — request refused (User-Agent)"
  if (status === 429) return "HTTP 429 — rate limited"
  return "HTTP " + status
}

// ---------------------------------------------------------------------------
// Locationforecast: current conditions
// ---------------------------------------------------------------------------

function parseForecast(body) {
  try {
    var data = JSON.parse(String(body || ""))
    if (!data || !data.properties || !data.properties.timeseries || !data.properties.timeseries.length) return null
    return data
  } catch (e) {
    return null
  }
}

// The timeseries entry that describes "now": the last one whose time is at
// or before `nowMs`. Entries are hourly for ~2.5 days, then 6-hourly, so a
// forecast that is a few hours stale still resolves to something sensible.
function currentEntry(forecast, nowMs) {
  var series = forecast && forecast.properties ? forecast.properties.timeseries : null
  if (!series || !series.length) return null
  var now = (nowMs === undefined || nowMs === null) ? Date.now() : nowMs
  var best = null
  for (var i = 0; i < series.length; i++) {
    var t = Date.parse(series[i].time)
    if (isNaN(t)) continue
    if (t <= now) best = series[i]
    else break
  }
  return best || series[0]
}

// Symbol for an entry: the coming hour when available, else the coming six
// or twelve hours (the tail of the series only carries the longer windows).
function symbolCodeFor(entry) {
  if (!entry || !entry.data) return ""
  var keys = ["next_1_hours", "next_6_hours", "next_12_hours"]
  for (var i = 0; i < keys.length; i++) {
    var window = entry.data[keys[i]]
    if (window && window.summary && window.summary.symbol_code) return String(window.summary.symbol_code)
  }
  return ""
}

function currentCondition(entry) {
  if (!entry || !entry.data || !entry.data.instant || !entry.data.instant.details) return null
  var d = entry.data.instant.details
  var tempC = num(d.air_temperature)
  if (tempC === null) return null
  var windMs = num(d.wind_speed)
  var next1 = entry.data.next_1_hours && entry.data.next_1_hours.details ? entry.data.next_1_hours.details : null
  var code = symbolCodeFor(entry)
  return {
    time: entry.time,
    tempC: tempC,
    windMs: windMs,
    windMph: windMs === null ? null : windMs * 2.23694,
    humidity: num(d.relative_humidity),
    precipMm: next1 ? num(next1.precipitation_amount) : null,
    symbolCode: code,
    isNight: symbolVariant(code) === "night"
  }
}

// ---------------------------------------------------------------------------
// Symbols → Nerd Font glyphs and labels
// ---------------------------------------------------------------------------

// nf-weather-* glyphs from the Nerd Fonts weather set (JetBrainsMono Nerd
// Font is Omarchy's bar font). Chosen to match the stock omarchy.weather
// pill so the two look like siblings.
var GLYPHS = {
  clear:        { day: "\ue30d", night: "\ue32b" },   // day_sunny / night_clear
  fair:         { day: "\ue30c", night: "\ue37e" },   // day_sunny_overcast / night_alt_partly_cloudy
  partlycloudy: { day: "\ue302", night: "\ue32e" },   // day_cloudy / night_alt_cloudy
  cloudy:       "\ue33d",                              // cloud
  fog:          { day: "\ue313", night: "\ue346" },   // day_fog / night_fog
  rain:         "\ue318",                              // rain
  heavyrain:    "\ue316",                              // rain_wind
  rainshowers:  { day: "\ue308", night: "\ue333" },   // day_showers / night_alt_showers
  thunder:      "\ue31d",                              // thunderstorm
  sleet:        "\ue3ad",                              // sleet
  sleetshowers: { day: "\ue30a", night: "\ue327" },   // day_sleet / night_alt_sleet
  snow:         "\ue31a",                              // snow
  snowshowers:  { day: "\ue30a", night: "\ue327" }
}
var GLYPH_UNAVAILABLE = "\ue374"   // nf-weather-na, shown when no forecast could be fetched

function symbolBase(code) {
  return String(code || "").replace(/_(day|night|polartwilight)$/, "")
}

function symbolVariant(code) {
  var m = /_(day|night|polartwilight)$/.exec(String(code || ""))
  return m ? m[1] : ""
}

function glyphFamily(base) {
  if (base === "clearsky") return "clear"
  if (base === "fair") return "fair"
  if (base === "partlycloudy") return "partlycloudy"
  if (base === "cloudy") return "cloudy"
  if (base === "fog") return "fog"
  if (/thunder/.test(base)) return "thunder"
  if (/sleetshowers/.test(base)) return "sleetshowers"
  if (/snowshowers/.test(base)) return "snowshowers"
  if (/rainshowers/.test(base)) return "rainshowers"
  if (/sleet/.test(base)) return "sleet"
  if (/snow/.test(base)) return "snow"
  if (base === "heavyrain") return "heavyrain"
  if (/rain/.test(base)) return "rain"
  return "cloudy"
}

// Polar twilight renders as day: the sun is below the horizon but it is
// not dark, and the day glyphs read better on the bar.
function iconForSymbol(code) {
  var family = GLYPHS[glyphFamily(symbolBase(code))]
  if (typeof family === "string") return family
  return symbolVariant(code) === "night" ? family.night : family.day
}

// "lightrainshowersandthunder_day" → "Light rain showers and thunder".
// MET's canonical ids include the double-s typos `lightssleetshowersandthunder`
// and `lightssnowshowersandthunder`; they are normalised here but must be
// kept as-is everywhere the API is matched.
function symbolLabel(code) {
  var base = symbolBase(code).replace(/^lights(?=s)/, "light")
  var fixed = { clearsky: "Clear sky", fair: "Fair", partlycloudy: "Partly cloudy", cloudy: "Cloudy", fog: "Fog" }
  if (fixed[base]) return fixed[base]
  var m = /^(light|heavy)?(rain|sleet|snow)(showers)?(andthunder)?$/.exec(base)
  if (!m) return base ? base.replace(/_/g, " ") : ""
  var words = []
  if (m[1]) words.push(m[1])
  words.push(m[2])
  if (m[3]) words.push("showers")
  if (m[4]) words.push("and thunder")
  var label = words.join(" ")
  return label.charAt(0).toUpperCase() + label.slice(1)
}

// ---------------------------------------------------------------------------
// Daily and hourly views of the forecast
// ---------------------------------------------------------------------------

function localDateKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function isFutureForecastDate(dateString, todayString) {
  if (!dateString) return false
  return String(dateString).slice(0, 10) > String(todayString || "")
}

// Groups the timeseries by local calendar day and returns up to `maxDays`
// days after `todayString` with min/max temperature and a representative
// symbol — the six-hour window of the entry closest to local noon.
function dailyForecast(forecast, todayString, maxDays) {
  var series = forecast && forecast.properties ? forecast.properties.timeseries : null
  if (!series || !series.length) return []
  var limit = maxDays || 4
  var buckets = {}
  var order = []
  for (var i = 0; i < series.length; i++) {
    var entry = series[i]
    var t = new Date(entry.time)
    if (isNaN(t.getTime())) continue
    var key = localDateKey(t)
    if (!isFutureForecastDate(key, todayString)) continue
    if (!entry.data || !entry.data.instant || !entry.data.instant.details) continue
    var temp = num(entry.data.instant.details.air_temperature)
    if (temp === null) continue
    var bucket = buckets[key]
    if (!bucket) {
      bucket = { date: key, minC: temp, maxC: temp, symbolCode: "", symbolDistance: 99 }
      buckets[key] = bucket
      order.push(key)
    }
    if (temp < bucket.minC) bucket.minC = temp
    if (temp > bucket.maxC) bucket.maxC = temp
    var distance = Math.abs(t.getHours() - 12)
    var six = entry.data.next_6_hours && entry.data.next_6_hours.summary ? entry.data.next_6_hours.summary.symbol_code : ""
    var candidate = six || symbolCodeFor(entry)
    if (candidate && distance < bucket.symbolDistance) {
      bucket.symbolDistance = distance
      bucket.symbolCode = String(candidate)
    }
  }
  var out = []
  for (var j = 0; j < order.length && out.length < limit; j++) {
    var b = buckets[order[j]]
    out.push({ date: b.date, minC: b.minC, maxC: b.maxC, symbolCode: b.symbolCode,
               icon: iconForSymbol(symbolBase(b.symbolCode) + "_day"), label: symbolLabel(b.symbolCode) })
  }
  return out
}

// Hourly points starting at the current entry: temperature, precipitation
// for the coming hour, and the symbol for that hour. Stops where the
// series turns six-hourly (no next_1_hours window).
function hourlyForecast(forecast, nowMs, hours) {
  var series = forecast && forecast.properties ? forecast.properties.timeseries : null
  if (!series || !series.length) return []
  var limit = hours || DEFAULTS.graphHours
  var start = currentEntry(forecast, nowMs)
  var out = []
  var started = false
  for (var i = 0; i < series.length && out.length < limit; i++) {
    var entry = series[i]
    if (!started) {
      if (entry !== start) continue
      started = true
    }
    if (!entry.data || !entry.data.instant || !entry.data.instant.details) continue
    var next1 = entry.data.next_1_hours
    if (!next1) break
    var t = new Date(entry.time)
    if (isNaN(t.getTime())) continue
    var temp = num(entry.data.instant.details.air_temperature)
    if (temp === null) continue
    var code = next1.summary && next1.summary.symbol_code ? String(next1.summary.symbol_code) : ""
    out.push({
      time: entry.time,
      hour: t.getHours(),
      hourLabel: pad2(t.getHours()),
      tempC: temp,
      precipMm: next1.details ? (num(next1.details.precipitation_amount) || 0) : 0,
      symbolCode: code,
      icon: iconForSymbol(code),
      isNight: symbolVariant(code) === "night"
    })
  }
  return out
}

// Round tick values between min and max — at least two, at most ~five.
function ticksFor(min, max) {
  var steps = [100, 50, 20, 10, 5, 2, 1]
  var ticks = []
  for (var i = 0; i < steps.length; i++) {
    ticks = []
    for (var v = Math.ceil(min / steps[i]) * steps[i]; v <= max; v += steps[i]) ticks.push(v)
    if (ticks.length >= 2) break
  }
  return ticks
}

function niceStep(range, targetTicks) {
  var raw = range / Math.max(1, targetTicks)
  var steps = [1, 2, 5, 10, 20, 50, 100]
  for (var i = 0; i < steps.length; i++) if (steps[i] >= raw) return steps[i]
  return steps[steps.length - 1]
}

// Axis bounds for the graph in the display unit: a padded temperature range
// (never narrower than 4 degrees) with round tick values, and the
// precipitation ceiling (at least 1 mm so dry days draw no phantom bars).
function graphScale(points, unit) {
  if (!points || !points.length) return { tempMin: 0, tempMax: 1, ticks: [], precipMax: 1, hasPrecip: false }
  var lo = Infinity, hi = -Infinity, precipMax = 0
  for (var i = 0; i < points.length; i++) {
    var t = convertTemp(points[i].tempC, unit)
    if (t < lo) lo = t
    if (t > hi) hi = t
    if (points[i].precipMm > precipMax) precipMax = points[i].precipMm
  }
  var minRange = unitSystem(unit) === "imperial" ? 8 : 4
  var range = Math.max(minRange, hi - lo)
  var pad = range * 0.15
  var tempMin = Math.floor(lo - pad)
  var tempMax = Math.ceil(hi + pad)
  if (tempMax - tempMin < minRange) tempMax = tempMin + minRange
  var ticks = ticksFor(tempMin, tempMax)
  return { tempMin: tempMin, tempMax: tempMax, ticks: ticks, precipMax: Math.max(1, precipMax), hasPrecip: precipMax > 0 }
}

// Same points, same numbers → no repaint.
function samePoints(a, b) {
  if (a === b) return true
  if (!a || !b || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    if (a[i].time !== b[i].time || a[i].tempC !== b[i].tempC || a[i].precipMm !== b[i].precipMm || a[i].symbolCode !== b[i].symbolCode) return false
  }
  return true
}

// ---------------------------------------------------------------------------
// Sunrise / sunset (computed locally — no API call)
// ---------------------------------------------------------------------------

// Solar position equations as used by suncalc (Agafonkin, MIT). Accurate to
// a few minutes, which is plenty for a weather popup. `date` is any time on
// the local day in question. Returns nulls during polar day/night.
function sunTimes(latitude, longitude, date) {
  var lat = num(latitude), lon = num(longitude)
  var none = { sunrise: null, sunset: null, polar: "" }
  if (lat === null || lon === null) return none
  var d = date instanceof Date ? date : new Date(date)
  if (isNaN(d.getTime())) return none
  var rad = Math.PI / 180
  var dayMs = 86400000, J1970 = 2440588, J2000 = 2451545
  var noon = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 12, 0, 0)
  var days = noon.valueOf() / dayMs - 0.5 + J1970 - J2000
  var lw = -lon * rad
  var phi = lat * rad
  var n = Math.round(days - 0.0009 - lw / (2 * Math.PI))
  var ds = 0.0009 + lw / (2 * Math.PI) + n
  var M = rad * (357.5291 + 0.98560028 * ds)
  var C = rad * (1.9148 * Math.sin(M) + 0.02 * Math.sin(2 * M) + 0.0003 * Math.sin(3 * M))
  var L = M + C + rad * 102.9372 + Math.PI
  var dec = Math.asin(Math.sin(L) * Math.sin(rad * 23.4397))
  var Jtransit = J2000 + ds + 0.0053 * Math.sin(M) - 0.0069 * Math.sin(2 * L)
  var h0 = -0.833 * rad
  var cosH = (Math.sin(h0) - Math.sin(phi) * Math.sin(dec)) / (Math.cos(phi) * Math.cos(dec))
  if (cosH > 1) return { sunrise: null, sunset: null, polar: "night" }
  if (cosH < -1) return { sunrise: null, sunset: null, polar: "day" }
  var H = Math.acos(cosH)
  var Jset = J2000 + (0.0009 + (H + lw) / (2 * Math.PI) + n) + 0.0053 * Math.sin(M) - 0.0069 * Math.sin(2 * L)
  var Jrise = Jtransit - (Jset - Jtransit)
  function fromJulian(j) { return new Date((j + 0.5 - J1970) * dayMs) }
  return { sunrise: fromJulian(Jrise), sunset: fromJulian(Jset), polar: "" }
}

function formatSunTime(date, polar) {
  if (date instanceof Date && !isNaN(date.getTime())) return pad2(date.getHours()) + ":" + pad2(date.getMinutes())
  if (polar === "day") return "up all day"
  if (polar === "night") return "down all day"
  return ""
}

// ---------------------------------------------------------------------------
// Tekstvarsel — MET Textforecast 3.0 (Norwegian land regions)
// ---------------------------------------------------------------------------

// Cheap gate so the 28 KB feed is only fetched for positions that can be
// inside one of its regions (mainland Norway and Svalbard).
function inTextForecastRegion(latitude, longitude) {
  var lat = num(latitude), lon = num(longitude)
  if (lat === null || lon === null) return false
  return lat >= 57 && lat <= 81.5 && lon >= 3.5 && lon <= 32
}

function parseTextForecast(body) {
  try {
    var data = JSON.parse(String(body || ""))
    if (!data || !data.features || !data.features.length) return null
    var out = []
    for (var i = 0; i < data.features.length; i++) {
      var f = data.features[i]
      var props = f.properties || {}
      var interval = f.when && f.when.interval ? f.when.interval : []
      var ring = f.geometry && f.geometry.type === "Polygon" && f.geometry.coordinates ? f.geometry.coordinates[0] : null
      if (!ring || !props.text) continue
      out.push({ area: String(props.area || props.name || ""), text: String(props.text), title: String(props.title || ""),
                 start: Date.parse(interval[0]), end: Date.parse(interval[1]), ring: ring })
    }
    return out.length ? out : null
  } catch (e) {
    return null
  }
}

// Ray casting on the outer ring; GeoJSON rings are [lon, lat].
function pointInRing(lon, lat, ring) {
  var inside = false
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    var xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1]
    var crosses = ((yi > lat) !== (yj > lat)) && (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)
    if (crosses) inside = !inside
  }
  return inside
}

function ringArea(ring) {
  var sum = 0
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    sum += (ring[j][0] + ring[i][0]) * (ring[j][1] - ring[i][1])
  }
  return Math.abs(sum / 2)
}

// The region containing a point — the smallest one, since the mountain
// region "Fjellet i Sør-Norge" overlaps the lowland ones. "" outside Norway.
function textForecastArea(features, latitude, longitude) {
  if (!features || !features.length) return ""
  var lat = num(latitude), lon = num(longitude)
  if (lat === null || lon === null) return ""
  var area = "", bestArea = 0
  for (var i = 0; i < features.length; i++) {
    if (!features[i].area || !pointInRing(lon, lat, features[i].ring)) continue
    var size = ringArea(features[i].ring)
    if (!area || size < bestArea) { area = features[i].area; bestArea = size }
  }
  return area
}

// Today's and tomorrow's text for an area (`areaOverride` forces a region;
// an unknown override falls back to the point's own region).
function textForecastFor(features, latitude, longitude, nowMs, areaOverride) {
  if (!features || !features.length) return null
  var area = String(areaOverride || "").replace(/^\s+|\s+$/g, "")
  var known = false
  for (var k = 0; area && k < features.length; k++) if (features[k].area === area) { known = true; break }
  if (!known) area = textForecastArea(features, latitude, longitude)
  if (!area) return null
  var now = (nowMs === undefined || nowMs === null) ? Date.now() : nowMs
  var periods = []
  for (var p = 0; p < features.length; p++) {
    if (features[p].area === area && !isNaN(features[p].start)) periods.push(features[p])
  }
  periods.sort(function(a, b) { return a.start - b.start })
  var today = null, tomorrow = null
  for (var q = 0; q < periods.length; q++) {
    if (periods[q].end <= now) continue
    if (!today) today = periods[q]
    else if (!tomorrow) tomorrow = periods[q]
  }
  if (!today) return null
  return { area: area, today: today, tomorrow: tomorrow }
}

// ---------------------------------------------------------------------------
// Weather warnings — MET MetAlerts 2.0
// ---------------------------------------------------------------------------

var ALERT_RANK = { red: 3, orange: 2, yellow: 1, green: 0 }
// MET's awareness colours are semantic and intentionally bypass the theme.
var ALERT_COLORS = { red: "#d0473a", orange: "#e07b39", yellow: "#d4a72c", green: "#5c9e5c" }
var ALERT_LEVEL_LABELS = { red: "Red level", orange: "Orange level", yellow: "Yellow level", green: "Green level" }

function parseAlerts(body) {
  try {
    var data = JSON.parse(String(body || ""))
    if (!data || !data.features) return []
    var out = []
    for (var i = 0; i < data.features.length; i++) {
      var props = data.features[i].properties || {}
      var interval = data.features[i].when && data.features[i].when.interval ? data.features[i].when.interval : []
      var level = String(props.riskMatrixColor || "").toLowerCase()
      if (!ALERT_RANK.hasOwnProperty(level)) {
        var m = /;\s*(red|orange|yellow|green)\s*;/i.exec(String(props.awareness_level || ""))
        level = m ? m[1].toLowerCase() : "yellow"
      }
      out.push({
        id: String(props.id || (props.event || "") + ":" + (interval[0] || "")),
        event: String(props.event || ""),
        name: String(props.eventAwarenessName || props.event || "Warning"),
        level: level,
        levelLabel: ALERT_LEVEL_LABELS[level] || level,
        severity: String(props.severity || ""),
        area: String(props.area || ""),
        description: String(props.description || ""),
        instruction: String(props.instruction || ""),
        consequences: String(props.consequences || ""),
        start: Date.parse(interval[0]),
        end: Date.parse(interval[1])
      })
    }
    out.sort(function(a, b) { return ALERT_RANK[b.level] - ALERT_RANK[a.level] })
    return out
  } catch (e) {
    return []
  }
}

function alertColor(level) {
  return ALERT_COLORS[String(level || "").toLowerCase()] || ALERT_COLORS.yellow
}

// ---------------------------------------------------------------------------
// Exports (node tests). QML reads the functions directly.
// ---------------------------------------------------------------------------

if (typeof module !== "undefined") {
  module.exports = {
    // constants and settings
    VERSION: VERSION, USER_AGENT: USER_AGENT, ATTRIBUTION: ATTRIBUTION, DEFAULTS: DEFAULTS,
    REFRESH_MINUTES_MIN: REFRESH_MINUTES_MIN, REFRESH_MINUTES_MAX: REFRESH_MINUTES_MAX,
    GRAPH_HOURS_MIN: GRAPH_HOURS_MIN, GRAPH_HOURS_MAX: GRAPH_HOURS_MAX,
    FORCED_REFRESH_FLOOR_MS: FORCED_REFRESH_FLOOR_MS, RETRY_LIMIT: RETRY_LIMIT, RETRY_DELAY_MS: RETRY_DELAY_MS,
    TEXTFORECAST_INTERVAL_MS: TEXTFORECAST_INTERVAL_MS, IP_LOCATION_URLS: IP_LOCATION_URLS,
    GEOCLUE_PROBE_COMMAND: GEOCLUE_PROBE_COMMAND, TEXTFORECAST_URL: TEXTFORECAST_URL, GLYPH_UNAVAILABLE: GLYPH_UNAVAILABLE,
    refreshMinutes: refreshMinutes, graphHours: graphHours, settingBool: settingBool,
    // units and formatting
    UNITS: UNITS, unitSystem: unitSystem, nextUnit: nextUnit, convertTemp: convertTemp, tempSuffix: tempSuffix,
    degreeSign: degreeSign, roundedTemp: roundedTemp, bareTemp: bareTemp, formatTemp: formatTemp, formatWind: formatWind,
    formatPrecip: formatPrecip, bareTempForDay: bareTempForDay, formatClock: formatClock, dayName: dayName,
    // location
    parseLocationFile: parseLocationFile, hasCoordinates: hasCoordinates, emptyLocation: emptyLocation,
    parseIpLocation: parseIpLocation, roundCoord: roundCoord, locationKey: locationKey, curlCommand: curlCommand,
    // place search
    geocodeRequests: geocodeRequests, normalizeName: normalizeName, parseOpenMeteoResults: parseOpenMeteoResults,
    parseKartverketResults: parseKartverketResults, parsePhotonResults: parsePhotonResults,
    parseGeocodeResponse: parseGeocodeResponse, mergeSuggestions: mergeSuggestions, suggestionIndexFor: suggestionIndexFor,
    locationCommit: locationCommit, reverseCommand: reverseCommand, parsePhotonReverse: parsePhotonReverse,
    kartverketPointCommand: kartverketPointCommand, parseKartverketPoint: parseKartverketPoint,
    // GeoClue
    whereAmICommand: whereAmICommand, parseWhereAmI: parseWhereAmI, fixQuality: fixQuality, gpsFixMessage: gpsFixMessage,
    gpsStateSummary: gpsStateSummary, gpsStateHelp: gpsStateHelp,
    // MET requests and forecast
    forecastUrl: forecastUrl, alertsLanguage: alertsLanguage, alertsUrl: alertsUrl, metCommand: metCommand,
    parseCurlResponse: parseCurlResponse, fetchErrorText: fetchErrorText, parseForecast: parseForecast,
    currentEntry: currentEntry, symbolCodeFor: symbolCodeFor, currentCondition: currentCondition,
    // symbols
    symbolBase: symbolBase, symbolVariant: symbolVariant, glyphFamily: glyphFamily, iconForSymbol: iconForSymbol, symbolLabel: symbolLabel,
    // daily / hourly / graph
    localDateKey: localDateKey, isFutureForecastDate: isFutureForecastDate, dailyForecast: dailyForecast,
    hourlyForecast: hourlyForecast, niceStep: niceStep, ticksFor: ticksFor, graphScale: graphScale, samePoints: samePoints,
    // sun
    sunTimes: sunTimes, formatSunTime: formatSunTime,
    // tekstvarsel
    inTextForecastRegion: inTextForecastRegion, parseTextForecast: parseTextForecast, pointInRing: pointInRing,
    ringArea: ringArea, textForecastArea: textForecastArea, textForecastFor: textForecastFor,
    // warnings
    parseAlerts: parseAlerts, alertColor: alertColor
  }
}
