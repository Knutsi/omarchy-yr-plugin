import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The "change location" view that replaces the popup's content: a search
// field with merged suggestions from three geocoders, the GPS button, and a
// way back to automatic (IP-based) location.
Column {
  id: root

  required property var service
  property color foreground: Color.foreground
  property color muted: Qt.darker(foreground, 1.5)
  property color faded: Qt.darker(foreground, 1.7)
  property string fontFamily: Style.font.family
  property real gutter: Style.space(16)

  readonly property var location: service.location
  readonly property var search: service.search
  readonly property bool saving: location.saveState !== "idle"
  readonly property var suggestions: search.suggestions
  property int selectedIndex: 0
  property var selectedPlace: null
  property string hint: ""

  signal dismissed()

  spacing: Style.space(12)

  function begin() {
    hint = ""
    selectedIndex = 0
    selectedPlace = null
    // Reset the query first: assigning the same text again would not fire
    // onQueryChanged, and the search would never run.
    search.query = ""
    search.clear()
    field.text = location.configured.name
    search.query = field.text
    field.selectAll()
    field.forceActiveFocus()
    location.probeGps()
  }

  function end() {
    search.query = ""
    search.clear()
    hint = ""
  }

  function pick(suggestion) {
    if (!suggestion) return
    location.persist(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function commit() {
    var choice = Model.locationCommit(field.text, suggestions, selectedIndex)
    if (choice === null) {
      hint = search.running ? "Still searching…" : "Pick a match from the list"
      return
    }
    if (choice.name === "") { location.clear(); return }
    pick(choice)
  }

  // Keep the keyboard cursor on the same place while sources arrive.
  onSuggestionsChanged: selectedIndex = Model.suggestionIndexFor(suggestions, selectedPlace, selectedIndex)
  onSelectedIndexChanged: selectedPlace = suggestions[selectedIndex] || null

  Connections {
    target: root.location
    function onSaved() { root.dismissed() }
  }

  // ---- Header: title, GPS button, close.
  Item {
    width: parent.width
    height: Style.space(28)

    Text {
      anchors.left: parent.left
      anchors.leftMargin: root.gutter
      anchors.verticalCenter: parent.verticalCenter
      text: "CHANGE LOCATION"
      color: root.muted
      font.family: root.fontFamily
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
        iconText: root.location.gpsBusy ? "󰦖" : "󰑱"   // nf-md-loading-ish spinner / nf-md-satellite_variant
        text: "My position"
        tooltipText: root.location.gpsSummary
        enabled: root.location.gpsState === "ok" && !root.location.gpsBusy
        opacity: root.location.gpsState === "ok" ? 1 : 0.45
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        bordered: true
        onClicked: root.location.locateWithGps()
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "✕"
        tooltipText: "Back (Esc)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.dismissed()
      }
    }
  }

  // ---- Search field. Escape always works, even while a save is pending.
  Item {
    width: parent.width
    height: field.implicitHeight

    TextField {
      id: field
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: root.gutter
      anchors.rightMargin: root.gutter
      readOnly: root.saving
      placeholderText: "Search for a place…"
      foreground: root.foreground
      font.family: root.fontFamily

      onTextChanged: { root.hint = ""; root.search.query = text }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.dismissed(); event.accepted = true }
        else if (event.key === Qt.Key_Down) { if (root.selectedIndex < root.suggestions.length - 1) root.selectedIndex++; event.accepted = true }
        else if (event.key === Qt.Key_Up) { if (root.selectedIndex > 0) root.selectedIndex--; event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { if (!root.saving) root.commit(); event.accepted = true }
      }
    }
  }

  // ---- Status line.
  Row {
    anchors.left: parent.left
    anchors.leftMargin: root.gutter
    spacing: Style.space(6)

    Text {
      visible: root.saving
      text: "󰦖"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      RotationAnimator on rotation { running: root.saving; from: 0; to: 360; duration: 800; loops: Animation.Infinite }
    }
    Text {
      text: root.saving ? "Saving and fetching the forecast…"
        : (root.location.saveError !== "" ? root.location.saveError
        : (root.hint !== "" ? root.hint
        : (field.text.trim().length < 2 ? "Type at least two letters"
        : (root.suggestions.length === 0 ? (root.search.running ? "Searching…" : "No matches")
        : "↑ ↓ to choose  ·  Enter to pick  ·  Esc to go back" + (root.search.running ? "  ·  searching…" : "")))))
      color: root.hint !== "" || root.location.saveError !== "" ? root.foreground : root.faded
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---- Suggestions.
  Column {
    visible: !root.saving && root.suggestions.length > 0
    width: parent.width
    spacing: 0

    Repeater {
      model: root.suggestions

      Rectangle {
        required property var modelData
        required property int index
        width: parent.width
        height: row.implicitHeight + Style.space(14)
        radius: Style.cornerRadius
        color: index === root.selectedIndex ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

        Row {
          id: row
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: root.gutter
          anchors.rightMargin: root.gutter
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Text {
            id: nameText
            text: modelData.name
            color: index === root.selectedIndex ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            visible: text !== ""
            width: Math.max(0, row.width - nameText.width - Style.space(8))
            text: modelData.description
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPositionChanged: root.selectedIndex = index
          onClicked: root.pick(modelData)
        }
      }
    }
  }

  PanelSeparator { width: parent.width }

  // ---- Where we are now, and the way back to auto-detect.
  Item {
    width: parent.width
    height: Math.max(nowText.implicitHeight, autoButton.implicitHeight)

    Text {
      id: nowText
      anchors.left: parent.left
      anchors.leftMargin: root.gutter
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - autoButton.width - root.gutter * 2 - Style.space(8)
      elide: Text.ElideRight
      text: root.location.configured.name !== ""
        ? "Now: " + root.location.configured.name.toUpperCase() + (root.location.nameWithoutCoordinates ? "  (no coordinates — using IP location)" : "  (saved)")
        : "Now: " + (root.location.detected.name ? root.location.detected.name.toUpperCase() : "—") + "  (auto-detected from IP)"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Button {
      id: autoButton
      anchors.right: parent.right
      anchors.rightMargin: root.gutter
      anchors.verticalCenter: parent.verticalCenter
      visible: root.location.configured.name !== ""
      iconText: "󰆤"   // nf-md-crosshairs_gps
      text: "Use automatic location"
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      onClicked: root.location.clear()
    }
  }

  // ---- GPS status: what the service can (or cannot) do right now.
  Text {
    anchors.left: parent.left
    anchors.leftMargin: root.gutter
    width: parent.width - root.gutter * 2
    visible: text !== ""
    text: root.location.gpsMessage !== "" ? root.location.gpsMessage : root.location.gpsHelp
    color: root.location.gpsState === "ok" ? root.muted : root.faded
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    anchors.left: parent.left
    anchors.leftMargin: root.gutter
    text: "Place names © Kartverket (CC BY 4.0)  ·  © OpenStreetMap contributors"
    color: root.faded
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
