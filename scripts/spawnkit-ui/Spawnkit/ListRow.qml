// One row of a Spawnkit list: an optional checkbox (or a lock when it cannot be toggled), an
// icon, a title, a status with a coloured dot on the right and, when expanded, a detail line.
// The whole row toggles; it has no border and only a faint fill on hover.
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
    property string status
    property color statusColor: Theme.textFaint
    property string detail
    property string tooltip
    property bool expanded
    property bool locked: !checkable

    implicitHeight: Math.max(Theme.rowHeight, content.implicitHeight + Theme.s2 * 2)
    hoverEnabled: true
    focusPolicy: checkable ? Qt.StrongFocus : Qt.NoFocus
    scale: pressed ? 0.995 : 1
    Behavior on scale { NumberAnimation { duration: root.pressed ? 70 : Theme.fast } }
    Behavior on implicitHeight { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutCubic } }

    QQC2.ToolTip.visible: hovered && tooltip.length > 0 && !expanded
    QQC2.ToolTip.delay: 600
    QQC2.ToolTip.text: tooltip

    HoverHandler { cursorShape: root.checkable ? Qt.PointingHandCursor : Qt.ArrowCursor }

    background: Rectangle {
        radius: Theme.radiusMd
        color: !root.checkable ? "transparent" : root.pressed ? Theme.pressed : root.hovered ? Theme.hover : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.fast } }
        Rectangle {
            anchors { fill: parent; margins: -2 }
            radius: parent.radius + 2
            color: "transparent"
            border.width: 2
            border.color: Theme.focusRing
            visible: root.visualFocus
        }
    }

    contentItem: Item {
        implicitHeight: content.implicitHeight
        RowLayout {
            id: content
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
            anchors.leftMargin: Theme.s3
            anchors.rightMargin: Theme.s3
            spacing: Theme.s3

            Item {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: (title.implicitHeight - 18) / 2 + 2
                implicitWidth: 18
                implicitHeight: 18
                CheckMark { visible: !root.locked; checked: root.checked }
                Kirigami.Icon {
                    anchors.centerIn: parent
                    visible: root.locked
                    width: 14
                    height: 14
                    source: "object-locked-symbolic"
                    isMask: true
                    color: Theme.textFaint
                }
            }
            Kirigami.Icon {
                Layout.alignment: Qt.AlignTop
                implicitWidth: 22
                implicitHeight: 22
                Layout.topMargin: (title.implicitHeight - 22) / 2
                source: root.iconName
                fallback: "application-x-executable"
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    spacing: Theme.s3
                    Text {
                        id: title
                        Layout.fillWidth: true
                        text: root.title
                        elide: Text.ElideRight
                        font.family: Theme.font
                        font.pointSize: Theme.base
                        font.weight: Font.Medium
                        color: Theme.text
                        opacity: root.checkable && !root.checked ? 0.55 : 1
                        Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                    }
                    Rectangle {
                        implicitWidth: 6
                        implicitHeight: 6
                        radius: 3
                        color: root.statusColor
                    }
                    Text {
                        text: root.status
                        font.family: Theme.font
                        font.pointSize: Theme.metaSize
                        color: Theme.textMuted
                    }
                }
                Text {
                    Layout.fillWidth: true
                    visible: opacity > 0
                    opacity: root.expanded ? 1 : 0
                    Layout.preferredHeight: root.expanded ? implicitHeight : 0
                    text: root.detail
                    elide: Text.ElideRight
                    font.family: Theme.mono
                    font.pointSize: Theme.monoSize
                    color: Theme.textFaint
                    Behavior on opacity { NumberAnimation { duration: Theme.normal } }
                }
            }
        }
    }
}
