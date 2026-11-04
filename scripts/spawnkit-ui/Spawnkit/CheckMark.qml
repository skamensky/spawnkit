// The checkbox drawn inside a ListRow: a rounded square that fills with the accent when checked.
import QtQuick
import org.kde.kirigami as Kirigami
import Spawnkit

Rectangle {
    id: root
    property bool checked
    implicitWidth: 18
    implicitHeight: 18
    radius: Theme.radiusSm
    color: checked ? Theme.accent : "transparent"
    border.width: checked ? 0 : 1.5
    border.color: Theme.hairline
    Behavior on color { ColorAnimation { duration: Theme.fast } }

    Kirigami.Icon {
        anchors.centerIn: parent
        width: 14
        height: 14
        source: "checkmark-symbolic"
        isMask: true
        color: Theme.accentText
        opacity: root.checked ? 1 : 0
        scale: root.checked ? 1 : 0.6
        Behavior on opacity { NumberAnimation { duration: Theme.fast } }
        Behavior on scale { NumberAnimation { duration: Theme.normal; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }
    }
}
