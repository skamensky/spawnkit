// Spawnkit's design tokens, shared by every dialog. Surfaces and text follow the active Plasma
// colour scheme through Kirigami; the accent is Spawnkit's own so its applets look alike on any
// theme. Hierarchy comes from steps of text alpha, never from borders or extra panels.
pragma Singleton
import QtQuick
import org.kde.kirigami as Kirigami

QtObject {
    readonly property bool dark: Kirigami.ColorUtils.brightnessForColor(Kirigami.Theme.backgroundColor)
        === Kirigami.ColorUtils.Dark

    readonly property color surface: Kirigami.Theme.backgroundColor
    readonly property color text: Kirigami.Theme.textColor
    readonly property color textMuted: Qt.alpha(text, 0.68)
    readonly property color textFaint: Qt.alpha(text, 0.50)
    readonly property color hover: Qt.alpha(text, dark ? 0.06 : 0.04)
    readonly property color pressed: Qt.alpha(text, dark ? 0.10 : 0.07)
    readonly property color hairline: Qt.alpha(text, 0.22)
    readonly property color accent: dark ? "#8B8FF9" : "#4F46E5"
    readonly property color accentHover: Qt.lighter(accent, dark ? 1.08 : 1.12)
    readonly property color accentText: dark ? "#0F1023" : "#FFFFFF"
    readonly property color focusRing: Qt.alpha(accent, 0.5)
    readonly property color positive: dark ? "#34D399" : "#059669"
    readonly property color neutral: dark ? "#FBBF24" : "#D97706"
    readonly property color negative: dark ? "#F87171" : "#DC2626"
    readonly property color danger: "#DC2626"
    readonly property color negativeText: "#FFFFFF"

    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s5: 24
    readonly property int s6: 32
    readonly property int radiusSm: 5
    readonly property int radiusMd: 8
    readonly property int radiusLg: 12
    readonly property int rowHeight: 44
    readonly property int buttonHeight: 36

    readonly property string font: "Inter"
    readonly property string mono: "IBM Plex Mono"
    readonly property real base: Kirigami.Theme.defaultFont.pointSize
    readonly property real titleSize: base * 1.5
    readonly property real metaSize: base * 0.9
    readonly property real monoSize: base * 0.85

    readonly property int fast: 120
    readonly property int normal: 180
}
