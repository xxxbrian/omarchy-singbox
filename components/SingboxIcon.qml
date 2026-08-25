import QtQuick
import qs.Commons
import qs.Ui

// A box for sing-box — an isometric cube drawn as strokes, struck through
// when the core is off, the same on/off idiom the shell's network widgets
// use. Drawn natively rather than from an SVG because bar slots are ~16px
// and Qt's SVG rasteriser smears strokes at that size.
//
// This is the brand mark, deliberately outside the ActionIcon grid: it has
// its own proportions and its own crossed/warning states, and putting it on
// the action grid would claim it belongs to the same family as row actions.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool crossed: false
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  onColorChanged: cube.requestPaint()
  onIconSizeChanged: cube.requestPaint()

  Canvas {
    id: cube
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width
      var h = height
      if (w <= 0 || h <= 0) return

      function px(u) { return u * w }
      function py(v) { return v * h }

      ctx.strokeStyle = root.color
      ctx.lineWidth = Math.max(1, w * 0.09)
      ctx.lineJoin = "round"
      ctx.lineCap = "round"

      // The hexagonal silhouette of a cube seen corner-on…
      ctx.beginPath()
      ctx.moveTo(px(0.5), py(0.04))
      ctx.lineTo(px(0.92), py(0.28))
      ctx.lineTo(px(0.92), py(0.72))
      ctx.lineTo(px(0.5), py(0.96))
      ctx.lineTo(px(0.08), py(0.72))
      ctx.lineTo(px(0.08), py(0.28))
      ctx.closePath()
      ctx.stroke()

      // …and the three inner edges that make it read as a solid.
      ctx.beginPath()
      ctx.moveTo(px(0.08), py(0.28)); ctx.lineTo(px(0.5), py(0.52))
      ctx.moveTo(px(0.92), py(0.28)); ctx.lineTo(px(0.5), py(0.52))
      ctx.moveTo(px(0.5), py(0.52)); ctx.lineTo(px(0.5), py(0.96))
      ctx.stroke()
    }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
