// An eyebrow above a group of rows, with an optional count.
import QtQuick
import QtQuick.Layouts
import Spawnkit

RowLayout {
    id: root
    property string text
    property int count: -1
    spacing: Theme.s2
    Text {
        text: root.text
        font.family: Theme.font
        font.pointSize: Theme.microSize
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.8
        color: Theme.textTertiary
    }
    Text {
        visible: root.count >= 0
        text: root.count
        font.family: Theme.font
        font.pointSize: Theme.microSize
        font.weight: Font.DemiBold
        font.features: { "tnum": 1 }
        color: Theme.textDisabled
    }
    Item { Layout.fillWidth: true }
}
