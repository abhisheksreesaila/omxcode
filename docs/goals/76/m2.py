"""Goal 76 M2: omxplorer wears the ribbon, the panels closed (docs/goals/76.md).

1. Nothing lost: every message the old menu bar, toolbar and rail sent (read from omxplorer at 1bf85bec) is sent by a ribbon tool
   or by the File menu now (read from today's source), but for the colour items, which the ribbon's Text colour / Fill colour
   pickers offer (EQUIVALENT); the other menus are still in the tree, hidden, for their shortcuts.
2. GTK (headless, 1440x900, settings holding the old "inspector=yes"), fleet.csv open (OMX_OPEN): the launch has no rail, no
   panel, no MenuBar row beyond File, and the board is 1440 - 2 x 12 wide; Insert > Table adds telemetry as a card and opens no
   panel; Insert > Links docks the Links panel (the board 301 narrower), `fl` + chips + Return link fleet.episode =
   telemetry.episode; the panel's x closes it (full width again); Ctrl+Shift+I opens the inspector and Esc on the sheet closes
   it; Ctrl+Shift+C inserts a chart and opens no panel; Ctrl+S saves the document; the Report shows its own tab; a shot of
   each tab; compact at 1000 wide.
3. The web host (headless Chromium, the page's regions): the same launch geometry; Insert > Table, Insert > Links docks and the x
   closes; then the agent host links fleet.episode = telemetry.episode through the ribbon's tools.
Pictures under build/g76/m2/.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g76/m2"
BASE = "1bf85bec"
APP = ROOT / "build/omxplorer/linux/omxplorer"
WEB = ROOT / "build/omxplorer/web"
DATA = [Path(os.environ["G76_DATA"])] if os.environ.get("G76_DATA") else [ROOT / "build/g47/full", ROOT.parent / "mojo-ui-g73/build/g47/full"]
W, H, PAD, PANEL = 1440, 900, 12, 301  # the window, omxplorer's BOARD_PAD, INSPECTOR_W + its line
sys.path.insert(0, str(ROOT / "scripts"))

# The old colour items (SET_INK + k, SET_FILL + k) are the swatches the ribbon's colour tools open (PICK_INK, PICK_FILL: the
# toolbar's way since goal 21); the hidden Format menu still holds them as an agent's tools. Insert > Table… (INSERT_TABLE) is a
# dialog holding a table file picker (a menu item can't be a picker); the ribbon's Table is that picker itself (PICK_TABLE, as the
# old toolbar's and rail's were); the hidden menu item stays an agent's `insert-table` tool.
EQUIVALENT = {"SET_INK + k": "PICK_INK", "SET_FILL + k": "PICK_FILL", "INSERT_TABLE": "PICK_TABLE"}


def run(cmd, timeout, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def data():
    for d in DATA:
        if (d / "fleet.csv").exists() and (d / "telemetry.parquet").exists():
            return d
    return None


def body(src, name):
    """def `name`'s source (to the next def at its indent)."""
    m = re.search(rf"^    def {name}\(.*?(?=^    def |\Z)", src, re.S | re.M)
    return m.group(0) if m else ""


def messages(code, calls):
    """The message argument of every call to `calls` in `code`: the second argument (Item, Button, FilePicker) or the third
    (Tool, ribbon_tool…), as written ("STYLE_ALIGN + ALIGN_LEFT")."""
    out = set()
    for fn, at in calls:
        for m in re.finditer(rf"\b{fn}\(", code):
            depth, args, cur, i = 0, [], "", m.end()
            while i < len(code):
                ch = code[i]
                if ch in "([{":
                    depth += 1
                elif ch in ")]}":
                    if depth == 0:
                        args.append(cur)
                        break
                    depth -= 1
                elif ch == '"':
                    j = code.index('"', i + 1)
                    cur += code[i:j + 1]
                    i = j + 1
                    continue
                elif ch == "," and depth == 0:
                    args.append(cur)
                    cur = ""
                    i += 1
                    continue
                cur += ch
                i += 1
            if len(args) > at:
                out.add(" ".join(args[at].split()))
    return out


