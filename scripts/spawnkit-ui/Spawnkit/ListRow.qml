// One row of a Spawnkit list: a checkbox (a lock when the row cannot be toggled), an icon tile,
// a title over a secondary line, and a status chip. phase shows the row's progress once work
// starts: "idle", "closing" (spinner), "closed" (green mark) or "stuck" (warning).
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import Spawnkit

T.AbstractButton {
    id: root
    property string iconName
    property string title
    property string secondary
    property string status
    property color statusColor: Theme.textTertiary
    property string tooltip
    property string phase: "idle"
    readonly property bool locked: !checkable
    readonly property bool interactive: checkable && phase === "idle"
    readonly property bool dimmed: (checkable && !checked && phase === "idle") || phase === "closed"

    implicitHeight: Theme.rowHeight
    // Rows that cannot be toggled stay enabled so their icons keep their colours; they just do nothing.
    hoverEnabled: interactive
    focusPolicy: interactive ? Qt.StrongFocus : Qt.NoFocus
    leftPadding: Theme.s3
    rightPadding: Theme.s3

    QQC2.ToolTip.visible: hovered && tooltip.length > 0
    QQC2.ToolTip.delay: 700
    QQC2.ToolTip.text: tooltip
    HoverHandler { enabled: root.interactive; cursorShape: Qt.PointingHandCursor }

    background: Rectangle {
        radius: Theme.radiusMd
        color: root.pressed ? Theme.pressed : root.hovered ? Theme.hover : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.quick } }
        Rectangle {
            anchors { fill: parent; margins: -2 }
            radius: parent.radius + 2
            color: "transparent"
            border.width: 2
            border.color: Theme.focusRing
            visible: root.visualFocus
        }
    }

    contentItem: RowLayout {
        spacing: Theme.s3

        // Leading mark: checkbox, lock, spinner, done or warning.
        Item {
            implicitWidth: 20
            implicitHeight: 20
            Check {
                anchors.centerIn: parent
                visible: !root.locked && root.phase !== "closing" && root.phase !== "stuck"
                checked: root.checked || root.phase === "closed"
                tone: root.phase === "closed" ? Theme.positive : Theme.accent
                mark: root.phase === "closed" ? "#FFFFFF" : Theme.accentText
                round: root.phase === "closed"
            }
            Kirigami.Icon {
                anchors.centerIn: parent
                visible: root.locked && root.phase === "idle"
                width: 15; height: 15
                source: "object-locked-symbolic"
                isMask: true
                color: Theme.textTertiary
            }
            Spinner {
                anchors.centerIn: parent
                visible: root.phase === "closing"
                size: 18
                color: Theme.accent
            }
            Kirigami.Icon {
                anchors.centerIn: parent
                visible: root.phase === "stuck"
                width: 18; height: 18
                source: "dialog-warning-symbolic"
                isMask: true
                color: Theme.caution
            }
        }

        IconTile {
            iconName: root.iconName
            label: root.title
            dim: root.dimmed ? 0.5 : 1
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            Text {
                Layout.fillWidth: true
                text: root.title
                elide: Text.ElideRight
                font.family: Theme.font
                font.pointSize: Theme.base
                font.weight: Font.Medium
                color: Theme.text
                opacity: root.dimmed ? 0.5 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.standard } }
            }
            Text {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.secondary
                elide: Text.ElideMiddle
                font.family: Theme.mono
                font.pointSize: Theme.monoSize
                color: Theme.textTertiary
                opacity: root.dimmed ? 0.6 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.standard } }
            }
        }

        Chip {
            text: root.status
            tone: root.statusColor
            opacity: root.dimmed ? 0.6 : 1
            Behavior on opacity { NumberAnimation { duration: Theme.standard } }
        }
    }
}
