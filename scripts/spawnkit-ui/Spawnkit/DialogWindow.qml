// The frame every Spawnkit dialog shares: a raised card with its own rounded corners and shadow,
// floating over the desktop without a system titlebar. The header holds an optional mark, the
// heading, a subtitle and a close button and can be dragged; the body follows; the footer holds
// buttons with the primary one last. accept(result) and reject() play the exit before ending.
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Spawnkit

Window {
    id: root
    property string heading
    property string subtitle
    // An item drawn before the heading, such as an app mark.
    property alias mark: markSlot.data
    // The dialog's body, between the header and the buttons.
    default property alias content: body.data
    // Buttons on the right; the last one is the primary action.
    property alias actions: actionRow.data
    // Items on the left of the footer, such as a secondary choice.
    property alias leadingActions: leadingRow.data
    property int preferredWidth: 580
    property bool closable: true
    readonly property int pad: Theme.shadowPad

    flags: Qt.Dialog | Qt.FramelessWindowHint
    color: "transparent"
    title: heading
    width: Math.max(preferredWidth, footer.implicitWidth + Theme.inset * 2) + pad * 2
    height: Math.min(layout.implicitHeight + Theme.inset * 2, Screen.desktopAvailableHeight * 0.85) + pad * 2
    visible: true

    property var pendingResult
    property bool leaving: false
    function accept(result) {
        if (leaving) return
        leaving = true
        pendingResult = result
        leave.start()
    }
    function reject() {
        if (leaving) return
        leaving = true
        pendingResult = undefined
        leave.start()
    }
    onClosing: close => {
        if (!leaving) { close.accepted = false; reject() }
    }
    Shortcut {
        sequences: [StandardKey.Cancel]
        enabled: root.closable
        onActivated: root.reject()
    }

    Item {
        id: stage
        anchors.fill: parent
        opacity: 0
        scale: 0.96
        transformOrigin: Item.Center
        Component.onCompleted: enter.start()

        ParallelAnimation {
            id: enter
            NumberAnimation { target: stage; property: "opacity"; to: 1; duration: Theme.standard; easing.type: Easing.OutCubic }
            NumberAnimation { target: stage; property: "scale"; to: 1; duration: Theme.slow; easing.type: Easing.OutQuint }
        }
        SequentialAnimation {
            id: leave
            ParallelAnimation {
                NumberAnimation { target: stage; property: "opacity"; to: 0; duration: Theme.quick; easing.type: Easing.InCubic }
                NumberAnimation { target: stage; property: "scale"; to: 0.97; duration: Theme.quick; easing.type: Easing.InCubic }
            }
            ScriptAction { script: root.pendingResult === undefined ? dialog.dismiss() : dialog.finish(root.pendingResult) }
        }

        // The card's silhouette, rendered only through the shadow effect.
        Item {
            id: silhouette
            anchors { fill: parent; margins: root.pad }
            visible: false
            Rectangle { anchors.fill: parent; radius: Theme.radiusCard; color: Theme.surface }
        }
        MultiEffect {
            source: silhouette
            anchors.fill: silhouette
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowBlur: 1
            shadowVerticalOffset: 16
            shadowScale: 1.0
            autoPaddingEnabled: true
        }

        Rectangle {
            id: card
            anchors { fill: parent; margins: root.pad }
            radius: Theme.radiusCard
            color: Theme.surface
            border.width: 1
            border.color: Theme.edge

            // A faint light from above, so the card reads as a lit surface rather than a flat fill.
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
                height: 120
                radius: Theme.radiusCard - 1
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(1, 1, 1, Theme.dark ? 0.035 : 0.0) }
                    GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
                }
            }

            ColumnLayout {
                id: layout
                anchors { fill: parent; margins: Theme.inset }
                spacing: 0

                RowLayout {
                    id: header
                    Layout.fillWidth: true
                    spacing: Theme.s4
                    DragHandler {
                        target: null
                        onActiveChanged: if (active) root.startSystemMove()
                    }
                    Item {
                        id: markSlot
                        Layout.alignment: Qt.AlignTop
                        visible: children.length > 0
                        implicitWidth: childrenRect.width
                        implicitHeight: childrenRect.height
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.s1
                        Text {
                            Layout.fillWidth: true
                            text: root.heading
                            wrapMode: Text.Wrap
                            font.family: Theme.display
                            font.pointSize: Theme.titleSize
                            font.weight: Font.DemiBold
                            font.letterSpacing: -0.4
                            color: Theme.text
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: text.length > 0
                            text: root.subtitle
                            wrapMode: Text.Wrap
                            lineHeight: 1.25
                            font.family: Theme.font
                            font.pointSize: Theme.base
                            color: Theme.textSecondary
                        }
                    }
                    IconButton {
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: -4
                        Layout.rightMargin: -6
                        visible: root.closable
                        iconName: "window-close-symbolic"
                        tooltip: "Close (Esc)"
                        onClicked: root.reject()
                    }
                }

                Item {
                    id: body
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.topMargin: children.length ? Theme.s6 : 0
                    implicitHeight: childrenRect.height
                    visible: children.length > 0
                }

                RowLayout {
                    id: footer
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.s6
                    spacing: Theme.s2
                    RowLayout { id: leadingRow; spacing: Theme.s2 }
                    Item { Layout.fillWidth: true }
                    RowLayout { id: actionRow; spacing: Theme.s2 }
                }
            }
        }
    }
}
