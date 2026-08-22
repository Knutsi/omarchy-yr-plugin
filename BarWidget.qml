import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill for the Yr.no (unofficial) plugin: a theme-tinted Nerd Font glyph
// (optionally followed by the temperature) that opens the popup in Panel.qml.
// One of these exists per monitor; all of them read the plugin's single
// Service instance, which the shell creates for `kinds: ["service", ...]`.
//
//   left click    toggle the popup
//   middle click  force a refresh (re-detects the IP location too)
//   right click   send the current conditions as a desktop notification
BarWidget {
  id: root
  moduleName: "io.github.knutsi.yr"

  property var service: null
  readonly property var weather: service ? service.weather : null
  readonly property string barFormat: String(setting("barFormat", Model.DEFAULTS.barFormat))
  readonly property bool iconOnly: barFormat === "icon" || root.vertical
  readonly property bool unavailable: !!weather && !weather.current && weather.fetchError !== ""
  // While the first forecast loads the pill shows a quiet placeholder of the
  // same shape, so the bar does not reflow when the numbers arrive.
  readonly property bool loading: !!weather && !weather.current && !unavailable
  readonly property string glyph: weather && weather.current ? weather.glyph : (unavailable ? Model.GLYPH_UNAVAILABLE : (loading ? Model.iconForSymbol("cloudy") : ""))
  readonly property string temp: weather ? (weather.barTemperature !== "" ? weather.barTemperature : (loading ? "--°" : "")) : ""
  readonly property string displayText: temp !== "" ? glyph + " " + temp : glyph
  readonly property string tooltip: !weather ? "Yr.no (unofficial)"
    : (weather.current ? [weather.conditionText, weather.temperatureText, service.location.displayName].filter(function(p) { return p !== "" }).join("  ·  ")
       : (weather.fetchError ? "Yr.no: " + weather.fetchError : "Yr.no: fetching forecast…"))

  // ---- Find the shared service. It normally exists before the bar mounts;
  //      right after `omarchy plugin add --enable` it may not, so ask the
  //      shell to create it and retry briefly.
  function bindService() {
    if (service || !bar || !bar.shell) return
    var s = bar.shell.serviceFor(moduleName)
    if (!s && typeof bar.shell.ensureService === "function") s = bar.shell.ensureService(moduleName)
    if (s) {
      service = s
      service.settings = root.settings
      injectPanel()
    }
  }

  onBarChanged: bindService()
  onSettingsChanged: { if (service) service.settings = root.settings; injectPanel() }
  onIconOnlyChanged: injectPanel()

  Timer {
    interval: 1000
    running: !root.service && !!root.bar
    repeat: true
    onTriggered: root.bindService()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("service" in target) target.service = root.service
    if ("anchorItem" in target) target.anchorItem = root.iconOnly ? iconButton : textButton
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() { if (weather) weather.refresh(true) }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }

  function notify() {
    if (!weather) return
    var headline = Model.notificationHeadline(service.location.displayName, weather.temperatureText)
    var details = [weather.conditionText, weather.windText ? "Wind " + weather.windText : "", weather.humidityText ? "Humidity " + weather.humidityText : ""]
      .filter(function(part) { return part !== "" }).join("  ·  ")
    Quickshell.execDetached(Model.notificationCommand(root.glyph || "", headline, details))
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function toggle() { togglePanel() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  visible: glyph !== ""
  implicitWidth: iconOnly ? iconButton.implicitWidth : textButton.implicitWidth
  implicitHeight: iconOnly ? iconButton.implicitHeight : textButton.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  function handlePress(b) {
    if (!root.bar) return
    if (b === Qt.RightButton) root.notify()
    else if (b === Qt.MiddleButton) root.refresh()
    else root.togglePanel()
  }

  BarIconButton {
    id: iconButton
    anchors.fill: parent
    visible: root.iconOnly
    bar: root.bar
    text: root.glyph
    dimmed: root.unavailable
    slotSize: Style.bar.statusSlot
    tooltipText: root.tooltip
    onPressed: function(b) { root.handlePress(b) }
  }

  WidgetButton {
    id: textButton
    anchors.fill: parent
    visible: !root.iconOnly
    bar: root.bar
    text: root.displayText
    dimmed: root.unavailable
    tooltipText: root.tooltip
    onPressed: function(b) { root.handlePress(b) }
  }
}
