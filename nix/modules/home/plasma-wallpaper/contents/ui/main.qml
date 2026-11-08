// The wallpaper's controls on the desktop: a smoked-glass pill with previous and next buttons
// (spawnkit-wallpaper previous|next). Hovering it slides out the photo's title and credit.
// Built from the Spawnkit UI kit (Theme's glass tokens, IconButton), copied in as ./Spawnkit.
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import "Spawnkit"

PlasmoidItem {
    id: root

    readonly property string command: "@wallpaper@"
    property var photo: ({ title: "", author: "", license: "" })
    property bool busy: false

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

    function run(action) {
        if (action !== "current") {
            if (busy)
                return
            busy = true
        }
        runner.connectSource(command + " " + action)
    }
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

    fullRepresentation: Item {
        id: stage
        Layout.minimumWidth: 320
        Layout.minimumHeight: 56
        Layout.preferredWidth: 320
        Layout.preferredHeight: 56

        HoverHandler { id: hover }
        readonly property bool open: hover.hovered && root.photo.title !== ""

        // The pill hugs the right edge and grows leftwards to show the caption.
        Item {
            id: pill
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            height: 48
            width: buttons.width + (stage.open ? caption.implicitWidth + Theme.s3 : 0) + Theme.s1 * 2
            Behavior on width {
                enabled: Theme.motion
                NumberAnimation { duration: Theme.standard; easing.type: Easing.OutCubic }
            }

            Rectangle {
                id: glass
                anchors.fill: parent
                radius: height / 2
                color: stage.open ? Theme.glassHover : Theme.glass
                border.width: 1
                border.color: Theme.glassEdge
                Behavior on color { ColorAnimation { duration: Theme.quick } }
                layer.enabled: true
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: Theme.glassShadow
                    shadowBlur: 0.6
                    shadowVerticalOffset: 2
                }
            }

            Column {
                id: caption
                anchors { left: parent.left; leftMargin: Theme.s4; verticalCenter: parent.verticalCenter }
                width: Math.min(implicitWidth, pill.width - buttons.width - Theme.s4)
                spacing: 1
                clip: true
                opacity: stage.open ? 1 : 0
                visible: opacity > 0
                Behavior on opacity {
                    enabled: Theme.motion
                    NumberAnimation { duration: Theme.quick }
                }
                Text {
                    width: Math.min(implicitWidth, 200)
                    text: root.photo.title
                    elide: Text.ElideRight
                    color: Theme.glassText
                    font { family: Theme.font; pointSize: Theme.metaSize; weight: Font.DemiBold }
                }
                Text {
                    width: Math.min(implicitWidth, 200)
                    text: root.photo.author ? root.photo.author + " · " + root.photo.license : ""
                    elide: Text.ElideRight
                    color: Theme.glassTextSecondary
                    font { family: Theme.font; pointSize: Theme.microSize }
                }
            }

            Row {
                id: buttons
                anchors { right: parent.right; rightMargin: Theme.s1; verticalCenter: parent.verticalCenter }
                spacing: 0
                IconButton {
                    glass: true
                    size: 40
                    iconScale: 0.55
                    iconName: "go-previous"
                    tooltip: i18n("Previous wallpaper")
                    enabled: !root.busy
                    onClicked: root.run("previous")
                }
                Rectangle {
                    width: 1
                    height: 22
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.glassEdge
                }
                IconButton {
                    glass: true
                    size: 40
                    iconScale: 0.55
                    iconName: "go-next"
                    tooltip: i18n("Next wallpaper")
                    enabled: !root.busy
                    onClicked: root.run("next")
                }
            }
        }
    }
}
