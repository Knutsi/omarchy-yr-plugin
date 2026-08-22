import QtQuick
import qs.Commons
import qs.Ui

// Current weather: big glyph + temperature (click the unit to cycle) and the
// condition on the left; location with search/GPS buttons and the
// wind/humidity/sunrise/sunset stats on the right.
Item {
  id: root

  required property var service
  property color foreground: Color.foreground
  property color muted: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family
  property real gutter: Style.space(16)

  signal unitTapped()
  signal locationTapped()
  signal siteTapped()

  readonly property var weather: service.weather
  readonly property var location: service.location
  readonly property bool kelvin: weather.unit === "kelvin"
  readonly property real glyphSize: Style.font.displayLarge * 2.3
  readonly property real tempSize: Style.font.displayLarge * (kelvin ? 1.6 : 2)

  implicitHeight: Math.max(left.height, right.height)

  Column {
    id: left
    anchors.left: parent.left
    anchors.leftMargin: root.gutter
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Row {
      spacing: Style.space(16)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Style.space(5)
        text: root.weather.glyph || "—"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.glyphSize
      }

      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          id: tempBig
          textFormat: Text.PlainText
          text: root.weather.temperatureValue || "—"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.tempSize
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          text: root.weather.current ? root.weather.tempUnit : ""
          color: unitHover.hovered ? Color.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          anchors.top: tempBig.top
          anchors.topMargin: Style.space(10)

          TapHandler { onTapped: root.unitTapped() }
          HoverHandler { id: unitHover; cursorShape: Qt.PointingHandCursor }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      // A blank line, not nothing, while the condition is unknown.
      text: root.weather.conditionText !== "" ? root.weather.conditionText : "\u00A0"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
    }
  }

  Column {
    id: right
    width: Math.max(stats.implicitWidth, Style.space(230))
    anchors.right: parent.right
    anchors.rightMargin: Style.space(20)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    // Location name + search + GPS. Name and search button open the search view.
    Row {
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: "󰍎"   // nf-md-map_marker
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: (root.location.displayName || "Set location").toUpperCase()
        color: locationHover.hovered ? root.foreground : Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.letterSpacing: 1
        anchors.verticalCenter: parent.verticalCenter
        // Leave room for the three buttons; long names are elided.
        width: Math.min(implicitWidth, right.width - Style.space(120))
        elide: Text.ElideRight

        TapHandler { onTapped: root.locationTapped() }
        HoverHandler { id: locationHover; cursorShape: Qt.PointingHandCursor }
      }
      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰍉"   // nf-md-magnify
        tooltipText: "Change location"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.locationTapped()
      }
      // GPS: enabled only when GeoClue is installed and authorised;
      // otherwise dimmed, with the tooltip saying what is missing.
      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: root.location.gpsBusy ? "󰦖" : "󰑱"   // nf-md-satellite_variant
        tooltipText: root.location.gpsSummary
        enabled: root.location.gpsState === "ok" && !root.location.gpsBusy
        foreground: root.location.gpsState === "ok" ? root.foreground : Qt.darker(root.foreground, 1.4)
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        opacity: root.location.gpsState === "ok" ? 1 : 0.45
        onClicked: root.location.locateWithGps()
      }
      // The same forecast on yr.no, in the default browser.
      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: root.service.siteBusy ? "󰦖" : "󰖟"   // spinner while yr's register is asked / nf-md-web
        tooltipText: root.service.siteBusy ? "Finding the place on yr.no…" : "Open on yr.no"
        enabled: root.location.hasLocation && !root.service.siteBusy
        foreground: root.location.hasLocation ? root.foreground : Qt.darker(root.foreground, 1.4)
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        opacity: root.location.hasLocation ? 1 : 0.45
        onClicked: root.siteTapped()
      }
    }

    Row {
      id: stats
      spacing: Style.space(20)

      Repeater {
        model: ["WIND", "HUMID", "SUNRISE", "SUNSET"]

        Column {
          required property string modelData
          spacing: Style.space(5)
          Text {
            textFormat: Text.PlainText
            text: modelData
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }
          Text {
            textFormat: Text.PlainText
            text: (modelData === "WIND" ? root.weather.windText
              : modelData === "HUMID" ? root.weather.humidityText
              : modelData === "SUNRISE" ? root.weather.sunriseText
              : root.weather.sunsetText) || "—"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }
      }
    }
  }
}
