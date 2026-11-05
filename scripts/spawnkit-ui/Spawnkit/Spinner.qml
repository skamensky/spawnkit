// An indeterminate progress ring: a faint track with a quarter arc sweeping round it.
import QtQuick
import QtQuick.Shapes
import Spawnkit

Item {
    id: root
    property int size: 16
    property color color: Theme.text
    property real stroke: 2
    implicitWidth: size
    implicitHeight: size

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: Qt.alpha(root.color, 0.18)
            strokeWidth: root.stroke
            fillColor: "transparent"
            PathAngleArc {
                centerX: root.size / 2; centerY: root.size / 2
                radiusX: root.size / 2 - root.stroke; radiusY: radiusX
                startAngle: 0; sweepAngle: 360
            }
        }
        ShapePath {
            strokeColor: root.color
            strokeWidth: root.stroke
            capStyle: ShapePath.RoundCap
            fillColor: "transparent"
            PathAngleArc {
                centerX: root.size / 2; centerY: root.size / 2
                radiusX: root.size / 2 - root.stroke; radiusY: radiusX
                startAngle: -90; sweepAngle: 100
            }
        }
        RotationAnimation on rotation {
            from: 0; to: 360
            duration: Theme.motion ? 900 : 0
            loops: Animation.Infinite
            running: root.visible && Theme.motion
        }
    }
}
