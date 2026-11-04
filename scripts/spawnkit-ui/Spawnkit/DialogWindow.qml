// The frame every Spawnkit dialog shares: one flat surface with a title, an optional subtitle,
// the dialog's content and a row of buttons, the primary one last. No bands, boxes or dividers.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Spawnkit

QQC2.ApplicationWindow {
    id: root
    property string heading
    property string subtitle
    // The dialog's body, between the subtitle and the buttons.
    default property alias content: body.data
    // Buttons on the right; the last one is the primary action.
    property alias actions: actionRow.data
    // Items on the left, such as a secondary choice.
    property alias leadingActions: leadingRow.data

    flags: Qt.Dialog
    title: heading
    color: Theme.surface
    property int preferredWidth: Kirigami.Units.gridUnit * 30
    width: Math.max(preferredWidth, footer.implicitWidth + Theme.s5 * 2)
    height: Math.min(layout.implicitHeight + Theme.s5 * 2, Screen.desktopAvailableHeight * 0.85)
    minimumWidth: Kirigami.Units.gridUnit * 24
    visible: true
    onClosing: dialog.dismiss()

    Shortcut {
        sequences: [StandardKey.Cancel]
        onActivated: dialog.dismiss()
    }

    ColumnLayout {
        id: layout
        anchors { fill: parent; margins: Theme.s5 }
        spacing: 0
        opacity: 0
        transform: Translate { id: shift; y: 6 }
        Component.onCompleted: appear.start()
        ParallelAnimation {
            id: appear
            NumberAnimation { target: layout; property: "opacity"; to: 1; duration: 160; easing.type: Easing.OutCubic }
            NumberAnimation { target: shift; property: "y"; to: 0; duration: 160; easing.type: Easing.OutCubic }
        }

        Text {
            Layout.fillWidth: true
            text: root.heading
            wrapMode: Text.Wrap
            font.family: Theme.font
            font.pointSize: Theme.titleSize
            font.weight: Font.DemiBold
            font.letterSpacing: -0.3
            color: Theme.text
        }
        Text {
            Layout.fillWidth: true
            Layout.topMargin: Theme.s1 + 2
            visible: text.length > 0
            text: root.subtitle
            wrapMode: Text.Wrap
            lineHeight: 1.15
            font.family: Theme.font
            font.pointSize: Theme.base
            color: Theme.textMuted
        }

        Item {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: children.length ? Theme.s4 : 0
            implicitHeight: childrenRect.height
            visible: children.length > 0
        }

        RowLayout {
            id: footer
            Layout.fillWidth: true
            Layout.topMargin: Theme.s5
            spacing: Theme.s2
            RowLayout { id: leadingRow; spacing: Theme.s2 }
            Item { Layout.fillWidth: true }
            RowLayout { id: actionRow; spacing: Theme.s2 }
        }
    }
}
