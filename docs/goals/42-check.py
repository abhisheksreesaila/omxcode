"""Milestone checker for docs/goals/42-GOAL.md (goal 42: Jot, omxcode keeps your data). Prints PASS/FAIL per milestone.

Run: pixi run python docs/goals/42-check.py        (a subset: … 42-check.py M0 M3)
Written before the work (2026-10-30), from the goal's words; never edited to make a milestone pass (add, don't weaken).
GTK runs are headless (scripts/headless.py). Every run gets its own fresh $JOT_DB in a temp dir.
"""

import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
sys.path.insert(0, str(ROOT / "scripts"))
APP = ROOT / "build" / "jot"
TMP = Path(tempfile.mkdtemp(prefix="g42-"))

NOTE_A = "Groceries: milk, eggs and 🍋 lemons"
NOTE_B = "Trip plan: flights to Lisbon in May"
# (step, what the next `JOT:` line, printed on every change of the app's state, must contain)
SESSION = [
    ("tap:New", "notes=1"),
    ("textarea:0=" + NOTE_A, 'open="' + NOTE_A + '"'),
    ("tap:New", "notes=2"),
    ("textarea:0=" + NOTE_B, 'open="' + NOTE_B + '"'),
    ("type:Search=lisb", "results=1"),
    ("type:Search=", "results=2"),
    ("tap:New", "notes=3"),
    ("textarea:0=Delete me", 'open="Delete me"'),
    ("tap:Delete", "notes=2"),
]


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)


def mojo_test(path, ok_lines):
    if not (ROOT / path).exists():
        return False, f"{path} missing"
    r = run(["pixi", "run", "mojo", "run", "-I", ".", path], 1800)
    out = r.stdout + r.stderr
    missing = [l for l in ok_lines if l not in out]
    if r.returncode != 0 or missing:
        errs = " | ".join(l for l in out.splitlines() if "error" in l.lower() or "FAIL" in l)[-500:]
        return False, f"{path}: exit {r.returncode}, missing {missing} {errs}"
    return True, f"{path}: " + ", ".join(ok_lines)


_BUILT = {}


def build(target):
    if target not in _BUILT:
        r = run(["scripts/build.sh", "jot", target], 3600)
        _BUILT[target] = (r.returncode == 0, (r.stdout + r.stderr)[-400:])
    return _BUILT[target]


def jot(db, steps, extra=None, timeout=600):
    import headless
    headless.ensure()
    env = dict(os.environ, MOJOUI_TEST=";".join(steps), JOT_DB=str(db), **(extra or {}))
    r = run([str(APP / "linux" / "jot")], timeout, env=env)
    return r.returncode, r.stdout + r.stderr


def in_order(out, expectations):
    lines = [l for l in out.splitlines() if l.startswith("JOT:")]
    at = 0
    for step, want in expectations:
        while at < len(lines) and want not in lines[at]:
            at += 1
        if at == len(lines):
            return False, f"after {step}: no JOT: line with {want!r} (last lines: {lines[-3:]})"
    return True, lines[-1] if lines else ""


def fts_count(db, query):
    con = sqlite3.connect(db)
    try:
        return con.execute("SELECT count(*) FROM notes_fts WHERE notes_fts MATCH ?", (query,)).fetchone()[0]
    finally:
        con.close()


def m0():
    return mojo_test("tests/test_sqlite.mojo", ["sqlite open: ok", "sqlite bind: ok", "sqlite tx: ok", "sqlite error: ok", "sqlite fts5: ok"])


def m1():
    ok, why = build("linux")
    if not ok:
        return False, "linux build failed: " + why
    db = TMP / "m1.db"
    code, out = jot(db, ["pause:500"] + [s for s, _ in SESSION])
    if code != 0:
        return False, f"exit {code}: {out[-400:]}"
    ok, last = in_order(out, SESSION)
    if not ok:
        return False, last
    if not db.exists():
        return False, f"no database at $JOT_DB ({db})"
    con = sqlite3.connect(db)
    rows = sorted(r[0] for r in con.execute("SELECT title FROM notes"))
    cols = [r[1] for r in con.execute("PRAGMA table_info(notes)")]
    con.close()
    if cols[:4] != ["id", "title", "body", "updated"]:
        return False, f"notes columns {cols}"
    if rows != sorted([NOTE_A, NOTE_B]):
        return False, f"rows in the file: {rows}"
    if fts_count(db, "lisb*") != 1 or fts_count(db, "lemons") != 1 or fts_count(db, "delete") != 0:
        return False, "notes_fts isn't in step with notes (lisb*, lemons, a deleted note)"
    return True, f"{len(SESSION)} steps as expected ({last}); the file holds both notes and FTS5 finds them"


