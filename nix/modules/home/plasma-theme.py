"""Switch the live Plasma desktop between the curated global themes.

The gallery subcommand is a thin browser front end over list, apply and revert.
"""

import argparse
import html
import json
import os
import subprocess
import sys
import errno
import shutil
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CATALOG = json.loads(Path(os.environ["SPAWNKIT_PLASMA_THEMES"]).read_text())
STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "spawnkit/plasma-theme.json"
# One fixed port, so launching the gallery again reopens the running one.
PORT = 47613
PREVIEWS = ("fullscreenpreview.jpg", "fullscreenpreview.png", "preview.png", "preview.jpg")


def data_dirs():
    home = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))
    rest = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
    return [Path(d) for d in [home, *rest] if d]


def package_dir(lookandfeel):
    for d in data_dirs():
        p = d / "plasma/look-and-feel" / lookandfeel
        if p.is_dir():
            return p
    return None


def preview(lookandfeel):
    p = package_dir(lookandfeel)
    for name in PREVIEWS if p else ():
        f = p / "contents/previews" / name
        if f.is_file():
            return f
    return None


def read(file, group, key):
    r = subprocess.run(["kreadconfig6", "--file", file, "--group", group, "--key", key], capture_output=True, text=True)
    return r.stdout.strip()


def current():
    return {
        # Plasma leaves the key unset until a global theme is chosen; its default is Breeze.
        "lookandfeel": read("kdeglobals", "KDE", "LookAndFeelPackage") or "org.kde.breeze.desktop",
        "kvantum": read("Kvantum/kvantum.kvconfig", "General", "theme"),
    }


def themes():
    now = current()["lookandfeel"]
    return [
        {**t, "installed": package_dir(t["lookandfeel"]) is not None, "active": t["lookandfeel"] == now}
        for t in CATALOG
    ]


def apply_state(lookandfeel, kvantum):
    if package_dir(lookandfeel) is None:
        raise SystemExit(f"look-and-feel {lookandfeel} is not installed")
    # Kvantum first, so the widget style the look-and-feel selects draws with the right theme.
    value = [kvantum] if kvantum else ["--delete"]
    subprocess.run(["kwriteconfig6", "--file", "Kvantum/kvantum.kvconfig", "--group", "General", "--key", "theme", *value], check=True)
    # Without --resetLayout the panels and widgets stay as they are.
    subprocess.run(["plasma-apply-lookandfeel", "--apply", lookandfeel], check=True, capture_output=True)


def apply(theme_id):
    theme = next((t for t in CATALOG if t["id"] == theme_id), None)
    if theme is None:
        raise SystemExit(f"unknown theme {theme_id}; see list")
    if not STATE.exists():
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(current()))
    apply_state(theme["lookandfeel"], theme.get("kvantum"))
    return theme


