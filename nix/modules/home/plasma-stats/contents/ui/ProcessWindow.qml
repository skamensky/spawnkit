// Every process, in the manner of a task manager: grouped under the app or service that owns it
// (an app's helper processes fold into one row), sortable by name, CPU, memory or PID, searchable,
// with End (SIGTERM, then Force kill) on each row. It polls `spawnkit-stats processes` while open.
// Above the list, graphs (Usage.qml) show the machine's CPU, memory, graphics and network use over
// the last minute the window has been open, from the same readings, and under them a pinned bar
// (MemoryMap.qml) of where the used memory sits: virtual machines, apps, RAM disks, kernel, other.
//
// Rows never jump: values glide between readings, the order is re-ranked at most every two seconds
// with the rows sliding to their places, and it holds still while the pointer is over the list.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Window
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import "Spawnkit"
import "processes.js" as P

Window {
    id: win
    property string stats
    property Item ender
    property Item copier
    property var listing: null
    property string sort: "cpu"
    property bool descending: true
    property bool grouped: true
    // One decimal on every CPU figure; main.qml persists it.
    property bool granular: false
    signal granularRequested(bool on)
    property var expanded: ({})
    property double rankedAt: 0
    readonly property bool holding: listHover.hovered
    readonly property int glide: 900
    // The machine's readings since the window opened, oldest first, a minute at most.
    property var history: []
    readonly property int capacity: 60

    title: i18n("Processes")
    width: 980
    height: 860
    minimumWidth: 700
    minimumHeight: 520
    color: Theme.surface
    transientParent: null

    // Also brings an open window to the front, restoring it if minimized. On Wayland KWin activates
    // it only with a token from the window that took the click, so call this before closing the popup.
    function open() {
        if (!visible)
            history = []
        if (visibility === Window.Minimized)
            showNormal()
        else
            show()
        raise()
        requestActivate()
        search.forceActiveFocus()
    }
    onVisibleChanged: {
        if (visible)
            poll()
        else
            next.stop()
    }

    function poll() {
        if (!runner.connectedSources.length)
            runner.connectSource(stats + " processes --interval 1")
    }
    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            try {
                win.listing = JSON.parse(data.stdout)
                win.record(win.listing.machine)
                win.refresh(false)
            } catch (err) {
                // Keep the last listing.
            }
            if (win.visible)
                next.restart()
        }
    }
    Timer {
        id: next
        interval: 100
        onTriggered: win.poll()
    }

    function record(machine) {
        const gpu = kind => {
            const g = machine.gpus.find(g => g.kind === kind)
            return g && g.state === "active" && g.usage_percent !== undefined ? g.usage_percent : null
        }
        const next = history.concat([{
            cpu: machine.cpu_percent,
            memory: 100 * machine.memory.used_bytes / machine.memory.total_bytes,
            integrated: gpu("integrated"),
            discrete: gpu("discrete"),
            received: machine.network.received_bytes_per_second,
            sent: machine.network.sent_bytes_per_second,
        }])
        history = next.slice(-capacity)
    }
    function series(field) {
        return history.map(h => h[field])
    }
    readonly property var machine: listing ? listing.machine : null
    readonly property var integratedGpu: machine ? machine.gpus.find(g => g.kind === "integrated") || null : null
    readonly property var discreteGpu: machine ? machine.gpus.find(g => g.kind === "discrete") || null : null
    readonly property real networkTop: P.ceiling(Math.max(0, ...history.map(h => Math.max(h.received, h.sent))))

    // "GeForce RTX 4060 Max-Q / Mobile" reads as "RTX 4060".
    function shortGpu(gpu) {
        const m = gpu.name.match(/(RTX|GTX|RX|Arc)\s*[A-Z]?\d+\w*( Ti| SUPER)?/)
        return m ? m[0] : gpu.name
    }
    function gpuState(gpu) {
        if (!gpu)
            return ""
        const name = shortGpu(gpu)
        if (gpu.state === "windows")
            return i18n("%1 in Windows", name)
        if (gpu.state === "asleep")
            return i18n("%1 asleep", name)
        if (gpu.state === "off")
            return i18n("%1 off", name)
        return gpu.usage_percent !== undefined ? i18n("%1 at %2", name, P.percent(gpu.usage_percent, win.granular)) : name
    }

    function setSort(column) {
        if (sort === column)
            descending = !descending
        else {
            sort = column
            descending = column === "cpu" || column === "memory"
        }
        refresh(true)
    }
    function toggle(key) {
        const next = Object.assign({}, expanded)
        if (next[key])
            delete next[key]
        else
            next[key] = true
        expanded = next
        refresh(true)
    }

    CopyMenu { id: rowMenu; copier: win.copier }

    function processRow(proc, group, depth) {
        return {
            key: "p:" + proc.pid + ":" + proc.start,
            depth, group: false, count: 1, open: false,
            name: proc.name,
            detail: proc.command,
            icon: depth ? "" : (group.icon || ""),
            kind: group.kind,
            cpu: proc.cpu_percent, memory: proc.memory_bytes,
            pid: proc.pid, user: proc.user,
            own: proc.own, critical: proc.critical,
            targets: P.target(proc),
        }
    }

    // The listing, filtered and sorted, as the list's rows. force re-ranks at once (after a
    // click); otherwise re-ranking waits two seconds and for the pointer to leave the list.
    function refresh(force) {
        if (!listing)
            return
        const query = search.text.trim().toLowerCase()
        const matches = p => !query || p.name.toLowerCase().includes(query) || p.command.toLowerCase().includes(query)
        const order = P.compare(sort, descending)
        const rows = []
        if (grouped) {
            const groups = []
            for (const g of listing.groups) {
                const nameMatches = !query || g.name.toLowerCase().includes(query)
                const procs = nameMatches ? g.processes : g.processes.filter(matches)
                if (!procs.length)
                    continue
                groups.push({
                    source: g, procs,
                    key: "g:" + g.id,
                    depth: 0, group: true, count: procs.length,
                    name: g.name,
                    detail: procs.length === 1 ? procs[0].command : i18np("%1 process", "%1 processes", procs.length),
                    icon: g.icon || "",
                    kind: g.kind,
                    cpu: procs.reduce((s, p) => s + p.cpu_percent, 0),
                    memory: procs.reduce((s, p) => s + p.memory_bytes, 0),
                    pid: Math.min(...procs.map(p => p.pid)),
                    user: procs[0].user,
                    own: procs.every(p => p.own),
                    critical: procs.some(p => p.critical),
                    targets: procs.map(P.target).join(" "),
                })
            }
            groups.sort(order)
            for (const g of groups) {
                const open = g.count > 1 && (!!expanded[g.key] || query.length > 0)
                rows.push({
                    key: g.key, depth: 0, group: g.count > 1, count: g.count, open,
                    name: g.name, detail: g.detail, icon: g.icon, kind: g.kind,
                    cpu: g.cpu, memory: g.memory, pid: g.pid, user: g.user,
                    own: g.own, critical: g.critical, targets: g.targets,
                })
                if (open)
                    g.procs.map(p => processRow(p, g.source, 1))
                        .sort(order).forEach(row => rows.push(row))
            }
        } else {
            for (const g of listing.groups)
                for (const p of g.processes)
                    if (matches(p))
                        rows.push(processRow(p, g, 0))
            rows.sort(order)
        }
        const now = Date.now()
        const reorder = force || (!holding && now - rankedAt >= 2000)
        if (reorder)
            rankedAt = now
        P.sync(rowModel, rows, reorder)
    }
    onHoldingChanged: if (!holding) rankedAt = 0

    readonly property int processCount: listing ? listing.groups.reduce((s, g) => s + g.processes.length, 0) : 0
    readonly property real cpuTotal: listing ? listing.groups.reduce((s, g) => s + g.cpu_percent, 0) : 0

    ListModel { id: rowModel }

    Shortcut {
        sequences: [StandardKey.Find]
        onActivated: search.forceActiveFocus()
    }
    Shortcut {
        sequences: [StandardKey.Cancel]
        onActivated: search.text.length ? search.clear() : win.close()
    }

    component Column_: Item {
        id: column
        property string label
        property string key
        property int align: Text.AlignRight
        property int indent: 0
        Layout.preferredWidth: width
        implicitHeight: 28
        HoverHandler { id: headHover; cursorShape: column.key ? Qt.PointingHandCursor : Qt.ArrowCursor }
        TapHandler { enabled: column.key.length > 0; onTapped: win.setSort(column.key) }
        Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: column.align === Text.AlignRight ? parent.right : undefined
            anchors.left: column.align === Text.AlignRight ? undefined : parent.left
            anchors.leftMargin: column.indent
            spacing: 2
            Text {
                text: column.label
                font.family: Theme.font
                font.pointSize: Theme.microSize
                font.weight: Font.DemiBold
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.6
                color: win.sort === column.key ? Theme.text : headHover.hovered && column.key ? Theme.textSecondary : Theme.textTertiary
            }
            Kirigami.Icon {
                visible: win.sort === column.key
                source: win.descending ? "arrow-down" : "arrow-up"
                width: 12
                height: 12
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.text
            }
        }
    }

    // A usage figure over a tint that deepens with load, so busy rows stand out at a glance.
    component Heat: Item {
        id: heat
        property real value
        property real level
        property string label
        implicitHeight: 26
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: Theme.s2
            radius: Theme.radiusSm
            color: Qt.alpha(heat.level > 0.6 ? Theme.caution : Theme.accent, 0.04 + 0.30 * Math.min(1, heat.level))
            opacity: heat.level > 0.01 ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: win.glide } }
        }
        Text {
            anchors.right: parent.right
            anchors.rightMargin: Theme.s2
            anchors.verticalCenter: parent.verticalCenter
            text: heat.label
            font.family: Theme.font
            font.pointSize: Theme.metaSize
            font.features: { "tnum": 1 }
            color: heat.level > 0.01 ? Theme.text : Theme.textSecondary
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.s6
        anchors.bottomMargin: Theme.s4
        spacing: Theme.s4

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s4
            ColumnLayout {
                spacing: 2
                Layout.fillWidth: true
                Text {
                    text: i18n("Processes")
                    font.family: Theme.display
                    font.pointSize: Theme.titleSize
                    font.weight: Font.DemiBold
                    font.letterSpacing: -0.4
                    color: Theme.text
                }
                Text {
                    text: win.listing
                        ? i18n("%1 processes in %2 apps and services · %3 CPU", win.processCount, win.listing.groups.length, P.percent(win.cpuTotal, win.granular))
                        : i18n("Measuring…")
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    font.family: Theme.font
                    font.pointSize: Theme.metaSize
                    font.features: { "tnum": 1 }
                    color: Theme.textSecondary
                }
            }
            // Group by app: a segmented pair.
            Rectangle {
                implicitWidth: segments.implicitWidth + 6
                implicitHeight: 34
                radius: Theme.radiusMd
                color: Theme.raised
                Row {
                    id: segments
                    anchors.centerIn: parent
                    spacing: 2
                    Repeater {
                        model: [{ label: i18n("Apps"), grouped: true }, { label: i18n("All processes"), grouped: false }]
                        delegate: Rectangle {
                            id: seg
                            required property var modelData
                            readonly property bool on: win.grouped === modelData.grouped
                            width: segText.implicitWidth + Theme.s4 * 2
                            height: 28
                            radius: Theme.radiusSm + 1
                            color: on ? Theme.surface : segHover.hovered ? Theme.hover : "transparent"
                            border.width: on ? 1 : 0
                            border.color: Theme.edge
                            Behavior on color { ColorAnimation { duration: Theme.quick } }
                            Text {
                                id: segText
                                anchors.centerIn: parent
                                text: seg.modelData.label
                                font.family: Theme.font
                                font.pointSize: Theme.metaSize
                                font.weight: Font.Medium
                                color: seg.on ? Theme.text : Theme.textSecondary
                            }
                            HoverHandler { id: segHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    win.grouped = seg.modelData.grouped
                                    win.refresh(true)
                                }
                            }
                        }
                    }
                }
            }
            Rectangle {
                id: granularToggle
                implicitWidth: granularText.implicitWidth + Theme.s4 * 2
                implicitHeight: 34
                radius: Theme.radiusMd
                color: win.granular ? Theme.surface : granularHover.hovered ? Theme.hover : Theme.raised
                border.width: win.granular ? 1 : 0
                border.color: Theme.edge
                Behavior on color { ColorAnimation { duration: Theme.quick } }
                Text {
                    id: granularText
                    anchors.centerIn: parent
                    text: i18n("Granular")
                    font.family: Theme.font
                    font.pointSize: Theme.metaSize
                    font.weight: Font.Medium
                    color: win.granular ? Theme.text : Theme.textSecondary
                }
                HoverHandler { id: granularHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: win.granularRequested(!win.granular) }
                QQC2.ToolTip.visible: granularHover.hovered
                QQC2.ToolTip.delay: 600
                QQC2.ToolTip.text: i18n("Show a decimal on every CPU figure")
            }
            QQC2.TextField {
                id: search
                Layout.preferredWidth: 240
                implicitHeight: 34
                placeholderText: i18n("Search name or command")
                placeholderTextColor: Theme.textTertiary
                color: Theme.text
                font.family: Theme.font
                font.pointSize: Theme.base
                leftPadding: Theme.s3 + 20
                rightPadding: Theme.s3
                onTextChanged: win.refresh(true)
                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Theme.raised
                    border.width: search.activeFocus ? 2 : 0
                    border.color: Theme.focusRing
                    Kirigami.Icon {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s3 - 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        source: "search"
                        color: Theme.textTertiary
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s3
            Usage {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                capacity: win.capacity
                title: i18n("CPU")
                value: win.machine ? P.percent(win.machine.cpu_percent, win.granular) : "–"
                detail: win.listing ? i18np("%1 thread", "%1 threads", win.listing.cpus) : ""
                series: [{ values: win.series("cpu"), color: Theme.accent }]
            }
            Usage {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                capacity: win.capacity
                title: i18n("Memory")
                value: win.machine ? P.percent(100 * win.machine.memory.used_bytes / win.machine.memory.total_bytes, false) : "–"
                detail: win.machine
                    ? i18n("%1 of %2 · swap %3", P.bytes(win.machine.memory.used_bytes), P.bytes(win.machine.memory.total_bytes), P.bytes(win.machine.swap.used_bytes))
                    : ""
                series: [{ values: win.series("memory"), color: Theme.positive }]
            }
            Usage {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                capacity: win.capacity
                title: i18n("Graphics")
                value: win.integratedGpu && win.integratedGpu.usage_percent !== undefined
                    ? P.percent(win.integratedGpu.usage_percent, win.granular)
                    : win.discreteGpu ? win.gpuState(win.discreteGpu) : "–"
                // The integrated GPU leads; the discrete one follows on the second line and graph.
                detail: win.integratedGpu ? win.gpuState(win.discreteGpu) || win.integratedGpu.name : ""
                series: win.integratedGpu
                    ? [{ values: win.series("integrated"), color: Theme.caution }, { values: win.series("discrete"), color: Theme.negative }]
                    : [{ values: win.series("discrete"), color: Theme.negative }]
            }
            Usage {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                capacity: win.capacity
                title: i18n("Network")
                value: win.machine ? "↓ " + P.rate(win.machine.network.received_bytes_per_second) : "–"
                detail: win.machine ? "↑ " + P.rate(win.machine.network.sent_bytes_per_second) : ""
                maximum: win.networkTop
                scaleLabel: P.rate(win.networkTop)
                series: [{ values: win.series("received"), color: Theme.accent }, { values: win.series("sent"), color: Theme.positive }]
            }
        }

        MemoryMap {
            Layout.fillWidth: true
            occupants: win.machine ? win.machine.memory.occupants : []
            total: win.machine ? win.machine.memory.total_bytes : 0
        }

        // Column headings; a click sorts, a second click reverses.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.s3
            Layout.rightMargin: Theme.s3
            spacing: 0
            Column_ { label: i18n("Name"); key: "name"; align: Text.AlignLeft; Layout.fillWidth: true }
            Column_ { label: i18n("CPU"); key: "cpu"; width: 84 }
            Column_ { label: i18n("Memory"); key: "memory"; width: 104 }
            Column_ { label: i18n("PID"); key: "pid"; width: 80 }
            Column_ { label: i18n("User"); key: "user"; width: 100; align: Text.AlignLeft; indent: Theme.s4 }
            Item { Layout.preferredWidth: 112 }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: rowModel
            boundsBehavior: Flickable.StopAtBounds
            reuseItems: false
            QQC2.ScrollBar.vertical: QQC2.ScrollBar { }
            HoverHandler { id: listHover }

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
            addDisplaced: Transition {
                enabled: Theme.motion
                NumberAnimation { properties: "y"; duration: Theme.standard; easing.type: Easing.OutCubic }
            }
            removeDisplaced: Transition {
                enabled: Theme.motion
                NumberAnimation { properties: "y"; duration: Theme.standard; easing.type: Easing.OutCubic }
            }

            delegate: Item {
                id: row
                required property int index
                required property string key
                required property int depth
                required property bool group
                required property int count
                required property bool open
                required property string name
                required property string detail
                required property string icon
                required property string kind
                required property real cpu
                required property real memory
                required property int pid
                required property string user
                required property bool own
                required property bool critical
                required property string targets
                property real cpuShown: cpu
                property real memoryShown: memory
                Behavior on cpuShown { enabled: Theme.motion; NumberAnimation { duration: win.glide; easing.type: Easing.InOutSine } }
                Behavior on memoryShown { enabled: Theme.motion; NumberAnimation { duration: win.glide; easing.type: Easing.InOutSine } }
                readonly property bool active: rowHover.hovered || (win.ender && win.ender.state(key) !== "")

                width: ListView.view.width
                height: 44

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusMd
                    color: rowTap.pressed && row.group ? Theme.pressed : rowHover.hovered ? Theme.hover : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.quick } }
                }
                HoverHandler { id: rowHover; cursorShape: row.group ? Qt.PointingHandCursor : Qt.ArrowCursor }
                TapHandler { id: rowTap; enabled: row.group; onTapped: win.toggle(row.key) }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: {
                        rowMenu.show(row.targets, row.name, win.grouped ? "apps" : "all")
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.s3
                    anchors.rightMargin: Theme.s3
                    spacing: 0

                    Item {
                        Layout.preferredWidth: row.depth * 36
                    }
                    Item {
                        Layout.preferredWidth: 20
                        implicitHeight: 20
                        Kirigami.Icon {
                            anchors.centerIn: parent
                            visible: row.group
                            source: "arrow-right"
                            width: 14
                            height: 14
                            color: Theme.textTertiary
                            rotation: row.open ? 90 : 0
                            Behavior on rotation { enabled: Theme.motion; NumberAnimation { duration: Theme.standard; easing.type: Easing.OutCubic } }
                        }
                    }
                    Kirigami.Icon {
                        visible: row.depth === 0
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        Layout.rightMargin: Theme.s3
                        // Apps without an icon get the generic program; services and the session a gear.
                        source: row.icon || (row.kind === "app" ? "application-x-executable" : "applications-system")
                        fallback: "application-x-executable"
                        opacity: row.icon ? 1 : 0.7
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        RowLayout {
                            spacing: Theme.s2
                            Layout.fillWidth: true
                            TextMetrics {
                                id: nameMetrics
                                text: row.name
                                font: nameText.font
                            }
                            Text {
                                id: nameText
                                text: row.name
                                elide: Text.ElideRight
                                // Measured, since an elided Text's own implicitWidth goes stale when
                                // a recycled row gets a longer name.
                                Layout.fillWidth: true
                                Layout.maximumWidth: Math.ceil(nameMetrics.advanceWidth) + 1
                                font.family: Theme.font
                                font.pointSize: row.depth ? Theme.metaSize : Theme.base
                                font.weight: row.depth ? Font.Normal : Font.Medium
                                color: Theme.text
                            }
                            Rectangle {
                                visible: row.count > 1
                                implicitWidth: countText.implicitWidth + 12
                                implicitHeight: 18
                                radius: 9
                                color: Theme.raised
                                Text {
                                    id: countText
                                    anchors.centerIn: parent
                                    text: row.count
                                    font.family: Theme.font
                                    font.pointSize: Theme.microSize
                                    font.features: { "tnum": 1 }
                                    color: Theme.textSecondary
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: row.detail
                            elide: Text.ElideRight
                            font.family: row.count > 1 ? Theme.font : Theme.mono
                            font.pointSize: row.count > 1 ? Theme.microSize : Theme.monoSize * 0.9
                            color: Theme.textTertiary
                        }
                    }
                    Heat {
                        Layout.preferredWidth: 84
                        value: row.cpuShown
                        level: row.cpuShown / 25
                        label: P.percent(row.cpuShown, win.granular)
                    }
                    Heat {
                        Layout.preferredWidth: 104
                        value: row.memoryShown
                        level: win.listing ? row.memoryShown / win.listing.memory_total_bytes / 0.15 : 0
                        label: P.bytes(row.memoryShown)
                    }
                    Text {
                        Layout.preferredWidth: 80
                        horizontalAlignment: Text.AlignRight
                        text: row.count > 1 ? "" : row.pid
                        font.family: Theme.font
                        font.pointSize: Theme.metaSize
                        font.features: { "tnum": 1 }
                        color: Theme.textSecondary
                    }
                    Text {
                        Layout.preferredWidth: 100
                        leftPadding: Theme.s4
                        text: row.user
                        elide: Text.ElideRight
                        font.family: Theme.font
                        font.pointSize: Theme.metaSize
                        color: row.own ? Theme.textSecondary : Theme.textTertiary
                    }
                    Item {
                        Layout.preferredWidth: 112
                        implicitHeight: 26
                        EndButton {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: row.own
                            opacity: row.active ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: Theme.quick } }
                            ender: win.ender
                            key: row.key
                            targets: row.targets.split(" ")
                            label: row.name
                            critical: row.critical
                        }
                        Kirigami.Icon {
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.s2
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !row.own && rowHover.hovered
                            source: "object-locked"
                            width: 16
                            height: 16
                            color: Theme.textTertiary
                            QQC2.ToolTip.visible: lockHover.hovered
                            QQC2.ToolTip.text: i18n("Owned by %1; ending it needs administrator rights", row.user)
                            HoverHandler { id: lockHover }
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: win.copier.message || win.ender.message
                elide: Text.ElideRight
                font.family: Theme.font
                font.pointSize: Theme.metaSize
                color: Theme.textSecondary
            }
            Text {
                text: i18n("Order held while pointing")
                opacity: win.holding ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.standard } }
                font.family: Theme.font
                font.pointSize: Theme.microSize
                color: Theme.textTertiary
            }
        }
    }
}
