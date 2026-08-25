import QtQuick
import qs.Commons

// A quiet row of key caps and what they do — the footer under a list you can
// drive from the keyboard.
//
// One entry per action. `caps` are the keys that perform it, and more than one
// cap means "either of these" (Esc or Backspace). A chord goes inside a single
// cap as one string ("⇧↵"), so the two meanings never collide:
//
//   hints: [{ caps: ["↑", "↓"], label: "choose" },
//           { caps: ["⇧↵"],     label: "pin" }]
//
// Painted in the bar foreground at low opacity, like HourlyGraph: a help bar
// that competes with the list it explains is not helping. A Flow rather than a
// Row so a narrow popup wraps instead of clipping.
Flow {
  id: root

  property var hints: []
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property real capHeight: Math.round(Style.font.caption * 1.9)

  spacing: Style.space(14)

  Repeater {
    model: root.hints

    Row {
      required property var modelData
      spacing: Style.space(5)

      Repeater {
        model: parent.modelData.caps

        Rectangle {
          required property string modelData
          implicitWidth: Math.max(cap.implicitWidth + Style.space(10), root.capHeight)
          implicitHeight: root.capHeight
          radius: Style.space(3)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

          Text {
            id: cap
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: modelData
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: parent.modelData.label
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
