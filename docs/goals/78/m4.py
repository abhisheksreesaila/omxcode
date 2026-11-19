"""Goal 78 M4: omxplorer on the free canvas, nothing regressed (docs/goals/78.md). `check() -> (ok, why)`.

1. A free .omx keeps each card's x, y, w, h (and the zoom): GTK makes a sheet (fleet + a chart), moves and resizes both, saves
   (Ctrl+S); opened again, every card is where it was. An older .omx (saved with the tiling, no "canvas" key, the format main
   writes) opens tiled as before (the chart splits the table's row, side by side, the room's width).
2. The DROID story with the owner's demo data (~/Downloads/omxplorer-demo-data/robots, read-only): fleet.csv, telemetry.parquet,
   the link fleet.clip = video.file, the row with the first clip selected (its video opens), the fleet table dragged wide
   enough for all 22 columns (the last, uuid, is drawn), the video moved beside it, the page scrolled right: the shot.
3. Goal 76's check M1–M3 (goal 73's checks and the 71 -> 70 -> 68 -> 47 chain inside), run as they are (G78_SKIP_76=1 skips
   it while iterating; the report says when it was skipped).
"""
import csv
import importlib.util
import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("g78common", HERE / "common.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def saved():
    d = c.DATA
    # a free sheet, saved
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "shortcut:Ctrl+Shift+C", "pause:1500",
             "freedrag:table=se,-300,-200,4,alt", "pause:300", "freedrag:chart0=move,700,-500,4,alt", "pause:300", "freedrag:chart0=e,120,0,4,alt",
             "pause:300", "shortcut:Ctrl+-", "pause:400", "boards:before", "shortcut:Ctrl+S", "pause:2000"]
    out = c.gtk(steps, "m4-save", open_path=d / "fleet.csv")
    before = c.boards(out)["before"]
    docs = c.OUT / "m4-save/docs"
    omx = sorted(docs.glob("*.omx"))
    if not omx:
        return False, "Ctrl+S saved no .omx"
    out2 = c.gtk(["waitfor:Links=60000", "pause:1500", "boards:after", f"shot:{c.OUT}/m4-1-reopened.png"], "m4-open", open_path=omx[0])
    after = c.boards(out2)["after"]
    probs = []
    if after["asked"] != before["asked"]:
        probs.append(f"reopened: {after['asked']} (saved {before['asked']})")
    if after["zoom"] != before["zoom"]:
        probs.append(f"zoom {before['zoom']} saved, {after['zoom']} reopened")
    # an older file: saved with the tiling (canvas=tiled: no "canvas" key, the format main writes), opened on a free-canvas setting
    out3 = c.gtk(["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800", "shortcut:Ctrl+Shift+C", "pause:1500",
                  "boards:tiledsave", "shortcut:Ctrl+S", "pause:2000"], "m4-old", settings="appearance=light\ncanvas=tiled\n", open_path=d / "fleet.csv")
    old = sorted((c.OUT / "m4-old/docs").glob("*.omx"))
    if not old:
        return False, "the tiled sheet saved no .omx"
    meta = old[0].read_bytes()
    if b'"canvas"' in meta:
        probs.append("a sheet saved with the tiling wrote a canvas key (it should be the old format)")
    out4 = c.gtk(["waitfor:Links=60000", "pause:1500", "boards:old", f"shot:{c.OUT}/m4-2-old-omx-tiled.png"], "m4-old-open", open_path=old[0])
    o = c.boards(out4)["old"]
    t, ch = o["cards"].get("table"), o["cards"].get("chart0")
    W = o["room"][0]
    if not t or not ch or not (t[1] == ch[1] == 0 and t[0] == 0 and t[2] + c.GAP + ch[2] == W and ch[0] == t[2] + c.GAP):
        probs.append(f"the older .omx didn't open tiled: table {t}, chart {ch}, room {o['room']}")
    if probs:
        return False, "save/open: " + "; ".join(probs)
    return True, f"a free .omx reopens with every card where it was ({len(after['asked'])} cards, zoom {after['zoom']}); an older .omx opens tiled ({t}, {ch})"


