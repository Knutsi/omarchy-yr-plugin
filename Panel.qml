import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Detail popup + data layer for io.github.knutsi.yr.
//
// Layout, top to bottom: current weather · weather warnings · hour-by-hour
// graph · next four days · tekstvarsel (Norway) · settings · attribution.
// Changing the location swaps the whole content for a search view, which
// also hosts the GPS (GeoClue) button.
//
// Data: MET Norway Locationforecast 2.0 (yr.no's API). One fetch per
// refresh interval (never more often than every 10 minutes, per MET's terms),
// revalidated with If-Modified-Since so unchanged forecasts cost a 304.
//
// Location: the same contract as the stock omarchy.weather plugin —
// ~/.local/state/omarchy/settings/weather.json written by
// `omarchy-weather-location`. Stored coordinates win; otherwise the position
// is detected once from the IP address (city-level).
Panel {
  id: root
  moduleName: "io.github.knutsi.yr"
  ipcTarget: "io.github.knutsi.yr"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by is that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    locationFile.reload()
    root.refresh(false)
    probeGps()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    locationFile.reload()
    root.refresh(false)
    probeGps()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Forecast state. Kept on failure so stale data stays visible.
  property var forecast: null
  property string lastModified: ""
  property string fetchedAt: ""
  property string fetchError: ""
  property int forecastRetries: 0

  // ---- Location state.
  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  property var detectedLocation: ({ name: "", latitude: null, longitude: null, countryCode: "" })
  property bool locationFileSettled: false
  property int ipProviderIndex: 0

  readonly property string configuredLocation: configuredLocationState.name
  readonly property bool hasConfiguredCoordinates: Model.hasCoordinates(configuredLocationState)
  readonly property var effectiveLocation: hasConfiguredCoordinates ? configuredLocationState : detectedLocation
  readonly property bool hasLocation: Model.hasCoordinates(effectiveLocation)
  readonly property string locationKey: hasLocation
    ? Model.roundCoord(effectiveLocation.latitude) + "," + Model.roundCoord(effectiveLocation.longitude)
    : ""

  // A new position invalidates the cached validator and fetches right away.
  onLocationKeyChanged: {
    lastModified = ""
    forecastRetries = 0
    forecastProc.running = false
    if (locationKey !== "") {
      Qt.callLater(fetchForecast)
      Qt.callLater(fetchAlerts)
    }
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.configuredLocationState = Model.parseLocationFile(text())
      root.locationFileSettled = true
    }
    onLoadFailed: {
      root.configuredLocationState = Model.parseLocationFile("")
      root.locationFileSettled = true
    }
  }

  // The first read can race shell startup; one delayed reload self-corrects.
  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  // The first refresh waits for the location file so a stored position
  // never triggers a needless IP lookup.
  onLocationFileSettledChanged: if (locationFileSettled) Qt.callLater(function() { root.refresh(false) })
  Component.onCompleted: probeGps()

  // ---- Click-to-edit state for the location.
  property bool editingLocation: false
  property bool savingLocation: false
  property bool savingLocationQueryStarted: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeQuery: ""
  property var geocodeResults: ({})
  property string commitHint: ""
  readonly property bool geocodeRunning: openMeteoProc.running || kartverketProc.running || photonProc.running

  // ---- GPS via GeoClue. Only ever queried when the user presses the button.
  property string gpsState: "unknown"   // unknown | missing | no-agent | ok
  property bool gpsBusy: false
  property string gpsMessage: ""
  property var pendingFix: null
  property string pendingFixName: ""
  readonly property string gpsTooltip: gpsBusy ? "Locating…" : Model.gpsStateText(gpsState)

  // Cheap (filesystem + process table only), asynchronous, and re-run every
  // time the popup opens — so installing GeoClue while the shell is running
  // enables the satellite button on the next open without a restart.
  function probeGps() {
    if (!gpsProbeProc.running) gpsProbeProc.running = true
  }

  function locateWithGps() {
    if (gpsState !== "ok" || gpsBusy) return
    gpsBusy = true
    gpsMessage = "Locating…"
    whereAmIProc.running = true
  }

  function finishGpsFix() {
    var fix = pendingFix
    if (!fix) { gpsBusy = false; return }
    var quality = Model.fixQuality(fix.accuracy)
    var name = pendingFixName || (Model.roundCoord(fix.latitude) + ", " + Model.roundCoord(fix.longitude))
    if (quality === "coarse") name += " (approx.)"
    gpsMessage = quality === "coarse"
      ? "Approximate position (±" + Math.round(fix.accuracy / 1000) + " km) — no Wi-Fi data for this area"
      : "Position found (±" + Math.round(fix.accuracy) + " m)"
    gpsBusy = false
    pendingFix = null
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = { name: name, latitude: fix.latitude, longitude: fix.longitude }
    persistLocation(name, fix.latitude, fix.longitude)
  }

  Process {
    id: gpsProbeProc
    command: Model.GEOCLUE_PROBE_COMMAND
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = String(text || "").trim()
        root.gpsState = (state === "ok" || state === "no-agent" || state === "missing") ? state : "missing"
      }
    }
  }

  Process {
    id: whereAmIProc
    command: Model.whereAmICommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var fix = Model.parseWhereAmI(text)
        if (fix.latitude === null) {
          root.gpsBusy = false
          root.gpsMessage = fix.denied
            ? "Denied by GeoClue — is the authorisation agent running?"
            : "No position found — Wi-Fi positioning has no data for this area"
          return
        }
        root.pendingFix = fix
        root.pendingFixName = ""
        reverseProc.command = Model.reverseCommand(fix.latitude, fix.longitude)
        reverseProc.running = true
      }
    }
  }

  Process {
    id: reverseProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rev = Model.parsePhotonReverse(text)
        if (rev) root.pendingFixName = rev.name
        if (rev && rev.countryCode === "NO" && root.pendingFix) {
          kartverketPointProc.command = Model.kartverketPointCommand(root.pendingFix.latitude, root.pendingFix.longitude)
          kartverketPointProc.running = true
        } else {
          root.finishGpsFix()
        }
      }
    }
  }

  Process {
    id: kartverketPointProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var name = Model.parseKartverketPoint(text)
        if (name) root.pendingFixName = name
        root.finishGpsFix()
      }
    }
  }

  // ---- Units: the `unit` setting (metric | imperial | kelvin), metric by default.
  readonly property string unit: Model.unitSystem(setting("unit", "metric"))
  readonly property var unitOptions: [
    { value: "metric", label: "°C", tooltip: "Celsius, m/s, mm" },
    { value: "imperial", label: "°F", tooltip: "Fahrenheit, mph, inches" },
    { value: "kelvin", label: "K", tooltip: "Kelvin, m/s, mm" }
  ]

  // Persists the choice on this widget's shell.json entry; the shell pushes
  // the new settings back into the widget, which re-renders everything.
  function setUnit(name) {
    unitSaveProc.command = ["omarchy", "bar", "set", "io.github.knutsi.yr", "unit", Model.unitSystem(name)]
    unitSaveProc.running = true
  }

  function toggleUnit() {
    setUnit(Model.nextUnit(unit))
  }

  Process {
    id: unitSaveProc
  }

  // ---- Tekstvarsel (MET Textforecast 3.0, Norway) — on unless turned off.
  readonly property bool textForecastEnabled: String(setting("textForecast", true)) !== "false"
  property var textFeatures: null
  property string textLastModified: ""
  readonly property var textReport: Model.textForecastFor(textFeatures, effectiveLocation.latitude, effectiveLocation.longitude, tick.getTime(), setting("textForecastArea", ""))

  function setTextForecast(enabled) {
    textSaveProc.command = ["omarchy", "bar", "set", "io.github.knutsi.yr", "textForecast", enabled ? "true" : "false", "--json"]
    textSaveProc.running = true
  }

  function fetchTextForecast() {
    if (textForecastProc.running) return
    textForecastProc.command = Model.textForecastCommand(textLastModified)
    textForecastProc.running = true
  }

  Process {
    id: textSaveProc
  }

  Process {
    id: textForecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var response = Model.parseCurlResponse(text)
        if (response.status !== 200) return
        var parsed = Model.parseTextForecast(response.body)
        if (!parsed) return
        root.textFeatures = parsed
        root.textLastModified = response.lastModified
      }
    }
  }

  // Text forecasts are issued a few times a day; three hours is plenty.
  Timer {
    interval: 3 * 3600 * 1000 + root.refreshJitterMs
    running: root.textForecastEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.fetchTextForecast()
  }

  // ---- Farevarsel (MET MetAlerts 2.0) — fetched with every forecast refresh.
  property var alerts: []
  property string alertsLastModified: ""
  property string alertsLocationKey: ""

  function fetchAlerts() {
    if (!hasLocation || alertsProc.running) return
    if (alertsLocationKey !== locationKey) { alertsLastModified = ""; alertsLocationKey = locationKey }
    alertsProc.command = Model.alertsCommand(effectiveLocation.latitude, effectiveLocation.longitude, alertsLastModified)
    alertsProc.running = true
  }

  Process {
    id: alertsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var response = Model.parseCurlResponse(text)
        if (response.status === 304) return
        if (response.status !== 200) return
        root.alerts = Model.parseAlerts(response.body)
        root.alertsLastModified = response.lastModified
      }
    }
  }

  // ---- Derived report. `tick` advances once a minute so the "current"
  //      timeseries entry moves on without a network round-trip.
  property var tick: new Date()
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.tick = new Date()
  }

  readonly property var currentEntry: Model.currentEntry(forecast, tick.getTime())
  readonly property var current: Model.currentCondition(currentEntry)
  readonly property string label: current ? Model.iconForSymbol(current.symbolCode) : ""
  readonly property int refreshMinutes: Math.max(10, parseInt(setting("refreshMinutes", 15), 10) || 15)
  readonly property int refreshJitterMs: Math.floor(Math.random() * 60000)
  readonly property int graphHours: Math.max(6, Math.min(48, parseInt(setting("graphHours", 24), 10) || 24))

  readonly property string reportLocation:  configuredLocation || detectedLocation.name || ""
  readonly property string reportTempNum:   current ? Model.roundedTemp(Model.convertTemp(current.tempC, unit)) : ""
  readonly property string tempUnit:        Model.tempSuffix(unit)
  readonly property string reportTemp:      current ? Model.formatTemp(current.tempC, unit) : ""
  readonly property string barTemp:         current ? Model.bareTemp(current.tempC, unit) : ""
  readonly property string reportCondition: current ? Model.symbolLabel(current.symbolCode) : ""
  readonly property string reportWind:      Model.formatWind(current, unit)
  readonly property string reportHumidity:  current && current.humidity !== null ? Math.round(current.humidity) + "%" : ""
  readonly property var sun:                Model.sunTimes(effectiveLocation.latitude, effectiveLocation.longitude, tick)
  readonly property string reportSunrise:   hasLocation ? Model.formatSunTime(sun.sunrise, sun.polar) : ""
  readonly property string reportSunset:    hasLocation ? Model.formatSunTime(sun.sunset, sun.polar) : ""
  readonly property var hourlyPoints:       Model.hourlyForecast(forecast, tick.getTime(), graphHours)
  readonly property var forecastDays:       Model.dailyForecast(forecast, Qt.formatDate(tick, "yyyy-MM-dd"), 4)
  readonly property string updatedClock:    fetchedAt ? Model.formatClock(fetchedAt) : ""
  readonly property string tooltipText:     current
    ? [reportCondition, reportTemp, reportLocation].filter(function(p) { return p !== "" }).join("  ·  ")
    : (fetchError ? "Yr weather: " + fetchError : "Yr weather")

  // ---- Refresh. `force` also re-detects the IP location (middle click).
  function refresh(force) {
    forecastRetries = 0
    if (!hasConfiguredCoordinates && (force || !Model.hasCoordinates(detectedLocation))) detectLocation()
    if (force) lastModified = ""
    fetchForecast()
    fetchAlerts()
  }

  function detectLocation() {
    if (ipLocationProc.running) return
    ipProviderIndex = 0
    startIpLookup()
  }

  function startIpLookup() {
    if (ipProviderIndex >= Model.IP_LOCATION_URLS.length) return
    ipLocationProc.command = ["curl", "-fsS", "--max-time", "5", Model.IP_LOCATION_URLS[ipProviderIndex]]
    ipLocationProc.running = true
  }

  function fetchForecast() {
    if (!hasLocation || forecastProc.running) return
    forecastProc.command = Model.forecastCommand(effectiveLocation.latitude, effectiveLocation.longitude, lastModified)
    forecastProc.running = true
  }

  function handleForecastResponse(raw) {
    var response = Model.parseCurlResponse(raw)

    if (response.status === 304) {
      forecastRetries = 0
      fetchError = ""
      finishSavingLocation()
      return
    }

    if (response.status === 200) {
      var parsed = Model.parseForecast(response.body)
      if (parsed) {
        forecast = parsed
        lastModified = response.lastModified
        fetchedAt = new Date().toISOString()
        forecastRetries = 0
        fetchError = ""
        finishSavingLocation()
        return
      }
    }

    fetchError = response.status ? "HTTP " + response.status : "no response"
    // 403 is a User-Agent/terms problem and 429 means we are being throttled:
    // retrying quickly would make either worse. Wait for the next interval.
    if (response.status === 403 || response.status === 429) return
    scheduleForecastRetry()
  }

  function scheduleForecastRetry() {
    if (forecastRetries >= 3) return
    forecastRetries++
    forecastRetryTimer.restart()
  }

  Timer {
    id: forecastRetryTimer
    interval: 2500
    onTriggered: root.fetchForecast()
  }

  Process {
    id: forecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleForecastResponse(text)
    }
  }

  Process {
    id: ipLocationProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var location = Model.parseIpLocation(text)
        if (Model.hasCoordinates(location)) {
          root.detectedLocation = location
          // Same coordinates as before → locationKey unchanged → no refetch
          // from the binding, so ask explicitly.
          root.fetchForecast()
          return
        }
        root.ipProviderIndex++
        Qt.callLater(root.startIpLookup)
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000 + root.refreshJitterMs
    running: true
    repeat: true
    onTriggered: root.refresh(false)
  }

  // ---- Location editing. The location row turns into a search field;
  //      picking a geocoded suggestion persists name + coordinates via
  //      omarchy-weather-location. An empty commit returns to auto-detect.
  function startEditingLocation() {
    editingLocation = true
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    geocodeResults = ({})
    geocodeQuery = ""
    commitHint = ""
    gpsMessage = ""
    suggestionIndex = 0
    probeGps()
    Qt.callLater(function() {
      locationField.text = root.configuredLocation
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var location = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (location === null) {
      commitHint = geocodeRunning ? "Still searching…" : "Pick a match from the list"
      return
    }
    if (location.name === "") {
      clearLocation()
      return
    }
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = { name: location.name, latitude: location.latitude, longitude: location.longitude }
    persistLocation(location.name, location.latitude, location.longitude)
  }

  function clearLocation() {
    persistLocation("", null, null)
    detectedLocation = { name: "", latitude: null, longitude: null, countryCode: "" }
    cancelEditingLocation()
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = { name: suggestion.name, latitude: suggestion.latitude, longitude: suggestion.longitude }
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function finishSavingLocation() {
    if (savingLocation && savingLocationQueryStarted) cancelEditingLocation()
  }

  function persistLocation(name, latitude, longitude) {
    if (name && latitude !== null && longitude !== null)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name, latitude + "," + longitude]
    else if (name)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name]
    else
      locationSaveProc.command = ["omarchy-weather-location", "--clear"]
    locationSaveProc.running = true
  }

  function requestGeocode() {
    var query = locationField.text.trim()
    commitHint = ""
    if (query.length < 2) {
      locationSuggestions = []
      geocodeResults = ({})
      geocodeQuery = ""
      return
    }
    geocodePendingQuery = query
    startGeocode()
  }

  // Each source runs in its own process; a source that is still busy with an
  // older query is re-run as soon as it finishes (see handleGeocode).
  function startGeocode() {
    var requests = Model.geocodeRequests(geocodePendingQuery)
    for (var i = 0; i < requests.length; i++) {
      var proc = geocodeProcFor(requests[i].source)
      if (proc.running || proc.query === geocodePendingQuery) continue
      proc.query = geocodePendingQuery
      proc.command = requests[i].command
      proc.running = true
    }
  }

  function geocodeProcFor(source) {
    if (source === "kartverket") return kartverketProc
    if (source === "photon") return photonProc
    return openMeteoProc
  }

  function handleGeocode(source, query, raw) {
    if (!editingLocation) return
    if (query !== geocodePendingQuery) {
      geocodeProcFor(source).query = ""
      Qt.callLater(startGeocode)
      return
    }
    if (query !== geocodeQuery) {
      geocodeResults = ({})
      geocodeQuery = query
      suggestionIndex = 0
    }
    var next = ({})
    for (var k in geocodeResults) next[k] = geocodeResults[k]
    next[source] = Model.parseGeocodeResponse(source, raw, query)
    geocodeResults = next
    locationSuggestions = Model.mergeSuggestions(geocodeResults, 8)
    if (suggestionIndex > locationSuggestions.length - 1) suggestionIndex = Math.max(0, locationSuggestions.length - 1)
  }

  Process {
    id: openMeteoProc
    property string query: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleGeocode("open-meteo", openMeteoProc.query, text)
    }
  }

  Process {
    id: kartverketProc
    property string query: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleGeocode("kartverket", kartverketProc.query, text)
    }
  }

  Process {
    id: photonProc
    property string query: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleGeocode("photon", photonProc.query, text)
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.savingLocation) return
      locationFile.reload()
      if (!root.savingLocationQueryStarted) {
        root.savingLocationQueryStarted = true
        root.forecastRetries = 0
        forecastProc.running = false
        root.lastModified = ""
        Qt.callLater(function() { root.refresh(false) })
      }
    }
  }

  function dayName(dateString) {
    return Model.dayName(dateString, function(date) { return Qt.formatDate(date, "ddd") })
  }

  function bareTempForDay(day, kind) {
    return Model.bareTempForDay(day, kind, unit)
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh(true) }
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
    function unit(name: string): void { root.setUnit(name) }
    function toggleUnit(): void { root.toggleUnit() }
    function locate(): void { root.probeGps(); Qt.callLater(function() { root.locateWithGps() }) }
    function textForecast(enabled: string): void { root.setTextForecast(String(enabled) !== "false") }
  }

  readonly property color mutedText: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
  readonly property color fadedText: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.7)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(weatherColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: weatherScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: weatherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: weatherColumn
          width: weatherScroll.width

          // ---------------------------------------------------------------
          // Main view
          // ---------------------------------------------------------------
          Column {
          id: mainView
          visible: !root.editingLocation
          width: parent.width
          spacing: Style.space(12)

          // ================================================================
          // 1. Current weather
          // ================================================================
          Item {
            width: parent.width
            height: Math.max(heroLeft.height, heroRight.height)

            Column {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

            Row {
              spacing: Style.space(16)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 5
                text: root.label || "—"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: 64
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  id: tempBig
                  text: root.reportTempNum || "—"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.unit === "kelvin" ? 44 : 56
                  font.bold: true
                }

                // Click the unit to cycle °C → °F → K (persisted).
                Text {
                  text: root.current ? root.tempUnit : ""
                  color: unitHover.hovered ? Color.accent : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.display
                  anchors.top: tempBig.top
                  anchors.topMargin: Style.space(10)

                  TapHandler {
                    onTapped: root.toggleUnit()
                  }
                  HoverHandler {
                    id: unitHover
                    cursorShape: Qt.PointingHandCursor
                  }
                }
              }
            }

              Text {
                visible: root.reportCondition !== ""
                text: root.reportCondition
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
              }
            }

            Column {
              id: heroRight
              width: Math.max(weatherStats.implicitWidth, Style.space(230))
              anchors.right: parent.right
              anchors.rightMargin: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              // Location name + search button. Clicking either opens the search view.
              Row {
                spacing: Style.space(6)

                Text {
                  text: "󰍎"  // nf-md-map_marker
                  color: root.mutedText
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: (root.reportLocation || "Set location").toUpperCase()
                  color: locationHover.hovered ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.letterSpacing: 1
                  anchors.verticalCenter: parent.verticalCenter

                  TapHandler {
                    onTapped: root.startEditingLocation()
                  }
                  HoverHandler {
                    id: locationHover
                    cursorShape: Qt.PointingHandCursor
                  }
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰍉"  // nf-md-magnify
                  tooltipText: "Change location"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.startEditingLocation()
                }
                // GPS: enabled only when GeoClue is installed and authorised;
                // otherwise dimmed, with the tooltip saying what is missing.
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.gpsBusy ? "󰦖" : "󰑱"  // nf-md-satellite_variant
                  tooltipText: root.gpsTooltip
                  foreground: root.gpsState === "ok" ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  opacity: root.gpsState === "ok" ? 1 : 0.45
                  onClicked: root.locateWithGps()
                }
              }

              Row {
                id: weatherStats
                visible: !!root.current
                spacing: Style.space(20)

                Repeater {
                  model: [
                    { label: "WIND", value: root.reportWind },
                    { label: "HUMID", value: root.reportHumidity },
                    { label: "SUNRISE", value: root.reportSunrise },
                    { label: "SUNSET", value: root.reportSunset }
                  ]

                  Column {
                    required property var modelData
                    spacing: Style.space(5)
                    Text {
                      text: modelData.label
                      color: root.mutedText
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.letterSpacing: 1
                    }
                    Text {
                      text: modelData.value || "—"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.title
                    }
                  }
                }
              }
            }
          }

          // ================================================================
          // 1b. Weather warnings (farevarsel)
          // ================================================================
          Item {
            visible: root.alerts.length > 0
            width: parent.width
            height: alertBanner.implicitHeight

            AlertBanner {
              id: alertBanner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(16)
              alerts: root.alerts
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }
          }

          Text {
            visible: !root.current
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.fetchError ? "Forecast unavailable (" + root.fetchError + ")" : (root.hasLocation ? "Fetching forecast…" : "Detecting location…")
            color: root.mutedText
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ================================================================
          // 2. Hour-by-hour graph
          // ================================================================
          Rectangle {
            visible: root.hourlyPoints.length > 1
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.12
          }

          Column {
            visible: root.hourlyPoints.length > 1
            width: parent.width
            spacing: Style.space(4)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              text: "NEXT " + root.hourlyPoints.length + " HOURS"
              color: root.mutedText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            HourlyGraph {
              width: parent.width
              points: root.hourlyPoints
              unit: root.unit
              foreground: root.bar.foreground
              tempColor: Color.urgent
              precipColor: Color.accent
              fontFamily: root.bar.fontFamily
            }
          }

          // ================================================================
          // 3. Next four days
          // ================================================================
          Rectangle {
            visible: root.forecastDays.length > 0
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.12
          }

          Column {
            visible: root.forecastDays.length > 0
            width: parent.width
            spacing: Style.space(8)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              text: "NEXT " + root.forecastDays.length + " DAYS"
              color: root.mutedText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Item {
              width: parent.width
              height: forecastRow.height

              Row {
                id: forecastRow
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(22)

                Repeater {
                  model: root.forecastDays

                  Row {
                    required property var modelData
                    required property int index
                    spacing: Style.space(8)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.icon
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.display
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      Text {
                        text: root.dayName(modelData.date).toUpperCase()
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1
                      }

                      Row {
                        spacing: Style.space(5)

                        Text {
                          text: root.bareTempForDay(modelData, "max")
                          color: root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.body
                        }
                        Text {
                          text: root.bareTempForDay(modelData, "min")
                          color: root.mutedText
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.body
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ================================================================
          // 3b. Tekstvarsel
          // ================================================================
          Rectangle {
            visible: root.textForecastEnabled && !!root.textReport
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.12
          }

          TextForecastSection {
            visible: root.textForecastEnabled && !!root.textReport
            width: parent.width
            report: root.textReport
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          // ================================================================
          // 4. Settings (left) · attribution and update stamp (right)
          // ================================================================
          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.12
          }

          Item {
            width: parent.width
            height: settingsRow.implicitHeight

            Row {
              id: settingsRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              spacing: Style.space(10)

              ButtonGroup {
                anchors.verticalCenter: parent.verticalCenter
                options: root.unitOptions
                value: root.unit
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                focusable: false
                onChanged: function(value) { root.setUnit(value) }
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰍉"
                text: "Location"
                tooltipText: "Search for a city (Enter)"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.startEditingLocation()
              }

              // Only offered where a text forecast exists (Norwegian regions).
              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: !!root.textReport
                iconText: "󰈙"  // nf-md-file_document
                tooltipText: root.textForecastEnabled ? "Tekstvarsel on — click to hide" : "Tekstvarsel off — click to show"
                foreground: root.textForecastEnabled ? Color.accent : Qt.darker(root.bar.foreground, 1.5)
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.body
                onClicked: root.setTextForecast(!root.textForecastEnabled)
              }
            }

            // Attribution (required by MET Norway's licence) + clickable stamp.
            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                text: Model.ATTRIBUTION
                color: root.fadedText
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: root.updatedClock !== "" || root.fetchError !== ""
                text: "·  " + (root.updatedClock !== "" ? "updated " + root.updatedClock : "not updated")
                  + (forecastProc.running ? "  󰦖" : "")
                color: updatedHover.hovered ? root.bar.foreground : root.fadedText
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption

                TapHandler {
                  onTapped: root.refresh(true)
                }
                HoverHandler {
                  id: updatedHover
                  cursorShape: Qt.PointingHandCursor
                }
              }
            }
          }
          }

          // ---------------------------------------------------------------
          // Search view — replaces everything while a location is picked.
          // ---------------------------------------------------------------
          Column {
            id: searchView
            visible: root.editingLocation
            width: parent.width
            spacing: Style.space(12)

            Item {
              width: parent.width
              height: Style.space(28)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                text: "CHANGE LOCATION"
                color: root.mutedText
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.gpsBusy ? "󰦖" : "󰑱"
                  text: "My position"
                  tooltipText: root.gpsTooltip
                  enabled: root.gpsState === "ok" && !root.gpsBusy
                  opacity: root.gpsState === "ok" ? 1 : 0.45
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  onClicked: root.locateWithGps()
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "✕"
                  tooltipText: "Back (Esc)"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.cancelEditingLocation()
                }
              }
            }

            Item {
              width: parent.width
              height: locationField.implicitHeight

              TextField {
                id: locationField
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(16)
                anchors.rightMargin: Style.space(16)
                enabled: !root.savingLocation
                placeholderText: "Search for a city…"
                foreground: root.bar.foreground
                font.family: root.bar.fontFamily

                onTextChanged: if (root.editingLocation && !root.savingLocation) geocodeDebounce.restart()

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.cancelEditingLocation()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                    event.accepted = true
                  } else if (event.key === Qt.Key_Up) {
                    if (root.suggestionIndex > 0) root.suggestionIndex--
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.commitLocation()
                    event.accepted = true
                  }
                }
              }
            }

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              spacing: Style.space(6)

              Text {
                text: root.savingLocation ? "󰦖" : ""
                visible: root.savingLocation
                color: root.mutedText
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                RotationAnimator on rotation {
                  running: root.savingLocation
                  from: 0; to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }
              Text {
                text: root.savingLocation ? "Saving and fetching the forecast…"
                  : (root.commitHint !== "" ? root.commitHint
                  : (locationField.text.trim().length < 2 ? "Type at least two letters"
                  : (root.locationSuggestions.length === 0 ? (root.geocodeRunning ? "Searching…" : "No matches")
                  : "↑ ↓ to choose  ·  Enter to pick  ·  Esc to go back" + (root.geocodeRunning ? "  ·  searching…" : ""))))
                color: root.commitHint !== "" ? root.bar.foreground : root.fadedText
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Column {
              visible: !root.savingLocation && root.locationSuggestions.length > 0
              width: parent.width
              spacing: 0

              Repeater {
                model: root.locationSuggestions

                Rectangle {
                  required property var modelData
                  required property int index
                  width: parent.width
                  height: suggestionRow.implicitHeight + Style.space(14)
                  radius: Style.cornerRadius
                  color: index === root.suggestionIndex ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                  Row {
                    id: suggestionRow
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(16)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {

                      id: suggestionName

                      text: modelData.name
                      color: index === root.suggestionIndex ? Style.hoverStateColor(root.bar.foreground, Color.accent) : root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {

                      visible: text !== ""

                      width: Math.max(0, suggestionRow.parent.width - suggestionName.width - Style.space(44))

                      text: modelData.description
                      color: root.mutedText
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight

                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: root.suggestionIndex = index
                    onClicked: root.pickSuggestion(modelData)
                  }
                }
              }
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            // Where we are now, and the way back to auto-detect.
            Item {
              width: parent.width
              height: Math.max(currentLocationText.implicitHeight, autoButton.implicitHeight)

              Text {
                id: currentLocationText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                text: root.configuredLocation !== ""
                  ? "Now: " + root.configuredLocation.toUpperCase() + "  (saved)"
                  : "Now: " + (root.detectedLocation.name ? root.detectedLocation.name.toUpperCase() : "—") + "  (auto-detected from IP)"
                color: root.mutedText
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Button {
                id: autoButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.configuredLocation !== ""
                iconText: "󰆤"
                text: "Use automatic location"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.clearLocation()
              }
            }

            // GPS status: what the service can (or cannot) do right now.
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              width: parent.width - Style.space(32)
              visible: text !== ""
              text: root.gpsMessage !== "" ? root.gpsMessage
                : (root.gpsState === "ok" ? "" : root.gpsTooltip)
              color: root.gpsState === "ok" ? root.mutedText : root.fadedText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              text: "Place names © Kartverket (CC BY 4.0)  ·  © OpenStreetMap contributors"
              color: root.fadedText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
