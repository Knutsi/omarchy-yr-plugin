import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Units · Location · tekstvarsel toggle on the left; attribution (required
// by MET Norway's licence) and the clickable "updated" stamp on the right.
Item {
  id: root

  required property var service
  property color foreground: Color.foreground
  property color faded: Qt.darker(foreground, 1.7)
  property string fontFamily: Style.font.family
  property real gutter: Style.space(16)

  signal locationRequested()

  readonly property var weather: service.weather
  readonly property var unitOptions: [
    { value: "metric", label: "°C", tooltip: "Celsius, m/s, mm" },
    { value: "imperial", label: "°F", tooltip: "Fahrenheit, mph, inches" },
    { value: "kelvin", label: "K", tooltip: "Kelvin, m/s, mm" }
  ]

  implicitHeight: controls.implicitHeight

  Row {
    id: controls
    anchors.left: parent.left
    anchors.leftMargin: Style.space(12)
    spacing: Style.space(10)

    ButtonGroup {
      anchors.verticalCenter: parent.verticalCenter
      options: root.unitOptions
      value: root.weather.unit
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      focusable: false
      onChanged: function(value) { root.service.setUnit(value) }
    }

    Button {
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰍉"
      text: "Location"
      tooltipText: "Search for a place (Enter)"
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      onClicked: root.locationRequested()
    }

    // Only offered where a text forecast exists (Norwegian regions), and
    // also when it is off so it can be turned back on.
    PanelActionButton {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.weather.textAvailable
      iconText: "󰈙"   // nf-md-file_document
      tooltipText: root.weather.textForecastEnabled ? "Tekstvarsel on — click to hide" : "Tekstvarsel off — click to show"
      foreground: root.weather.textForecastEnabled ? Color.accent : Qt.darker(root.foreground, 1.5)
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: root.service.setTextForecast(!root.weather.textForecastEnabled)
    }
  }

  Row {
    anchors.right: parent.right
    anchors.rightMargin: root.gutter
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      text: Model.ATTRIBUTION
      color: root.faded
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    // Clicking the stamp forces a reload (rate-limited to one per 10 s).
    Text {
      textFormat: Text.PlainText
      visible: root.weather.updatedText !== "" || root.weather.fetchError !== ""
      text: "·  " + (root.weather.updatedText !== "" ? "updated " + root.weather.updatedText : "not updated")
        + (root.weather.busy ? "  󰦖" : "")
      color: root.service.settingsError !== "" ? Color.urgent : (updatedHover.hovered ? root.foreground : root.faded)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption

      TapHandler { onTapped: root.weather.refresh(true) }
      HoverHandler { id: updatedHover; cursorShape: Qt.PointingHandCursor }
    }
  }
}
