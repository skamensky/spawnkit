// A small round button holding one symbolic icon, for chrome such as close or copy.
import QtQuick
import QtQuick.Templates as T
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import Spawnkit

T.AbstractButton {
    id: root
    property string iconName
    property string tooltip
    property int size: 28

    implicitWidth: size
    implicitHeight: size
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    QQC2.ToolTip.visible: hovered && tooltip.length > 0
    QQC2.ToolTip.delay: 500
    QQC2.ToolTip.text: tooltip
    HoverHandler { cursorShape: Qt.PointingHandCursor }

    background: Rectangle {
        radius: width / 2
        color: root.pressed ? Theme.raisedPressed : root.hovered ? Theme.raised : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.quick } }
        Rectangle {
            anchors { fill: parent; margins: -2 }
            radius: width / 2
            color: "transparent"
            border.width: 2
            border.color: Theme.focusRing
            visible: root.visualFocus
        }
    }

    contentItem: Item {
        Kirigami.Icon {
            anchors.centerIn: parent
            width: root.size * 0.5
            height: width
            source: root.iconName
            isMask: true
            color: root.hovered ? Theme.text : Theme.textTertiary
            Behavior on color { ColorAnimation { duration: Theme.quick } }
        }
    }
}
