import QtQuick
import qs.Commons
import qs.Ui

// Tekstvarsel: MET's written forecast for the user's Norwegian land region.
// Today's text, then tomorrow's, in a box that scrolls when the text is long.
// The texts are MET's (Norwegian); the chrome is English.
Column {
  id: root

  property var report: null          // WeatherService.textReport
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real gutter: Style.space(16)
  property real maxBodyHeight: Style.space(120)

  readonly property color muted: Qt.darker(foreground, 1.5)

  spacing: Style.space(6)
  visible: !!report

  PanelSectionHeader {
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.leftMargin: root.gutter
    text: "TEKSTVARSEL  ·  " + (root.report ? root.report.area.toUpperCase() : "")
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Item {
    width: parent.width
    height: Math.min(root.maxBodyHeight, body.implicitHeight)

    Flickable {
      id: scroller
      anchors.fill: parent
      anchors.leftMargin: root.gutter
      anchors.rightMargin: root.gutter
      contentWidth: width
      contentHeight: body.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: body
        width: scroller.width
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.report ? root.report.today.text : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSectionHeader {
          textFormat: Text.PlainText
          visible: !!(root.report && root.report.tomorrow)
          text: "TOMORROW"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          visible: !!(root.report && root.report.tomorrow)
          width: parent.width
          text: root.report && root.report.tomorrow ? root.report.tomorrow.text : ""
          color: Qt.darker(root.foreground, 1.2)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }

    // Fade hint when there is more text below.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(18)
      visible: scroller.interactive && scroller.contentY + scroller.height < scroller.contentHeight - 1
      gradient: Gradient {
        GradientStop { position: 0.0; color: "transparent" }
        GradientStop { position: 1.0; color: Color.popups.background }
      }
    }
  }
}
