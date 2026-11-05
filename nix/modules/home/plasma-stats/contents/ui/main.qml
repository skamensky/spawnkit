// The machine's load in one popup: an icon in the panel that opens, on click, a Spawnkit card with
// processor, graphics, memory, swap and disk use. It polls `spawnkit-stats` (the same JSON agents
// read) about once a second, only while the card is open. Every number and bar glides to its new
// value over one poll, so updates read as motion rather than jumps. The processor row unfolds into
// a map of its physical cores, one bar per hardware thread; pointing at a core names its threads
// and clock. Below them, the busiest processes with End buttons, and a link to the process window
// (ProcessWindow.qml) for every process.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import "Spawnkit"
import "processes.js" as P

PlasmoidItem {
    id: root

    readonly property string statsPath: "@stats@"
    readonly property string statsCommand: statsPath + " --interval 0.5 --top 8"
    // One poll: the CLI's 0.5 s measurement, its start-up and the pause below.
    readonly property int glide: 950
    property var stats: null
    property bool showCores: false
    property var hoveredCore: null

    // Lists rebuilt only when their length changes, so their delegates (and animations) survive
    // each poll; the delegates read the current values from root.stats.
    readonly property int gpuCount: stats ? stats.gpus.length : 0
    readonly property int threadCount: stats && stats.cpu.threads ? stats.cpu.threads.length : 0
    property var coreGroups: []
    onThreadCountChanged: coreGroups = groupCores()
    // The busiest processes, re-ranked at most every two seconds and never under the pointer.
    property double rankedAt: 0
    property bool holdingTop: false
    readonly property int topShown: 5
    ListModel { id: topModel }
    onStatsChanged: rankTop()
    onHoldingTopChanged: if (!holdingTop) rankedAt = 0
    function rankTop() {
        const procs = stats && stats.processes ? stats.processes : []
        const row = p => ({
            key: "p:" + p.pid + ":" + p.start,
            name: p.name, command: p.command, cpu: p.cpu_percent, memory: p.memory_bytes,
            own: p.own, critical: p.critical, target: P.target(p),
        })
        const now = Date.now()
        if (!holdingTop && now - rankedAt >= 2000) {
            rankedAt = now
            P.sync(topModel, procs.filter(p => p.cpu_percent >= 1).slice(0, topShown).map(row), true)
            return
        }
        // Held: refresh the listed rows' figures where the new reading still has them.
        const byKey = {}
        procs.forEach(p => byKey["p:" + p.pid + ":" + p.start] = p)
        const rows = []
        for (let i = 0; i < topModel.count; i++) {
            const old = topModel.get(i)
            const p = byKey[old.key]
            rows.push(p ? row(p) : {
                key: old.key, name: old.name, command: old.command, cpu: old.cpu, memory: old.memory,
                own: old.own, critical: old.critical, target: old.target,
            })
        }
        P.sync(topModel, rows, false)
    }

    Ender {
        id: processEnder
        stats: root.statsPath
    }
    ProcessWindow {
        id: processWindow
        stats: root.statsPath
        ender: processEnder
        granular: Plasmoid.configuration.granularProcesses
        onGranularRequested: on => Plasmoid.configuration.granularProcesses = on
        visible: false
    }

    Plasmoid.icon: "speedometer-symbolic"
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    toolTipMainText: i18n("System stats")
    toolTipSubText: i18n("Click for processor, graphics, memory and disk use")

    onExpandedChanged: {
        if (root.expanded)
            poll()
        else
            hoveredCore = null
    }

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
                // Keep the last snapshot rather than blanking the card.
            }
            if (root.expanded)
                next.restart()
        }
    }
    Timer {
        id: next
        interval: 350
        onTriggered: root.poll()
    }

    // [{kind, title, cores: [{core, threads: [index into stats.cpu.threads]}]}], performance
    // cores first, each physical core's threads together.
    function groupCores() {
        const threads = stats && stats.cpu.threads ? stats.cpu.threads : []
        const groups = []
        for (const kind of ["performance", "efficiency", null]) {
            const cores = []
            const byCore = {}
            threads.forEach((thread, index) => {
                if (thread.kind !== kind)
                    return
                const key = thread.core === null ? "t" + thread.id : "c" + thread.core
                if (byCore[key] === undefined) {
                    byCore[key] = cores.length
                    cores.push({ core: cores.length + 1, threads: [] })
                }
                cores[byCore[key]].threads.push(index)
            })
            if (cores.length)
                groups.push({
                    kind,
                    title: kind === "performance" ? i18n("Performance cores")
                        : kind === "efficiency" ? i18n("Efficiency cores") : i18n("Cores"),
                    cores,
                })
        }
        return groups
    }
    function thread(index) {
        return stats && stats.cpu.threads ? stats.cpu.threads[index] : null
    }
    function averageGhz(group) {
        let sum = 0, n = 0
        for (const core of group.cores)
            for (const index of core.threads) {
                const t = thread(index)
                if (t && t.mhz) {
                    sum += t.mhz
                    n++
                }
            }
        return n ? (sum / n / 1000).toFixed(1) : ""
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

    // A value that eases to each new reading over one poll.
    component Glide: QtObject {
        property real target: 0
        property real value: target
        Behavior on value {
            enabled: Theme.motion
            NumberAnimation { duration: root.glide; easing.type: Easing.InOutSine }
        }
    }

    component Metric: ColumnLayout {
        id: metric
        property string label
        property string detail
        // -1 hides the value and the bar.
        property real percent: -1
        property bool ready: root.stats !== null
        property real high: 75
        property real critical: 92
        property string chip
        property color chipTone: Theme.textTertiary
        property bool expandable: false
        property bool open: false
        // A hide button that appears on hover.
        property bool hideable: false
        signal toggled()
        signal hideRequested()
        readonly property Glide shown: Glide { target: Math.max(0, metric.percent) }
        spacing: Theme.s2
        Layout.fillWidth: true

        HoverHandler { id: rowHover }

        Item {
            Layout.fillWidth: true
            implicitHeight: header.implicitHeight

            Rectangle {
                visible: metric.expandable
                anchors.fill: parent
                anchors.margins: -Theme.s1
                radius: Theme.radiusSm
                color: press.pressed ? Theme.pressed : hover.hovered ? Theme.hover : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.quick } }
            }
            HoverHandler {
                id: hover
                enabled: metric.expandable
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                id: press
                enabled: metric.expandable
                onTapped: metric.toggled()
            }

            RowLayout {
                id: header
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Theme.s2
                ColumnLayout {
                    spacing: 1
                    Layout.fillWidth: true
                    RowLayout {
                        spacing: Theme.s1
                        Text {
                            text: metric.label
                            font.family: Theme.font
                            font.pointSize: Theme.base
                            font.weight: Font.Medium
                            color: Theme.text
                        }
                        Kirigami.Icon {
                            visible: metric.expandable
                            source: "arrow-down"
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: implicitWidth
                            color: Theme.textTertiary
                            rotation: metric.open ? 180 : 0
                            Behavior on rotation {
                                enabled: Theme.motion
                                NumberAnimation { duration: Theme.standard; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                    Text {
                        visible: text.length > 0
                        text: metric.detail
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        font.family: Theme.font
                        font.pointSize: Theme.microSize
                        font.features: { "tnum": 1 }
                        color: Theme.textTertiary
                    }
                }
                // Always laid out, only faded, so hovering does not shift the row.
                IconButton {
                    visible: metric.hideable
                    opacity: rowHover.hovered || hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.quick } }
                    size: 24
                    iconName: "view-hidden"
                    tooltip: i18n("Hide this row")
                    onClicked: metric.hideRequested()
                }
                Chip {
                    visible: metric.chip.length > 0
                    text: metric.chip
                    tone: metric.chipTone
                }
                Text {
                    visible: metric.percent >= 0
                    text: metric.ready ? Math.round(metric.shown.value) + "%" : "–"
                    font.family: Theme.display
                    font.pointSize: Theme.leadSize * 1.15
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    color: Theme.text
                    horizontalAlignment: Text.AlignRight
                    Layout.minimumWidth: Theme.s7 + Theme.s5
                }
            }
        }
        Rectangle {
            visible: metric.percent >= 0
            Layout.fillWidth: true
            implicitHeight: 6
            radius: 3
            color: Theme.raised
            Rectangle {
                width: parent.width * Math.min(100, metric.shown.value) / 100
                height: parent.height
                radius: 3
                color: root.tone(metric.shown.value, metric.high, metric.critical)
                Behavior on color { ColorAnimation { duration: root.glide } }
            }
        }
    }

    // One physical core: a bar per hardware thread rising from the cell's foot, and the core's
    // busiest thread as a number.
    component CoreCell: Rectangle {
        id: cell
        property var core
        property string kind
        readonly property bool hovered: cellHover.hovered
        readonly property real peak: {
            let p = 0
            for (const index of core.threads) {
                const t = root.thread(index)
                if (t)
                    p = Math.max(p, t.usage_percent)
            }
            return p
        }
        readonly property Glide peakShown: Glide { target: cell.peak }
        implicitHeight: Theme.tileSize
        Layout.fillWidth: true
        radius: Theme.radiusSm
        color: Theme.raised
        border.width: hovered ? 1 : 0
        border.color: Theme.outline
        clip: true

        HoverHandler {
            id: cellHover
            onHoveredChanged: {
                if (hovered)
                    root.hoveredCore = { kind: cell.kind, core: cell.core }
                else if (root.hoveredCore && root.hoveredCore.core === cell.core)
                    root.hoveredCore = null
            }
        }

        Row {
            id: lanes
            anchors.fill: parent
            anchors.margins: 2
            spacing: 2
            Repeater {
                model: cell.core.threads
                delegate: Item {
                    id: lane
                    required property int modelData
                    readonly property var info: root.thread(modelData)
                    readonly property Glide load: Glide { target: lane.info ? lane.info.usage_percent : 0 }
                    width: (lanes.width - (cell.core.threads.length - 1) * lanes.spacing) / cell.core.threads.length
                    height: lanes.height
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(2, parent.height * Math.min(100, lane.load.value) / 100)
                        radius: Theme.radiusSm - 2
                        color: Qt.alpha(root.tone(lane.load.value, 75, 92), 0.55)
                        Behavior on color { ColorAnimation { duration: root.glide } }
                    }
                }
            }
        }
        Text {
            anchors.centerIn: parent
            text: Math.round(cell.peakShown.value)
            font.family: Theme.font
            font.pointSize: Theme.microSize
            font.weight: Font.Medium
            font.features: { "tnum": 1 }
            color: cell.peak >= 50 ? Theme.text : Theme.textSecondary
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
                    opacity: root.stats === null ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Theme.standard } }
                }
            }

            SectionLabel { text: i18n("Processor and graphics") }

            Metric {
                readonly property var cpu: root.stats ? root.stats.cpu : null
                label: i18n("Processor")
                detail: !cpu ? ""
                    : root.showCores ? i18n("Each core's busiest thread")
                    : i18np("%1 thread · click for each core", "%1 threads · click for each core", cpu.cores)
                percent: cpu ? cpu.usage_percent : 0
                chip: cpu && cpu.temperature_c !== null ? Math.round(cpu.temperature_c) + " °C" : ""
                chipTone: cpu ? root.tone(cpu.temperature_c, 80, 92) : Theme.textTertiary
                expandable: root.threadCount > 0
                open: root.showCores
                onToggled: root.showCores = !root.showCores
            }

            ColumnLayout {
                id: coreMap
                visible: root.showCores && root.threadCount > 0
                Layout.fillWidth: true
                spacing: Theme.s3

                Repeater {
                    model: root.coreGroups
                    delegate: ColumnLayout {
                        id: group
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.s1 + 2

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: group.modelData.title
                                font.family: Theme.font
                                font.pointSize: Theme.microSize
                                font.weight: Font.Medium
                                color: Theme.textSecondary
                                Layout.fillWidth: true
                            }
                            Text {
                                readonly property string ghz: root.averageGhz(group.modelData)
                                text: i18np("%1 core", "%1 cores", group.modelData.cores.length)
                                    + (ghz ? " · " + i18n("%1 GHz", ghz) : "")
                                font.family: Theme.font
                                font.pointSize: Theme.microSize
                                font.features: { "tnum": 1 }
                                color: Theme.textTertiary
                            }
                        }
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 8
                            columnSpacing: Theme.s1
                            rowSpacing: Theme.s1
                            uniformCellWidths: true
                            Repeater {
                                model: group.modelData.cores
                                delegate: CoreCell {
                                    required property var modelData
                                    core: modelData
                                    kind: group.modelData.kind ?? ""
                                }
                            }
                        }
                    }
                }

                // Pointing at a core names its threads, their loads and clocks.
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    font.family: Theme.font
                    font.pointSize: Theme.microSize
                    font.features: { "tnum": 1 }
                    color: root.hoveredCore ? Theme.textSecondary : Theme.textTertiary
                    text: {
                        const h = root.hoveredCore
                        if (!h)
                            return i18n("Point at a core for its threads and clock")
                        const name = h.kind === "performance" ? i18n("P-core %1", h.core.core)
                            : h.kind === "efficiency" ? i18n("E-core %1", h.core.core)
                            : i18n("Core %1", h.core.core)
                        const parts = h.core.threads.map(index => {
                            const t = root.thread(index)
                            return t ? i18n("CPU %1 %2%", t.id, Math.round(t.usage_percent))
                                + (t.mhz ? " " + i18n("at %1 GHz", (t.mhz / 1000).toFixed(1)) : "") : ""
                        })
                        return name + " · " + parts.join(", ")
                    }
                }
            }

            Repeater {
                model: root.gpuCount
                delegate: Metric {
                    required property int index
                    readonly property var gpu: root.stats ? root.stats.gpus[index] : null
                    readonly property string state: gpu ? gpu.state : ""
                    readonly property bool active: state === "active" && gpu.usage_percent !== undefined
                    readonly property bool integrated: gpu !== null && gpu.kind === "integrated"
                    visible: !(integrated && Plasmoid.configuration.hideIntegratedGpu)
                    hideable: integrated
                    onHideRequested: Plasmoid.configuration.hideIntegratedGpu = true
                    label: gpu && gpu.kind === "discrete" ? i18n("Graphics card") : i18n("Graphics")
                    detail: gpu ? gpu.name : ""
                    percent: active ? gpu.usage_percent : -1
                    chip: state === "windows" ? i18n("In Windows")
                        : state === "asleep" ? i18n("Asleep")
                        : state === "off" ? i18n("Off")
                        : gpu && gpu.temperature_c !== undefined ? Math.round(gpu.temperature_c) + " °C" : ""
                    chipTone: state === "windows" ? Theme.accent
                        : gpu && gpu.temperature_c !== undefined ? root.tone(gpu.temperature_c, 80, 90)
                        : Theme.textTertiary
                }
            }

            Text {
                visible: Plasmoid.configuration.hideIntegratedGpu
                    && root.stats !== null && root.stats.gpus.some(g => g.kind === "integrated")
                text: i18n("Integrated graphics hidden · <a href=\"show\">Show</a>")
                textFormat: Text.StyledText
                linkColor: Theme.accent
                font.family: Theme.font
                font.pointSize: Theme.microSize
                color: Theme.textTertiary
                onLinkActivated: Plasmoid.configuration.hideIntegratedGpu = false
                HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
            }

            SectionLabel { text: i18n("Memory and storage") }

            Metric {
                readonly property var part: root.stats ? root.stats.memory : null
                label: i18n("Memory")
                detail: part ? i18n("%1 of %2 GiB", root.gib(part.used_bytes), root.gib(part.total_bytes)) : ""
                percent: root.share(part)
            }
            Metric {
                readonly property var part: root.stats ? root.stats.swap : null
                label: i18n("Swap")
                detail: part ? i18n("%1 of %2 GiB", root.gib(part.used_bytes), root.gib(part.total_bytes)) : ""
                percent: root.share(part)
            }
            Metric {
                readonly property var part: root.stats ? root.stats.disk : null
                label: i18n("Disk")
                detail: part ? i18n("%1 of %2 GiB used on %3", root.gib(part.used_bytes), root.gib(part.total_bytes), part.path) : ""
                percent: root.share(part)
                high: 85
                critical: 95
            }

            RowLayout {
                Layout.fillWidth: true
                SectionLabel { text: i18n("Busiest processes"); Layout.fillWidth: true }
                Text {
                    text: i18n("<a href=\"all\">All processes</a>")
                    textFormat: Text.StyledText
                    linkColor: Theme.accent
                    font.family: Theme.font
                    font.pointSize: Theme.microSize
                    font.weight: Font.Medium
                    onLinkActivated: {
                        root.expanded = false
                        processWindow.open()
                    }
                    HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
                }
            }

            ListView {
                id: topList
                Layout.fillWidth: true
                // Always room for a full list, so the card keeps its size as processes come and go.
                implicitHeight: root.topShown * 36
                interactive: false
                model: topModel
                Text {
                    visible: topList.count === 0
                    anchors.centerIn: parent
                    text: i18n("Nothing above 1% CPU")
                    font.family: Theme.font
                    font.pointSize: Theme.microSize
                    color: Theme.textTertiary
                }
                HoverHandler { onHoveredChanged: root.holdingTop = hovered }
                move: Transition {
                    enabled: Theme.motion
                    NumberAnimation { properties: "y"; duration: Theme.slow; easing.type: Easing.OutCubic }
                }
                moveDisplaced: Transition {
                    enabled: Theme.motion
                    NumberAnimation { properties: "y"; duration: Theme.slow; easing.type: Easing.OutCubic }
                }
                add: Transition {
                    enabled: Theme.motion
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.standard }
                }
                displaced: Transition {
                    enabled: Theme.motion
                    NumberAnimation { properties: "y"; duration: Theme.slow; easing.type: Easing.OutCubic }
                }
                delegate: Item {
                    id: topRow
                    required property string key
                    required property string name
                    required property string command
                    required property real cpu
                    required property real memory
                    required property bool own
                    required property bool critical
                    required property string target
                    readonly property Glide cpuShown: Glide { target: topRow.cpu }
                    readonly property bool active: topHover.hovered || processEnder.state(key) !== ""
                    width: ListView.view.width
                    height: 36
                    HoverHandler { id: topHover }
                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: -Theme.s2
                        anchors.rightMargin: -Theme.s2
                        radius: Theme.radiusSm
                        color: topHover.hovered ? Theme.hover : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.quick } }
                    }
                    RowLayout {
                        anchors.fill: parent
                        spacing: Theme.s2
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: topRow.name
                                elide: Text.ElideRight
                                font.family: Theme.font
                                font.pointSize: Theme.metaSize
                                font.weight: Font.Medium
                                color: Theme.text
                            }
                            Text {
                                Layout.fillWidth: true
                                text: P.bytes(topRow.memory) + " · " + topRow.command
                                elide: Text.ElideRight
                                font.family: Theme.font
                                font.pointSize: Theme.microSize
                                color: Theme.textTertiary
                            }
                        }
                        // Always laid out, only faded, so hovering does not shift the row.
                        EndButton {
                            visible: topRow.own
                            opacity: topRow.active ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: Theme.quick } }
                            ender: processEnder
                            key: topRow.key
                            targets: [topRow.target]
                            label: topRow.name
                            critical: topRow.critical
                        }
                        Text {
                            text: Math.round(topRow.cpuShown.value) + "%"
                            horizontalAlignment: Text.AlignRight
                            Layout.minimumWidth: Theme.s7 + Theme.s4
                            font.family: Theme.font
                            font.pointSize: Theme.base
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                            color: Theme.text
                        }
                    }
                }
            }
            Text {
                visible: processEnder.message.length > 0
                Layout.fillWidth: true
                text: processEnder.message
                elide: Text.ElideRight
                font.family: Theme.font
                font.pointSize: Theme.microSize
                color: Theme.textSecondary
            }
        }
    }
}
