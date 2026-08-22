import QtQuick
import Quickshell
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
    settingsQueue = settingsQueue.concat([{ key: key, argv: Model.settingCommand(pluginId, key, value, asJson) }])
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

  // ---- Saved places (pinned favourites + the latest searches) live on the
  //      same entry, as an undeclared `places` key, and are read back from
  //      `settings` like everything else. They cannot be written through
  //      `omarchy bar set`: `qs ipc` spreads a JSON-array argument into
  //      separate arguments, so a one-place list arrives as a bare object and
  //      a longer one as "too many arguments". The list is written in-process
  //      instead, through the shell's own entry writer, the way Omarchy's
  //      widgets keep their own small state.
  readonly property var places: Model.parsePlaces(settings.places)
  readonly property bool canPin: Model.canPin(places)

  function currentEntry() {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    var layout = config && config.bar && config.bar.layout ? config.bar.layout : {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var arr = layout[sections[s]] || []
      for (var i = 0; i < arr.length; i++) if (arr[i] && String(arr[i].id || "").indexOf(pluginId) === 0) return arr[i]
    }
    return null
  }

  function savePlaces(list) {
    if (!shell || typeof shell.updateEntryInline !== "function") {
      settingsError = "Could not save places (shell API missing)"
      return
    }
    // Start from the shell's live entry, not our last settings snapshot, so a
    // setting written a moment ago is carried forward rather than clobbered.
    var base = currentEntry() || settings
    var entry = { id: pluginId }
    for (var key in base) if (key !== "id") entry[key] = base[key]
    entry.places = list
    shell.updateEntryInline(pluginId, entry)
    settingsError = ""
  }
  function rememberPlace(place) { savePlaces(Model.rememberPlace(places, place)) }
  function togglePin(place) { savePlaces(Model.togglePin(places, place)) }

  // ← / → in the popup (and the IPC verbs) walk the pinned places.
  function switchPinned(direction) {
    if (locationService.saveState !== "idle") return
    var next = Model.neighbourPinned(places, locationService.effective, direction)
    if (next) locationService.persist(next.name, next.latitude, next.longitude)
  }

  // ---- The same forecast on yr.no, for the location in use: the place's
  //      own page when yr's register knows it (found by the name in use,
  //      then by the nearest town), the coordinate page otherwise. The URL
  //      is literals plus a validated id or two numbers, launched as argv
  //      (no shell). Lookups are bounded by curl's timeout and cached per
  //      location for the session; a failure just means coordinates.
  property var siteCache: ({})
  property bool siteBusy: false
  property var sitePending: null     // the click being resolved: { latitude, longitude, name, cacheKey }

  function openSite() {
    if (!locationService.hasLocation) return
    var loc = locationService.effective
    var pending = { latitude: loc.latitude, longitude: loc.longitude, name: locationService.displayName }
    pending.cacheKey = locationService.key + "|" + pending.name
    if (siteCache[pending.cacheKey] !== undefined) { launchSite(pending, siteCache[pending.cacheKey]); return }
    if (siteBusy) return
    // Build the request before flipping the busy flag, so nothing can leave
    // the globe stuck on its spinner.
    var byName = Model.yrSearchCommand(pending.name)
    sitePending = pending
    siteBusy = true
    if (byName) siteRequest.start(byName, "name")
    else startNearbySite()
  }

  function startNearbySite() {
    var cmd = Model.yrNearbyCommand(sitePending.latitude, sitePending.longitude)
    if (cmd) siteRequest.start(cmd, "nearby")
    else finishSite("")
  }

  function finishSite(id) {
    var pending = sitePending
    sitePending = null
    siteBusy = false
    if (!pending) return
    var cache = siteCache
    cache[pending.cacheKey] = id
    siteCache = cache
    launchSite(pending, id)
  }

  function launchSite(pending, id) {
    var cmd = Model.browserCommand(Model.yrUrl(pending.latitude, pending.longitude, Qt.locale().name, id))
    if (cmd) Quickshell.execDetached(cmd)
  }

  CurlRequest {
    id: siteRequest
    onFinished: function(tag, stdout, exitCode) {
      var pending = root.sitePending
      if (!pending) return
      var id = exitCode === 0
        ? Model.pickYrLocation(Model.parseYrLocations(stdout), pending.latitude, pending.longitude, tag === "name" ? pending.name : "")
        : ""
      if (id === "" && tag === "name") { root.startNearbySite(); return }
      root.finishSite(id)
    }
  }

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
    function nextPinned(): void { root.switchPinned(1) }
    function previousPinned(): void { root.switchPinned(-1) }
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
        places: root.places.length,
        siteBusy: root.siteBusy,
        pendingSettings: root.settingsQueue.length,
        settingsError: root.settingsError
      })
    }
  }
}
