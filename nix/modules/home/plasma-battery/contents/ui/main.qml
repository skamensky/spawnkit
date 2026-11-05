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
    readonly property bool unplugged: battery["Has Battery"] === true
        && (power.data["AC Adapter"] || {})["Plugged in"] === false
    readonly property int percent: battery["Percent"] || 0

    Plasmoid.status: unplugged ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.HiddenStatus
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    // Without a full representation Plasma shows the bare root item and never the compact one.
    preferredRepresentation: fullRepresentation
    toolTipMainText: i18n("On battery: %1%", percent)

    fullRepresentation: Item {
        Layout.minimumWidth: row.implicitWidth
        Layout.preferredWidth: row.implicitWidth

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

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
}
