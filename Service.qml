import QtQuick
import Quickshell.Io
import "Model.js" as Model

// The plugin's single shell-wide instance (kinds: ["service", "bar-widget"]).
// Omarchy mounts one bar widget per monitor; they all read this object via
// bar.shell.serviceFor(<plugin id>), so data is fetched once, settings are
// shared, and IPC verbs reach every screen.
Item {
  id: root

  // Injected by the shell.
  property var shell: null
  property var manifest: null
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.knutsi.yr"

  // Pushed by the bar widgets from their shell.json entry.
  property var settings: ({})

  readonly property alias location: locationService
  readonly property alias weather: weatherService
  readonly property alias search: geocodeSearch

  // Bumped by the `edit` IPC verb after summoning the popup; the panel that
  // is open reacts by entering the search view.
  property int editRequests: 0
  property string settingsError: ""
  readonly property var createdAt: new Date()

  LocationService { id: locationService }
  WeatherService { id: weatherService; location: locationService; settings: root.settings }
  GeocodeSearch { id: geocodeSearch }

  // A forecast for the new place means a save is complete.
  Connections {
    target: weatherService
    function onForecastArrived() { locationService.markSaved() }
  }

  // ---- Settings live on the widget's shell.json entry; the shell pushes
  //      them back to every widget, which re-renders everything.
  // Writes are queued: two quick clicks (or IPC calls) must both land.
  property var settingsQueue: []

  function setSetting(key, value, asJson) {
    var argv = ["omarchy", "bar", "set", pluginId, key, String(value)]
    if (asJson) argv.push("--json")
    settingsQueue = settingsQueue.concat([{ key: key, argv: argv }])
    pumpSettings()
  }

  function pumpSettings() {
    if (settingsRequest.running || !settingsQueue.length) return
    var next = settingsQueue[0]
    settingsQueue = settingsQueue.slice(1)
    settingsRequest.start(next.argv, next.key)
  }

  function setUnit(name) { setSetting("unit", Model.unitSystem(name), false) }
  function toggleUnit() { setUnit(Model.nextUnit(weatherService.unit)) }
  function setTextForecast(enabled) { setSetting("textForecast", enabled ? "true" : "false", true) }

  CurlRequest {
    id: settingsRequest
    onFinished: function(tag, stdout, exitCode) {
      root.settingsError = exitCode === 0 ? "" : "Could not save setting '" + tag + "' (omarchy bar set failed)"
      root.pumpSettings()
    }
  }

  function requestEdit() {
    if (shell && typeof shell.summon === "function") shell.summon(pluginId, "")
    editRequests++
  }

  IpcHandler {
    target: root.pluginId

    function refresh(): void { weatherService.refresh(true) }
    function locate(): void { locationService.probeGps(); Qt.callLater(function() { locationService.locateWithGps() }) }
    function unit(name: string): void { root.setUnit(name) }
    function toggleUnit(): void { root.toggleUnit() }
    function textForecast(enabled: string): void { root.setTextForecast(Model.settingBool(enabled, true)) }
    function edit(): void { root.requestEdit() }
    function location(): string { return JSON.stringify(locationService.effective) }
    function status(): string {
      return JSON.stringify({
        createdAt: root.createdAt.toISOString(),
        location: locationService.effective,
        locationSource: locationService.source,
        saveState: locationService.saveState,
        gpsState: locationService.gpsState,
        forecastUpdatedAt: weatherService.updatedAt ? weatherService.updatedAt.toISOString() : null,
        fetchError: weatherService.fetchError,
        alerts: weatherService.alerts.length,
        textArea: weatherService.textArea,
        unit: weatherService.unit,
        textForecast: weatherService.textForecastEnabled,
        pendingSettings: root.settingsQueue.length,
        settingsError: root.settingsError
      })
    }
  }
}
