// Walks the user through handing the RTX to Windows: the programs holding it, grouped by how
// they let go, then the closing itself, shown live in the same window.
//
// Input: {holders: [{pid, name, command, closable, release}], without_rtx}; release is "close",
// "logout" or "service". The dialog sends {action: "close", pids} or {action: "without_rtx"},
// then follows the caller's messages: {event: "closing", pids}, {event: "progress", left: [pid]},
// {event: "stuck", pids} (answered with {action: "force"} or {action: "wait"}) and
// {event: "done", left: [{pid, name, release}]}, after which it finishes with {action: "started"},
// {action: "logout"} or {action: "later"}.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Spawnkit

DialogWindow {
    id: root
    readonly property var holders: dialog.input.holders.slice()
        .sort((a, b) => (b.closable - a.closable) || a.name.localeCompare(b.name) || a.pid - b.pid)
    readonly property var willClose: holders.filter(h => h.closable)
    readonly property var atLogout: holders.filter(h => h.release === "logout")
    readonly property var stuck: holders.filter(h => h.release === "service")
    readonly property bool blocked: stuck.length > 0
    property var chosen: willClose.map(h => h.pid)
    readonly property var leftOpen: willClose.filter(h => !chosen.includes(h.pid))

    // What the dialog is doing: "review", "closing", "stuck", "logout", "waiting" or "starting".
    property string phase: "review"
    property var closing: []     // pids being closed now
    property var closed: []      // pids that have gone
    property var stubborn: []    // pids that ignored the close
    property var left: []        // holders still there once closing is over

    // Programs whose names do not match their icon's name.
    readonly property var icons: ({
        "chrome": "google-chrome", "chromium": "chromium", "kwin_wayland": "kwin", "kwin_x11": "kwin", "Xwayland": "xorg", "Xorg": "xorg",
        "gnome-shell": "preferences-system-windows",
        "python3": "text-x-python", "qemu-system-x86_64": "qemu"
    })
    readonly property var statuses: ({
        "close": ["Closes now", Theme.positive],
        "logout": ["Needs a logout", Theme.caution],
        "service": ["System service", Theme.negative]
    })

    heading: phase === "logout" ? "Log out to start Windows"
           : phase === "waiting" ? "Windows is waiting"
           : phase === "starting" ? "Starting Windows" : "Start Windows"
    subtitle: phase === "review" ? (blocked ? "A system service is holding the RTX." : "Some programs are still using the RTX.")
            : phase === "closing" ? "Closing " + names(closing.map(byPid)) + "…"
            : phase === "stuck" ? names(stubborn.map(byPid)) + " didn't close."
            : phase === "logout" ? names(left.filter(h => h.release === "logout")) + (left.filter(h => h.release === "logout").length === 1 ? " releases" : " release") + " the RTX when your session ends."
            : phase === "waiting" ? "It starts as soon as " + names(left) + (left.length === 1 ? " closes." : " close.")
            : "The RTX is free; the VM is powering on."
    closable: phase !== "closing" && phase !== "starting"

    function byPid(pid) { return holders.find(h => h.pid === pid) }
    function toggle(pid, on) { chosen = on ? chosen.concat([pid]) : chosen.filter(p => p !== pid) }
    function names(list) {
        const n = list.map(h => h.name).filter((v, i, a) => a.indexOf(v) === i)
        return n.length < 2 ? n.join("") : n.slice(0, -1).join(", ") + " and " + n[n.length - 1]
    }
    function count(n, word) { return n + " " + word + (n === 1 ? "" : "s") }
    function rowPhase(pid) {
        if (closed.includes(pid)) return "closed"
        if (stubborn.includes(pid) && (phase === "stuck" || phase === "waiting")) return "stuck"
        if (closing.includes(pid)) return "closing"
        return "idle"
    }

    Connections {
        target: dialog
        function onReceived(message) {
            if (message.event === "closing") {
                root.closing = message.pids; root.stubborn = []; root.phase = "closing"
            } else if (message.event === "progress") {
                root.closed = root.closing.filter(p => !message.left.includes(p))
            } else if (message.event === "stuck") {
                root.closed = root.closing.filter(p => !message.pids.includes(p))
                root.stubborn = message.pids; root.phase = "stuck"
            } else if (message.event === "done") {
                root.closed = root.closing.filter(p => !message.left.some(h => h.pid === p))
                root.stubborn = root.closing.filter(p => message.left.some(h => h.pid === p))
                root.left = message.left
                root.phase = message.left.some(h => h.release === "logout") ? "logout"
                           : message.left.length ? "waiting" : "starting"
                if (root.phase === "starting") settle.start()
            }
        }
    }
    Timer { id: settle; interval: Theme.motion ? 900 : 0; onTriggered: root.accept({action: "started"}) }

    // The path to Windows, as steps.
    readonly property var steps: {
        const done = phase !== "review"
        const closingDone = phase === "logout" || phase === "waiting" || phase === "starting"
        const list = []
        if (blocked)
            list.push({label: names(stuck) + " holds the RTX", state: "blocked"})
        else if (chosen.length || closing.length)
            list.push({label: "Close " + count(closing.length || chosen.length, "program"),
                       state: closingDone ? "done" : done ? "active" : "active"})
        if (atLogout.length && !blocked)
            list.push({label: "Log out", state: phase === "logout" ? "active" : "upcoming"})
        if (leftOpen.length && !blocked && !closing.length)
            list.push({label: "Close " + names(leftOpen) + " yourself", state: "upcoming"})
        list.push({label: "Windows starts", state: phase === "starting" ? "active" : blocked ? "upcoming" : "upcoming"})
        return list
    }

    component HolderRow: ListRow {
        required property var modelData
        Layout.fillWidth: true
        checkable: modelData.closable && root.phase === "review" && !root.blocked
        checked: root.chosen.includes(modelData.pid)
        onToggled: root.toggle(modelData.pid, checked)
        iconName: root.icons[modelData.name] || modelData.name.toLowerCase()
        title: modelData.name
        secondary: modelData.command
        status: rowPhase(modelData.pid) === "closed" ? "Closed"
              : rowPhase(modelData.pid) === "stuck" ? "Still open"
              : rowPhase(modelData.pid) === "closing" ? "Closing"
              : root.statuses[modelData.release][0]
        statusColor: rowPhase(modelData.pid) === "closed" ? Theme.positive
                   : rowPhase(modelData.pid) === "stuck" ? Theme.caution
                   : rowPhase(modelData.pid) === "closing" ? Theme.accent
                   : root.statuses[modelData.release][1]
        tooltip: "PID " + modelData.pid + "\n" + modelData.command
        phase: rowPhase(modelData.pid)
    }

    mark: Rectangle {
        width: 44; height: 44
        radius: Theme.radiusLg
        gradient: Gradient {
            GradientStop { position: 0; color: Theme.accentBright }
            GradientStop { position: 1; color: Theme.accent }
        }
        Rectangle {
            anchors.fill: parent; radius: parent.radius; color: "transparent"
            border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.22)
        }
        Kirigami.Icon {
            anchors.centerIn: parent
            width: 24; height: 24
            source: "computer-symbolic"
            isMask: true
            color: Theme.accentText
        }
    }

    ColumnLayout {
        anchors { left: parent.left; right: parent.right }
        spacing: 0

        Steps {
            Layout.fillWidth: true
            Layout.leftMargin: 2
            steps: root.steps
        }

        QQC2.ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.topMargin: Theme.s5
            Layout.preferredHeight: Math.min(groups.implicitHeight, 5 * Theme.rowHeight + 60)
            Layout.leftMargin: -Theme.s3
            Layout.rightMargin: -Theme.s3
            contentWidth: availableWidth
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            ColumnLayout {
                id: groups
                width: scroll.availableWidth
                spacing: 0
                SectionLabel {
                    visible: root.willClose.length > 0
                    Layout.leftMargin: Theme.s3
                    Layout.bottomMargin: Theme.s2
                    text: root.blocked ? "Your programs"
                        : root.phase === "review" ? "Spawnkit will close"
                        : root.closing.every(p => root.closed.includes(p)) ? "Closed" : "Closing"
                    count: root.willClose.length
                }
                Repeater { model: root.willClose; delegate: HolderRow {} }
                SectionLabel {
                    visible: root.atLogout.length + root.stuck.length > 0
                    Layout.leftMargin: Theme.s3
                    Layout.topMargin: root.willClose.length ? Theme.s5 : 0
                    Layout.bottomMargin: Theme.s2
                    text: "Can't be closed from here"
                    count: root.atLogout.length + root.stuck.length
                }
                Repeater { model: root.holders.filter(h => !h.closable); delegate: HolderRow {} }
            }
        }

        // What happens next, as a callout whose tone follows the situation.
        Callout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.s5
            tone: root.phase === "stuck" ? "caution"
                : root.phase === "closing" ? "accent"
                : root.phase === "starting" ? "positive"
                : root.blocked ? "negative"
                : root.phase === "logout" || (root.phase === "review" && root.atLogout.length) ? "caution" : "neutral"
            text: root.phase === "stuck"
                    ? "Force-quitting " + root.names(root.stubborn.map(root.byPid)) + " loses anything unsaved in " + (root.stubborn.length === 1 ? "it." : "them.")
                : root.phase === "closing"
                    ? "Waiting up to ten seconds for each program to exit."
                : root.phase === "logout"
                    ? "Windows starts by itself once you log out. Log back in afterwards and open Windows (Looking Glass)."
                : root.phase === "waiting"
                    ? "Close " + root.names(root.left) + " yourself; Windows then starts by itself. Open Windows (Looking Glass) once it is up."
                : root.phase === "starting"
                    ? "Windows (Looking Glass) opens in a moment."
                : root.blocked
                    ? "A logout does not release it. Stop the service and try again, or start Windows without the RTX."
                : root.atLogout.length
                    ? "Windows starts after you log out, when " + root.names(root.atLogout) + " let go."
                : root.leftOpen.length
                    ? "Windows waits until you close " + root.names(root.leftOpen) + " yourself."
                    : "Windows starts as soon as these close. Unsaved work in them is lost."
            // The command that unblocks a service holder, ready to copy.
            Rectangle {
                visible: root.blocked && root.phase === "review"
                Layout.fillWidth: true
                implicitHeight: 32
                radius: Theme.radiusSm
                color: Theme.dark ? Qt.rgba(0, 0, 0, 0.3) : Qt.rgba(0, 0, 0, 0.05)
                RowLayout {
                    anchors { fill: parent; leftMargin: Theme.s3; rightMargin: Theme.s1 }
                    spacing: Theme.s2
                    Text {
                        Layout.fillWidth: true
                        text: "sudo systemctl stop " + root.stuck.map(h => h.name).filter((v, i, a) => a.indexOf(v) === i).join(" ")
                        elide: Text.ElideRight
                        font.family: Theme.mono
                        font.pointSize: Theme.monoSize
                        color: Theme.text
                    }
                    IconButton {
                        iconName: "edit-copy-symbolic"
                        tooltip: "Copy"
                        size: 26
                        onClicked: dialog.copy(parent.children[0].text)
                    }
                }
            }
        }
    }

    leadingActions: [
        Button {
            visible: dialog.input.without_rtx && !root.blocked && root.phase === "review"
            kind: "ghost"
            text: "Start without RTX"
            onClicked: root.accept({action: "without_rtx"})
        }
    ]

    actions: [
        Button {
            visible: root.phase === "review" || root.phase === "closing"
            enabled: root.phase === "review"
            text: "Cancel"
            onClicked: root.reject()
        },
        // With a holder that never lets go, starting without the RTX becomes the main choice.
        Button {
            visible: root.blocked && dialog.input.without_rtx && root.phase === "review"
            kind: "primary"
            defaultButton: true
            text: "Start without RTX"
            onClicked: root.accept({action: "without_rtx"})
        },
        Button {
            visible: !root.blocked && (root.phase === "review" || root.phase === "closing")
            kind: "primary"
            defaultButton: true
            busy: root.phase === "closing"
            text: root.phase === "closing" ? "Closing…"
                : root.chosen.length
                    ? "Close " + root.chosen.length + (root.atLogout.length ? " and continue" : " and start Windows")
                    : root.atLogout.length ? "Continue" : "Start Windows"
            onClicked: dialog.send({action: "close", pids: root.chosen})
        },
        Button {
            visible: root.phase === "stuck"
            text: "Keep waiting"
            onClicked: { root.phase = "closing"; dialog.send({action: "wait"}) }
        },
        Button {
            visible: root.phase === "stuck"
            kind: "danger"
            text: "Force quit"
            onClicked: dialog.send({action: "force"})
        },
        Button {
            visible: root.phase === "logout"
            text: "Later"
            onClicked: root.accept({action: "later"})
        },
        Button {
            visible: root.phase === "logout"
            kind: "primary"
            defaultButton: true
            text: "Log out now"
            onClicked: root.accept({action: "logout"})
        },
        Button {
            visible: root.phase === "waiting"
            kind: "primary"
            defaultButton: true
            text: "OK"
            onClicked: root.accept({action: "later"})
        },
        Button {
            visible: root.phase === "starting"
            kind: "primary"
            busy: true
            text: "Starting…"
        }
    ]
}
