// An app icon on a raised rounded tile, so icons of any shape or colour sit in one visual rhythm.
// A program without an icon gets a monogram on a hue of its own instead of a generic placeholder.
import QtQuick
import org.kde.kirigami as Kirigami
import Spawnkit

Rectangle {
    id: root
    property string iconName
    property string label         // the name shown as a monogram when the icon is missing
    property real dim: 1
    readonly property bool monogram: label.length > 0 && !dialog.hasIcon(iconName)
    readonly property real hue: {
        let h = 0
        for (let i = 0; i < label.length; i++) h = (h * 31 + label.charCodeAt(i)) % 360
        return h / 360
    }
    implicitWidth: Theme.tileSize
    implicitHeight: Theme.tileSize
    radius: Theme.radiusMd
    color: monogram ? Qt.hsla(hue, 0.55, Theme.dark ? 0.62 : 0.5, Theme.dark ? 0.2 : 0.14) : Theme.raised
    opacity: dim
    Behavior on opacity { NumberAnimation { duration: Theme.standard } }

    Kirigami.Icon {
        id: icon
        anchors.centerIn: parent
        width: Math.round(root.width * 0.6)
        height: width
        source: root.iconName
        fallback: ""
        visible: !root.monogram
    }
    Text {
        anchors.centerIn: parent
        visible: root.monogram
        text: root.label.charAt(0).toUpperCase()
        font.family: Theme.display
        font.pointSize: Theme.leadSize
        font.weight: Font.DemiBold
        color: Qt.hsla(root.hue, 0.6, Theme.dark ? 0.78 : 0.36, 1)
    }
}
