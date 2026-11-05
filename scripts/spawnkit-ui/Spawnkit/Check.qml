// A 20px checkbox: a rounded square that fills with the accent while the tick draws itself on.
// tone switches the fill, for a green "done" mark.
import QtQuick
import QtQuick.Shapes
import Spawnkit

Rectangle {
    id: root
    property bool checked
    property color tone: Theme.accent
    property color mark: Theme.accentText
    property bool round: false
    readonly property real draw: checked ? 1 : 0

    implicitWidth: 20
    implicitHeight: 20
    radius: round ? width / 2 : Theme.radiusSm
    color: checked ? tone : "transparent"
    border.width: checked ? 0 : 1.5
    border.color: Theme.outline
    Behavior on color { ColorAnimation { duration: Theme.quick } }

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        visible: root.checked
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.14) }
            GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
        }
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            id: tick
            strokeColor: root.mark
            strokeWidth: 2
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            fillColor: "transparent"
            startX: 5.2; startY: 10.4
            PathLine { x: 8.6; y: 13.8 }
            PathLine { x: 14.8; y: 6.8 }
            trim.end: root.draw
            Behavior on trim.end { NumberAnimation { duration: Theme.standard; easing.type: Easing.OutCubic } }
        }
    }
}