def nothing_lost():
    old = run(["git", "show", f"{BASE}:examples/omxplorer/app.mojo"], 60).stdout
    new = (ROOT / "examples/omxplorer/app.mojo").read_text()
    old_set = (messages(body(old, "menu_bar"), [("Item", 1)]) | messages(body(old, "toolbar") + body(old, "format_tools") + body(old, "report_tools"), [("Tool", 2), ("FilePicker", 1)])
               | messages(body(old, "rail"), [("FilePicker", 1), ("Button", 1)]))
    file_menu = re.search(r'Menu\("File", \[.*?\]\),', body(new, "menus"), re.S).group(0)
    rib = body(new, "ribbon_tabs") + body(new, "format_groups")
    new_set = (messages(rib, [("ribbon_tool", 2), ("ribbon_picker", 2), ("ribbon_toggle", 2)]) | messages(file_menu, [("Item", 1)])
               | messages(body(new, "format_tools") + body(new, "report_tools"), [("Tool", 2)]))  # (format_groups and the Report tab read these)
    lost = sorted(m for m in old_set if m not in new_set and EQUIVALENT.get(m) not in new_set)
    if "t.message" not in rib:
        return f"the ribbon doesn't read format_tools/report_tools' messages (format_groups, the Report tab)", old_set
    if lost:
        return f"the ribbon and the File menu lost {lost} (old menu bar + toolbar + rail at {BASE}: {len(old_set)} messages)", old_set
    if not re.search(r"menus\[k\] = menus\[k\]\.copy\(\)\.hidden\(\)", new):
        return "the menus other than File aren't kept (hidden) for their shortcuts", old_set
    return None, old_set


def regions(path):
    out = {}
    for r in json.loads(Path(path).read_text()):
        if r["w"] > 0 and r["h"] > 0:
            out.setdefault(r["name"].split(":")[0], []).append((r["x"], r["y"], r["w"], r["h"]))
    return out


def board_w(regs):
    s = regs.get("sheet", [])
    return s[0][2] if s else -1


def geometry(path, want_panel, where, width=W):
    regs = regions(path)
    if "sidebar" in regs:
        return f"{where}: a side rail is shown ({regs['sidebar']})"
    if ("inspector" in regs) != want_panel:
        return f"{where}: the panel is {'missing' if want_panel else 'open'} ({regs.get('inspector')})"
    want = width - 2 * PAD - (PANEL if want_panel else 0)
    got = board_w(regs)
    if abs(got - want) > 2:
        return f"{where}: the board is {got} wide, not {want} (window {width} - 2 x {PAD}" + (f" - the panel's {PANEL})" if want_panel else ")")
    if len(regs.get("toolbar", [])) != 1:
        return f"{where}: {len(regs.get('toolbar', []))} ribbon bands shown, not one"
    return None


def config(name, extra=""):
    d = OUT / name
    for sub in ("docs", "config"):
        (d / sub).mkdir(parents=True, exist_ok=True)
    (d / "config/settings.txt").write_text("appearance=light\ninspector=yes\n" + extra)  # (the old default: ignored now)
    return d


