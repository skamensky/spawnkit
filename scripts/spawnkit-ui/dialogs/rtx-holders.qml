// Lists the programs holding the RTX before Windows starts. Input: {holders: [{pid, name,
// command, closable, release}], without_rtx}; release is "close", "logout" or "service".
// Result: {action: "close", pids} or {action: "without_rtx"}.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Spawnkit

DialogWindow {
    id: root
    readonly property var holders: dialog.input.holders.slice()
        .sort((a, b) => (b.closable - a.closable) || a.name.localeCompare(b.name) || a.pid - b.pid)
    readonly property var closable: holders.filter(h => h.closable)
    readonly property var waiting: holders.filter(h => !h.closable)
    property var chosen: closable.map(h => h.pid)
    property bool details: false
    readonly property var stuck: holders.filter(h => h.release === "service")
    readonly property var atLogout: holders.filter(h => h.release === "logout")
    readonly property var leftOpen: closable.filter(h => !chosen.includes(h.pid))
    readonly property bool canStart: stuck.length === 0

    // Programs whose names do not match their icon's name.
    readonly property var icons: ({
        "kwin_wayland": "kwin", "kwin_x11": "kwin", "Xwayland": "xorg", "Xorg": "xorg",
        "gnome-shell": "preferences-system-windows", "nvidia-powerd": "nvidia",
        "nvidia-persistenced": "nvidia", "python3": "text-x-python", "qemu-system-x86_64": "qemu"
    })
    readonly property var statuses: ({
        "close": ["Closes now", Theme.positive],
        "logout": ["Releases at logout", Theme.neutral],
        "service": ["System service", Theme.negative]
    })

    heading: "Start Windows"
    subtitle: "Some programs are still using the RTX."

    function toggle(pid, on) {
        chosen = on ? chosen.concat([pid]) : chosen.filter(p => p !== pid)
    }

    function names(list) {
        const n = list.map(h => h.name).filter((v, i, a) => a.indexOf(v) === i)
        return n.length < 2 ? n.join("") : n.slice(0, -1).join(", ") + " and " + n[n.length - 1]
    }

    component GroupLabel: Text {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.s3
        Layout.bottomMargin: Theme.s1 + 2
        font.family: Theme.font
        font.pointSize: Theme.metaSize
        font.weight: Font.Medium
        color: Theme.textFaint
    }

    component HolderRow: ListRow {
        required property var modelData
        Layout.fillWidth: true
        checkable: modelData.closable
        checked: root.chosen.includes(modelData.pid)
        onToggled: root.toggle(modelData.pid, checked)
        iconName: root.icons[modelData.name] || modelData.name.toLowerCase()
        title: modelData.name
        status: root.statuses[modelData.release][0]
        statusColor: root.statuses[modelData.release][1]
        detail: "PID " + modelData.pid + "  ·  " + modelData.command
        tooltip: detail
        expanded: root.details
    }

    ColumnLayout {
        anchors { left: parent.left; right: parent.right }
        spacing: 0

        QQC2.ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(groups.implicitHeight, Kirigami.Units.gridUnit * 22)
            Layout.leftMargin: -Theme.s3
            Layout.rightMargin: -Theme.s3
            contentWidth: availableWidth
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            ColumnLayout {
                id: groups
                width: scroll.availableWidth
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.rightMargin: Theme.s3
                    GroupLabel { text: root.closable.length ? "Spawnkit will close" : "Can't be closed from here" }
                    Text {
                        Layout.bottomMargin: Theme.s1 + 2
                        text: root.details ? "Hide details" : "Show details"
                        font.family: Theme.font
                        font.pointSize: Theme.metaSize
                        font.weight: Font.Medium
                        color: detailsHover.hovered ? Theme.text : Theme.textFaint
                        Behavior on color { ColorAnimation { duration: Theme.fast } }
                        HoverHandler { id: detailsHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.details = !root.details }
                    }
                }
                Repeater { model: root.closable; delegate: HolderRow {} }
                GroupLabel {
                    visible: root.waiting.length && root.closable.length
                    Layout.topMargin: root.closable.length ? Theme.s4 : 0
                    text: "Can't be closed from here"
                }
                Repeater { model: root.waiting; delegate: HolderRow {} }
            }
        }

        // What happens next, in one sentence.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.s4
            spacing: Theme.s2 + 2
            Kirigami.Icon {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 1
                implicitWidth: 16
                implicitHeight: 16
                source: root.canStart ? "dialog-information-symbolic" : "dialog-warning-symbolic"
                isMask: true
                color: root.canStart ? Theme.textFaint : Theme.negative
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                lineHeight: 1.15
                font.family: Theme.font
                font.pointSize: Theme.metaSize
                color: Theme.textMuted
                text: !root.canStart
                    ? root.names(root.stuck) + " keeps the RTX even after logout. Start without it, or stop the service and try again."
                    : root.atLogout.length
                        ? "Windows starts after you log out, when " + root.names(root.atLogout) + " let go."
                        : root.leftOpen.length
                            ? "Windows waits until you close " + root.names(root.leftOpen) + " yourself."
                            : "Windows starts as soon as these close. Unsaved work in them is lost."
            }
        }
    }

    leadingActions: [
        ActionButton {
            visible: dialog.input.without_rtx && root.canStart
            text: "Start without RTX"
            onClicked: dialog.finish({action: "without_rtx"})
        }
    ]

    actions: [
        ActionButton {
            text: "Cancel"
            onClicked: dialog.dismiss()
        },
        // With a holder that never lets go, starting without the RTX becomes the main choice.
        ActionButton {
            visible: !root.canStart && dialog.input.without_rtx
            kind: "primary"
            text: "Start without RTX"
            onClicked: dialog.finish({action: "without_rtx"})
        },
        ActionButton {
            visible: root.canStart
            kind: "primary"
            text: root.chosen.length ? "Close " + root.chosen.length + " and start Windows" : "Start Windows"
            onClicked: dialog.finish({action: "close", pids: root.chosen})
        }
    ]
}
