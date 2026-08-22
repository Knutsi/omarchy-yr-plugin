import QtQuick
import qs.Commons
import "Model.js" as Model

// MET weather warnings (farevarsel) for the location: one row per alert with
// the awareness colour as a stripe; click to expand the description.
Column {
  id: root

  property var alerts: []            // Model.parseAlerts() output
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property string expandedId: ""

  spacing: Style.space(6)
  visible: alerts && alerts.length > 0

  Repeater {
    model: root.alerts

    Rectangle {
      id: row
      required property var modelData
      required property int index
      readonly property bool expanded: root.expandedId === modelData.id
      readonly property color level: Model.alertColor(modelData.level)

      width: parent.width
      height: content.implicitHeight + Style.space(16)
      radius: Style.cornerRadius
      color: Qt.rgba(level.r, level.g, level.b, rowHover.hovered ? 0.18 : 0.12)

      Rectangle {
        width: Style.space(4)
        height: parent.height
        radius: Style.cornerRadius
        color: row.level
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Row {
          spacing: Style.space(8)
          width: parent.width

          Text {
            textFormat: Text.PlainText
            text: "󰀦"  // nf-md-alert
            color: row.level
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            text: row.modelData.name + "  ·  " + row.modelData.levelLabel
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            text: row.expanded ? "󰅃" : "󰅀"  // nf-md-chevron_up / chevron_down
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: row.modelData.area
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: row.expanded && text !== ""
          width: parent.width
          text: row.modelData.description
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: row.expanded && text !== ""
          width: parent.width
          text: row.modelData.instruction
          color: Qt.darker(root.foreground, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
          wrapMode: Text.WordWrap
        }
      }

      TapHandler {
        onTapped: root.expandedId = row.expanded ? "" : row.modelData.id
      }
      HoverHandler {
        id: rowHover
        cursorShape: Qt.PointingHandCursor
      }
    }
  }
}
