// An inline message on a tinted panel: an icon, a sentence or two, and optional extra content
// such as a command to copy. tone picks the colour; "neutral" uses the raised surface.
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Spawnkit

Rectangle {
    id: root
    property string tone: "neutral"
    property string iconName: tone === "negative" ? "dialog-error-symbolic"
        : tone === "caution" ? "dialog-warning-symbolic"
        : tone === "positive" ? "checkmark-symbolic" : "dialog-information-symbolic"
    property string text
    default property alias extra: extraSlot.data
    readonly property color accentColor: tone === "negative" ? Theme.negative
        : tone === "caution" ? Theme.caution
        : tone === "positive" ? Theme.positive
        : tone === "accent" ? Theme.accent : Theme.textSecondary

    implicitHeight: layout.implicitHeight + Theme.s3 * 2
    radius: Theme.radiusLg
    color: tone === "neutral" ? Theme.raised : Qt.alpha(accentColor, Theme.dark ? 0.12 : 0.08)
    border.width: 1
    border.color: tone === "neutral" ? Theme.hairline : Qt.alpha(accentColor, 0.22)
    Behavior on color { ColorAnimation { duration: Theme.standard } }

    RowLayout {
        id: layout
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.s3 }
        spacing: Theme.s3
        Kirigami.Icon {
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 1
            implicitWidth: 18
            implicitHeight: 18
            source: root.iconName
            isMask: true
            color: root.accentColor
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.s2
            Text {
                Layout.fillWidth: true
                text: root.text
                wrapMode: Text.Wrap
                lineHeight: 1.25
                font.family: Theme.font
                font.pointSize: Theme.base
                color: Theme.text
            }
            ColumnLayout {
                id: extraSlot
                Layout.fillWidth: true
                visible: children.length > 0
                spacing: Theme.s2
            }
        }
    }
}