def gtk(d):
    import headless
    headless.ensure()
    if not APP.exists():
        return "build/omxplorer/linux/omxplorer is missing (scripts/build.sh omxplorer linux)"
    home = config("gtk-home")
    L = "link"
    steps = ";".join([
        "waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "boards:launch", f"regions:{OUT}/gtk-0.json", f"shot:{OUT}/gtk-1-launch.png",
        "tap:ribbon-tab-insert", "pause:300", f"shot:{OUT}/gtk-tab-insert.png",
        f"pick:Table={d / 'telemetry.parquet'}", "pause:3000", f"regions:{OUT}/gtk-2.json", f"shot:{OUT}/gtk-2-telemetry.png",
        "tap:Links", "pause:500", f"regions:{OUT}/gtk-3.json", f"shot:{OUT}/gtk-3-links-docked.png",
        f"type:{L}=fl", "pause:300", f"submit:{L}", "pause:300", "tap:link-pick-0", "pause:300", "tap:link-pick-0", "pause:300",
        "tap:link-pick-1", "pause:300", "tap:link-pick-0", "pause:300", f"submit:{L}", "pause:800", f"shot:{OUT}/gtk-4-linked.png",
        "tap:panel-close", "pause:500", f"regions:{OUT}/gtk-5.json", f"shot:{OUT}/gtk-5-closed.png",
        "shortcut:Ctrl+Shift+I", "pause:400", f"regions:{OUT}/gtk-6.json", f"shot:{OUT}/gtk-6-inspector.png",
        "key:grid=Escape", "pause:400", f"regions:{OUT}/gtk-7.json",
        "shortcut:Ctrl+Shift+C", "pause:1500", f"regions:{OUT}/gtk-8.json", f"shot:{OUT}/gtk-8-chart.png",
        "shortcut:Ctrl+S", "pause:1500",
        "tap:ribbon-tab-home", "pause:300", f"shot:{OUT}/gtk-tab-home.png",
        "tap:ribbon-tab-data", "pause:300", f"shot:{OUT}/gtk-tab-data.png",
        "tap:ribbon-tab-format", "pause:300", f"shot:{OUT}/gtk-tab-format.png",
        "tap:ribbon-tab-view", "pause:300", f"shot:{OUT}/gtk-tab-view.png",
        "tap:Report", "pause:800", f"shot:{OUT}/gtk-tab-report.png", "say:ribbon-tab-report",
        "tap:ribbon-tab-view", "pause:300", "tap:Sheet", "pause:500",
        "window:1000x800", "pause:800", f"regions:{OUT}/gtk-9.json", f"shot:{OUT}/gtk-9-compact.png",
    ])
    env = {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "OMX_OPEN": str(d / "fleet.csv"), "MOJOUI_TEST": steps,
           "MOJOUI_WINDOW": f"{W}x{H}", "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": "50"}
    r = run([str(APP)], 900, env)
    out = r.stdout + r.stderr
    (OUT / "gtk.log").write_text(out)
    bad = [l for l in out.splitlines() if "TEST:" in l]
    if r.returncode != 0 or bad:
        return f"GTK run failed (exit {r.returncode}): " + " / ".join(bad)[:500]
    m = re.search(r"^BOARDS: launch (\d+)x(\d+) in (\d+)x(\d+)$", out, re.M)
    if not m or int(m.group(2)) > int(m.group(4)):  # (the Board fits the room the ribbon leaves: nothing scrolls at launch)
        return f"GTK launch: the Board overflows its room ({m.group(0) if m else 'no BOARDS line'})"
    for k, panel, where in ((0, False, "launch"), (2, False, "after Insert > Table"), (3, True, "Links docked"), (5, False, "after the x"),
                            (6, True, "Ctrl+Shift+I"), (7, False, "Esc on the sheet"), (8, False, "Ctrl+Shift+C (a chart: no panel)")):
        why = geometry(OUT / f"gtk-{k}.json", panel, "GTK " + where)
        if why:
            return why
    if "MENU: Edit" not in out or "MENU: Format" not in out:
        return "GTK: the hidden menus (their shortcuts) aren't in the tree"
    cards = lambda k: [c for c in json.loads((OUT / f"gtk-{k}.json").read_text()) if c["name"].startswith("card:")]
    if len(cards(2)) != len(cards(0)) + 1:
        return f"GTK: Insert > Table didn't add a card ({len(cards(0))} → {len(cards(2))})"
    if len(cards(8)) != len(cards(7)) + 1:
        return f"GTK: Ctrl+Shift+C didn't add a chart ({len(cards(7))} → {len(cards(8))})"
    links = [l for l in out.splitlines() if l.startswith("LINK: ")]
    if "LINK: fleet.episode = telemetry.episode (typed)" not in links:
        return f"GTK: the Links panel through the ribbon didn't link fleet.episode = telemetry.episode: {links[:3]}"
    if not list((home / "docs").glob("*.omx")):
        return "GTK: Ctrl+S saved no .omx"
    if "SAY: ribbon-tab-report" not in out and "ribbon-tab-report" not in out:
        return "GTK: the Report has no tab of its own"
    regs = regions(OUT / "gtk-9.json")
    band = regs.get("toolbar", [(0, 0, 0, 0)])[0]
    if band[3] > 52:
        return f"GTK compact (1000 wide): the band is {band[3]} high (icons only: 44 and the theme's padding)"
    return None