def story():
    demo = c.DEMO
    if not (demo / "fleet.csv").exists() or not (demo / "telemetry.parquet").exists():
        return None, f"the owner's demo data isn't in {demo}"
    rows = list(csv.DictReader(open(demo / "fleet.csv")))
    first = next(i for i, r in enumerate(rows) if r["clip"])
    clip = Path(rows[first]["clip"]).name
    steps = ["waitfor:Create table=60000", "tap:Create table", "waitfor:Links=60000", "pause:800",
             f"pick:Table={demo / 'telemetry.parquet'}", "waitfor:close-telemetry=120000", "pause:1500",
             "tap:Links", "pause:500", "type:link=fleet.clip = video.file", "submit:link", "pause:800", "tap:panel-close", "pause:500",
             "boardscroll:0", "freedrag:table=e,2400,0,6,alt", "pause:500", "tapspot:grid=clip@1", "pause:300"]
    steps += ["key:grid=ArrowDown"] * first
    steps += ["pause:3000", "boards:opened", "hoverspot:grid=uuid", "pause:200"]
    out = c.gtk(steps, "m4-story-a", open_path=demo / "fleet.csv")
    b = c.boards(out)["opened"]
    probs = []
    if f"OPEN: video {clip}" not in out:
        probs.append(f"selecting row {first + 1} didn't play {clip}")
    v = b["cards"].get("video0")
    t = b["cards"]["table"]
    if not v:
        return False, f"story: no video card ({list(b['cards'])})"
    # the video beside the fleet table, telemetry under it; then the page scrolled right to the video
    steps2 = steps[:-4] + ["pause:3000", f"freedrag:video0=move,{t[0] + t[2] + c.GAP - v[0]},{t[1] - v[1]},6", "pause:500",
                           "boards:story", "boardscrollx:end", "boardscroll:0", "pause:500", f"shot:{c.OUT}/m4-3-droid-story-scrolled-right.png",
                           "boardscrollx:0", "pause:300", f"shot:{c.OUT}/m4-4-droid-story-left.png"]
    out2 = c.gtk(steps2, "m4-story", open_path=demo / "fleet.csv")
    s = c.boards(out2)["story"]
    v2, t2, tel = s["cards"].get("video0"), s["cards"]["table"], s["cards"].get("tablecard0")
    if not v2 or v2[0] < t2[0] + t2[2] or v2[1] != t2[1]:
        probs.append(f"the video {v2} isn't beside the fleet table {t2}")
    if not tel or tel[1] < t2[1] + t2[3]:
        probs.append(f"telemetry {tel} isn't under the fleet table {t2}")
    sx = c.scroll(out2, "x")
    if not sx or sx[0][0] + sx[0][2] < sx[0][1] - 1:
        probs.append(f"not scrolled right: {sx[:1]}")
    if probs:
        return False, "story: " + "; ".join(probs)
    return True, (f"DROID story (owner's data): row {first + 1}'s {clip} plays in the video card; fleet {t2[2]} wide shows all 22 columns "
                  f"(uuid drawn); the video beside it at {v2[:2]}, telemetry under; scrolled right {sx[0][0]}+{sx[0][2]} of {sx[0][1]}")


def g76():
    if os.environ.get("G78_SKIP_76"):
        return None, "goal 76's check skipped (G78_SKIP_76)"
    r = c.run(["pixi", "run", "python", "docs/goals/76-check.py", "M1", "M2", "M3"], 4 * 3600)
    out = r.stdout + r.stderr
    (c.OUT / "m4-76-check.log").write_text(out)
    lines = [l for l in out.splitlines() if re.match(r"^M\d: ", l)]
    if r.returncode != 0 or not lines or any(" FAIL " in l or "BLOCKED" in l for l in lines):
        return False, "76-check: " + " / ".join(l[:400] for l in lines)
    return True, "76-check " + ", ".join(l.split("  ")[0] for l in lines)


def check():
    if not (c.DATA / "fleet.csv").exists():
        return None, f"no DROID data in {c.DATA}"
    c.OUT.mkdir(parents=True, exist_ok=True)
    c.build(("omxplorer", "linux"))
    parts = []
    blocked = []
    for fn in (saved, story, g76):
        ok, why = fn()
        if ok is False:
            return False, why
        (parts if ok else blocked).append(why)
    if blocked:
        return None, "; ".join(parts) + "; BLOCKED: " + "; ".join(blocked)
    return True, "; ".join(parts)
