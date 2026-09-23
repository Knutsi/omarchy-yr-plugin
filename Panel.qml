import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The popup for one monitor's bar pill. Pure view: every piece of data comes
// from the plugin's shared Service (injected by BarWidget.qml as `service`).
//
// Layout, top to bottom: current weather · weather warnings · hour-by-hour
// graph · next days · tekstvarsel (Norway) · settings and attribution.
// "Change location" swaps the whole content for SearchView.qml, and Shift+←/→
// pans the graph's hour cursor, which the hero then reads out.
//
// Popup lifecycle (open/openFromHotkey/close/toggle and the hover-reveal
// flag) follows Omarchy's stock weather plugin so the bar's popout
// coordinator treats this panel like a first-party one.
Panel {
  id: root
  moduleName: "io.github.knutsi.yr"
  manageIpc: false     // IPC lives in Service.qml (one instance for all screens)

  property var anchorItem: null
  property var service: null
  property bool openedFromHotkey: false
  property bool editing: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by is that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property bool ready: !!service
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color mutedText: Qt.darker(fg, 1.5)
  readonly property color fadedText: Qt.darker(fg, 1.7)
  readonly property real gutter: Style.space(16)
  readonly property real popupWidth: Style.space(540)

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    onOpened()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    onOpened()
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function onOpened() {
    if (!service) return
    service.location.reload()
    service.location.probeGps()
    service.weather.refresh(false)
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (editing) stopEditing()
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
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function startEditing() {
    if (!service || editing) return
    editing = true
    Qt.callLater(function() { if (searchLoader.item) searchLoader.item.begin() })
  }

  function stopEditing() {
    if (!editing) return
    editing = false
    if (searchLoader.item) searchLoader.item.end()
    Qt.callLater(function() { if (hourPan) hourPan.forceActiveFocus() })
  }

  // The hour cursor is a reading aid, not a setting: it never survives the
  // popup being closed (by Escape, a click outside, the pill, a popout switch
  // or IPC — `opened` follows the controller, so all of them land here) or the
  // search view taking the graph's place. Backspace leaves it without closing.
  onOpenedChanged: if (!opened) graph.reset()
  onEditingChanged: if (editing) graph.reset()

  // `omarchy-shell <id> edit` summons the popup, then bumps this counter.
  Connections {
    target: root.service
    function onEditRequestsChanged() { if (root.opened) root.startEditing() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: hourPan
    contentWidth: panel.fittedContentWidth(root.popupWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onReturnRequested: root.startEditing()
      onCloseRequested: root.close()
      // ← / → (or h / l) switch between the pinned places.
      onMoveRequested: function(dx, dy) { if (dx !== 0 && root.service) root.service.switchPinned(dx) }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // `s` opens the search / saved-places view, the way Return does. Both
      // cases, following the shell catcher's own `x`/`X` convention.
      onTextKey: function(text) { if (text === "s" || text === "S") root.startEditing() }

      // The hour-cursor keys, which PanelKeyCatcher cannot express: it
      // reports arrows with their modifiers stripped, so Shift+←/→ would
      // arrive indistinguishable from the place switch on plain ←/→.
      //
      // This item holds the panel's keyboard focus (KeyboardPanel.focusTarget
      // above) and accepts only the keys it owns. Everything else it leaves
      // unaccepted, and Qt walks the event up the parent chain to keyCatcher —
      // its parent — so every other key behaves exactly as it did before.
      // Plain focus and bubbling; an earlier attempt at Keys.forwardTo on the
      // catcher never fired at all.
      Item {
        id: hourPan
        focus: true
        width: 0
        height: 0

        Keys.onPressed: function(event) {
          if (root.editing || !root.ready) return
          // Backspace leaves hour-pan mode — but only when there is a pan to
          // leave, so an idle Backspace stays someone else's key.
          if (event.key === Qt.Key_Backspace) {
            if (!graph.panning) return
            graph.reset()
            event.accepted = true
            return
          }
          if (!(event.modifiers & Qt.ShiftModifier)) return
          if (event.key === Qt.Key_Left) { graph.pan(-1); event.accepted = true }
          else if (event.key === Qt.Key_Right) { graph.pan(1); event.accepted = true }
        }
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width

          // ---- Main view
          Column {
            visible: !root.editing
            width: parent.width
            spacing: Style.space(12)

            Text {
              textFormat: Text.PlainText
              visible: !root.ready
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Starting the weather service…"
              color: root.mutedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            HeroSection {
              visible: root.ready
              width: parent.width
              service: root.service
              foreground: root.fg
              fontFamily: root.fontFamily
              gutter: root.gutter
              hour: graph.selectedView
              onUnitTapped: root.service.toggleUnit()
              onLocationTapped: root.startEditing()
              onSiteTapped: root.service.openSite()
            }

            // Warnings (farevarsel)
            Item {
              visible: root.ready && root.service.weather.alerts.length > 0
              width: parent.width
              height: alertBanner.implicitHeight

              AlertBanner {
                id: alertBanner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: root.gutter
                anchors.rightMargin: root.gutter
                alerts: root.ready ? root.service.weather.alerts : []
                foreground: root.fg
                fontFamily: root.fontFamily
              }
            }

            // Every section below keeps its final size while data loads, so the
            // popup does not grow in steps: the graph area shows the status
            // until the first forecast, the days row shows placeholders, and
            // the tekstvarsel box is reserved whenever the spot is in Norway.

            // Hour-by-hour graph
            PanelSeparator { visible: graphSection.visible; foreground: root.fg }
            Column {
              id: graphSection
              visible: root.ready
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: root.gutter
                text: "NEXT " + (root.ready && root.service.weather.hourlyPoints.length > 1 ? root.service.weather.hourlyPoints.length : (root.ready ? root.service.weather.graphHours : 24)) + " HOURS"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Item {
                width: parent.width
                height: graph.implicitHeight

                HourlyGraph {
                  id: graph
                  width: parent.width
                  points: root.ready ? root.service.weather.hourlyPoints : []
                  unit: root.ready ? root.service.weather.unit : "metric"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                }

                Text {
                  textFormat: Text.PlainText
                  visible: graph.count <= 1
                  anchors.centerIn: parent
                  text: !root.ready ? ""
                    : (root.service.weather.fetchError !== "" ? "Forecast unavailable (" + root.service.weather.fetchError + ")"
                    : (root.service.location.hasLocation ? "Fetching forecast…"
                    : (root.service.location.detectError !== "" ? root.service.location.detectError : "Detecting location…")))
                  color: root.mutedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.italic: true
                }
              }
            }

            // Next days
            PanelSeparator { visible: daysSection.visible; foreground: root.fg }
            Column {
              id: daysSection
              visible: root.ready
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: root.gutter
                text: "NEXT " + (root.ready && root.service.weather.forecastDays.length > 0 ? root.service.weather.forecastDays.length : 4) + " DAYS"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              ForecastDaysRow {
                width: parent.width
                weather: root.ready ? root.service.weather : null
                foreground: root.fg
                fontFamily: root.fontFamily
              }
            }

            // Tekstvarsel
            PanelSeparator { visible: textSection.visible; foreground: root.fg }
            TextForecastSection {
              id: textSection
              visible: root.ready && root.service.weather.textForecastEnabled && root.service.weather.textExpected
              loaded: root.ready && !!root.service.weather.textFeatures
              width: parent.width
              report: root.ready ? root.service.weather.textReport : null
              foreground: root.fg
              fontFamily: root.fontFamily
              gutter: root.gutter
            }

            // Settings · attribution
            PanelSeparator { foreground: root.fg }
            SettingsRow {
              visible: root.ready
              width: parent.width
              service: root.service
              foreground: root.fg
              fontFamily: root.fontFamily
              gutter: root.gutter
              onLocationRequested: root.startEditing()
            }
          }

          // ---- Search view, built on demand.
          Loader {
            id: searchLoader
            width: parent.width
            active: root.editing && root.ready
            visible: active
            sourceComponent: SearchView {
              service: root.service
              foreground: root.fg
              fontFamily: root.fontFamily
              gutter: root.gutter
              onDismissed: root.stopEditing()
            }
            onLoaded: item.begin()
          }
        }
      }
    }
  }
}
