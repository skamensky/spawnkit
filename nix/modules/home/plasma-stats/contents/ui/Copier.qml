// Puts `spawnkit-stats details` for a row on the clipboard, opening with where it was copied from,
// so the card and the process window copy the same text.
import QtQuick
import org.kde.plasma.plasma5support as P5Support
import "processes.js" as P

Item {
    id: copier
    property string stats
    // A passing confirmation for a status line.
    property string message
    property var pending: ({})

    // targets: space-separated "PID:START"; label names the row; view: a `details --view` choice.
    function copy(targets, label, view) {
        const command = stats + " details --text --view " + view + " --row=" + P.quoted(label) + " " + targets
        pending[command] = label
        runner.connectSource(command)
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            const label = copier.pending[source]
            delete copier.pending[source]
            const text = data.stdout.trim()
            if (text) {
                clipboard.text = text
                clipboard.selectAll()
                clipboard.copy()
            }
            copier.message = text ? i18n("Copied the details of %1", label)
                : i18n("Couldn't copy the details of %1", label)
            messageEnds.restart()
        }
    }
    // Text items are QML's way to the clipboard.
    TextEdit { id: clipboard; visible: false }
    Timer {
        id: messageEnds
        interval: 3000
        onTriggered: copier.message = ""
    }
}
