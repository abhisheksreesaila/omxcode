"""Goal 76 M1: the Ribbon, a framework piece (docs/goals/76.md).

  tests/test_ribbon.mojo passes (tabs, groups, captions, tags, the selected tab, compact, hidden bands, an Inspector's ✕);
  then examples/ribbon (mojoui.ribbon in Liquid) on GTK (headless, MOJOUI_TEST steps) and on the web host (headless
  Chromium for the pictures, the agent tools for what a person can't see):
  - a tool of a tab that isn't selected is reached by its title or tag (GTK `tap:Chart` while Home shows; the agent's tool
    list holds `chart`, `insert-table` and `details` on Home and calling `chart` sends it);
  - shortcuts fire with only the File menu showing (Ctrl+B: the hidden Format menu's item);
  - a tab tap shows its band (one toolbar region, 78 pt, under the 38 pt tab row), the View tab's Details opens a docked
    panel, its ✕ closes it (the inspector region comes and goes);
  - compact (a narrow window): a 44 pt band, no captions.
Pictures under build/g76/m1/.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g76/m1"
APP = ROOT / "build/ribbon/linux/ribbon"
WEB = ROOT / "build/ribbon/web"
sys.path.insert(0, str(ROOT / "scripts"))


def run(cmd, timeout, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def built():
    for what, path in (("linux", APP), ("web", WEB / "mojoui_app.so")):
        if not path.exists():
            r = run(["scripts/build.sh", "ribbon", what], 1800)
            if r.returncode != 0:
                return f"scripts/build.sh ribbon {what}: " + (r.stdout + r.stderr)[-500:]
    return None


def unit():
    r = run(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_ribbon.mojo"], 900)
    if "ribbon: ok" not in r.stdout:
        return "tests/test_ribbon.mojo: " + (r.stdout + r.stderr)[-600:]
    return None


def regions(path):
    """{name: [(x, y, w, h)]} from a regions: step's JSON, shown regions only (no box: hidden)."""
    out = {}
    for r in json.loads(Path(path).read_text()):
        if r["w"] > 0 and r["h"] > 0:
            out.setdefault(r["name"], []).append((r["x"], r["y"], r["w"], r["h"]))
    return out


def band(regs, height, where):
    t = regs.get("toolbar", [])
    if len(t) != 1:
        return f"{where}: {len(t)} toolbar regions shown, not one (only the selected tab's band shows): {t}"
    x, y, w, h = t[0]
    if y != 38 or not height - 1 <= h <= height + 6:  # (the theme's own band padding and edge line on top: Liquid's 2 + 1 + 2)
        return f"{where}: the band is at y={y}, {h} pt high (want y=38, under the tab row, {height} pt and the theme's padding)"
    HEIGHTS.setdefault((where.split()[0], height), set()).add(h)
    if len(HEIGHTS[(where.split()[0], height)]) > 1:
        return f"{where}: the bands differ in height from tab to tab ({sorted(HEIGHTS[(where.split()[0], height)])}): switching tabs would move the page"
    return None


HEIGHTS = {}


