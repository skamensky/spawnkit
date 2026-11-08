// One resource's last minute in the process window, after Windows' Task Manager: the current
// figure over a graph that scrolls left as readings arrive. Each series is { values, color } with
// values oldest first; a null value (a GPU that is asleep or in Windows) leaves a gap.
//
// The graph is drawn once per reading, one step wider than its frame with the newest reading just
// out of view, then slid left by that step, so it glides without repainting every frame.
import QtQuick
import QtQuick.Layouts
import "Spawnkit"

Rectangle {
    id: card
    property string title
    property string value
    property string detail
    property var series: []
    // The graph's top: fixed for percentages, or (network) a ceiling the window derives from the data.
    property real maximum: 100
    property string scaleLabel
    property int capacity: 60
    readonly property real step: frame.width / (capacity - 1)

    radius: Theme.radiusLg
    color: Theme.raised
    implicitHeight: 156

    onSeriesChanged: {
        graph.requestPaint()
        slide.stop()
        graph.x = 0
        if (Theme.motion)
            slide.start()
        else
            graph.x = -step
    }

    component Swatch: Rectangle {
        width: 3
        height: 12
        radius: 1.5
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.s3
        anchors.topMargin: Theme.s3 - 2
        spacing: 2

        Text {
            text: card.title
            font.family: Theme.font
            font.pointSize: Theme.microSize
            font.weight: Font.DemiBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.6
            color: Theme.textTertiary
        }
        RowLayout {
            spacing: Theme.s2
            Layout.fillWidth: true
            Swatch { color: card.series.length ? card.series[0].color : "transparent" }
            Text {
                Layout.fillWidth: true
                text: card.value
                elide: Text.ElideRight
                font.family: Theme.display
                font.pointSize: Theme.leadSize * 1.25
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: Theme.text
            }
        }
        RowLayout {
            spacing: Theme.s2
            Layout.fillWidth: true
            Swatch {
                visible: card.series.length > 1
                color: card.series.length > 1 ? card.series[1].color : "transparent"
            }
            Text {
                Layout.fillWidth: true
                text: card.detail
                elide: Text.ElideRight
                font.family: Theme.font
                font.pointSize: Theme.microSize
                font.features: { "tnum": 1 }
                color: Theme.textSecondary
            }
        }

        Item {
            id: frame
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: Theme.s2
            clip: true

            Repeater {
                model: 3
                Rectangle {
                    required property int index
                    y: Math.round(frame.height * (index + 1) / 4)
                    width: frame.width
                    height: 1
                    color: Theme.hairline
                }
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: frame.width
                height: 1
                color: Theme.edge
            }
            Text {
                anchors.right: parent.right
                anchors.top: parent.top
                visible: card.scaleLabel.length > 0
                text: card.scaleLabel
                font.family: Theme.font
                font.pointSize: Theme.microSize * 0.9
                font.features: { "tnum": 1 }
                color: Theme.textTertiary
                z: 1
            }

            Canvas {
                id: graph
                width: frame.width + card.step
                height: frame.height
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    const bottom = height - 1
                    const scale = (height - 2) / Math.max(card.maximum, 1e-9)
                    for (const s of card.series) {
                        const n = s.values.length
                        const xAt = i => width - (n - 1 - i) * card.step
                        const yAt = v => bottom - Math.min(card.maximum, Math.max(0, v)) * scale
                        // Each unbroken run of readings: a tinted area under a line.
                        let i = 0
                        while (i < n) {
                            while (i < n && s.values[i] === null)
                                i++
                            const first = i
                            while (i < n && s.values[i] !== null)
                                i++
                            if (i === first)
                                continue
                            ctx.beginPath()
                            ctx.moveTo(xAt(first), bottom)
                            for (let k = first; k < i; k++)
                                ctx.lineTo(xAt(k), yAt(s.values[k]))
                            ctx.lineTo(xAt(i - 1), bottom)
                            ctx.closePath()
                            ctx.fillStyle = Qt.alpha(s.color, 0.16)
                            ctx.fill()
                            ctx.beginPath()
                            ctx.moveTo(xAt(first), yAt(s.values[first]))
                            for (let k = first + 1; k < i; k++)
                                ctx.lineTo(xAt(k), yAt(s.values[k]))
                            ctx.lineWidth = 1.5
                            ctx.lineJoin = "round"
                            ctx.strokeStyle = s.color
                            ctx.stroke()
                        }
                    }
                }
                NumberAnimation on x {
                    id: slide
                    running: false
                    from: 0
                    to: -card.step
                    duration: 1000
                    easing.type: Easing.InOutSine
                }
            }
        }
    }
}
