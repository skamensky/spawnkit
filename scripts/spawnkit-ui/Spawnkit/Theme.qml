// Spawnkit's design tokens, shared by every dialog.
//
// A dialog is one raised card floating over the desktop: its surface and text follow the active
// Plasma colour scheme through Kirigami, while the accent is Spawnkit's own indigo so its applets
// look alike on any theme. Hierarchy comes from the type scale and from three layers of surface
// (card, raised fills, tinted status), never from rules or boxes. Durations derive from Kirigami's,
// so Plasma's animation-speed setting, including "off", applies everywhere.
pragma Singleton
import QtQuick
import org.kde.kirigami as Kirigami

QtObject {
    readonly property bool dark: Kirigami.ColorUtils.brightnessForColor(Kirigami.Theme.backgroundColor)
        === Kirigami.ColorUtils.Dark

    // Surfaces, from the card up.
    readonly property color surface: dark
        ? Kirigami.ColorUtils.tintWithAlpha(Kirigami.Theme.backgroundColor, "#ffffff", 0.055) : "#ffffff"
    readonly property color edge: dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.09)
    readonly property color shadow: Qt.rgba(0, 0, 0, dark ? 0.6 : 0.25)
    readonly property color text: Kirigami.Theme.textColor
    readonly property color raised: Qt.alpha(text, dark ? 0.07 : 0.05)
    readonly property color raisedHover: Qt.alpha(text, dark ? 0.11 : 0.08)
    readonly property color raisedPressed: Qt.alpha(text, dark ? 0.15 : 0.11)
    readonly property color hover: Qt.alpha(text, dark ? 0.05 : 0.035)
    readonly property color pressed: Qt.alpha(text, dark ? 0.09 : 0.06)
    readonly property color hairline: Qt.alpha(text, dark ? 0.09 : 0.08)
    readonly property color outline: Qt.alpha(text, dark ? 0.28 : 0.26)

    // Text, in four steps of emphasis.
    readonly property color textSecondary: Qt.alpha(text, 0.64)
    readonly property color textTertiary: Qt.alpha(text, 0.44)
    readonly property color textDisabled: Qt.alpha(text, 0.28)

    // Accent and status colours, each with a tint for chips and callouts.
    readonly property color accent: dark ? "#8187FA" : "#4F46E5"
    readonly property color accentBright: dark ? "#9CA1FF" : "#6366F1"
    readonly property color accentText: dark ? "#0E0F2A" : "#FFFFFF"
    readonly property color accentTint: Qt.alpha(accent, dark ? 0.16 : 0.10)
    readonly property color focusRing: Qt.alpha(accent, 0.55)
    readonly property color positive: dark ? "#3DD68C" : "#0F9D58"
    readonly property color positiveTint: Qt.alpha(positive, dark ? 0.14 : 0.10)
    readonly property color caution: dark ? "#F6C453" : "#C77700"
    readonly property color cautionTint: Qt.alpha(caution, dark ? 0.14 : 0.10)
    readonly property color negative: dark ? "#FF7B72" : "#D93025"
    readonly property color negativeTint: Qt.alpha(negative, dark ? 0.14 : 0.09)
    readonly property color danger: dark ? "#E5484D" : "#DC2626"
    readonly property color dangerText: "#FFFFFF"

    // Spacing on a 4px grid; inset is the card's padding.
    readonly property int s1: 4
    readonly property int s2: 8
    readonly property int s3: 12
    readonly property int s4: 16
    readonly property int s5: 20
    readonly property int s6: 24
    readonly property int s7: 32
    readonly property int inset: 28
    readonly property int radiusSm: 6
    readonly property int radiusMd: 10
    readonly property int radiusLg: 14
    readonly property int radiusCard: 18
    readonly property int rowHeight: 56
    readonly property int buttonHeight: 38
    readonly property int tileSize: 34
    readonly property int shadowPad: 44

    // Type: Inter for everything, Inter Display at title sizes, Plex Mono for commands.
    readonly property string font: "Inter"
    readonly property string display: "Inter Display"
    readonly property string mono: "IBM Plex Mono"
    readonly property real base: Kirigami.Theme.defaultFont.pointSize
    readonly property real titleSize: base * 1.6
    readonly property real leadSize: base * 1.05
    readonly property real metaSize: base * 0.88
    readonly property real microSize: base * 0.8
    readonly property real monoSize: base * 0.84

    // Motion. Kirigami scales these with Plasma's animation speed; zero means animations are off.
    readonly property bool motion: Kirigami.Units.longDuration > 0
    readonly property int quick: Kirigami.Units.shortDuration
    readonly property int standard: Kirigami.Units.longDuration
    readonly property int slow: Kirigami.Units.veryLongDuration
}
