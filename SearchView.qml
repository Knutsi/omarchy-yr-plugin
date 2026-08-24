import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The "change location" view that replaces the popup's content: an empty
// search field with the saved places (pinned, then recent) listed under it,
// merged suggestions from three geocoders while typing, the GPS button, and
// a way back to automatic (IP-based) location.
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
  readonly property var places: service.places
  readonly property bool queryEmpty: field.text.trim() === ""
  // What the keyboard cursor walks: suggestions while typing, the saved
  // places while the box is empty.
  readonly property bool showingPlaces: queryEmpty && suggestions.length === 0 && places.length > 0
  readonly property var choices: suggestions.length > 0 ? suggestions : (showingPlaces ? places : [])
  property int selectedIndex: 0
  property var selectedPlace: null
  property var pendingPlace: null      // the search pick whose save is in flight
  property string hint: ""

  // One line of status, in priority order. Key hints are not status: they live
  // in the bar under the list.
  readonly property string statusText: {
    if (saving) return "Saving and fetching the forecast…"
    if (location.saveError !== "") return location.saveError
    if (hint !== "") return hint
    if (showingPlaces) return "Saved places  ·  type to search"
    if (queryEmpty) return "Type a place to search"
    if (field.text.trim().length < 2) return "Type at least two letters"
    if (search.running) return "Searching…"
    if (suggestions.length === 0) return "No matches"
    return "\u00A0"   // the line keeps its height when there is nothing to say
  }

  // What the keyboard can do right now: the list keys only while there is a
  // list to walk, and Backspace only while the box is empty — with text in it
  // Backspace deletes a character instead of going back.
  readonly property var keyHints: {
    var back = { caps: queryEmpty ? ["Esc", "⌫"] : ["Esc"], label: "back" }
    if (choices.length === 0) return [back]
    return [{ caps: ["↑", "↓"], label: "choose" },
            { caps: ["↵"], label: "open" },
            { caps: ["⇧↵"], label: "pin" },
            back]
  }

  signal dismissed()

  spacing: Style.space(12)

  function begin() {
    hint = ""
    selectedIndex = 0
    selectedPlace = null
    pendingPlace = null
    // Reset the query first: assigning the same text again would not fire
    // onQueryChanged, and the search would never run.
    search.query = ""
    search.clear()
    field.text = ""
    field.forceActiveFocus()
    location.probeGps()
  }

  function end() {
    search.query = ""
    search.clear()
    hint = ""
  }

  function pick(place) {
    if (!place) return
    pendingPlace = place
    location.persist(place.name, place.latitude, place.longitude)
  }

  // Shift+Enter pins the row under the cursor instead of opening it — and
  // unpins it if it is already pinned, the way the pin button does. Works on a
  // search result as well as a saved row: Service.togglePin remembers first.
  function pinSelected() {
    var place = choices[selectedIndex]
    if (!place) return
    if (!Model.isPinned(places, place) && !service.canPin) {
      hint = "Five places are pinned already — unpin one first"
      return
    }
    service.togglePin(place)
  }

  function commit() {
    if (showingPlaces) { pick(choices[selectedIndex]); return }
    var choice = Model.locationCommit(field.text, suggestions, selectedIndex)
    if (choice === null) {
      hint = queryEmpty ? "Type a place to search" : (search.running ? "Still searching…" : "Pick a match from the list")
      return
    }
    pick(choice)
  }

  // Keep the keyboard cursor on the same place while sources arrive.
  onChoicesChanged: selectedIndex = Model.suggestionIndexFor(choices, selectedPlace, selectedIndex)
  onSelectedIndexChanged: selectedPlace = choices[selectedIndex] || null

  Connections {
    target: root.location
    function onSaved() {
      if (root.pendingPlace) root.service.rememberPlace(root.pendingPlace)
      root.pendingPlace = null
      root.dismissed()
    }
    function onSaveFailed() { root.pendingPlace = null }
  }

  // ---- Header: title, GPS button, close.
  Item {
    width: parent.width
    height: Style.space(28)

    Text {
      textFormat: Text.PlainText
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

      onTextChanged: {
        // A place name; anything longer is a paste, not a search.
        if (text.length > Model.MAX_QUERY_CHARS) { text = text.slice(0, Model.MAX_QUERY_CHARS); return }
        root.hint = ""
        root.search.query = text
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.dismissed(); event.accepted = true }
        // Backspace on an empty box goes back, the way it leaves hour-pan mode
        // in the forecast view. With text in the box it still deletes, so the
        // way out is one press past the last character.
        else if (event.key === Qt.Key_Backspace && field.text.length === 0) { root.dismissed(); event.accepted = true }
        else if (event.key === Qt.Key_Down) { if (root.selectedIndex < root.choices.length - 1) root.selectedIndex++; event.accepted = true }
        else if (event.key === Qt.Key_Up) { if (root.selectedIndex > 0) root.selectedIndex--; event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (event.modifiers & Qt.ShiftModifier) root.pinSelected()
          else if (!root.saving) root.commit()
          event.accepted = true
        }
      }
    }
  }

  // ---- Status line.
  Row {
    anchors.left: parent.left
    anchors.leftMargin: root.gutter
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      visible: root.saving
      text: "󰦖"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      RotationAnimator on rotation { running: root.saving; from: 0; to: 360; duration: 800; loops: Animation.Infinite }
    }
    Text {
      textFormat: Text.PlainText
      text: root.statusText
      color: root.hint !== "" || root.location.saveError !== "" ? root.foreground : root.faded
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---- Suggestions while typing.
  Column {
    visible: !root.saving && root.suggestions.length > 0
    width: parent.width
    spacing: 0

    Repeater {
      model: root.suggestions

      PlaceRow {
        required property var modelData
        required property int index
        width: parent.width
        name: modelData.name
        description: modelData.description
        selected: index === root.selectedIndex
        foreground: root.foreground
        fontFamily: root.fontFamily
        gutter: root.gutter
        onHovered: root.selectedIndex = index
        onPicked: root.pick(modelData)
      }
    }
  }

  // ---- Saved places while the box is empty: pinned first (filled pin),
  //      then the latest searches (outlined pin).
  Column {
    visible: !root.saving && root.showingPlaces
    width: parent.width
    spacing: 0

    Repeater {
      model: root.showingPlaces ? root.places : []

      PlaceRow {
        required property var modelData
        required property int index
        width: parent.width
        name: modelData.name
        description: modelData.description
        selected: index === root.selectedIndex
        pinnable: true
        pinned: modelData.pinned
        canPin: root.service.canPin
        foreground: root.foreground
        fontFamily: root.fontFamily
        gutter: root.gutter
        onHovered: root.selectedIndex = index
        onPicked: root.pick(modelData)
        onPinToggled: root.service.togglePin(modelData)
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.places.some(function(p) { return p.pinned })
      anchors.left: parent.left
      anchors.leftMargin: root.gutter
      topPadding: Style.space(6)
      text: "Tip: ← → in the forecast view switch between pinned places"
      color: root.faded
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---- Key hints, under the list they describe.
  KeyHints {
    anchors.left: parent.left
    anchors.leftMargin: root.gutter
    width: parent.width - root.gutter * 2
    visible: !root.saving
    hints: root.keyHints
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  PanelSeparator { width: parent.width }

  // ---- Where we are now, and the way back to auto-detect.
  Item {
    width: parent.width
    height: Math.max(nowText.implicitHeight, autoButton.implicitHeight)

    Text {
      id: nowText
      textFormat: Text.PlainText
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
    textFormat: Text.PlainText
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
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.leftMargin: root.gutter
    text: "Place names © Kartverket (CC BY 4.0)  ·  © OpenStreetMap contributors"
    color: root.faded
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
