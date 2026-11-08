// A small round button holding one symbolic icon, for chrome such as close or copy. glass draws
// it for a glass surface (Theme.glass), white on the wallpaper rather than on a themed card.
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
    property real iconScale: 0.5
    property bool glass: false

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
        color: root.pressed ? (root.glass ? Theme.glassPressed : Theme.raisedPressed)
            : root.hovered ? (root.glass ? Theme.glassRaised : Theme.raised) : "transparent"
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
            width: root.size * root.iconScale
            height: width
            source: root.iconName
            isMask: true
            color: root.glass ? Theme.glassText
                : root.hovered ? Theme.text : Theme.textTertiary
            Behavior on color { ColorAnimation { duration: Theme.quick } }
        }
    }
}
