// Where the used memory sits, pinned above the process list whatever its sort or search: one bar
// split into the parts `spawnkit-stats processes` reports (machine.memory.occupants), each virtual
// machine, the apps and services, RAM disks, the kernel and the rest, with a legend under it. The
// parts add up to the Memory card's used figure, so memory no process row shows is accounted for.
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import "Spawnkit"
import "processes.js" as P

Rectangle {
    id: map
    // [{id, name, bytes, detail}]
    property var occupants: []
    property real total: 0
    readonly property real sum: occupants.reduce((s, o) => s + o.bytes, 0)

    function colorOf(part, index) {
        if (part.id === "apps")
            return Theme.accent
        if (part.id === "ram-disks")
            return Theme.caution
        if (part.id === "kernel")
            return Theme.positive
        if (part.id === "other")
            return Theme.outline
        // Virtual machines, the first at full strength and later ones fainter.
        return Qt.alpha(Theme.negative, Math.max(0.45, 1 - 0.25 * index))
    }

    radius: Theme.radiusLg
    color: Theme.raised
    implicitHeight: content.implicitHeight + 2 * Theme.s3

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: Theme.s3
        spacing: Theme.s2

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: i18n("Where memory sits")
                font.family: Theme.font
                font.pointSize: Theme.microSize
                font.weight: Font.DemiBold
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.6
                color: Theme.textTertiary
            }
            Item { Layout.fillWidth: true }
            Text {
                text: map.total ? i18n("%1 in use of %2", P.bytes(map.sum), P.bytes(map.total)) : ""
                font.family: Theme.font
                font.pointSize: Theme.microSize
                font.features: { "tnum": 1 }
                color: Theme.textTertiary
            }
        }

        // The bar spans all of RAM; its empty tail is the memory still available.
        Rectangle {
            id: bar
            Layout.fillWidth: true
            implicitHeight: 10
            radius: 5
            color: Theme.hairline
            clip: true
            Row {
                anchors.fill: parent
                spacing: 0
                Repeater {
                    model: map.occupants
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        height: bar.height
                        width: map.total ? bar.width * modelData.bytes / map.total : 0
                        color: map.colorOf(modelData, index)
                        Behavior on width { enabled: Theme.motion; NumberAnimation { duration: Theme.standard; easing.type: Easing.InOutSine } }
                    }
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: Theme.s4
            Repeater {
                model: map.occupants
                delegate: Row {
                    id: entry
                    required property var modelData
                    required property int index
                    spacing: Theme.s2
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10
                        height: 10
                        radius: 3
                        color: map.colorOf(entry.modelData, entry.index)
                    }
                    Text {
                        text: entry.modelData.name
                        font.family: Theme.font
                        font.pointSize: Theme.metaSize
                        color: Theme.textSecondary
                    }
                    Text {
                        text: P.bytes(entry.modelData.bytes)
                        font.family: Theme.font
                        font.pointSize: Theme.metaSize
                        font.weight: Font.Medium
                        font.features: { "tnum": 1 }
                        color: Theme.text
                    }
                    HoverHandler { id: entryHover }
                    QQC2.ToolTip.visible: entryHover.hovered
                    QQC2.ToolTip.delay: 400
                    QQC2.ToolTip.text: entry.modelData.detail
                }
            }
        }
    }
}
