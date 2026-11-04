// The clock reads events from spawnkit-calendar's local copy, which a user timer syncs
// from Google; opening the popup reloads it.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string calendarCommand: "@calendar@"
    property date now: new Date()
    property var byDay: ({})
    property string synced: ""
    property bool syncing: false

    function dayKey(d) { return Qt.formatDate(d, "yyyy-MM-dd") }

    function index(events) {
        const days = {}
        for (const e of events) {
            const first = new Date(e.start.slice(0, 10) + "T00:00:00")
            let last = new Date(e.end.slice(0, 10) + "T00:00:00")
            if (e.allDay || last < first) last.setDate(last.getDate() - 1)
            if (last < first) last = first
            for (let d = new Date(first), n = 0; d <= last && n < 62; d.setDate(d.getDate() + 1), n++) {
                const k = dayKey(d)
                ;(days[k] = days[k] || []).push(e)
            }
        }
        byDay = days
    }

    function reload() { runner.connectSource(calendarCommand + " events") }
    function sync() {
        syncing = true
        runner.connectSource(calendarCommand + " sync")
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            if (source.endsWith(" sync")) {
                root.syncing = false
                root.reload()
                return
            }
            try {
                const parsed = JSON.parse(data.stdout)
                root.synced = parsed.synced || ""
                root.index(parsed.events)
            } catch (err) {
                root.synced = ""
            }
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const before = root.dayKey(root.now)
            root.now = new Date()
            if (root.dayKey(root.now) !== before) root.reload()
        }
    }
    Timer {
        interval: 5 * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.reload()
    }

    onExpandedChanged: if (root.expanded) reload()
    toolTipMainText: Qt.formatDate(now, Qt.locale().dateFormat(Locale.LongFormat))
    toolTipSubText: ""
    preferredRepresentation: compactRepresentation

    compactRepresentation: MouseArea {
        Layout.minimumWidth: column.implicitWidth + Kirigami.Units.largeSpacing
        Layout.preferredWidth: Layout.minimumWidth
        onClicked: root.expanded = !root.expanded

        ColumnLayout {
            id: column
            anchors.centerIn: parent
            spacing: 0
            PlasmaComponents.Label {
                Layout.alignment: Qt.AlignHCenter
                text: Qt.formatTime(root.now, Qt.locale().timeFormat(Locale.ShortFormat))
            }
            PlasmaComponents.Label {
                Layout.alignment: Qt.AlignHCenter
                text: Qt.formatDate(root.now, Qt.locale().dateFormat(Locale.ShortFormat))
                font: Kirigami.Theme.smallFont
            }
        }
    }

    fullRepresentation: ColumnLayout {
        id: popup
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 30
        spacing: Kirigami.Units.smallSpacing

        property date month: new Date(root.now.getFullYear(), root.now.getMonth(), 1)
        property date selected: root.now
        readonly property var dayEvents: root.byDay[root.dayKey(selected)] || []

        Connections {
            target: root
            function onExpandedChanged() {
                if (root.expanded) {
                    popup.month = new Date(root.now.getFullYear(), root.now.getMonth(), 1)
                    popup.selected = root.now
                }
            }
        }

        RowLayout {
            PlasmaExtras.Heading {
                Layout.fillWidth: true
                level: 2
                text: Qt.locale().standaloneMonthName(popup.month.getMonth()) + " " + popup.month.getFullYear()
            }
            PlasmaComponents.ToolButton {
                icon.name: "go-previous"
                onClicked: popup.month = new Date(popup.month.getFullYear(), popup.month.getMonth() - 1, 1)
            }
            PlasmaComponents.ToolButton {
                text: i18n("Today")
                onClicked: {
                    popup.month = new Date(root.now.getFullYear(), root.now.getMonth(), 1)
                    popup.selected = root.now
                }
            }
            PlasmaComponents.ToolButton {
                icon.name: "go-next"
                onClicked: popup.month = new Date(popup.month.getFullYear(), popup.month.getMonth() + 1, 1)
            }
        }

        GridLayout {
            id: grid
            Layout.fillWidth: true
            columns: 7
            rowSpacing: 0
            columnSpacing: 0
            readonly property int firstDay: Qt.locale().firstDayOfWeek % 7
            readonly property date start: {
                const d = new Date(popup.month)
                d.setDate(1 - ((d.getDay() - firstDay + 7) % 7))
                return d
            }

            Repeater {
                model: 7
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    opacity: 0.6
                    text: Qt.locale().dayName((grid.firstDay + index) % 7, Locale.NarrowFormat)
                }
            }
            Repeater {
                model: 42
                delegate: MouseArea {
                    id: cell
                    readonly property date day: new Date(grid.start.getFullYear(), grid.start.getMonth(), grid.start.getDate() + index)
                    readonly property string key: root.dayKey(day)
                    readonly property bool isToday: key === root.dayKey(root.now)
                    readonly property bool isSelected: key === root.dayKey(popup.selected)
                    readonly property var events: root.byDay[key] || []
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 2
                    hoverEnabled: true
                    onClicked: popup.selected = day

                    Rectangle {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, parent.height) - 2
                        height: width
                        radius: width / 2
                        color: cell.isToday ? Kirigami.Theme.highlightColor
                            : cell.isSelected || cell.containsMouse ? Qt.alpha(Kirigami.Theme.highlightColor, 0.25) : "transparent"
                        border.color: cell.isSelected && !cell.isToday ? Kirigami.Theme.highlightColor : "transparent"
                    }
                    PlasmaComponents.Label {
                        anchors.centerIn: parent
                        text: cell.day.getDate()
                        color: cell.isToday ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                        opacity: cell.day.getMonth() === popup.month.getMonth() ? 1 : 0.4
                    }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 2
                        spacing: 2
                        Repeater {
                            model: Math.min(cell.events.length, 3)
                            Rectangle {
                                width: 4
                                height: 4
                                radius: 2
                                color: cell.events[index].color
                            }
                        }
                    }
                }
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        PlasmaExtras.Heading {
            level: 4
            text: Qt.formatDate(popup.selected, Qt.locale().dateFormat(Locale.LongFormat))
        }

        PlasmaComponents.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            ListView {
                id: agenda
                model: popup.dayEvents
                spacing: Kirigami.Units.smallSpacing
                clip: true
                delegate: PlasmaComponents.ItemDelegate {
                    width: ListView.view.width
                    onClicked: if (modelData.link) Qt.openUrlExternally(modelData.link)
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            Layout.preferredWidth: 4
                            Layout.fillHeight: true
                            radius: 2
                            color: modelData.color
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: modelData.summary
                                elide: Text.ElideRight
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                                elide: Text.ElideRight
                                text: (modelData.allDay ? i18n("All day")
                                    : Qt.formatTime(new Date(modelData.start), Qt.locale().timeFormat(Locale.ShortFormat))
                                      + " – " + Qt.formatTime(new Date(modelData.end), Qt.locale().timeFormat(Locale.ShortFormat)))
                                    + " · " + modelData.calendar
                            }
                        }
                        PlasmaComponents.ToolButton {
                            visible: modelData.meet !== ""
                            icon.name: "camera-video"
                            PlasmaComponents.ToolTip.text: i18n("Join video call")
                            PlasmaComponents.ToolTip.visible: hovered
                            onClicked: Qt.openUrlExternally(modelData.meet)
                        }
                    }
                }
                PlasmaExtras.PlaceholderMessage {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 2
                    visible: agenda.count === 0
                    text: i18n("No events")
                }
            }
        }

        RowLayout {
            PlasmaComponents.Label {
                Layout.fillWidth: true
                opacity: 0.6
                font: Kirigami.Theme.smallFont
                text: root.syncing ? i18n("Syncing with Google Calendar…")
                    : root.synced ? i18n("Google Calendar, synced %1", Qt.formatTime(new Date(root.synced), Qt.locale().timeFormat(Locale.ShortFormat)))
                    : i18n("Not synced yet")
            }
            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"
                enabled: !root.syncing
                PlasmaComponents.ToolTip.text: i18n("Sync now")
                PlasmaComponents.ToolTip.visible: hovered
                onClicked: root.sync()
            }
            PlasmaComponents.ToolButton {
                icon.name: "internet-web-browser"
                PlasmaComponents.ToolTip.text: i18n("Open Google Calendar")
                PlasmaComponents.ToolTip.visible: hovered
                onClicked: Qt.openUrlExternally("https://calendar.google.com/calendar/r/day/"
                    + Qt.formatDate(popup.selected, "yyyy/M/d"))
            }
        }
    }
}
