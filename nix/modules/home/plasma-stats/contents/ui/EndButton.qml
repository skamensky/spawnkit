// A row's compact end control: "End" (SIGTERM), "End anyway" for processes the desktop needs,
// a spinner while waiting for the exit, then "Force kill" (SIGKILL) if it is still running.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Templates as T
import "Spawnkit"

T.AbstractButton {
    id: button
    property Item ender
    property string key
    property var targets: []
    property string label
    property bool critical: false
    readonly property string phase: ender ? ender.state(key) : ""
    readonly property bool busy: phase === "ending" || phase === "killing"
    readonly property bool danger: phase === "stubborn" || phase === "confirm"

    implicitHeight: 26
    implicitWidth: Math.max(64, text.implicitWidth + Theme.s3 * 2)
    hoverEnabled: true
    enabled: !busy
    onClicked: ender.end(key, targets, label, critical)
    QQC2.ToolTip.visible: hovered
    QQC2.ToolTip.delay: 600
    QQC2.ToolTip.text: phase === "stubborn" ? i18n("Send SIGKILL: stops it immediately, without saving")
        : phase === "confirm" ? i18n("Your desktop session relies on this; ending it may close or restart parts of it")
        : targets.length > 1 ? i18n("Ask its %1 processes to exit (SIGTERM)", targets.length)
        : i18n("Ask it to exit (SIGTERM)")
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    background: Rectangle {
        radius: Theme.radiusSm
        color: button.danger ? (button.pressed ? Qt.darker(Theme.danger, 1.1) : Theme.danger)
            : button.pressed ? Theme.raisedPressed : button.hovered ? Theme.raisedHover : Theme.raised
        Behavior on color { ColorAnimation { duration: Theme.quick } }
    }
    contentItem: Item {
        Spinner {
            anchors.centerIn: parent
            visible: button.busy
            size: 14
        }
        Text {
            id: text
            anchors.centerIn: parent
            visible: !button.busy
            text: button.phase === "stubborn" ? i18n("Force kill")
                : button.phase === "confirm" ? i18n("End anyway")
                : i18n("End")
            font.family: Theme.font
            font.pointSize: Theme.microSize
            font.weight: Font.Medium
            color: button.danger ? Theme.dangerText : Theme.text
        }
    }
}
