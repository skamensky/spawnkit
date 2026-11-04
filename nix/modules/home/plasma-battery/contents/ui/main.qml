// Plasma's own battery widget stays visible on AC; this one takes no panel space unless
// the laptop runs on battery.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    P5Support.DataSource {
        id: power
        engine: "powermanagement"
        connectedSources: ["Battery", "AC Adapter"]
    }

    readonly property var battery: power.data["Battery"] || {}
    readonly property bool onBattery: battery["Has Battery"] === true
        && (power.data["AC Adapter"] || {})["Plugged in"] === false
    readonly property int percent: battery["Percent"] || 0

    Plasmoid.status: onBattery ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.HiddenStatus
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: compactRepresentation
    toolTipMainText: i18n("On battery: %1%", percent)

    compactRepresentation: RowLayout {
        spacing: Kirigami.Units.smallSpacing
        visible: root.onBattery
        Layout.preferredWidth: root.onBattery ? implicitWidth : 0
        Layout.minimumWidth: Layout.preferredWidth
        Layout.maximumWidth: Layout.preferredWidth

        Kirigami.Icon {
            source: "battery-" + String(Math.round(root.percent / 10) * 10).padStart(3, "0")
            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
        }
        PlasmaComponents.Label {
            text: root.percent + "%"
        }
    }
}
