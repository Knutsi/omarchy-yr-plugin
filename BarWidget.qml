import QtQuick
import qs.Commons
import qs.Ui

// Bar pill for knutsi.weather-yr: a theme-tinted Nerd Font glyph (optionally
// followed by the temperature) that opens the detail popup in Panel.qml.
//
//   left click    toggle the popup
//   middle click  force a refresh (re-detects the IP location too)
//   right click   send the current conditions as a desktop notification
BarWidget {
  id: root
  moduleName: "knutsi.weather-yr"

  readonly property var panel: panelLoader.item
  readonly property string barFormat: String(setting("barFormat", "icon-temp"))
  readonly property bool iconOnly: barFormat === "icon" || root.vertical
  readonly property string glyph: panel ? panel.label : ""
  readonly property string temp: panel ? panel.barTemp : ""
  readonly property string displayText: temp !== "" ? glyph + " " + temp : glyph
  readonly property string tooltip: panel ? panel.tooltipText : ""

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root.iconOnly ? iconButton : textButton
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh(true)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function notify() {
    if (!root.bar || !panelLoader.item) return
    var p = panelLoader.item
    var headline = (p.reportLocation ? p.reportLocation + "  " : "") + p.reportTemp
    var details = [p.reportCondition, p.reportWind ? "Wind " + p.reportWind : "", p.reportHumidity ? "Humidity " + p.reportHumidity : ""]
      .filter(function(part) { return part !== "" }).join("  ·  ")
    if (headline === "") headline = "Weather unavailable"
    root.bar.run("omarchy-notification-send -g " + Util.shellQuote(root.glyph || "")
      + " " + Util.shellQuote(headline) + " " + Util.shellQuote(details))
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: glyph !== ""
  implicitWidth: iconOnly ? iconButton.implicitWidth : textButton.implicitWidth
  implicitHeight: iconOnly ? iconButton.implicitHeight : textButton.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onIconOnlyChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
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
    tooltipText: root.tooltip
    onPressed: function(b) { root.handlePress(b) }
  }
}
