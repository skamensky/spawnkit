// The panel icon: a dial whose hand points at the CPU use, tinted green when idle, through orange,
// to red when the machine is busy.
import QtQuick
import QtQuick.Shapes

Item {
    id: gauge
    property real percent: 0
    // The dial runs clockwise from lower left to lower right.
    readonly property real sweep: 270
    readonly property real angle: -sweep / 2 + sweep * Math.max(0, Math.min(100, percent)) / 100
    readonly property color tone: mix(percent)
    readonly property real stroke: Math.max(2, Math.round(width / 11))
    readonly property real radius: (width - stroke) / 2

    function mix(value) {
        const stops = [[20, "#2FD07F"], [55, "#FF9A2E"], [85, "#F0353B"]]
        if (value <= stops[0][0])
            return stops[0][1]
        for (let i = 1; i < stops.length; i++)
            if (value <= stops[i][0]) {
                const from = Qt.color(stops[i - 1][1]), to = Qt.color(stops[i][1])
                const t = (value - stops[i - 1][0]) / (stops[i][0] - stops[i - 1][0])
                return Qt.rgba(from.r + (to.r - from.r) * t, from.g + (to.g - from.g) * t,
                               from.b + (to.b - from.b) * t, 1)
            }
        return stops[stops.length - 1][1]
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: "transparent"
            strokeColor: gauge.tone
            strokeWidth: gauge.stroke
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: gauge.width / 2
                centerY: gauge.height / 2
                radiusX: gauge.radius
                radiusY: gauge.radius
                startAngle: 135
                sweepAngle: gauge.sweep
            }
        }
    }
    // The hand, pivoting on the hub at the dial's centre.
    Rectangle {
        x: (gauge.width - width) / 2
        y: gauge.height / 2 - height + width / 2
        width: gauge.stroke
        height: gauge.radius * 0.8
        radius: width / 2
        color: gauge.tone
        antialiasing: true
        transform: Rotation {
            origin.x: gauge.stroke / 2
            origin.y: gauge.radius * 0.8 - gauge.stroke / 2
            angle: gauge.angle
        }
    }
    Rectangle {
        anchors.centerIn: parent
        width: gauge.stroke * 2
        height: width
        radius: width / 2
        color: gauge.tone
    }
}
