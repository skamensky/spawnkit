// A small round button on the desktop that skips to the next nature wallpaper
// (spawnkit-wallpaper next). Hovering shows the current photo's title and credit.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string command: "@wallpaper@"
    property var photo: ({ title: "", author: "", license: "" })
    property bool busy: false

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation
    toolTipMainText: photo.title || i18n("Next wallpaper")
    toolTipSubText: photo.author ? i18n("Photo: %1 (%2). Click for the next one.", photo.author, photo.license) : ""

    function run(action) { runner.connectSource(command + " " + action) }
    Component.onCompleted: run("current")

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            root.busy = false
            try { root.photo = JSON.parse(data.stdout) } catch (err) {}
        }
    }

    fullRepresentation: MouseArea {
        id: button
        Layout.minimumWidth: Kirigami.Units.iconSizes.large
        Layout.minimumHeight: Kirigami.Units.iconSizes.large
        Layout.preferredWidth: Kirigami.Units.iconSizes.large + Kirigami.Units.largeSpacing
        Layout.preferredHeight: Layout.preferredWidth
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        Accessible.role: Accessible.Button
        Accessible.name: i18n("Next wallpaper")
        onClicked: {
            if (root.busy)
                return
            root.busy = true
            root.run("next")
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height)
            height: width
            radius: width / 2
            color: Qt.rgba(0, 0, 0, button.containsMouse ? 0.55 : 0.32)
            border.color: Qt.rgba(1, 1, 1, button.containsMouse ? 0.5 : 0.25)
            border.width: 1
            Behavior on color { ColorAnimation { duration: Kirigami.Units.shortDuration } }

            Kirigami.Icon {
                anchors.centerIn: parent
                width: parent.width * 0.5
                height: width
                source: "media-skip-forward"
                color: "white"
                isMask: true
                opacity: root.busy ? 0.4 : 1
            }
        }
    }
}
