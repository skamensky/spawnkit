// A flow of steps on one line: a node and label per step, joined by connectors that fill in as
// steps complete. steps: [{label, state}] with state "done", "active", "upcoming" or "blocked".
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Spawnkit

RowLayout {
    id: root
    property var steps: []
    spacing: Theme.s2

    Repeater {
        model: root.steps
        delegate: RowLayout {
            id: step
            required property var modelData
            required property int index
            readonly property string state: modelData.state
            readonly property color tone: state === "done" ? Theme.positive
                : state === "active" ? Theme.accent
                : state === "blocked" ? Theme.negative : Theme.textDisabled
            spacing: Theme.s2

            // Connector from the previous step.
            Rectangle {
                visible: step.index > 0
                Layout.fillWidth: true
                Layout.minimumWidth: Theme.s5
                implicitHeight: 2
                radius: 1
                color: Theme.hairline
                Rectangle {
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    radius: 1
                    width: step.state === "upcoming" ? 0 : parent.width
                    color: step.state === "blocked" ? Theme.negative : Theme.positive
                    opacity: step.state === "active" ? 0.6 : 1
                    Behavior on width { NumberAnimation { duration: Theme.slow; easing.type: Easing.OutCubic } }
                }
            }

            // Node.
            Item {
                implicitWidth: 18
                implicitHeight: 18
                Rectangle {
                    anchors.centerIn: parent
                    width: 18; height: 18; radius: 9
                    color: Qt.alpha(step.tone, 0.18)
                    visible: step.state === "active"
                    SequentialAnimation on scale {
                        running: Theme.motion && step.state === "active"
                        loops: Animation.Infinite
                        NumberAnimation { to: 1.35; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                    }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: step.state === "upcoming" ? 10 : 12
                    height: width
                    radius: width / 2
                    color: step.state === "upcoming" ? "transparent" : step.tone
                    border.width: step.state === "upcoming" ? 1.5 : 0
                    border.color: Theme.outline
                    Behavior on color { ColorAnimation { duration: Theme.standard } }
                    Kirigami.Icon {
                        anchors.centerIn: parent
                        visible: step.state === "done"
                        width: 8; height: 8
                        source: "checkmark-symbolic"
                        isMask: true
                        color: "#FFFFFF"
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: step.state === "blocked"
                        text: "!"
                        font.family: Theme.font
                        font.pointSize: Theme.microSize
                        font.weight: Font.Bold
                        color: "#FFFFFF"
                    }
                }
            }

            Text {
                text: step.modelData.label
                font.family: Theme.font
                font.pointSize: Theme.metaSize
                font.weight: step.state === "active" ? Font.DemiBold : Font.Medium
                color: step.state === "upcoming" ? Theme.textTertiary : step.state === "blocked" ? Theme.negative : Theme.text
                Behavior on color { ColorAnimation { duration: Theme.standard } }
            }
        }
    }
}
