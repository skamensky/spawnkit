// Windows' Snap Assist for KWin: when a window is snapped to the left or right half of its
// screen and nothing fills the other half, the other windows are offered there. Arrow keys,
// Tab, Home and End move the highlight, Enter or a click picks a window, and the offer goes
// away at the first sign it is not wanted: Escape or any other key, a click or tap anywhere
// else, a window appearing or being activated, the snapped window leaving its half, or a
// desktop switch.
//
// This is a scene effect rather than a KWin script with a window of its own because KWin
// delivers keyboard input only to the active Wayland surface; a window KWin creates for
// itself has none, so it can never see Escape or the arrows. An active scene effect grabs the
// keyboard and the pointer, and its per-screen views replace KWin's scene, so each view first
// draws the desktop as it is (wallpaper, panel and windows at their places) and then the offer
// on top.
import QtQuick
import org.kde.kwin as KWinComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

KWinComponents.SceneEffect {
    id: effect

    // The window that was snapped, the half it left free (in screen coordinates), the windows
    // offered for it (topmost first) and which of them the keyboard highlights.
    property var snapped: null
    property bool freeIsLeft: false
    property rect free: Qt.rect(0, 0, 0, 0)
    property var candidates: []
    property int current: 0
    // The grid's column count, set by the view that lays the tiles out, so Up and Down move
    // by a row.
    property int columns: 1

    function near(a, b) {
        return Math.abs(a - b) <= 2;
    }

    function fills(w, rect) {
        const g = w.frameGeometry;
        return near(g.x, rect.x) && near(g.y, rect.y) && near(g.width, rect.width) && near(g.height, rect.height);
    }

    function onDesktop(w) {
        return w.onAllDesktops || w.desktops.indexOf(KWinComponents.Workspace.currentDesktop) !== -1;
    }

    // KWin's own windows (an effect's or a script's QML window) have no process behind them.
    function eligible(w) {
        return w && !w.deleted && w.pid > 0 && w.normalWindow && !w.skipTaskbar && onDesktop(w);
    }

    // Geometry settles over several signals; look once it has.
    Timer {
        id: settle
        interval: 120
        property var window: null
        onTriggered: effect.consider(window)
    }

    function later(w) {
        settle.window = w;
        settle.restart();
    }

    // The half of its screen that w fills, as {side, free}: side is "left" or "right" and free
    // the other half in screen coordinates. Null when w fills neither.
    function half(w) {
        const area = KWinComponents.Workspace.clientArea(KWinComponents.Workspace.MaximizeArea, w);
        const split = Math.round(area.width / 2);
        const left = Qt.rect(area.x, area.y, split, area.height);
        const right = Qt.rect(area.x + split, area.y, area.width - split, area.height);
        if (fills(w, left)) {
            return { side: "left", free: right };
        }
        if (fills(w, right)) {
            return { side: "right", free: left };
        }
        return null;
    }

    // Offers the other windows when w, the active window, has just come to fill half of its
    // screen; withdraws an offer that w no longer justifies. A window that was already in its
    // half and merely had its geometry restated (KWin does that when windows around it come
    // and go) is not being snapped, so it gets no new offer.
    property var filled: new Map()
    function consider(w) {
        const now = eligible(w) ? half(w) : null;
        const settled = now !== null && filled.get(w) === now.side;
        if (now) {
            filled.set(w, now.side);
        } else {
            filled.delete(w);
        }
        if (!now || w.minimized || w.move || w.resize || w !== KWinComponents.Workspace.activeWindow) {
            if (w === snapped) {
                dismiss();
            }
            return;
        }
        if (settled && !visible) {
            return;
        }
        const other = now.free;
        const others = KWinComponents.Workspace.stackingOrder.slice().reverse()
            .filter(c => c !== w && eligible(c) && c.output === w.output);
        if (others.length === 0 || others.some(c => !c.minimized && fills(c, other))) {
            dismiss();
            return;
        }
        // The same offer again (the snapped window settled in a few steps): keep the highlight.
        if (!(visible && w === snapped && sameRect(other, free) && sameWindows(others, candidates))) {
            current = 0;
        }
        snapped = w;
        freeIsLeft = now.side === "right";
        free = other;
        candidates = others;
        visible = true;
    }

    function sameRect(a, b) {
        return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
    }

    function sameWindows(a, b) {
        return a.length === b.length && a.every((w, i) => w === b[i]);
    }

    function dismiss() {
        visible = false;
        candidates = [];
        snapped = null;
    }

    function choose(c) {
        if (!c || c.deleted) {
            dismiss();
            return;
        }
        const toLeft = freeIsLeft;
        dismiss();
        c.minimized = false;
        KWinComponents.Workspace.activeWindow = c;
        if (toLeft) {
            KWinComponents.Workspace.slotWindowQuickTileLeft();
        } else {
            KWinComponents.Workspace.slotWindowQuickTileRight();
        }
    }

    function move(delta, wrap) {
        const n = candidates.length;
        if (n === 0) {
            return;
        }
        const target = current + delta;
        if (wrap) {
            current = ((target % n) + n) % n;
        } else if (target >= 0 && target < n) {
            current = target;
        }
    }

    // Every view forwards its key presses here, whichever screen the pointer is on.
    function key(event) {
        switch (event.key) {
        case Qt.Key_Escape:
            dismiss();
            break;
        case Qt.Key_Left:
        case Qt.Key_Backtab:
            move(-1, true);
            break;
        case Qt.Key_Right:
        case Qt.Key_Tab:
            move(1, true);
            break;
        case Qt.Key_Up:
            move(-columns, false);
            break;
        case Qt.Key_Down:
            move(columns, false);
            break;
        case Qt.Key_Home:
            current = 0;
            break;
        case Qt.Key_End:
            current = Math.max(0, candidates.length - 1);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            choose(candidates[current]);
            break;
        case Qt.Key_Shift:
        case Qt.Key_Control:
        case Qt.Key_Alt:
        case Qt.Key_AltGr:
        case Qt.Key_Meta:
        case Qt.Key_Super_L:
        case Qt.Key_Super_R:
        case Qt.Key_CapsLock:
        case Qt.Key_NumLock:
            // A modifier on its own, as at the start of Meta+Right, which KWin handles as a
            // shortcut before it reaches the effect; the snapped window will move and the offer
            // follow it.
            break;
        default:
            // Anything else was meant for the snapped window: get out of its way.
            dismiss();
        }
        event.accepted = true;
    }

    function watch(w) {
        if (!w.normalWindow || w.pid <= 0) {
            return;
        }
        const later = () => effect.later(w);
        const minimized = () => {
            if (w === effect.snapped && w.minimized) {
                effect.dismiss();
            }
        };
        w.quickTileModeChanged.connect(later);
        w.tileChanged.connect(later);
        w.frameGeometryChanged.connect(later);
        w.minimizedChanged.connect(minimized);
        watched.push([w, later, minimized]);
    }

    function unwatch(w) {
        watched = watched.filter(([c, later, minimized]) => {
            if (c !== w) {
                return true;
            }
            c.quickTileModeChanged.disconnect(later);
            c.tileChanged.disconnect(later);
            c.frameGeometryChanged.disconnect(later);
            c.minimizedChanged.disconnect(minimized);
            effect.filled.delete(c);
            return false;
        });
    }

    // Window signals outlive the effect; drop them when KWin unloads it.
    property var watched: []
    Component.onCompleted: Array.from(KWinComponents.Workspace.windows).forEach(watch)
    Component.onDestruction: watched.slice().forEach(([w]) => unwatch(w))

    Connections {
        target: KWinComponents.Workspace
        function onWindowAdded(w) {
            effect.watch(w);
            // A window of KWin's own, such as the tile outline, is not the user turning away.
            if (effect.visible && w.pid > 0 && (w.normalWindow || w.dialog || w.popupWindow || w.utility)) {
                effect.dismiss();
            }
        }
        function onWindowRemoved(w) {
            effect.unwatch(w);
            if (!effect.visible) {
                return;
            }
            if (w === effect.snapped) {
                effect.dismiss();
            } else if (effect.candidates.indexOf(w) !== -1) {
                const rest = effect.candidates.filter(c => c !== w);
                if (rest.length === 0) {
                    effect.dismiss();
                } else {
                    effect.candidates = rest;
                    effect.current = Math.min(effect.current, rest.length - 1);
                }
            }
        }
        function onWindowActivated(w) {
            if (effect.visible && w !== effect.snapped) {
                effect.dismiss();
            }
        }
        function onCurrentDesktopChanged() {
            effect.dismiss();
        }
    }

    delegate: FocusScope {
        id: view
        focus: true

        readonly property var targetScreen: KWinComponents.SceneView.screen
        readonly property bool here: effect.snapped !== null && effect.snapped.output.name === targetScreen.name

        Keys.onPressed: event => effect.key(event)

        // The desktop as it is: the desktop window, the panel and every window on this screen,
        // in stacking order. Minimized and hidden windows are not on it, nor KWin's own windows
        // (they have no process behind them). A translucent window loses the blur KWin's scene
        // puts behind it, so each window gets an opaque backdrop in the theme's window color,
        // which is about what the blur would show.
        Repeater {
            model: KWinComponents.WindowFilterModel {
                activity: KWinComponents.Workspace.currentActivity
                desktop: KWinComponents.Workspace.currentDesktop
                screenName: view.targetScreen.name
                windowModel: KWinComponents.WindowModel {}
            }

            Item {
                x: model.window.x - view.targetScreen.geometry.x
                y: model.window.y - view.targetScreen.geometry.y
                width: model.window.width
                height: model.window.height
                z: model.window.stackingOrder
                visible: !model.window.minimized && !model.window.hidden && model.window.pid > 0

                Rectangle {
                    anchors.fill: parent
                    visible: !model.window.desktopWindow
                    radius: Kirigami.Units.cornerRadius
                    Kirigami.Theme.colorSet: Kirigami.Theme.Window
                    Kirigami.Theme.inherit: false
                    color: Kirigami.Theme.backgroundColor
                }

                KWinComponents.WindowThumbnail {
                    client: model.window
                    anchors.fill: parent
                }
            }
        }

        // Any press away from the offered windows ends the offer.
        MouseArea {
            anchors.fill: parent
            z: 1000000
            acceptedButtons: Qt.AllButtons
            onPressed: effect.dismiss()
        }

        Item {
            id: offer
            visible: view.here
            z: 1000001
            x: effect.free.x - view.targetScreen.geometry.x
            y: effect.free.y - view.targetScreen.geometry.y
            width: effect.free.width
            height: effect.free.height
            opacity: visible ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: Kirigami.Units.shortDuration
                }
            }

            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(0, 0, 0, 0.4)
            }

            Grid {
                id: grid
                readonly property int count: effect.candidates.length
                readonly property real gap: Kirigami.Units.gridUnit
                readonly property real captionHeight: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing * 3
                readonly property real aspect: view.targetScreen.geometry.height / view.targetScreen.geometry.width
                columns: Math.max(1, Math.ceil(Math.sqrt(count)))
                readonly property int rowCount: Math.ceil(count / columns)
                readonly property real cellWidth: Math.min(Kirigami.Units.gridUnit * 24,
                    (offer.width - gap * (columns + 1)) / columns,
                    ((offer.height - gap * (rowCount + 1)) / rowCount - captionHeight) / aspect)
                readonly property real cellHeight: cellWidth * aspect + captionHeight
                anchors.centerIn: parent
                spacing: gap
                onColumnsChanged: effect.columns = columns
                Component.onCompleted: effect.columns = columns

                Repeater {
                    model: effect.candidates

                    Rectangle {
                        id: tile
                        required property var modelData
                        required property int index
                        readonly property bool highlighted: effect.current === index
                        width: grid.cellWidth
                        height: grid.cellHeight
                        radius: Kirigami.Units.cornerRadius
                        color: highlighted ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(1, 1, 1, 0.08)
                        border.color: highlighted ? Kirigami.Theme.highlightColor : "transparent"
                        border.width: 2

                        Row {
                            id: caption
                            x: Kirigami.Units.smallSpacing * 2
                            y: Kirigami.Units.smallSpacing * 2
                            width: parent.width - x * 2
                            height: Kirigami.Units.iconSizes.small
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
                                verticalAlignment: Text.AlignVCenter
                                height: parent.height
                                width: caption.width - Kirigami.Units.iconSizes.small - caption.spacing
                            }
                        }

                        KWinComponents.WindowThumbnail {
                            client: tile.modelData
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing * 2
                            anchors.topMargin: grid.captionHeight
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: effect.current = tile.index
                            onClicked: effect.choose(tile.modelData)
                        }
                    }
                }
            }
        }
    }
}
