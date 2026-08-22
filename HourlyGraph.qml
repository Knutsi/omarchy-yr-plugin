import QtQuick
import qs.Commons
import "Model.js" as Model

// yr.no-style hour-by-hour graph: weather symbols along the top, a
// temperature curve over precipitation bars, hour labels underneath.
// Everything is painted in the bar foreground at varying opacity so the graph
// stays quiet in every theme, however loud its accent or red is.
Item {
  id: root

  property var points: []          // Model.hourlyForecast() output
  property string unit: "metric"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property int count: points ? points.length : 0
  readonly property real axisWidth: Style.space(30)
  readonly property real symbolRowHeight: Style.space(22)
  readonly property real labelRowHeight: Style.space(16)
  readonly property real plotHeight: Style.space(96)
  readonly property real plotLeft: axisWidth
  readonly property real plotWidth: Math.max(0, width - axisWidth * 2)
  readonly property real columnWidth: count > 0 ? plotWidth / count : 0
  readonly property int symbolStep: columnWidth >= Style.space(18) ? 1 : (columnWidth >= Style.space(10) ? 2 : 3)
  readonly property int labelStep: columnWidth >= Style.space(34) ? 1 : (columnWidth >= Style.space(14) ? 3 : 6)
  readonly property var axis: Model.graphScale(points, unit)

  implicitHeight: symbolRowHeight + plotHeight + labelRowHeight
  visible: count > 1

  function columnCenter(i) {
    return plotLeft + columnWidth * (i + 0.5)
  }

  // ---- Symbols, one per column (or every 2nd/3rd when the columns are narrow).
  Repeater {
    model: root.count

    Text {
      required property int index
      visible: index % root.symbolStep === 0
      x: root.columnCenter(index) - width / 2
      y: 0
      height: root.symbolRowHeight
      verticalAlignment: Text.AlignVCenter
      text: root.points[index] ? root.points[index].icon : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconSmall
    }
  }

  // ---- Plot: gridlines + axis labels + precipitation bars + temperature curve.
  Canvas {
    id: canvas
    x: 0
    y: root.symbolRowHeight
    width: root.width
    height: root.plotHeight
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)

      var pts = root.points || []
      var n = pts.length
      if (n < 2) return

      var s = root.axis
      var left = root.plotLeft
      var w = root.plotWidth
      var top = Style.space(6)
      var bottom = height - Style.space(2)
      var plotH = bottom - top
      var colW = root.columnWidth

      function yForTemp(t) {
        return bottom - (t - s.tempMin) / (s.tempMax - s.tempMin) * plotH
      }

      var fg = root.foreground
      var captionPx = Style.font.caption
      ctx.font = captionPx + "px \"" + root.fontFamily + "\""
      ctx.textBaseline = "middle"

      // Gridlines with temperature labels on the left axis.
      ctx.lineWidth = 1
      for (var g = 0; g < s.ticks.length; g++) {
        var gy = Math.round(yForTemp(s.ticks[g])) + 0.5
        ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.12)
        ctx.beginPath()
        ctx.moveTo(left, gy)
        ctx.lineTo(left + w, gy)
        ctx.stroke()
        ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.6)
        ctx.textAlign = "right"
        ctx.fillText(s.ticks[g] + Model.degreeSign(root.unit), left - Style.space(6), gy)
      }

      // Precipitation bars, scaled so the wettest hour fills ~55% of the plot.
      if (s.hasPrecip) {
        var barMax = plotH * 0.55
        ctx.textAlign = "center"
        for (var i = 0; i < n; i++) {
          var mm = pts[i].precipMm || 0
          if (mm <= 0) continue
          var bh = Math.max(2, mm / s.precipMax * barMax)
          var bw = Math.max(2, colW * 0.62)
          var bx = root.columnCenter(i) - bw / 2
          ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.28)
          ctx.fillRect(bx, bottom - bh, bw, bh)
          if (colW >= Style.space(16)) {
            ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.6)
            ctx.fillText(Model.formatPrecip(mm, root.unit).replace(/ (mm|in)$/, ""), root.columnCenter(i), bottom - bh - captionPx * 0.7)
          }
        }
        // Right axis: precipitation unit hint.
        ctx.textAlign = "left"
        ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.6)
        ctx.fillText(root.unit === "imperial" ? "in" : "mm", left + w + Style.space(6), bottom - barMax)
      }

      // Temperature curve (smoothed through column centres) with a soft fill.
      var curve = Qt.rgba(fg.r, fg.g, fg.b, 0.75)
      var xs = [], ys = []
      for (var k = 0; k < n; k++) {
        xs.push(root.columnCenter(k))
        ys.push(yForTemp(Model.convertTemp(pts[k].tempC, root.unit)))
      }

      function tracePath() {
        ctx.beginPath()
        ctx.moveTo(xs[0], ys[0])
        for (var j = 1; j < n; j++) {
          var cx = (xs[j - 1] + xs[j]) / 2
          var cy = (ys[j - 1] + ys[j]) / 2
          ctx.quadraticCurveTo(xs[j - 1], ys[j - 1], cx, cy)
        }
        ctx.lineTo(xs[n - 1], ys[n - 1])
      }

      tracePath()
      ctx.lineTo(xs[n - 1], bottom)
      ctx.lineTo(xs[0], bottom)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.06)
      ctx.fill()

      tracePath()
      ctx.lineWidth = 2
      ctx.lineJoin = "round"
      ctx.strokeStyle = curve
      ctx.stroke()

      // "Now" marker at the first column.
      ctx.fillStyle = curve
      ctx.beginPath()
      ctx.arc(xs[0], ys[0], 3, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  onPointsChanged: canvas.requestPaint()
  onUnitChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onPlotHeightChanged: canvas.requestPaint()
  onColumnWidthChanged: canvas.requestPaint()

  // ---- Hour labels.
  Repeater {
    model: root.count

    Text {
      required property int index
      visible: index % root.labelStep === 0
      x: root.columnCenter(index) - width / 2
      y: root.symbolRowHeight + root.plotHeight
      height: root.labelRowHeight
      verticalAlignment: Text.AlignVCenter
      text: root.points[index] ? root.points[index].hourLabel : ""
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
