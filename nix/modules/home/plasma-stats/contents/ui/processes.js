// Helpers shared by the card's busiest-processes list and the process window.
.pragma library

// Brings a ListModel to items (objects with a unique `key`) in place, so delegates and their
// animations survive. With reorder the model takes items' order (ListView animates the moves);
// without it existing rows keep their places and new rows go after their predecessor in items.
function sync(model, items, reorder) {
    const keys = []
    for (let i = 0; i < model.count; i++)
        keys.push(model.get(i).key)
    const wanted = new Set(items.map(item => item.key))
    for (let i = keys.length - 1; i >= 0; i--)
        if (!wanted.has(keys[i])) {
            model.remove(i)
            keys.splice(i, 1)
        }
    if (reorder) {
        items.forEach((item, i) => {
            const at = keys.indexOf(item.key, i)
            if (at < 0) {
                model.insert(i, item)
                keys.splice(i, 0, item.key)
            } else {
                if (at !== i) {
                    model.move(at, i, 1)
                    keys.splice(i, 0, keys.splice(at, 1)[0])
                }
                model.set(i, item)
            }
        })
        return
    }
    let previous = -1
    items.forEach(item => {
        const at = keys.indexOf(item.key)
        if (at >= 0) {
            model.set(at, item)
            previous = at
        } else {
            model.insert(previous + 1, item)
            keys.splice(previous + 1, 0, item.key)
            previous++
        }
    })
}

function bytes(n) {
    if (n >= 1073741824)
        return (n / 1073741824).toFixed(1) + " GiB"
    if (n >= 1048576)
        return Math.round(n / 1048576) + " MiB"
    return Math.round(n / 1024) + " KiB"
}

function percent(value) {
    return (value >= 10 ? Math.round(value) : value.toFixed(1)) + "%"
}

function target(proc) {
    return proc.pid + ":" + proc.start
}

// "desc" for usage, "asc" for name and PID.
function compare(sort, descending) {
    const sign = descending ? -1 : 1
    return (a, b) => {
        let d
        if (sort === "name")
            d = a.name.toLowerCase().localeCompare(b.name.toLowerCase())
        else if (sort === "pid")
            d = a.pid - b.pid
        else if (sort === "memory")
            d = a.memory - b.memory
        else
            d = a.cpu - b.cpu
        return d !== 0 ? sign * d : a.name.localeCompare(b.name) || a.pid - b.pid
    }
}