def revert():
    if not STATE.exists():
        raise SystemExit("nothing to revert: no theme was applied through this tool")
    saved = json.loads(STATE.read_text())
    apply_state(saved["lookandfeel"], saved["kvantum"])
    STATE.unlink()
    return saved


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Plasma themes</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><style>
:root{color-scheme:dark;--bg:#111318;--card:#1b1e26;--line:#2a2f3a;--fg:#e8eaf0;--mute:#9aa0ad;--accent:#7aa2ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 Inter,system-ui,sans-serif}
header{position:sticky;top:0;z-index:2;display:flex;gap:12px;align-items:center;flex-wrap:wrap;padding:14px 20px;background:#111318ee;backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}
h1{font-size:18px;margin:0 12px 0 0}button,.chip{font:inherit;color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:8px;padding:6px 12px;cursor:pointer}
.chip.on{border-color:var(--accent);color:var(--accent)}#status{color:var(--mute);margin-left:auto}
main{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:18px;padding:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden;display:flex;flex-direction:column}
.card.active{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.card img{width:100%;aspect-ratio:16/10;object-fit:cover;background:#000;display:block;cursor:zoom-in}
.body{padding:12px 14px;display:flex;flex-direction:column;gap:6px;flex:1}.row{display:flex;justify-content:space-between;align-items:center;gap:8px}
.name{font-weight:600}.tag{font-size:12px;color:var(--mute)}.desc{color:var(--mute);font-size:14px;flex:1}
.apply{background:var(--accent);color:#0b1020;border:0;font-weight:600}.card.active .apply{background:transparent;color:var(--accent);border:1px solid var(--accent)}
dialog{border:0;padding:0;background:transparent;max-width:95vw}dialog img{max-width:95vw;max-height:90vh;border-radius:8px}dialog::backdrop{background:#000c}
</style></head><body><header><h1>Plasma themes</h1><span class="chip on" data-f="all">All</span><span class="chip" data-f="dark">Dark</span><span class="chip" data-f="light">Light</span>
<button id="revert">Revert to original</button><span id="status">Click Apply: your real desktop changes.</span></header><main id="grid"></main>
<dialog id="zoom"><img alt=""></dialog><script>
let themes=[],filter="all";const grid=document.getElementById("grid"),status=document.getElementById("status");
const esc=s=>String(s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
function render(){grid.innerHTML=themes.filter(t=>filter=="all"||t.tone==filter).map(t=>`<div class="card${t.active?" active":""}">
<img loading="lazy" src="/preview/${t.id}" alt="${esc(t.name)} preview" onerror="this.style.visibility='hidden'">
<div class="body"><div class="row"><span class="name">${esc(t.name)}</span><span class="tag">${esc(t.tone)}${t.installed?"":" · not installed"}</span></div>
<div class="desc">${esc(t.description)}</div><div class="row"><span class="tag">${esc(t.author)}</span>
<button class="apply" data-id="${t.id}" ${t.installed?"":"disabled"}>${t.active?"Active":"Apply"}</button></div></div></div>`).join("")}
async function load(){themes=await (await fetch("/themes")).json();render()}
async function post(url,label){status.textContent=label+"…";const r=await fetch(url,{method:"POST"});status.textContent=r.ok?(await r.text()):"Failed: "+await r.text();load()}
grid.onclick=e=>{const b=e.target.closest(".apply");if(b){const t=themes.find(x=>x.id==b.dataset.id);post("/apply/"+t.id,"Applying "+t.name)}
else if(e.target.tagName=="IMG"){const z=document.getElementById("zoom");z.querySelector("img").src=e.target.src;z.showModal()}};
document.getElementById("zoom").onclick=e=>e.currentTarget.close();
document.getElementById("revert").onclick=()=>post("/revert","Reverting");
document.querySelectorAll(".chip").forEach(c=>c.onclick=()=>{document.querySelectorAll(".chip").forEach(x=>x.classList.toggle("on",x==c));filter=c.dataset.f;render()});
load();</script></body></html>"""


class Gallery(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body, kind="text/plain; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            return self.reply(200, PAGE, "text/html; charset=utf-8")
        if self.path == "/themes":
            return self.reply(200, json.dumps(themes()), "application/json")
        if self.path.startswith("/preview/"):
            theme = next((t for t in CATALOG if t["id"] == self.path[9:]), None)
            f = theme and preview(theme["lookandfeel"])
            if f:
                return self.reply(200, f.read_bytes(), "image/png" if f.suffix == ".png" else "image/jpeg")
        self.reply(404, "not found")

    def do_POST(self):
        # Only this page may switch the desktop; refuse requests another site's page sends.
        if self.headers.get("Origin") not in (None, f"http://{self.headers.get('Host')}"):
            return self.reply(403, "forbidden")
        try:
            if self.path.startswith("/apply/"):
                theme = apply(self.path[7:])
                return self.reply(200, f"Applied {theme['name']}. Already open Qt apps restyle when restarted.")
            if self.path == "/revert":
                revert()
                return self.reply(200, "Reverted to the original theme.")
        except (SystemExit, subprocess.CalledProcessError) as e:
            return self.reply(500, html.escape(str(e)))
        self.reply(404, "not found")


def main():
    parser = argparse.ArgumentParser(prog="spawnkit-plasma-theme", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="list the curated themes").add_argument("--json", action="store_true")
    sub.add_parser("current", help="show the applied look-and-feel and Kvantum theme as JSON")
    sub.add_parser("apply", help="apply a theme to the running desktop").add_argument("id")
    sub.add_parser("revert", help="restore the theme from before the first apply")
    g = sub.add_parser("gallery", help="browse and apply themes from a local web page")
    g.add_argument("--no-browser", action="store_true", help="print the URL instead of opening it")
    args = parser.parse_args()

    if args.cmd == "list":
        rows = themes()
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for t in rows:
                mark = "*" if t["active"] else (" " if t["installed"] else "!")
                print(f"{mark} {t['id']:<22} {t['tone']:<5} {t['name']}")
    elif args.cmd == "current":
        print(json.dumps(current()))
    elif args.cmd == "apply":
        print(f"applied {apply(args.id)['id']}")
    elif args.cmd == "revert":
        print(json.dumps(revert()))
    elif args.cmd == "gallery":
        url = f"http://127.0.0.1:{PORT}/"
        try:
            server = ThreadingHTTPServer(("127.0.0.1", PORT), Gallery)
        except OSError as e:
            if e.errno != errno.EADDRINUSE:
                raise
            server = None
        print(url, flush=True)
        if not args.no_browser:
            open_window(url)
        if server:
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                sys.exit(0)


def open_window(url):
    # A tab handed to an already running Chrome lands behind its existing window; an app
    # window is a new window, which KWin raises.
    chrome = shutil.which("google-chrome")
    if chrome:
        subprocess.Popen([chrome, f"--app={url}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        webbrowser.open(url)


main()
