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

  implicitHeight: row.height
  visible: weather.forecastDays.length > 0

  Row {
    id: row
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(22)

    Repeater {
      model: root.weather.forecastDays

      Row {
        required property var modelData
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.icon
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: Model.dayName(modelData.date, function(d) { return Qt.formatDate(d, "ddd") }).toUpperCase()
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Row {
            spacing: Style.space(5)
            Text {
              textFormat: Text.PlainText
              text: Model.bareTempForDay(modelData, "max", root.weather.unit)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              text: Model.bareTempForDay(modelData, "min", root.weather.unit)
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