def web(d):
    import drive
    from agent_client import Client
    if not (WEB / "mojoui_app.so").exists():
        return "build/omxplorer/web is missing (scripts/build.sh omxplorer web)"
    home = config("web-home")
    env = {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "OMX_OPEN": str(d / "fleet.csv")}
    steps = ";".join([
        "wait:Create table", "tap:Create table", "wait:Links", "pause:800", f"regions:{OUT}/web-0.json", f"shot:{OUT}/web-1-launch.png",
        "tap:Insert", "pause:300", f"pick:Table={d / 'telemetry.parquet'}", "pause:4000", f"regions:{OUT}/web-2.json", f"shot:{OUT}/web-2-telemetry.png",
        "tap:Links", "pause:600", f"regions:{OUT}/web-3.json", f"shot:{OUT}/web-3-links-docked.png",
        "tap:panel-close", "pause:600", f"regions:{OUT}/web-5.json",
        "shortcut:Ctrl+Shift+I", "pause:600", f"regions:{OUT}/web-6.json", "shortcut:Ctrl+Shift+I", "pause:600",
        "tap:Format", "pause:300", f"shot:{OUT}/web-tab-format.png",
    ])
    r, out = drive.web_run(WEB, steps, viewport=(W, H), env=env)
    (OUT / "web.log").write_text(out)
    if r.returncode != 0:
        return "web run failed: " + out[-600:]
    for k, panel, where in ((0, False, "launch"), (2, False, "after Insert > Table"), (3, True, "Links docked"), (5, False, "after the x"), (6, True, "Ctrl+Shift+I")):
        why = geometry(OUT / f"web-{k}.json", panel, "web " + where)
        if why:
            return why
    # the agent links through the ribbon's tools (goal 73's chips, reached by their names while Home shows)
    home2 = config("web-agent")
    c = Client(WEB, env={"OMX_DOCUMENTS": str(home2 / "docs"), "OMX_CONFIG": str(home2 / "config"), "MOJOUI_TRACE": "1"})  # (no OMX_OPEN: its start-up line would land on the agent's stdout)
    log = []
    import threading
    threading.Thread(target=lambda: [log.append(l.rstrip("\n")) for l in c.p.stderr], daemon=True).start()

    def call(tool, **args):
        text, _, err = c.call(tool, **args)
        if err:
            raise RuntimeError(f"{tool} failed: {text}")
        return text

    def until(tool, timeout=240):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if tool in c.names():
                return
            time.sleep(0.3)
        raise RuntimeError(f"{tool} never appeared")

    def chip(prefix):
        for t in c.tools():
            if t["name"].startswith("link-pick-") and ("Put " + prefix) in t.get("description", ""):
                return t["name"]
        return None

    try:
        call("open-file", path=str(d / "fleet.csv"))
        until("create-table")
        call("create-table")
        until("insert-table")
        call("insert-table")  # (the hidden Insert menu's Table…: its dialog's picker, as goal 73's proof calls it)
        until("choose-table")
        call("choose-table", path=str(d / "telemetry.parquet"))
        until("table-telemetry")
        call("links")
        until("link")
        call("link", text="fleet.ep")
        time.sleep(0.3)
        call("link-pick-0")
        time.sleep(0.2)
        call("link-pick-0")
        time.sleep(0.2)
        for want in ("fleet.episode = telemetry.", "fleet.episode = telemetry.episode"):
            name = chip(want)
            if not name:
                return f"web agent: no chip offers {want}"
            call(name)
            time.sleep(0.2)
        call("link", submit=True)
        time.sleep(0.8)
    finally:
        try:
            c.p.stdin.close()
            c.p.wait(timeout=30)
        except Exception:
            c.p.kill()
    if not any("LINK: fleet.episode = telemetry.episode" in l for l in log):
        return "web agent: no link fleet.episode = telemetry.episode: " + str([l for l in log if l.startswith("LINK")][-3:])
    return None


def check():
    OUT.mkdir(parents=True, exist_ok=True)
    why, old = nothing_lost()
    if why:
        return False, why
    d = data()
    if d is None:
        return None, f"no DROID fleet.csv + telemetry.parquet in {DATA} (scripts/robot_data.py makes them)"
    for step in (gtk, web):
        why = step(d)
        if why:
            return False, why
    return True, (f"none of the old menu bar's, toolbar's and rail's {len(old)} messages lost; GTK and the web: no rail, no panel at launch "
                  f"(the old inspector=yes ignored), the board {W - 2 * PAD} wide; Insert > Table a card, no panel; Insert > Links docked "
                  f"({W - 2 * PAD - PANEL}), the x back to full; fleet.episode = telemetry.episode linked (GTK chips, web agent); "
                  "Ctrl+Shift+I, Esc, Ctrl+Shift+C (no panel), Ctrl+S; the Report's own tab; compact at 1000")


if __name__ == "__main__":
    print(check())
