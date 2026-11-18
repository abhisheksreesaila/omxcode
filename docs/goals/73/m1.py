"""Goal 73 M1: links you type with help (docs/goals/73.md).

  tests/test_link_complete.mojo passes; then omxplorer with the DROID fleet.csv + telemetry.parquet, on GTK (headless, real
  widgets, MOJOUI_TEST steps) and on the web host (the agent tools): typing `fl` offers `fleet`, `fleet.ep` offers `episode`,
  and a link made from the chips and Return is `fleet.episode = telemetry.episode`. Pictures under build/g73/m1/.

Data: G73_DATA (default: goal 71's build/g47/full, read only).
"""
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g73/m1"
DATA = Path(os.environ.get("G73_DATA", "/home/abhisheksreesaila/Projects/mxapp/mojo-ui-g71/build/g47/full"))
APP = ROOT / "build/omxplorer/linux/omxplorer"
sys.path.insert(0, str(ROOT / "scripts"))

OFFER = re.compile(r"^LINKS: draft '(.*)' offers \[(.*)\]$")


def run(cmd, timeout, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def offers(text):
    """Every `LINKS: draft '…' offers […]` the app traced, in order: [(draft, [chips])]."""
    got = []
    for line in text.splitlines():
        m = OFFER.match(line.strip())
        if m:
            got.append((m.group(1), [c for c in m.group(2).split(" | ") if c != ""]))
    return got


def need(got, draft, chips=None, first=None):
    """The app offered `chips` (or began with `first`) for `draft`, at some point."""
    for d, c in got:
        if d == draft and (chips is None or c == chips) and (first is None or c[:1] == [first]):
            return None
    return f"draft {draft!r} never offered {chips if chips is not None else first!r} (saw {[x for x in got if x[0] == draft]})"


def unit():
    r = run(["pixi", "run", "mojo", "run", "-I", ".", "tests/test_link_complete.mojo"], 900)
    if "link_complete: ok" not in r.stdout:
        return "tests/test_link_complete.mojo: " + (r.stdout + r.stderr)[-600:]
    return None


def gtk():
    import headless
    headless.ensure()
    if not APP.exists():
        return "build/omxplorer/linux/omxplorer is missing (scripts/build.sh omxplorer linux)"
    home = OUT / "gtk-home"
    for d in ("docs", "config"):
        (home / d).mkdir(parents=True, exist_ok=True)
    (home / "config/settings.txt").write_text("appearance=light\n")
    L = "link"  # (the Links field by its tag: its hint holds a "=", which a step's own "=" can't)
    steps = ";".join([
        f"pick:Choose a file={DATA / 'fleet.csv'}", "waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000",
        f"pick:Table={DATA / 'telemetry.parquet'}", "pause:2500", "tap:Links", "pause:400",
        f"shot:{OUT}/gtk-1-empty.png",
        f"type:{L}=fl", "pause:300", f"shot:{OUT}/gtk-2-fl.png",
        f"type:{L}=fleet.ep", "pause:300", f"shot:{OUT}/gtk-3-fleet-ep.png",
        "tap:link-pick-0", "pause:300", f"shot:{OUT}/gtk-4-operators.png",
        "tap:link-pick-0", "pause:300", f"shot:{OUT}/gtk-5-second-end.png",
        f"type:{L}=fleet.episode = tel", "pause:300",
        "tap:link-pick-0", "pause:300", f"shot:{OUT}/gtk-6-telemetry-columns.png",
        f"type:{L}=fleet.episode = telemetry.ep", "pause:300",
        "tap:link-pick-0", "pause:300", f"shot:{OUT}/gtk-7-whole-link.png",
        f"submit:{L}", "pause:600", f"shot:{OUT}/gtk-8-linked.png",
    ])
    env = {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "MOJOUI_TEST": steps,
           "MOJOUI_WINDOW": "1440x900", "MOJOUI_SHOT": str(OUT / "gtk-final.png"), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": "50"}
    r = run([str(APP)], 900, env)
    out = r.stdout + r.stderr
    (OUT / "gtk.log").write_text(out)
    bad = [l for l in out.splitlines() if "TEST:" in l]
    if r.returncode != 0 or bad:
        return f"GTK run failed (exit {r.returncode}): " + " / ".join(bad)[:500]
    got = offers(out)
    for miss in (need(got, "fl", ["fleet."]), need(got, "fleet.ep", ["episode"]), need(got, "fleet.episode ", ["=", "~"]),
                 need(got, "fleet.episode = ", first="fleet."), need(got, "fleet.episode = tel", ["telemetry."]),
                 need(got, "fleet.episode = telemetry.", first="episode"),
                 need(got, "fleet.episode = telemetry.episode", ["episode"])):
        if miss:
            return "GTK: " + miss
    if "LINK: fleet.episode = telemetry.episode (typed)" not in out:
        return "GTK: Return on the chips' draft didn't link fleet.episode = telemetry.episode"
    if got[-1][0] != "":  # (after Return the field is empty: no stale change brings the old text back)
        return f"GTK: after Return the draft is {got[-1][0]!r}, not empty"
    return None


def web():
    from agent_client import Client
    web_dir = ROOT / "build/omxplorer/web"
    if not (web_dir / "mojoui_app.so").exists():
        return "build/omxplorer/web is missing (scripts/build.sh omxplorer web)"
    home = OUT / "web-home"
    for d in ("docs", "config"):
        (home / d).mkdir(parents=True, exist_ok=True)
    env = {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": "50"}
    c = Client(web_dir, env=env)
    log = []
    import threading

    def drain():
        for line in c.p.stderr:
            log.append(line.rstrip("\n"))
    threading.Thread(target=drain, daemon=True).start()

    def call(tool, **args):
        text, _, err = c.call(tool, **args)
        if err:
            raise RuntimeError(f"{tool} failed: {text}")
        return text

    def until(tool, timeout=120):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if tool in c.names():
                return
            time.sleep(0.2)
        raise RuntimeError(f"{tool} never appeared")

    def chip(prefix):
        """The chip (tool) whose description says it puts `prefix…` in the link."""
        for t in c.tools():
            if t["name"].startswith("link-pick-") and ("Put " + prefix) in t.get("description", ""):
                return t["name"]
        return None

    try:
        call("open-file", path=str(DATA / "fleet.csv"))
        until("create-table")
        call("create-table")
        until("insert-table")
        call("insert-table")
        until("choose-table")
        call("choose-table", path=str(DATA / "telemetry.parquet"))
        until("table-telemetry", 240)
        call("links")
        until("link")
        call("link", text="fl")
        time.sleep(0.3)
        call("link-pick-0")  # fleet.
        time.sleep(0.2)
        call("link", text="fleet.ep")
        time.sleep(0.3)
        call("link-pick-0")  # fleet.episode + space
        time.sleep(0.2)
        # chips only from here: = (the first), then the card telemetry., then its column episode
        call("link-pick-0")
        time.sleep(0.2)
        name = chip("fleet.episode = telemetry.")
        if not name:
            return "web: after the operator no chip offers telemetry."
        call(name)
        time.sleep(0.2)
        name = chip("fleet.episode = telemetry.episode")
        if not name:
            return "web: after telemetry. no chip offers its episode column"
        call(name)
        time.sleep(0.2)
        call("link", text="fleet.episode = telemetry.episode", submit=True)
        time.sleep(0.6)
        shown = call("links")
        got = offers("\n".join(log))
        for miss in (need(got, "fl", ["fleet."]), need(got, "fleet.ep", ["episode"]), need(got, "fleet.episode = telemetry.", first="episode")):
            if miss:
                return "web: " + miss
        if not any("LINK: fleet.episode = telemetry.episode" in l for l in log):
            return "web: no link fleet.episode = telemetry.episode was made (log: %s)" % [l for l in log if l.startswith("LINK")][-3:]
        return None
    finally:
        try:
            c.p.stdin.close()
            c.p.wait(timeout=30)
        except Exception:
            c.p.kill()


def panel_edge(png, y=500, inside=1250):
    """Where the inspector starts in a shot: walking left on row y from a point inside the (empty, white) panel, the first
    pixel that isn't the panel's white, plus one."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    for x in range(inside, 0, -1):
        if min(im.getpixel((x, y))) < 250:
            return x + 1
    return -1


def steady_panel():
    """The chips never widen the Links panel (a row of three long names pushed it 12 points over the card beside it)."""
    a, b = panel_edge(OUT / "gtk-1-empty.png"), panel_edge(OUT / "gtk-6-telemetry-columns.png")
    return "" if a > 0 and a == b else f"the Links panel moved when the chips came: starts at x={a} empty, x={b} with telemetry's columns"


def check():
    OUT.mkdir(parents=True, exist_ok=True)
    why = unit()
    if why:
        return False, why
    why = gtk()
    if why:
        return False, why
    why = steady_panel()
    if why:
        return False, why
    why = web()
    if why:
        return False, why
    return True, "the panel holds its width with chips; completions: unit test ok; GTK and the web host offer fleet. / episode / telemetry. from typed prefixes and link fleet.episode = telemetry.episode from chips + Return"


if __name__ == "__main__":
    print(check())
