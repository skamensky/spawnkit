// Ends processes through `spawnkit-stats signal` and remembers where each row's ending stands, so
// the card and the process window show the same state for the same process or app.
//
// A row (keyed by its process or group key) goes idle → "ending" (SIGTERM sent, up to 3 s to exit)
// → gone, or → "stubborn" when something is still running, which offers SIGKILL ("killing").
// Rows the desktop session needs first pass through "confirm".
import QtQuick
import org.kde.plasma.plasma5support as P5Support

Item {
    id: ender
    property string stats
    // {key: "confirm" | "ending" | "stubborn" | "killing"}
    property var states: ({})
    // The last outcome, for a status line.
    property string message
    property var pending: ({})

    function state(key) {
        return states[key] || ""
    }
    function put(key, value) {
        const next = Object.assign({}, states)
        if (value)
            next[key] = value
        else
            delete next[key]
        states = next
    }

    // targets: "PID:START" strings; label names the process or app in messages.
    function end(key, targets, label, critical) {
        const now = state(key)
        if (now === "ending" || now === "killing")
            return
        if (now === "stubborn") {
            run(key, targets, label, "--kill", "killing")
            return
        }
        if (critical && now !== "confirm") {
            put(key, "confirm")
            unconfirm.restart()
            return
        }
        run(key, targets, label, "--term", "ending")
    }
    function run(key, targets, label, flag, phase) {
        const command = stats + " signal " + flag + " --wait 3 " + targets.join(" ")
        pending[command] = { key, label, flag, count: targets.length }
        put(key, phase)
        runner.connectSource(command)
    }

    Timer {
        id: unconfirm
        interval: 4000
        onTriggered: {
            const next = {}
            for (const key in ender.states)
                if (ender.states[key] !== "confirm")
                    next[key] = ender.states[key]
            ender.states = next
        }
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            const job = ender.pending[source]
            delete ender.pending[source]
            if (!job)
                return
            let results = []
            try {
                results = JSON.parse(data.stdout).results
            } catch (err) {
                ender.put(job.key, "")
                ender.message = i18n("Couldn't end %1: %2", job.label, (data.stderr || "").trim() || i18n("no answer"))
                return
            }
            const denied = results.filter(r => !r.exited && r.error)
            const running = results.filter(r => !r.exited && !r.error)
            if (denied.length && !running.length) {
                ender.put(job.key, "")
                ender.message = i18n("Couldn't end %1: %2", job.label, denied[0].error)
            } else if (running.length) {
                ender.put(job.key, job.flag === "--kill" ? "" : "stubborn")
                ender.message = job.flag === "--kill"
                    ? i18n("%1 survived SIGKILL (it may be stuck in the kernel)", job.label)
                    : i18n("%1 is still running · Force kill sends SIGKILL", job.label)
            } else {
                ender.put(job.key, "")
                ender.message = job.flag === "--kill" ? i18n("Killed %1", job.label) : i18n("Ended %1", job.label)
            }
        }
    }
}
