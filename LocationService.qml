import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Where the weather is for. One instance, shared by every bar widget.
//
// Sources, in priority order:
//   1. ~/.local/state/omarchy/settings/weather.json — written by Omarchy's
//      own `omarchy-weather-location` (shared with the stock weather widget)
//      and watched live. A name without coordinates is geocoded once and
//      the coordinates are stored back.
//   2. IP geolocation (city-level), looked up once per session or on demand.
//   3. GeoClue (GPS / Wi-Fi positioning) — only when the user asks.
Item {
  id: root

  property var configured: Model.emptyLocation()
  property var detected: Model.emptyLocation()
  property bool settled: false                 // weather.json has been read (or found absent)
  property bool nameUnresolved: false           // configured name could not be geocoded

  readonly property bool hasConfiguredCoordinates: Model.hasCoordinates(configured)
  readonly property var effective: hasConfiguredCoordinates ? configured : detected
  readonly property bool hasLocation: Model.hasCoordinates(effective)
  readonly property string key: hasLocation ? Model.locationKey(effective.latitude, effective.longitude) : ""
  readonly property string displayName: configured.name || detected.name || ""
  readonly property bool nameWithoutCoordinates: configured.name !== "" && !hasConfiguredCoordinates
  readonly property string source: hasConfiguredCoordinates ? "saved" : (Model.hasCoordinates(detected) ? "ip" : "")

  // "idle" → "saving" (CLI running) → "fetching" (waiting for the forecast) → "idle"
  property string saveState: "idle"
  property string saveError: ""
  signal saved()
  signal saveFailed(string reason)

  property string detectError: ""
  readonly property bool detecting: ipRequest.running

  // ---- GPS
  property string gpsState: "unknown"   // unknown | missing | no-agent | ok
  property bool gpsBusy: false
  property string gpsMessage: ""
  property var pendingFix: null
  property string pendingFixName: ""
  readonly property string gpsSummary: gpsBusy ? "Locating…" : Model.gpsStateSummary(gpsState)
  readonly property string gpsHelp: Model.gpsStateHelp(gpsState)

  // ------------------------------------------------------------------
  // weather.json
  // ------------------------------------------------------------------
  FileView {
    id: locationFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyFile(text())
    onLoadFailed: root.applyFile("")
  }

  function applyFile(text) {
    var next = Model.parseLocationFile(text)
    var changed = next.name !== configured.name || next.latitude !== configured.latitude || next.longitude !== configured.longitude
    if (changed) {
      configured = next
      nameUnresolved = false
    }
    settled = true
    if (Model.hasCoordinates(next)) return
    if (next.name !== "") resolveName(next.name)
    else if (!Model.hasCoordinates(detected)) detect(false)
  }

  function reload() { locationFile.reload() }

  // The first read can race shell startup; reload once more, and give up
  // waiting after a few seconds so a missing file never blocks the forecast.
  Timer { interval: 1500; running: true; onTriggered: locationFile.reload() }
  Timer { interval: 5000; running: !root.settled; onTriggered: { if (!root.settled) root.applyFile("") } }

  // ------------------------------------------------------------------
  // Name-only file → coordinates (asked of the same three geocoders).
  // ------------------------------------------------------------------
  property var resolveQueue: []
  property string resolvingName: ""

  function resolveName(name) {
    if (resolveRequest.running && resolvingName === name) return
    resolvingName = name
    resolveQueue = Model.geocodeRequests(name)
    resolveNext()
  }

  function resolveNext() {
    if (!resolveQueue.length) {
      nameUnresolved = true
      if (!Model.hasCoordinates(detected)) detect(false)
      return
    }
    var req = resolveQueue[0]
    resolveQueue = resolveQueue.slice(1)
    resolveRequest.start(req.command, req.source)
  }

  CurlRequest {
    id: resolveRequest
    onFinished: function(source, stdout) {
      var rows = Model.parseGeocodeResponse(source, stdout, root.resolvingName)
      if (rows.length) {
        var hit = rows[0]
        root.persist(root.resolvingName, hit.latitude, hit.longitude)
        return
      }
      root.resolveNext()
    }
  }

  // ------------------------------------------------------------------
  // IP geolocation
  // ------------------------------------------------------------------
  property int ipIndex: 0

  function detect(force) {
    if (ipRequest.running) return
    if (!force && Model.hasCoordinates(detected)) return
    detectError = ""
    ipIndex = 0
    detectNext()
  }

  function detectNext() {
    if (ipIndex >= Model.IP_LOCATION_URLS.length) {
      detectError = "Could not detect a location from the IP address"
      return
    }
    ipRequest.start(Model.curlCommand(Model.IP_LOCATION_URLS[ipIndex]), String(ipIndex))
  }

  CurlRequest {
    id: ipRequest
    onFinished: function(tag, stdout) {
      var location = Model.parseIpLocation(stdout)
      if (Model.hasCoordinates(location)) {
        root.detected = location
        root.detectedChanged()   // same coordinates as before still count as an answer
        return
      }
      root.ipIndex++
      root.detectNext()
    }
  }

  // ------------------------------------------------------------------
  // Persistence through Omarchy's CLI (shared with the stock widget)
  // ------------------------------------------------------------------
  function persist(name, latitude, longitude) {
    if (saveRequest.running) return
    saveError = ""
    var argv = name ? Model.persistCommand(name, latitude, longitude) : Model.clearLocationCommand()
    if (!argv) {
      saveError = "Cannot save this place: no usable name or coordinates"
      saveFailed(saveError)
      return
    }
    saveState = "saving"
    saveRequest.start(argv, name ? "set" : "clear")
  }

  function clear() {
    nameUnresolved = false
    persist("", null, null)
  }

  // Called by the weather service once a forecast for the new place arrived.
  function markSaved() {
    if (saveState === "idle") return
    saveWatchdog.stop()
    saveState = "idle"
    saved()
  }

  CurlRequest {
    id: saveRequest
    onFinished: function(tag, stdout, exitCode) {
      if (exitCode !== 0) {
        root.saveState = "idle"
        root.saveError = "omarchy-weather-location failed (exit " + exitCode + ")"
        root.saveFailed(root.saveError)
        return
      }
      root.saveState = "fetching"
      saveWatchdog.restart()
      locationFile.reload()
      if (tag === "clear") {
        root.configured = Model.emptyLocation()
        root.detect(true)
      }
    }
  }

  // A save whose forecast never arrives must not leave a spinner behind.
  Timer {
    id: saveWatchdog
    interval: 10000
    onTriggered: {
      if (root.saveState === "idle") return
      root.saveState = "idle"
      root.saveError = "Saved, but no forecast arrived yet"
      root.saveFailed(root.saveError)
    }
  }

  // ------------------------------------------------------------------
  // GeoClue — only ever queried when the user presses the button.
  // ------------------------------------------------------------------
  function probeGps() {
    probeRequest.start(Model.GEOCLUE_PROBE_COMMAND, "probe")
  }

  CurlRequest {
    id: probeRequest
    onFinished: function(tag, stdout) {
      var state = String(stdout || "").trim()
      root.gpsState = (state === "ok" || state === "no-agent" || state === "missing") ? state : "missing"
    }
  }

  function locateWithGps() {
    if (gpsState !== "ok" || gpsBusy) return
    gpsBusy = true
    gpsMessage = "Locating…"
    whereAmIRequest.start(Model.whereAmICommand(), "fix")
  }

  CurlRequest {
    id: whereAmIRequest
    onFinished: function(tag, stdout) {
      var fix = Model.parseWhereAmI(stdout)
      if (fix.latitude === null) {
        root.gpsBusy = false
        root.gpsMessage = fix.denied
          ? "Denied by GeoClue — is the authorisation agent running?"
          : "No position found — Wi-Fi positioning has no data for this area"
        return
      }
      root.pendingFix = fix
      root.pendingFixName = ""
      reverseRequest.start(Model.reverseCommand(fix.latitude, fix.longitude), "reverse")
    }
  }

  CurlRequest {
    id: reverseRequest
    onFinished: function(tag, stdout) {
      var rev = Model.parsePhotonReverse(stdout)
      if (rev) root.pendingFixName = rev.name
      if (rev && rev.countryCode === "NO" && root.pendingFix) {
        pointRequest.start(Model.kartverketPointCommand(root.pendingFix.latitude, root.pendingFix.longitude), "point")
      } else {
        root.finishGpsFix()
      }
    }
  }

  CurlRequest {
    id: pointRequest
    onFinished: function(tag, stdout) {
      var name = Model.parseKartverketPoint(stdout)
      if (name) root.pendingFixName = name
      root.finishGpsFix()
    }
  }

  function finishGpsFix() {
    var fix = pendingFix
    pendingFix = null
    gpsBusy = false
    if (!fix) return
    var name = pendingFixName || (Model.roundCoord(fix.latitude) + ", " + Model.roundCoord(fix.longitude))
    if (Model.fixQuality(fix.accuracy) === "coarse") name += " (approx.)"
    gpsMessage = Model.gpsFixMessage(fix)
    persist(name, fix.latitude, fix.longitude)
  }
}