def gtk():
    import headless
    headless.ensure()
    steps = ";".join([
        f"regions:{OUT}/gtk-0.json", f"shot:{OUT}/gtk-1-home.png",
        "tap:Chart",  # (Insert's tool, while Home shows)
        "shortcut:Ctrl+B", "pause:200", f"shot:{OUT}/gtk-2-bold.png",  # (the hidden Format menu's shortcut)
        "tap:ribbon-tab-insert", "pause:300", f"regions:{OUT}/gtk-3.json", f"shot:{OUT}/gtk-3-insert.png",
        "pick:Table=/tmp/ribbon-sample.csv",
        "tap:ribbon-tab-view", "pause:200", "tap:Details", "pause:300", f"regions:{OUT}/gtk-4.json", f"shot:{OUT}/gtk-4-panel.png",
        "tap:panel-close", "pause:300", f"regions:{OUT}/gtk-5.json", f"shot:{OUT}/gtk-5-closed.png",
        "window:820x600", "pause:600", f"regions:{OUT}/gtk-6.json", f"shot:{OUT}/gtk-6-compact.png",
    ])
    r = run([str(APP)], 300, {"MOJOUI_TEST": steps, "MOJOUI_WINDOW": "1200x700", "OMX_CONFIG": str(OUT / "cfg")})
    out = r.stdout + r.stderr
    (OUT / "gtk.log").write_text(out)
    bad = [l for l in out.splitlines() if "TEST:" in l]
    if r.returncode != 0 or bad:
        return f"GTK run failed (exit {r.returncode}): " + " / ".join(bad)[:500]
    said = [l[len("RIBBON: "):] for l in out.splitlines() if l.startswith("RIBBON: ")]
    want = ["Chart", "Bold", "Picked /tmp/ribbon-sample.csv", "Panel", "Close"]
    if said != want:
        return f"GTK: the tools sent {said}, not {want}"
    for k, where in ((0, "Home"), (3, "Insert"), (5, "after the ✕")):
        why = band(regions(OUT / f"gtk-{k}.json"), 78, "GTK " + where)
        if why:
            return why
    if "inspector" not in regions(OUT / "gtk-4.json"):
        return "GTK: Details didn't open the docked panel"
    if "inspector" in regions(OUT / "gtk-5.json"):
        return "GTK: the panel's ✕ didn't close it"
    why = band(regions(OUT / "gtk-6.json"), 44, "GTK compact")
    if why:
        return why
    if "BOX: ribbon-caption" in out.split("SHOT: " + str(OUT / "gtk-6-compact.png"))[-1]:
        return "GTK compact: captions still drawn"
    return None


def web():
    import drive
    from agent_client import Client
    steps = ";".join([
        f"regions:{OUT}/web-0.json", f"shot:{OUT}/web-1-home.png", "shortcut:Ctrl+B", "pause:300", f"shot:{OUT}/web-2-bold.png",
        "tap:Insert", "pause:400", f"regions:{OUT}/web-3.json", f"shot:{OUT}/web-3-insert.png",
        "tap:View", "pause:300", "tap:Details", "pause:400", f"regions:{OUT}/web-4.json", f"shot:{OUT}/web-4-panel.png",
        "tap:panel-close", "pause:400", f"regions:{OUT}/web-5.json", f"shot:{OUT}/web-5-closed.png",
    ])
    r, out = drive.web_run(WEB, steps, viewport=(1200, 700))
    (OUT / "web.log").write_text(out)
    if r.returncode != 0:
        return "web run failed: " + out[-600:]
    if "LABEL: Last: Close · bold" not in out:  # (Ctrl+B, then Details, then the ✕: the page says the last and that bold is on)
        return "web: the page doesn't say 'Last: Close · bold' after Ctrl+B, Details and the ✕: " + str([l for l in out.splitlines() if l.startswith("LABEL: Last")])
    for k, where in ((0, "Home"), (3, "Insert"), (5, "after the ✕")):
        why = band(regions(OUT / f"web-{k}.json"), 78, "web " + where)
        if why:
            return why
    if "inspector" not in regions(OUT / "web-4.json") or "inspector" in regions(OUT / "web-5.json"):
        return "web: Details didn't open the panel, or its ✕ didn't close it"
    r2, out2 = drive.web_run(WEB, f"regions:{OUT}/web-6.json;shot:{OUT}/web-6-compact.png", viewport=(820, 600))
    why = band(regions(OUT / "web-6.json"), 44, "web compact")
    if r2.returncode != 0 or why:
        return why or "web compact run failed: " + out2[-400:]
    # an agent reaches every tab's tools while Home shows
    c = Client(WEB)
    try:
        names = c.names()
        for tool in ("save", "bold", "chart", "insert-table", "details", "ribbon-tab-view", "file-new", "format-italic"):
            if tool not in names:
                return f"agent: no tool {tool!r} while Home shows ({names})"
        text, _, err = c.call("chart")
        if err:
            return "agent: chart failed: " + text
    finally:
        log = c.close()
    if "RIBBON: Chart" not in log:
        return "agent: calling chart (a hidden tab's tool) sent nothing: " + log[-300:]
    return None


def check():
    OUT.mkdir(parents=True, exist_ok=True)
    for step in (unit, built, gtk, web):
        why = step()
        if why:
            return False, why
    return True, ("unit test ok; examples/ribbon on GTK and the web: a hidden tab's tool tapped by title (GTK) and called by an agent (web), "
                  "Ctrl+B from a hidden menu, one 78 pt band under the tab row per tab, Details docks a panel and its ✕ closes it, compact 44 pt with no captions")


if __name__ == "__main__":
    print(check())
