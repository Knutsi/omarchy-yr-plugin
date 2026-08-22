import QtQuick
import qs.Commons

// Tekstvarsel: MET's written forecast for the user's Norwegian land region.
// Today's text, then tomorrow's, in a box that scrolls when the text is long.
Column {
  id: root

  property var report: null          // Model.textForecastFor() output
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real maxBodyHeight: Style.space(120)

  readonly property color muted: Qt.darker(foreground, 1.5)

  spacing: Style.space(6)
  visible: !!report

  Text {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(16)
    text: "TEKSTVARSEL  ·  " + (root.report ? root.report.area.toUpperCase() : "")
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
  }

  Item {
    width: parent.width
    height: Math.min(root.maxBodyHeight, body.implicitHeight)

    Flickable {
      id: scroller
      anchors.fill: parent
      anchors.leftMargin: Style.space(16)
      anchors.rightMargin: Style.space(16)
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
          width: parent.width
          text: root.report ? root.report.today.text : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: !!(root.report && root.report.tomorrow)
          text: "I MORGEN"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }

        Text {
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
