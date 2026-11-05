// The machine's load in one popup: an icon in the panel that opens, on click, a Spawnkit card with
// processor, graphics, memory, swap and disk use. It polls `spawnkit-stats` (the same JSON agents
// read) only while the card is open.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import "Spawnkit"

PlasmoidItem {
    id: root

    readonly property string statsCommand: "@stats@ --interval 0.6"
    property var stats: null

    Plasmoid.icon: "speedometer-symbolic"
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    toolTipMainText: i18n("System stats")
    toolTipSubText: i18n("Click for processor, graphics, memory and disk use")

    onExpandedChanged: if (root.expanded) poll()

    function poll() {
        if (!runner.connectedSources.length)
            runner.connectSource(statsCommand)
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            try {
                root.stats = JSON.parse(data.stdout)
            } catch (err) {
                root.stats = null
            }
            if (root.expanded)
                next.restart()
        }
    }
    Timer {
        id: next
        interval: 1000
        onTriggered: root.poll()
    }

    function gib(bytes) {
        const g = bytes / 1073741824
        return g >= 100 ? g.toFixed(0) : g.toFixed(1)
    }
    function share(part) {
        return part && part.total_bytes > 0 ? 100 * part.used_bytes / part.total_bytes : 0
    }
    // Accent while comfortable, amber when high, red when nearly full or hot.
    function tone(value, high, critical) {
        return value >= critical ? Theme.negative : value >= high ? Theme.caution : Theme.accent
    }

    component Metric: ColumnLayout {
        id: metric
        property string label
        property string detail
        property string value
        property real percent: -1
        property color fill: root.tone(percent, 75, 92)
        property string chip
        property color chipTone: Theme.textTertiary
        spacing: Theme.s2
        Layout.fillWidth: true

        RowLayout {
            spacing: Theme.s2
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                Text {
                    text: metric.label
                    font.family: Theme.font
                    font.pointSize: Theme.base
                    font.weight: Font.Medium
                    color: Theme.text
                }
                Text {
                    visible: text.length > 0
                    text: metric.detail
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    font.family: Theme.font
                    font.pointSize: Theme.microSize
                    color: Theme.textTertiary
                }
            }
            Chip {
                visible: metric.chip.length > 0
                text: metric.chip
                tone: metric.chipTone
            }
            Text {
                visible: text.length > 0
                text: metric.value
                font.family: Theme.display
                font.pointSize: Theme.leadSize * 1.15
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: Theme.text
                horizontalAlignment: Text.AlignRight
                Layout.minimumWidth: Theme.s7 + Theme.s5
            }
        }
        Rectangle {
            visible: metric.percent >= 0
            Layout.fillWidth: true
            implicitHeight: 6
            radius: 3
            color: Theme.raised
            Rectangle {
                width: parent.width * Math.max(0, Math.min(100, metric.percent)) / 100
                height: parent.height
                radius: 3
                color: metric.fill
                Behavior on width { enabled: Theme.motion; NumberAnimation { duration: Theme.standard; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: Theme.standard } }
            }
        }
    }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 21
        Layout.preferredHeight: card.implicitHeight + Theme.s5 * 2
        Layout.minimumWidth: Layout.preferredWidth
        Layout.minimumHeight: Layout.preferredHeight

        ColumnLayout {
            id: card
            anchors.fill: parent
            anchors.margins: Theme.s5
            spacing: Theme.s4

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: i18n("System")
                    font.family: Theme.display
                    font.pointSize: Theme.titleSize * 0.8
                    font.weight: Font.DemiBold
                    color: Theme.text
                    Layout.fillWidth: true
                }
                Spinner {
                    visible: root.stats === null
                }
            }

            SectionLabel { text: i18n("Processor and graphics") }

            Metric {
                readonly property var cpu: root.stats ? root.stats.cpu : null
                label: i18n("Processor")
                detail: cpu ? i18np("%1 thread", "%1 threads", cpu.cores) : ""
                value: cpu ? Math.round(cpu.usage_percent) + "%" : "–"
                percent: cpu ? cpu.usage_percent : 0
                chip: cpu && cpu.temperature_c !== null ? Math.round(cpu.temperature_c) + " °C" : ""
                chipTone: cpu ? root.tone(cpu.temperature_c, 80, 92) : Theme.textTertiary
            }

            Repeater {
                model: root.stats ? root.stats.gpus : []
                delegate: Metric {
                    required property var modelData
                    readonly property bool active: modelData.state === "active" && modelData.usage_percent !== undefined
                    label: modelData.kind === "discrete" ? i18n("Graphics card") : i18n("Graphics")
                    detail: modelData.name
                    value: active ? Math.round(modelData.usage_percent) + "%" : ""
                    percent: active ? modelData.usage_percent : -1
                    chip: modelData.state === "windows" ? i18n("In Windows")
                        : modelData.state === "asleep" ? i18n("Asleep")
                        : modelData.state === "off" ? i18n("Off")
                        : modelData.temperature_c !== undefined ? Math.round(modelData.temperature_c) + " °C" : ""
                    chipTone: modelData.state === "windows" ? Theme.accent
                        : modelData.temperature_c !== undefined ? root.tone(modelData.temperature_c, 80, 90)
                        : Theme.textTertiary
                }
            }

            SectionLabel { text: i18n("Memory and storage") }

            Metric {
                readonly property var part: root.stats ? root.stats.memory : null
                label: i18n("Memory")
                detail: part ? i18n("%1 of %2 GiB", root.gib(part.used_bytes), root.gib(part.total_bytes)) : ""
                value: part ? Math.round(root.share(part)) + "%" : "–"
                percent: root.share(part)
            }
            Metric {
                readonly property var part: root.stats ? root.stats.swap : null
                label: i18n("Swap")
                detail: part ? i18n("%1 of %2 GiB", root.gib(part.used_bytes), root.gib(part.total_bytes)) : ""
                value: part ? Math.round(root.share(part)) + "%" : "–"
                percent: root.share(part)
            }
            Metric {
                readonly property var part: root.stats ? root.stats.disk : null
                label: i18n("Disk")
                detail: part ? i18n("%1 of %2 GiB used on %3", root.gib(part.used_bytes), root.gib(part.total_bytes), part.path) : ""
                value: part ? Math.round(root.share(part)) + "%" : "–"
                percent: root.share(part)
                fill: root.tone(percent, 85, 95)
            }
        }
    }
}
