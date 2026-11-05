// A Spawnkit button. kind: "primary" (accent fill, one per dialog), "danger" (red fill), "tonal"
// (raised fill, the usual secondary) or "ghost" (text only, for tertiary choices). busy shows a
// spinner in place of the label's leading edge and blocks input; defaultButton answers Return.
import QtQuick
import QtQuick.Templates as T
import Spawnkit

T.Button {
    id: root
    property string kind: "tonal"
    property bool busy: false
    property bool defaultButton: false
    readonly property bool filled: kind === "primary" || kind === "danger"
    readonly property color fill: kind === "danger" ? Theme.danger : Theme.accent
    readonly property color labelColor: kind === "primary" ? Theme.accentText
        : kind === "danger" ? Theme.dangerText
        : kind === "ghost" ? (hovered ? Theme.text : Theme.textSecondary)
        : Theme.text

    implicitHeight: Theme.buttonHeight
    implicitWidth: Math.max(Theme.buttonHeight * 2.2, row.implicitWidth + Theme.s4 * 2)
    leftPadding: Theme.s4
    rightPadding: Theme.s4
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    opacity: enabled || busy ? 1 : 0.45
    scale: pressed ? 0.97 : 1
    Behavior on scale { NumberAnimation { duration: root.pressed ? 60 : Theme.quick; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: Theme.standard } }

    Shortcut {
        enabled: root.defaultButton && root.visible && root.enabled && !root.busy
        sequences: ["Return", "Enter"]
        onActivated: root.clicked()
    }

    contentItem: Item {
        implicitWidth: row.implicitWidth
        implicitHeight: row.implicitHeight
        Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.s2
            Spinner {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.busy
                size: 15
                color: root.labelColor
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.text
                font.family: Theme.font
                font.pointSize: Theme.base
                font.weight: root.filled ? Font.DemiBold : Font.Medium
                font.letterSpacing: -0.1
                color: root.labelColor
                Behavior on color { ColorAnimation { duration: Theme.quick } }
            }
        }
    }

    background: Rectangle {
        radius: Theme.radiusMd
        color: root.filled ? root.fill
             : root.kind === "tonal" ? (root.pressed ? Theme.raisedPressed : root.hovered ? Theme.raisedHover : Theme.raised)
             : root.pressed ? Theme.pressed : root.hovered ? Theme.hover : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.quick } }

        // Filled buttons get a glass edge: brighter at the top, a faint full outline.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            visible: root.filled
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(1, 1, 1, root.hovered ? 0.16 : 0.10) }
                GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
            }
        }
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            visible: root.filled
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
        }
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
