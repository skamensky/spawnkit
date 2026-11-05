// A status pill: a tinted capsule with a dot and a short label in the status colour.
import QtQuick
import Spawnkit

Rectangle {
    id: root
    property string text
    property color tone: Theme.textTertiary
    property color tint: Qt.alpha(tone, Theme.dark ? 0.14 : 0.10)
    property bool dot: true
    implicitWidth: row.implicitWidth + Theme.s3 * 2 - (dot ? 2 : 0)
    implicitHeight: 24
    radius: height / 2
    color: tint
    Behavior on color { ColorAnimation { duration: Theme.standard } }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.dot
            width: 6; height: 6; radius: 3
            color: root.tone
            Behavior on color { ColorAnimation { duration: Theme.standard } }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            font.family: Theme.font
            font.pointSize: Theme.metaSize
            font.weight: Font.Medium
            font.letterSpacing: 0.1
            color: root.tone
            Behavior on color { ColorAnimation { duration: Theme.standard } }
        }
    }
}
