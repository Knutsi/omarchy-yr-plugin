import QtQuick
import qs.Commons
import "Model.js" as Model

// The coming days: glyph, weekday, high / low.
Item {
  id: root

  required property var weather
  property color foreground: Color.foreground
  property color muted: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  // Four quiet placeholder columns until the days arrive, so the row — and
  // the popup — keep their size.
  readonly property var days: weather && weather.forecastDays && weather.forecastDays.length > 0 ? weather.forecastDays : [null, null, null, null]
  readonly property string placeholderGlyph: Model.iconForSymbol("cloudy")

  implicitHeight: row.height

  Row {
    id: row
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(22)

    Repeater {
      model: root.days

      Row {
        required property var modelData
        spacing: Style.space(8)
        opacity: modelData ? 1 : 0.35

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: modelData ? modelData.icon : root.placeholderGlyph
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: modelData ? Model.dayName(modelData.date, function(d) { return Qt.formatDate(d, "ddd") }).toUpperCase() : "—"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Row {
            spacing: Style.space(5)
            Text {
              textFormat: Text.PlainText
              text: modelData ? Model.bareTempForDay(modelData, "max", root.weather.unit) : "—"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              text: modelData ? Model.bareTempForDay(modelData, "min", root.weather.unit) : "—"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }
      }
    }
  }
}