def prefixes(db, n=50):
    """50 search prefixes taken from the seeded titles' words, deterministic for a given file."""
    con = sqlite3.connect(db)
    words = sorted({w.lower() for (t,) in con.execute("SELECT title FROM notes") for w in re.findall(r"[A-Za-z]{4,}", t)})
    con.close()
    if not words:
        return []
    step = max(1, len(words) // n)
    return [w[: 2 + i % 3] for i, w in enumerate(words[::step][:n])]


def m2():
    ok, why = build("linux")
    if not ok:
        return False, "linux build failed: " + why
    db = TMP / "m2.db"
    code, out = jot(db, ["gaps:start", "gaps:8000"], {"JOT_SEED": "10000"})
    gap = re.search(r"GAPS: (\d+) frames, longest ([\d.]+) ms", out)
    seeded = out.find("JOT SEED: done")
    if code != 0 or not gap or seeded < 0:
        return False, f"exit {code}; GAPS line {bool(gap)}; seed done {seeded >= 0}: {out[-400:]}"
    if seeded > gap.start():
        return False, "the seed finished after the measured window (the gap measure didn't cover it)"
    # (added in review round 1, D-1322: the measure started before the seed did, and the seed's work is at least twice
    # the 100 ms gap threshold, so a seed on the UI thread would show as a gap; a slow start can't pass measuring nothing)
    started, seed_start = out.find("GAPS: start"), out.find("JOT SEED: start")
    if started < 0 or seed_start < 0 or started > seed_start:
        return False, f"GAPS: start at {started}, JOT SEED: start at {seed_start}: the measure didn't start before the seed"
    took = re.search(r"JOT SEED: done \d+ notes in (\d+) ms", out)
    if not took or int(took.group(1)) < 200:
        return False, f"the seed took {took.group(1) if took else '?'} ms (< 200 ms, twice the gap threshold: no margin to see a freeze)"
    frames, longest = int(gap.group(1)), float(gap.group(2))
    if frames < 20 or longest > 100:
        return False, f"while seeding: {frames} frames painted, longest gap {longest} ms (≥ 20 frames, ≤ 100 ms)"
    con = sqlite3.connect(db)
    n = con.execute("SELECT count(*) FROM notes").fetchone()[0]
    con.close()
    if n != 10000:
        return False, f"{n} notes seeded, want 10000"
    qs = prefixes(db)
    if len(qs) < 50:
        return False, f"only {len(qs)} search prefixes from the seeded titles"
    code, out = jot(db, ["pause:500"] + [f"type:Search={q}" for q in qs])
    got = re.findall(r"JOT SEARCH: q=(\S*) results=(\d+) ms=([\d.]+)", out)
    if code != 0 or len(got) < 50:
        return False, f"exit {code}; {len(got)} JOT SEARCH lines for 50 queries"
    by_q = {}
    for q, r, ms in got:
        by_q[q] = (int(r), float(ms))
    wrong = [q for q in qs if q not in by_q or by_q[q][0] != fts_count(db, q + "*")]
    if wrong:
        return False, f"result counts differ from FTS5 for {wrong[:5]}"
    times = sorted(ms for _, ms in by_q.values())
    p95 = times[int(0.95 * (len(times) - 1))]
    hits = sum(1 for q in qs if by_q[q][0] > 0)
    if p95 > 16 or hits < 40:
        return False, f"search p95 {p95} ms (≤ 16); {hits}/50 queries found something (≥ 40)"
    return True, f"10,000 notes seeded with the window painting ({frames} frames, longest gap {longest} ms); 50 searches p95 {p95} ms, counts equal FTS5"


def m3():
    ok, why = build("linux")
    if not ok:
        return False, "linux build failed: " + why
    imp = TMP / "import.md"
    imp.write_text("Reading list\nDune\nPiranesi\n")
    drop = TMP / "dropped.txt"
    drop.write_text("Dropped from the file manager\nit should become a note\n")
    out_md = TMP / "export.md"
    db = TMP / "m3.db"
    steps = [("pick:Import=" + str(imp), "notes=1"), ("save:Export=" + str(out_md), "notes=1"),
             ("dropfile:notes=" + str(drop), "notes=2")]
    code, out = jot(db, ["pause:500"] + [s for s, _ in steps])
    if code != 0:
        return False, f"exit {code}: {out[-400:]}"
    ok, last = in_order(out, steps)
    if not ok:
        return False, last
    if not out_md.exists() or out_md.read_text() != imp.read_text():
        return False, "the exported file doesn't equal the imported note"
    con = sqlite3.connect(db)
    bodies = sorted(r[0] for r in con.execute("SELECT body FROM notes"))
    con.close()
    if bodies != sorted([imp.read_text(), drop.read_text()]):
        return False, f"bodies in the file: {bodies}"
    # (added with M5's matrix, D-1316: the same three on the web through scripts/drive.py: the file input's upload, the
    # FileSaver's real browser download, a drop event carrying a File)
    ok, why = build("web")
    if not ok:
        return False, "web build failed: " + why
    import drive
    wdb, wout = TMP / "m3-web.db", TMP / "export-web.md"
    res, out = drive.web_run(str(APP / "web"), f"pick:Import={imp};save:Export={wout};dropfile:notes={drop}", env={"JOT_DB": str(wdb)})
    if not wout.exists() or wout.read_text() != imp.read_text():
        return False, f"web: the downloaded export doesn't equal the imported note ({out[-300:]})"
    con = sqlite3.connect(wdb)
    wbodies = sorted(r[0] for r in con.execute("SELECT body FROM notes"))
    con.close()
    if wbodies != sorted([imp.read_text(), drop.read_text()]):
        return False, f"web: bodies in the file: {wbodies}"
    # (added in review round 1, D-1326: two files dropped together, both with one name, each become a note: on the web
    # they arrived for a screen the first one had changed and were dropped, and the second overwrote the first's upload)
    one, two = TMP / "a" / "same.txt", TMP / "b" / "same.txt"
    for f, text in ((one, "First of two\ndropped together\n"), (two, "Second of two\nsame file name\n")):
        f.parent.mkdir(exist_ok=True)
        f.write_text(text)
    want = sorted([one.read_text(), two.read_text()])
    gdb = TMP / "m3-two.db"
    code, out = jot(gdb, ["pause:500", f"dropfile:notes={one},{two}", "pause:500"])
    con = sqlite3.connect(gdb)
    got = sorted(r[0] for r in con.execute("SELECT body FROM notes"))
    con.close()
    if code != 0 or got != want:
        return False, f"GTK: two files dropped together left {got}"
    wdb2 = TMP / "m3-web-two.db"
    res, out = drive.web_run(str(APP / "web"), f"dropfile:notes={one},{two}", env={"JOT_DB": str(wdb2)})
    con = sqlite3.connect(wdb2)
    got = sorted(r[0] for r in con.execute("SELECT body FROM notes"))
    con.close()
    if got != want:
        return False, f"web: two files dropped together left {got} ({out[-200:]})"
    return True, "imported, exported byte for byte, and a dropped file became a note (GTK and the web); two dropped together (one name) became two"


def m4():
    ok, why = build("linux")
    if not ok:
        return False, "linux build failed: " + why
    db = TMP / "m4.db"
    last_words = "Last words before quitting"
    code, out = jot(db, ["pause:500", "tap:New", "textarea:0=" + last_words, "quit"], timeout=120)
    if code != 0 or "JOT QUIT:" not in out:
        return False, f"exit {code}; quit hook line {'JOT QUIT:' in out}: {out[-300:]}"
    # (added with M4, D-1315: the window really closed through close-request, not only the app's shutdown at the
    # end of a test run, which tells App.closing too)
    if "QUIT: window closed" not in out:
        return False, "the quit step didn't close the window (no 'QUIT: window closed')"
    con = sqlite3.connect(db)
    bodies = [r[0] for r in con.execute("SELECT body FROM notes")]
    con.close()
    if bodies != [last_words]:
        return False, f"after quit the file holds {bodies}"
    code, out = jot(db, ["pause:500"])
    if code != 0 or not in_order(out, [("relaunch", "notes=1")])[0] or last_words not in out:
        return False, f"relaunched: exit {code}, {out[-300:]}"
    return True, "typing then quit: saved by the quit hook, there after a relaunch"


def m5():
    problems = []
    page = (ROOT / "docs" / "gallery" / "index.html").read_text()
    if "Database" not in page:
        problems.append("no Database section in the gallery")
    import numpy as np
    from PIL import Image
    for name in ("jot-gtk.png", "jot-web.png"):
        p = ROOT / "docs" / "gallery" / "img" / name
        if f"img/{name}" not in page:
            problems.append(f"the gallery doesn't show {name}")
        if not p.exists():
            problems.append(f"{name} missing")
        elif np.asarray(Image.open(p).convert("L"), dtype=float).std() < 2:
            problems.append(f"{name} is blank")
    if run(["pixi", "run", "python", "scripts/components.py", "--check"]).returncode != 0:
        problems.append("docs/components.md is stale")
    comps = (ROOT / "docs" / "components.md").read_text().lower()
    for word in ("sqlite", "save dialog", "file drop", "quit hook"):
        if word not in comps:
            problems.append(f"docs/components.md doesn't list {word}")
    if "mojoui.sqlite" not in (ROOT / "docs" / "llms.txt").read_text():
        problems.append("docs/llms.txt doesn't name mojoui.sqlite")
    top = (ROOT / "EXPERIMENTS.md").read_text().split("\n## ", 2)
    if len(top) < 2 or "42" not in top[1].splitlines()[0]:
        problems.append("EXPERIMENTS.md's newest entry isn't goal 42")
    for target in ("web", "mac"):
        ok, why = build(target)
        if not ok:
            problems.append(f"{target} build failed: {why[-150:]}")
    if problems:
        return False, "; ".join(problems)
    return True, "gallery Database section, matrix, llms.txt, EXPERIMENTS; web and mac built"


def m6():
    """The race (added 2026-10-30): native mojoui.sqlite vs SQLite-wasm + OPFS in Chromium, 1M notes."""
    import json
    path = ROOT / "docs" / "goals" / "42" / "race.json"
    if not path.exists():
        return False, "docs/goals/42/race.json missing (scripts/jot_race.py)"
    r = json.loads(path.read_text())
    srcs = ["mojoui/sqlite.mojo", "scripts/jot_race.py"]
    stale = run(["git", "diff", "--quiet", r.get("commit", "none"), "HEAD", "--", *srcs]).returncode != 0
    dirty = run(["git", "diff", "--quiet", "HEAD", "--", *srcs]).returncode != 0
    if stale or dirty:
        return False, f"race.json is stale for {srcs}"
    a, b = r.get("a", {}), r.get("b", {})
    for side, s in (("a", a), ("b", b)):
        missing = [k for k in ("notes", "build_s", "cold_open_ms", "search_p50_ms", "search_p95_ms", "disk_mb", "counts") if k not in s]
        if missing and not (side == "b" and s.get("error")):
            return False, f"side {side} lacks {missing}"
    if a.get("notes") != 1_000_000 or len(a.get("counts", [])) != 200:
        return False, f"A: {a.get('notes')} notes, {len(a.get('counts', []))} queries (want 1,000,000 and 200)"
    if b.get("error"):
        if b.get("notes", 0) >= 1_000_000:
            return False, "B reports an error but also 1M notes"
        return True, f"B couldn't hold 1M notes ({b['error'][:120]}; largest {b.get('notes')}); A: search p95 {a['search_p95_ms']} ms, cold open {a['cold_open_ms']} ms"
    if b.get("notes") != 1_000_000 or a["counts"] != b["counts"]:
        return False, f"B: {b.get('notes')} notes; counts equal on every query: {a['counts'] == b.get('counts')}"
    if "vfs" not in b or "vfs_tried" not in b:
        return False, "race.json doesn't say which OPFS VFS B used and which were tried"
    verdict = (f"1M notes: search p95 A {a['search_p95_ms']} vs B {b['search_p95_ms']} ms ({b['vfs']}); "
               f"cold open A {a['cold_open_ms']} vs B {b['cold_open_ms']} ms; build A {a['build_s']} vs B {b['build_s']} s; "
               f"disk A {a['disk_mb']} vs B {b['disk_mb']} MB")
    if a["search_p95_ms"] > b["search_p95_ms"] / 2 or a["cold_open_ms"] > b["cold_open_ms"] / 2:
        return False, "omxcode didn't win: " + verdict
    return True, verdict


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6}

if __name__ == "__main__":
    pick = [a for a in sys.argv[1:] if a in MILESTONES] or list(MILESTONES)
    failed = 0
    for name in pick:
        try:
            ok, msg = MILESTONES[name]()
        except Exception as e:  # a crash in a proof is a FAIL, not a pass
            ok, msg = False, f"{type(e).__name__}: {e}"
        failed += not ok
        print(f"{name} {'PASS' if ok else 'FAIL'}: {msg}", flush=True)
    sys.exit(1 if failed else 0)
