import QtQuick
import "Model.js" as Model

// Everything fetched from MET Norway for the current location — forecast,
// warnings, text forecast — and the views derived from it. One instance,
// shared by every bar widget, so a multi-monitor setup makes one set of
// requests.
Item {
  id: root

  required property var location     // LocationService
  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string unit: Model.unitSystem(setting("unit", Model.DEFAULTS.unit))
  readonly property int refreshMinutes: Model.refreshMinutes(setting("refreshMinutes", Model.DEFAULTS.refreshMinutes))
  readonly property int graphHours: Model.graphHours(setting("graphHours", Model.DEFAULTS.graphHours))
  readonly property bool textForecastEnabled: Model.settingBool(setting("textForecast", Model.DEFAULTS.textForecast), Model.DEFAULTS.textForecast)
  readonly property string textForecastAreaOverride: String(setting("textForecastArea", "") || "")
  readonly property string alertsLanguage: Model.alertsLanguage(Qt.locale().name)

  // ---- Raw data. Kept on failure so stale data stays visible.
  property var forecast: null
  property var alerts: []
  property var textFeatures: null
  property string fetchError: ""
  property var updatedAt: null
  readonly property bool busy: forecastFetcher.running
  property int retries: 0
  property double lastForcedMs: 0

  signal forecastArrived()

  // ---- Clock. Advances once a minute so "now" moves without a fetch.
  property var tick: new Date()
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.tick = new Date() }

  // ---- Derived views.
  readonly property var currentEntry: Model.currentEntry(forecast, tick.getTime())
  readonly property var current: Model.currentCondition(currentEntry)
  readonly property string glyph: current ? Model.iconForSymbol(current.symbolCode) : ""
  readonly property string conditionText: current ? Model.symbolLabel(current.symbolCode) : ""
  readonly property string temperatureValue: current ? Model.roundedTemp(Model.convertTemp(current.tempC, unit)) : ""
  readonly property string temperatureText: current ? Model.formatTemp(current.tempC, unit) : ""
  readonly property string barTemperature: current ? Model.bareTemp(current.tempC, unit) : ""
  readonly property string tempUnit: Model.tempSuffix(unit)
  readonly property string windText: Model.formatWind(current, unit)
  readonly property string humidityText: current && current.humidity !== null ? Math.round(current.humidity) + "%" : ""
  readonly property var sun: Model.sunTimes(location.effective.latitude, location.effective.longitude, tick)
  readonly property string sunriseText: location.hasLocation ? Model.formatSunTime(sun.sunrise, sun.polar) : ""
  readonly property string sunsetText: location.hasLocation ? Model.formatSunTime(sun.sunset, sun.polar) : ""
  readonly property string updatedText: updatedAt ? Model.formatClock(updatedAt) : ""
  readonly property string textArea: Model.textForecastArea(textFeatures, location.effective.latitude, location.effective.longitude)
  readonly property var textReport: Model.textForecastFor(textFeatures, location.effective.latitude, location.effective.longitude, tick.getTime(), textForecastAreaOverride)
  readonly property bool textAvailable: !!textReport

  // Arrays keep their identity unless the content changed, so delegates are
  // not rebuilt every minute.
  property var hourlyPoints: []
  property var forecastDays: []
  property string daysKey: ""

  function recompute() {
    var next = Model.hourlyForecast(forecast, tick.getTime(), graphHours)
    if (!Model.samePoints(hourlyPoints, next)) hourlyPoints = next
    var today = Model.localDateKey(tick)
    var key = today + "|" + (forecast ? String(forecast.properties.meta && forecast.properties.meta.updated_at) : "")
    if (key !== daysKey) {
      daysKey = key
      forecastDays = Model.dailyForecast(forecast, today, 4)
    }
  }
  onForecastChanged: recompute()
  onTickChanged: recompute()
  onGraphHoursChanged: recompute()

  // ---- Refresh policy.
  function refresh(force) {
    if (force) {
      var now = Date.now()
      if (now - lastForcedMs < Model.FORCED_REFRESH_FLOOR_MS) return
      lastForcedMs = now
      forecastFetcher.reset()
      alertsFetcher.reset()
    }
    if (!location.hasLocation) return
    retries = 0
    forecastFetcher.fetch()
    alertsFetcher.fetch()
    fetchTextForecast(false)
  }

  function fetchTextForecast(force) {
    if (!location.hasLocation || !Model.inTextForecastRegion(location.effective.latitude, location.effective.longitude)) return
    if (force) textFetcher.reset()
    if (textFeatures && !force && !textTimer.due) return
    textTimer.due = false
    textFetcher.fetch()
  }

  Connections {
    target: root.location
    function onKeyChanged() { if (root.location.key !== "") Qt.callLater(function() { root.refresh(false) }) }
  }

  // Regular refresh, jittered so installs never line up on the minute.
  readonly property int jitterMs: Math.floor(Math.random() * 60000)
  Timer {
    interval: root.refreshMinutes * 60 * 1000 + root.jitterMs
    running: true
    repeat: true
    onTriggered: root.refresh(false)
  }

  // If nothing has arrived a few seconds after start, try regardless.
  Timer {
    interval: 8000
    running: true
    onTriggered: if (!root.forecast) root.refresh(false)
  }

  Timer {
    id: textTimer
    property bool due: true
    interval: Model.TEXTFORECAST_INTERVAL_MS + root.jitterMs
    running: true
    repeat: true
    onTriggered: { due = true; root.fetchTextForecast(false) }
  }

  // ---- Forecast.
  MetFetcher {
    id: forecastFetcher
    url: Model.forecastUrl(root.location.effective.latitude, root.location.effective.longitude)
    key: root.location.key
    maxTimeSec: Model.TIMEOUT_FORECAST_S
    onSucceeded: function(body) {
      var parsed = Model.parseForecast(body)
      if (!parsed) { root.handleForecastFailure(200); return }
      root.forecast = parsed
      root.updatedAt = new Date()
      root.fetchError = ""
      root.retries = 0
      root.forecastArrived()
    }
    onNotModified: function() {
      root.fetchError = ""
      root.retries = 0
      root.forecastArrived()
    }
    onFailed: function(status) { root.handleForecastFailure(status) }
  }

  function handleForecastFailure(status) {
    fetchError = Model.fetchErrorText(status)
    // 403 is a User-Agent/terms problem and 429 means we are being throttled:
    // retrying quickly would make either worse. Wait for the next interval.
    if (status === 403 || status === 429) return
    if (retries >= Model.RETRY_LIMIT) return
    retries++
    retryTimer.restart()
  }

  Timer {
    id: retryTimer
    interval: Model.RETRY_DELAY_MS
    onTriggered: forecastFetcher.fetch()
  }

  // ---- Warnings (farevarsel). A dropped fetch keeps the previous list.
  MetFetcher {
    id: alertsFetcher
    url: Model.alertsUrl(root.location.effective.latitude, root.location.effective.longitude, root.alertsLanguage)
    key: root.location.key
    maxTimeSec: Model.TIMEOUT_TEXT_S
    onSucceeded: function(body) { root.alerts = Model.parseAlerts(body) }
  }

  // ---- Tekstvarsel (land regions of Norway).
  MetFetcher {
    id: textFetcher
    url: Model.TEXTFORECAST_URL
    key: "landoverview"
    maxTimeSec: Model.TIMEOUT_TEXT_S
    onSucceeded: function(body) {
      var parsed = Model.parseTextForecast(body)
      if (parsed) root.textFeatures = parsed
    }
  }
}
