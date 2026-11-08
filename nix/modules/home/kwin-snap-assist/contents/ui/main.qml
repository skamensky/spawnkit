// Windows' Snap Assist for KWin: when a window is snapped to a half or a quarter of its
// screen and the space beside it is free, the other windows are offered for that space (after a
// quarter, first the other quarter of that side, then the other half). Arrow keys, Tab, Home
// and End move the highlight, Enter or a click picks a window, and the offer goes away at the
// first sign it is not wanted: Escape or any other key, a click or tap anywhere else, a window
// appearing or being activated, the snapped window leaving its place, or a desktop switch.
//
// It also owns Meta+Up and Meta+Down, which walk the active window up and down its side of the
// screen as on Windows: from a half to the top or bottom quarter and back, past the top to
// maximized, past the bottom to free again; a free window maximizes or minimizes. KWin's own
// Meta+Left and Meta+Right already turn a half into the corner on that side and carry a window
// to the next screen when it is pressed toward a screen it already touches.
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

    // The window that was snapped, the place left free beside it (one of the zone names below,
    // and its rectangle in screen coordinates), the windows offered for it (topmost first) and
    // which of them the keyboard highlights.
    property var snapped: null
    property string freeZone: ""
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

    // The halves and quarters of w's screen, by zone name.
    function zones(w) {
        const a = KWinComponents.Workspace.clientArea(KWinComponents.Workspace.MaximizeArea, w);
        const xm = Math.round(a.width / 2);
        const ym = Math.round(a.height / 2);
        return {
            full: a,
            left: Qt.rect(a.x, a.y, xm, a.height),
            right: Qt.rect(a.x + xm, a.y, a.width - xm, a.height),
            topleft: Qt.rect(a.x, a.y, xm, ym),
            bottomleft: Qt.rect(a.x, a.y + ym, xm, a.height - ym),
            topright: Qt.rect(a.x + xm, a.y, a.width - xm, ym),
            bottomright: Qt.rect(a.x + xm, a.y + ym, a.width - xm, a.height - ym)
        };
    }

    // The zone w fills, or null when it fills none.
    function zone(w) {
        const r = zones(w);
        return Object.keys(r).find(name => fills(w, r[name])) || null;
    }

    // What to fill once a window took a zone, most natural first: the rest of its side, then
    // the other side.
    readonly property var nextZones: ({
        left: ["right"],
        right: ["left"],
        topleft: ["bottomleft", "right"],
        bottomleft: ["topleft", "right"],
        topright: ["bottomright", "left"],
        bottomright: ["topright", "left"]
    })

    // KWin's quick-tile action that puts the active window in a zone.
    readonly property var tileSlot: ({
        left: "slotWindowQuickTileLeft",
        right: "slotWindowQuickTileRight",
        topleft: "slotWindowQuickTileTopLeft",
        bottomleft: "slotWindowQuickTileBottomLeft",
        topright: "slotWindowQuickTileTopRight",
        bottomright: "slotWindowQuickTileBottomRight"
    })

    // Offers the other windows when w, the active window, has just come to fill a half or a
    // quarter of its screen; withdraws an offer that w no longer justifies. A window that was
    // already in its zone and merely had its geometry restated (KWin does that when windows
    // around it come and go) is not being snapped, so it gets no new offer.
    property var filled: new Map()
    function consider(w) {
        const now = eligible(w) ? zone(w) : null;
        const settled = now !== null && filled.get(w) === now;
        if (now) {
            filled.set(w, now);
        } else {
            filled.delete(w);
        }
        if (!now || now === "full" || w.minimized || w.move || w.resize || w !== KWinComponents.Workspace.activeWindow) {
            if (w === snapped) {
                dismiss();
            }
            return;
        }
        if (settled && !visible) {
            return;
        }
        const r = zones(w);
        const others = KWinComponents.Workspace.stackingOrder.slice().reverse()
            .filter(c => c !== w && eligible(c) && c.output === w.output);
        const covered = name => others.some(c => !c.minimized && fills(c, r[name]));
        const taken = name => covered(name)
            || (name === "left" && covered("topleft") && covered("bottomleft"))
            || (name === "right" && covered("topright") && covered("bottomright"));
        const target = nextZones[now].find(name => !taken(name));
        if (others.length === 0 || !target) {
            dismiss();
            return;
        }
        const other = r[target];
        // The same offer again (the snapped window settled in a few steps): keep the highlight.
        if (!(visible && w === snapped && sameRect(other, free) && sameWindows(others, candidates))) {
            current = 0;
        }
        snapped = w;
        freeZone = target;
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
        const slot = tileSlot[freeZone];
        dismiss();
        c.minimized = false;
        KWinComponents.Workspace.activeWindow = c;
        KWinComponents.Workspace[slot]();
    }

    // Meta+Up and Meta+Down on the active window. KWin's quick-tile actions combine: Top on a
    // half gives that side's top quarter, Top on a bottom quarter gives the half back, and the
    // same direction again untiles (or moves to the screen in that direction, if any).
    function up() {
        const w = KWinComponents.Workspace.activeWindow;
        if (!w || w.deleted) {
            return;
        }
        switch (zone(w)) {
        case "full":
            break;
        case "left":
        case "right":
        case "bottomleft":
        case "bottomright":
            KWinComponents.Workspace.slotWindowQuickTileTop();
            break;
        case "topleft":
        case "topright":
            KWinComponents.Workspace.slotWindowMaximize();
            break;
        default:
            if (w.maximizable) {
                KWinComponents.Workspace.slotWindowMaximize();
            }
        }
    }

    function down() {
        const w = KWinComponents.Workspace.activeWindow;
        if (!w || w.deleted) {
            return;
        }
        switch (zone(w)) {
        case "full":
            KWinComponents.Workspace.slotWindowMaximize();
            break;
        case "left":
        case "right":
        case "topleft":
        case "topright":
        case "bottomleft":
        case "bottomright":
            KWinComponents.Workspace.slotWindowQuickTileBottom();
            break;
        default:
            if (w.minimizable) {
                KWinComponents.Workspace.slotWindowMinimize();
            }
        }
    }

    KWinComponents.ShortcutHandler {
        name: "Snap Assist Up"
        text: "Snap Assist: window up (maximize, top quarter)"
        sequence: "Meta+Up"
        onActivated: effect.up()
    }

    KWinComponents.ShortcutHandler {
        name: "Snap Assist Down"
        text: "Snap Assist: window down (bottom quarter, restore, minimize)"
        sequence: "Meta+Down"
        onActivated: effect.down()
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
