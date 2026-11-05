// Windows' language indicator: a click toggles between two layouts; with three or more it opens
// a menu of them. The wheel steps through them either way. Hidden with a single layout.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.workspace.keyboardlayout
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    KeyboardLayout { id: keyboard }

    readonly property var layouts: keyboard.layoutsList
    readonly property var current: layouts.length ? layouts[keyboard.layout] : { shortName: "", longName: "" }

    Plasmoid.status: layouts.length > 1 ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.HiddenStatus
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    // Without a full representation Plasma shows the bare root item and never the compact one.
    preferredRepresentation: fullRepresentation
    toolTipMainText: current.longName
    toolTipSubText: layouts.length > 2 ? i18n("Click to choose a layout") : i18n("Click to switch layout")

    fullRepresentation: MouseArea {
        id: button
        Layout.minimumWidth: label.implicitWidth + Kirigami.Units.smallSpacing * 2
        Layout.preferredWidth: Layout.minimumWidth
        acceptedButtons: Qt.LeftButton
        property int wheelDelta: 0

        onClicked: {
            if (root.layouts.length > 2)
                menu.openRelative();
            else
                keyboard.switchToNextLayout();
        }
        onWheel: wheel => {
            wheelDelta += wheel.angleDelta.y || wheel.angleDelta.x;
            while (wheelDelta >= 120) { wheelDelta -= 120; keyboard.switchToPreviousLayout(); }
            while (wheelDelta <= -120) { wheelDelta += 120; keyboard.switchToNextLayout(); }
        }

        PlasmaComponents.Label {
            id: label
            anchors.centerIn: parent
            text: root.current.shortName.toUpperCase()
        }

        PlasmaExtras.ModelContextMenu {
            id: menu
            visualParent: button
            placement: PlasmaExtras.Menu.TopPosedLeftAlignedPopup
            model: root.layouts.map((l, i) => ({ text: l.longName, index: i, icon: i === keyboard.layout ? "checkmark" : "" }))
            onClicked: item => keyboard.layout = item.index
        }
    }
}
