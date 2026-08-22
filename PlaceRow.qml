import QtQuick
import qs.Commons
import qs.Ui

// One row in the search view's lists: a place name with a muted description,
// highlighted while it is the keyboard cursor, and — for saved places — a
// pin toggle at the right edge. The pin has its own mouse area on top of
// the row's, so toggling it never picks the place.
Rectangle {
  id: root

  property string name: ""
  property string description: ""
  property bool selected: false
  property bool pinnable: false
  property bool pinned: false
  property bool canPin: true
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real gutter: Style.space(16)

  signal picked()
  signal hovered()
  signal pinToggled()

  readonly property color muted: Qt.darker(foreground, 1.5)

  height: row.implicitHeight + Style.space(14)
  radius: Style.cornerRadius
  color: selected ? Style.hoverFillFor(foreground, Color.accent) : "transparent"

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPositionChanged: root.hovered()
    onClicked: root.picked()
  }

  Row {
    id: row
    anchors.left: parent.left
    anchors.right: pin.visible ? pin.left : parent.right
    anchors.leftMargin: root.gutter
    anchors.rightMargin: pin.visible ? Style.space(8) : root.gutter
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    Text {
      id: nameText
      textFormat: Text.PlainText
      text: root.name
      color: root.selected ? Style.hoverStateColor(root.foreground, Color.accent) : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      width: Math.max(0, row.width - nameText.width - Style.space(8))
      text: root.description
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  PanelActionButton {
    id: pin
    visible: root.pinnable
    anchors.right: parent.right
    anchors.rightMargin: root.gutter
    anchors.verticalCenter: parent.verticalCenter
    iconText: root.pinned ? "󰐃" : "󰤱"   // nf-md-pin / nf-md-pin_outline
    tooltipText: root.pinned ? "Unpin" : (root.canPin ? "Pin" : "Pinned list is full (5)")
    enabled: root.pinned || root.canPin
    foreground: root.pinned ? root.foreground : root.muted
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    opacity: enabled ? 1 : 0.45
    onClicked: root.pinToggled()
  }
}
