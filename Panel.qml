import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Detail popup + data layer for knutsi.weather-yr.
//
// Layout, top to bottom: current weather · hour-by-hour graph · next four
// days · settings (units, location) · attribution. Changing the location
// swaps the whole content for a search view.
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
  moduleName: "knutsi.weather-yr"
  ipcTarget: "knutsi.weather-yr"
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
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    locationFile.reload()
    root.refresh(false)
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
    if (locationKey !== "") Qt.callLater(fetchForecast)
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

  // ---- Click-to-edit state for the location.
  property bool editingLocation: false
  property bool savingLocation: false
  property bool savingLocationQueryStarted: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

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
    unitSaveProc.command = ["omarchy", "bar", "set", "knutsi.weather-yr", "unit", Model.unitSystem(name)]
    unitSaveProc.running = true
  }

  function toggleUnit() {
    setUnit(Model.nextUnit(unit))
  }

  Process {
    id: unitSaveProc
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
  readonly property string reportPrecip:    current ? Model.formatPrecip(current.precipMm, unit) : ""
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
    suggestionIndex = 0
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
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
      }
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
    contentWidth: panel.fittedContentWidth(Style.space(520))
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

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
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

            Column {
              id: heroRight
              width: Math.max(weatherStats.implicitWidth, Style.space(210))
              anchors.right: parent.right
              anchors.rightMargin: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              // Location name + search button. Clicking either opens the search view.
              Row {
                spacing: Style.space(6)

                Text {
                  text: ""  // nf-fa-map_marker
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
                  iconText: ""  // nf-fa-search
                  tooltipText: "Change location"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.startEditingLocation()
                }
              }

              Text {
                visible: root.reportCondition !== ""
                text: root.reportCondition
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Row {
                id: weatherStats
                visible: !!root.current
                spacing: Style.space(28)

                Repeater {
                  model: [
                    { label: "WIND", value: root.reportWind },
                    { label: "HUMID", value: root.reportHumidity },
                    { label: "RAIN 1H", value: root.reportPrecip }
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
          // 4. Settings
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
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(12)

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
                iconText: ""
                text: "Location"
                tooltipText: "Search for a city (Enter)"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.startEditingLocation()
              }
            }
          }

          // ---- Attribution (required by MET Norway's licence) and freshness.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)

            Text {
              text: Model.ATTRIBUTION
              color: root.fadedText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            // Clicking the timestamp forces a reload.
            Text {
              visible: root.updatedClock !== "" || root.fetchError !== ""
              text: "·  " + (root.updatedClock !== "" ? "updated " + root.updatedClock : "not updated")
                + (forecastProc.running ? "  󰦖" : "")
              color: updatedHover.hovered ? root.bar.foreground : root.fadedText
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.underline: updatedHover.hovered

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

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "✕"
                tooltipText: "Back (Esc)"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.cancelEditingLocation()
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
                  : (locationField.text.trim().length < 2 ? "Type at least two letters"
                  : (root.locationSuggestions.length === 0 ? (geocodeProc.running ? "Searching…" : "No matches")
                  : "↑ ↓ to choose  ·  Enter to pick  ·  Esc to go back"))
                color: root.fadedText
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
                      text: modelData.name
                      color: index === root.suggestionIndex ? Style.hoverStateColor(root.bar.foreground, Color.accent) : root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      visible: text !== ""
                      text: modelData.description
                      color: root.mutedText
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
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
          }
        }
      }
    }
  }
}
