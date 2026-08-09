import QtQuick
import org.kde.kirigami as Kirigami

// An animated circular ring gauge drawn on a Canvas: a faint full track plus a
// progress arc with a faked sweep gradient, a soft outer glow, rounded caps and a
// bright end-dot. The value/caption are overlaid as crisp text in the center.
Item {
    id: g

    property real value: 0                 // target 0..100
    property color accentColor: Kirigami.Theme.highlightColor
    property color trackColor: Qt.rgba(Kirigami.Theme.textColor.r,
                                       Kirigami.Theme.textColor.g,
                                       Kirigami.Theme.textColor.b, 0.13)
    property real thickness: Math.max(3, Math.min(width, height) * 0.11)
    property string centerText: ""
    property string caption: ""
    property bool mono: false              // monospace center text (binary/blocks)
    property bool showText: true

    // animated progress value the canvas actually draws
    property real animValue: 0
    Behavior on animValue {
        NumberAnimation { duration: Kirigami.Units.longDuration * 2; easing.type: Easing.OutCubic }
    }
    onValueChanged: animValue = Math.max(0, Math.min(100, value))
    Component.onCompleted: animValue = Math.max(0, Math.min(100, value))

    onAnimValueChanged: canvas.requestPaint()
    onAccentColorChanged: canvas.requestPaint()
    onTrackColorChanged: canvas.requestPaint()
    onThicknessChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true
        renderStrategy: Canvas.Cooperative

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, h = height;
            if (w <= 0 || h <= 0) return;
            var cx = w / 2, cy = h / 2;
            var r = Math.min(w, h) / 2 - g.thickness / 2 - 2;
            if (r <= 1) return;

            var top = -Math.PI / 2;
            var full = Math.PI * 2;

            // faint full track
            ctx.lineCap = "round";
            ctx.lineWidth = g.thickness;
            ctx.strokeStyle = g.trackColor;
            ctx.beginPath();
            ctx.arc(cx, cy, r, 0, full);
            ctx.stroke();

            var frac = g.animValue / 100;
            if (frac <= 0.0001) return;
            var end = top + full * frac;

            var cStart = Qt.lighter(g.accentColor, 1.35);
            var cEnd = g.accentColor;

            // soft outer glow
            ctx.lineWidth = g.thickness + 5;
            ctx.strokeStyle = Qt.rgba(cEnd.r, cEnd.g, cEnd.b, 0.20);
            ctx.beginPath();
            ctx.arc(cx, cy, r, top, end);
            ctx.stroke();

            // segmented sweep gradient (start color -> accent)
            var segs = Math.max(10, Math.floor(frac * 64));
            ctx.lineWidth = g.thickness;
            for (var i = 0; i < segs; i++) {
                var a0 = top + (end - top) * (i / segs);
                var a1 = top + (end - top) * ((i + 1) / segs) + 0.012;
                var t = segs > 1 ? i / (segs - 1) : 1;
                ctx.strokeStyle = Qt.rgba(cStart.r + (cEnd.r - cStart.r) * t,
                                          cStart.g + (cEnd.g - cStart.g) * t,
                                          cStart.b + (cEnd.b - cStart.b) * t, 1);
                ctx.beginPath();
                ctx.arc(cx, cy, r, a0, a1);
                ctx.stroke();
            }

            // bright end-dot
            var ex = cx + r * Math.cos(end);
            var ey = cy + r * Math.sin(end);
            ctx.beginPath();
            ctx.fillStyle = cStart;
            ctx.arc(ex, ey, g.thickness / 2, 0, full);
            ctx.fill();
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 0
        visible: g.showText && g.centerText !== ""

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: g.centerText
            color: Kirigami.Theme.textColor
            font.family: g.mono ? "monospace" : Kirigami.Theme.defaultFont.family
            font.bold: true
            font.letterSpacing: g.mono ? 0.5 : 0
            font.pixelSize: Math.max(8, Math.min(g.width, g.height) * (g.mono ? 0.155 : 0.27))
        }
        Text {
            visible: g.caption !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            text: g.caption
            color: Kirigami.Theme.textColor
            opacity: 0.55
            font.pixelSize: Math.max(7, Math.min(g.width, g.height) * 0.115)
            font.letterSpacing: 1.5
            font.bold: true
        }
    }
}
