// A Spawnkit button. kind: "primary" (accent fill), "danger" (red fill) or "text" (no fill until
// hovered). Buttons carry no icons; the label says what happens.
import QtQuick
import QtQuick.Templates as T
import Spawnkit

T.Button {
    id: root
    property string kind: "text"
    readonly property bool filled: kind !== "text"
    readonly property color fill: kind === "danger" ? Theme.danger : Theme.accent

    implicitHeight: Theme.buttonHeight
    implicitWidth: Math.max(Theme.buttonHeight * 2, label.implicitWidth + Theme.s4 * 2)
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    scale: pressed ? 0.985 : 1
    Behavior on scale { NumberAnimation { duration: root.pressed ? 70 : Theme.fast } }

    contentItem: Text {
        id: label
        text: root.text
        font.family: Theme.font
        font.pointSize: Theme.base
        font.weight: root.filled ? Font.DemiBold : Font.Medium
        color: !root.filled ? (root.hovered ? Theme.text : Theme.textMuted)
             : root.kind === "danger" ? Theme.negativeText : Theme.accentText
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        Behavior on color { ColorAnimation { duration: Theme.fast } }
    }

    background: Rectangle {
        radius: Theme.radiusMd
        color: root.filled ? (root.hovered ? Qt.lighter(root.fill, 1.08) : root.fill)
             : root.pressed ? Theme.pressed : root.hovered ? Theme.hover : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.fast } }
        Rectangle {
            anchors { fill: parent; margins: -3 }
            radius: parent.radius + 3
            color: "transparent"
            border.width: 2
            border.color: Theme.focusRing
            visible: root.visualFocus
        }
    }
}
