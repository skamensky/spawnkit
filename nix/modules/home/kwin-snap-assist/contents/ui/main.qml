// Windows' Snap Assist for KWin: when a window is snapped to the left or right half of its
// screen and nothing fills the other half, offer the other windows there; clicking one snaps
// it into that half. Escape, a click on the backdrop or activating another window dismisses it.
import QtQuick
import QtQuick.Window
import org.kde.kwin
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Item {
    id: root

    property var snapped: null
    property bool freeIsLeft: false
    property var candidates: []

    // Geometry settles over several signals; look once it has.
    Timer {
        id: settle
        interval: 150
        property var window: null
        onTriggered: root.consider(window)
    }

    function near(a, b) {
        return Math.abs(a - b) <= 2;
    }

    function fills(w, rect) {
        const g = w.frameGeometry;
        return near(g.x, rect.x) && near(g.y, rect.y) && near(g.width, rect.width) && near(g.height, rect.height);
    }

    function onDesktop(w) {
        return w.onAllDesktops || w.desktops.indexOf(Workspace.currentDesktop) !== -1;
    }

    function eligible(w) {
        return w && w.normalWindow && !w.skipTaskbar && !w.deleted && onDesktop(w);
    }

    function consider(w) {
        if (assist.visible || !eligible(w) || w.minimized || w !== Workspace.activeWindow) {
            return;
        }
        const area = Workspace.clientArea(KWin.MaximizeArea, w);
        const half = Math.round(area.width / 2);
        const left = Qt.rect(area.x, area.y, half, area.height);
        const right = Qt.rect(area.x + half, area.y, area.width - half, area.height);
        let free;
        if (fills(w, left)) {
            free = right;
        } else if (fills(w, right)) {
            free = left;
        } else {
            return;
        }
        const others = Workspace.stackingOrder.slice().reverse().filter(c => eligible(c) && c !== w && c.output === w.output);
        if (others.length === 0 || others.some(c => !c.minimized && fills(c, free))) {
            return;
        }
        snapped = w;
        freeIsLeft = free === left;
        candidates = others;
        assist.width = free.width;
        assist.height = free.height;
        assist.show();
        // KWin places a new window itself; move it over the free half once it is mapped.
        assist.x = free.x;
        assist.y = free.y;
        assist.requestActivate();
    }

    function dismiss() {
        assist.visible = false;
        candidates = [];
        snapped = null;
    }

    function choose(c) {
        const left = freeIsLeft;
        dismiss();
        c.minimized = false;
        Workspace.activeWindow = c;
        if (left) {
            Workspace.slotWindowQuickTileLeft();
        } else {
            Workspace.slotWindowQuickTileRight();
        }
    }

    function watch(w) {
        if (!w.normalWindow) {
            return;
        }
        const later = () => {
            settle.window = w;
            settle.restart();
        };
        w.quickTileModeChanged.connect(later);
        w.tileChanged.connect(later);
        watched.push([w, later]);
    }

    // Window signals outlive the script; drop them when KWin unloads it.
    property var watched: []
    Component.onCompleted: Array.from(Workspace.windows).forEach(watch)
    Component.onDestruction: watched.forEach(([w, later]) => {
        w.quickTileModeChanged.disconnect(later);
        w.tileChanged.disconnect(later);
    })

    Connections {
        target: Workspace
        function onWindowAdded(w) {
            root.watch(w);
        }
        function onWindowRemoved(w) {
            root.watched = root.watched.filter(([c]) => c !== w);
        }
        function onWindowActivated(w) {
            if (assist.visible && root.eligible(w) && w !== root.snapped) {
                root.dismiss();
            }
        }
        function onCurrentDesktopChanged() {
            root.dismiss();
        }
    }

    Window {
        id: assist
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "transparent"
        visible: false
        onActiveChanged: if (!active && visible) root.dismiss()

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.45)
            focus: true
            Keys.onEscapePressed: root.dismiss()

            MouseArea {
                anchors.fill: parent
                onClicked: root.dismiss()
            }

            Grid {
                id: grid
                readonly property int count: root.candidates.length
                readonly property real gap: Kirigami.Units.gridUnit
                columns: Math.max(1, Math.ceil(Math.sqrt(count)))
                readonly property int rowCount: Math.ceil(count / columns)
                readonly property real cellWidth: Math.min(Kirigami.Units.gridUnit * 22,
                    (assist.width - gap * (columns + 1)) / columns)
                readonly property real cellHeight: Math.min(cellWidth * 0.7,
                    (assist.height - gap * (rowCount + 1)) / rowCount)
                anchors.centerIn: parent
                spacing: gap

                Repeater {
                    model: root.candidates

                    Rectangle {
                        id: tile
                        required property var modelData
                        width: grid.cellWidth
                        height: grid.cellHeight
                        radius: Kirigami.Units.cornerRadius
                        color: hover.containsMouse ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(1, 1, 1, 0.08)
                        border.color: hover.containsMouse ? Kirigami.Theme.highlightColor : "transparent"
                        border.width: 2

                        Row {
                            id: caption
                            x: Kirigami.Units.smallSpacing * 2
                            y: Kirigami.Units.smallSpacing * 2
                            width: parent.width - x * 2
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: tile.modelData.icon
                                width: Kirigami.Units.iconSizes.small
                                height: width
                            }
                            PlasmaComponents.Label {
                                text: tile.modelData.caption
                                color: "white"
                                elide: Text.ElideRight
                                width: caption.width - Kirigami.Units.iconSizes.small - caption.spacing
                            }
                        }

                        WindowThumbnail {
                            wId: tile.modelData.internalId
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing * 2
                            anchors.topMargin: caption.y + caption.height + Kirigami.Units.smallSpacing
                        }

                        MouseArea {
                            id: hover
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.choose(tile.modelData)
                        }
                    }
                }
            }
        }
    }
}
