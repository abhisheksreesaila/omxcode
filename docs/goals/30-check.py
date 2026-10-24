"""Milestone checker for GOAL.md (goal 30: the island, and 100 million rows that never freeze the window; goal 29's
checks run as M5, every earlier goal's inside them). Rebuilds from scratch, prints PASS/FAIL per milestone.

Run: scripts/check   (a subset without rebuilding: scripts/check M1 M2; earlier goals: through docs/goals/NN-check.py)
Each milestone's proof is written before its work starts (todo() until then: it fails).
"""

import importlib.util
import re
import sys
import time
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())  # (archived in docs/goals/)
sys.path.insert(0, str(ROOT / "scripts"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g29 = load("goal29", "docs/goals/29-check.py")
g15 = load("goal15", "docs/goals/15-check.py")
g20 = g29.g20
run, BUILD = g20.run, g20.BUILD
APPS = g29.APPS
labels = g15.labels


def m0():
    """The new engine everywhere: vendored from 23edc59; every example built for every platform it lists; a chart
    through a job equals the chart in place."""
    problems = []
    stamp = (ROOT / "vendor/MXFRAME_COMMIT").read_text().split("\n")[0]
    if "23edc59" not in stamp:
        problems.append(f"vendor/MXFRAME_COMMIT says {stamp[:60]}")
    for ex in APPS:
        plats = (ROOT / "examples" / ex / "platforms").read_text().split() if (ROOT / "examples" / ex / "platforms").exists() else ["linux", "web", "mac", "ios"]
        for plat in plats:
            if plat in ("linux", "web", "mac", "ios") and not (BUILD / ex / plat).exists():
                problems.append(f"{ex} has no {plat} build")
    err = g20.mojo_test("tests/test_chart_job.mojo", "PASSED", "test_chart_job", "tests")
    if err:
        problems.append(err)
    return not problems, "; ".join(problems[:6]) or ("vendor/ is MX frame 23edc59; every example built for Linux, the web, Mac and iPhone (as its "
                                                      "platforms list); 6 charts through a job equal the same charts in place")


OUT = BUILD / "g30"


def big():
    """Goal 20's 100M-row file (order, amount, region, day, paid): the main checkout's copy, else this one's."""
    main = ROOT.parent / "mojo-ui" / "build" / "g20" / "big.parquet"
    return main if main.exists() else BUILD / "g20" / "big.parquet"


def gtk(steps, name, **more):
    """omxplorer on the private headless display, traced (MOJOUI_TRACE: the jobs say what they do, frame gaps), fresh settings."""
    home = OUT / name
    for d in ("docs", "config", "uploads"):
        (home / d).mkdir(parents=True, exist_ok=True)
    for f in (home / "config").glob("*"):
        f.unlink()
    env = dict(g20.g19.env(), OMX_DOCUMENTS=str(home / "docs"), OMX_CONFIG=str(home / "config"), MOJOUI_TRACE="1",
               MOJOUI_TEST=steps, MOJOUI_SHOT=str(OUT / f"{name}-gtk.png"), MOJOUI_WINDOW="1742x876", **more)
    r = run([str(BUILD / "omxplorer" / "linux" / "omxplorer")], env=env, timeout=900)
    out = r.stdout + r.stderr
    (OUT / f"{name}.txt").write_text(out)
    if r.returncode != 0 or "CRITICAL" in out or "TEST: " in out:
        raise RuntimeError(f"GTK run {name} failed (exit {r.returncode}): {out[-600:]}")
    return out


def charts_in(out):
    """Each chart's text as it landed (CHART: chartN, then its lines up to the next line that isn't a row)."""
    got = []
    lines = out.splitlines()
    for i, l in enumerate(lines):
        if l.startswith("CHART: "):
            rows = []
            for m in lines[i + 1:]:
                if " | " not in m:
                    break
                rows.append(m)
            got.append("\n".join(rows))
    return got


def gaps(out):
    return [float(v) for v in re.findall(r"^GAPS: \d+ frames, longest ([\d.]+) ms$", out, re.M)]


def m1():
    """Queries off the window at 100M rows: opening, a median, a month chart, a column's figures; a newer pick cancels."""
    problems = []
    if not big().exists():
        return False, f"no 100M-row file at {big()} (goal 20's big.parquet)"
    b = run(["scripts/mxbuild.sh", "tests/bigchart_dump.mojo", "-o", str(BUILD / "bigchart_dump")], timeout=1800)
    if b.returncode != 0:
        return False, "bigchart_dump: " + (b.stdout + b.stderr)[-400:]
    want = run([str(BUILD / "bigchart_dump"), str(big())], timeout=900).stdout
    blocks = re.findall(r"^CHART (\w+)\n(.*?)(?=^CHART |^SUM )", want, re.M | re.S)
    want_chart = {k: "\n".join(l for l in v.strip().splitlines() if " | " in l) for k, v in blocks}  # (rows only: the tool also prints timings)
    want_sum = re.search(r"^SUM (.*)$", want, re.M).group(1)
    opened = "gaps:start;pick:Choose a file={f};gaps:3500;tap:Create table;pause:300;tap:Chart;pause:1500".format(f=big())
    a = gtk(opened + ";tap:Data;gaps:start;segment:1=Median;gaps:2000;tap:Back;gaps:start;" + g29.g28.ASK + "by month;gaps:5500", "g30-m1")
    g = gaps(a)
    if len(g) != 3 or max(g) > 50.0:
        problems.append(f"frame gaps while opening, the median and the month chart ran: {g} ms (want 3, each ≤ 50)")
    landed = charts_in(a)
    if want_chart.get("median") not in landed:
        problems.append(f"the median chart that landed isn't the in-place one: {landed[-2:] if landed else 'none'}")
    if want_chart.get("month") not in landed:
        problems.append(f"the month chart that landed isn't the in-place one (got {len(landed)} charts)")
    for job in ("open big.parquet", "chart0 median amount by region", "chart0 median amount by month", "column amount"):
        if f"JOB: start {job}" not in a:
            problems.append(f"no background job for {job}")
    if not re.search(r"^LABEL: Sum " + re.escape(want_sum) + "$", a, re.M):
        problems.append(f"the status bar's sum isn't the in-place {want_sum}")
    c = gtk(opened + ";tap:Data;gaps:start;segment:1=Median;pause:100;segment:1=Sum;gaps:2000", "g30-m1-cancel")
    after = c.split("JOB: start chart0 median amount by region", 1)[-1]
    if "JOB: start chart0 median amount by region" not in c or "landed chart0" not in after:
        problems.append("the cancel run didn't start the median and then land a chart")
    elif re.search(r"^region \| median amount$", after, re.M):
        problems.append("the median landed though Sum was picked while it ran (want it cancelled)")
    if max(gaps(c) or [999]) > 50.0:
        problems.append(f"frame gaps around the cancel: {gaps(c)} ms")
    # the jobs' lifecycle (reviewer, round 1): a chart removed while another's job runs; another file opened mid-job
    rm = gtk(opened + ";tap:Chart;pause:800;tap:Data;segment:1=Median;pause:100;tap:Remove;pause:2000", "g30-m1-remove")
    after = rm.split("JOB: start chart1 median amount by region", 1)[-1]
    if "JOB: start chart1 median amount by region" not in rm or "JOB: landed chart0" not in after or want_chart.get("median") not in charts_in(after):
        problems.append("removing chart 0 while chart 1's median ran: the median didn't land on chart 1, now chart 0")
    # (CSV_1M is under BIG_FILE, so it opens at once, with no job of its own landing after the drop; a fresh worktree
    # has no CSV_1M before goal 15's ensure_csv writes it, and then the swap opens nothing)
    ok, msg = g15.ensure_csv()
    if not ok:
        return False, msg
    swap = gtk(opened + ";tap:Data;segment:1=Median;pause:100;pick:Open={f};pause:2500".format(f=g15.CSV_1M), "g30-m1-swap")
    after = swap.split("JOB: start chart0 median amount by region", 1)[-1]
    dropped = after.split("JOB: dropped every job", 1)[-1]  # (an old job may land before the new file opens: the column's 2 s)
    if ("JOB: start chart0 median amount by region" not in swap or "JOB: dropped every job" not in after or "JOB: landed" in dropped
            or "landed chart0" in after.split("JOB: dropped every job", 1)[0] or "BUTTON: Create table" not in dropped):
        problems.append("opening another file during a median: the old document's jobs weren't dropped (or the new file didn't open)")
    return not problems, "; ".join(problems[:6]) or (f"at 100M rows on GTK the window kept drawing (longest frame gaps {', '.join(f'{v:.0f}' for v in g)} ms) "
                                                      "while the file opened, a median and a month chart ran and the column's figures came; each "
                                                      "equals the in-place answer; Sum picked during the median cancels it; a chart removed mid-job leaves the others' jobs "
                                                      "landing on their new places; another file opened mid-job drops the old jobs")


def said(out, tag="island"):
    """What `say:TAG` steps read, in order."""
    return re.findall(rf"^SAYS: {tag} = (.*)$", out or "", re.M)


def crop(png, box):
    from PIL import Image
    x, y, w, h = (int(round(v)) for v in box)
    return Image.open(png).convert("RGB").crop((x, y, x + w, y + h))


def m2():
    """The Island component: its own test, in the component matrix, and drawn alike by GTK and the web."""
    problems = []
    err = g20.mojo_test("tests/test_island.mojo", "PASSED", "test_island", "tests")
    if err:
        problems.append(err)
    comps = run(["pixi", "run", "python", "scripts/components.py", "--check"], timeout=120)
    if comps.returncode != 0 or "Island" not in (ROOT / "docs/components.md").read_text():
        problems.append("docs/components.md doesn't list the Island (or is stale): " + comps.stdout.strip()[-200:])
    ok, msg = g15.ensure_csv()
    if not ok:
        return False, msg
    r = g15.both(g15.OPEN + ";pause:900", "g30-island")
    if r[0] is None:
        return False, r[1]
    from PIL import ImageChops, ImageStat
    shots = []
    for host, k in (("gtk", 0), ("web", 1)):
        b = g29.g28.g25.boxes(r[k], "island")
        if not b:
            problems.append(f"{host}: no island on screen")
            continue
        shots.append(crop(BUILD / "omxplorer" / f"g30-island-{host}.png", b[0]))
    if len(shots) == 2:
        if shots[0].size != shots[1].size:
            problems.append(f"the island's size differs: GTK {shots[0].size}, web {shots[1].size}")
        else:
            diff = ImageStat.Stat(ImageChops.difference(shots[0], shots[1])).mean
            if max(diff) > 4.0:
                problems.append(f"GTK and the web draw the island differently (mean difference {[round(v, 1) for v in diff]})")
            shots[0].save(OUT / "island-gtk.png")
            shots[1].save(OUT / "island-web.png")
    return not problems, "; ".join(problems[:6]) or ("tests/test_island.mojo (faces, the 320 ms morph on the calm curve, less motion, expiry, hit areas, every "
                                                      "face drawn differently); in docs/components.md; GTK and the web draw the island alike")


def m3():
    """omxplorer wears the island: no chips or toast; Sort's Undo; an error stays; the panel; at 100M a running, a done and a resting face."""
    problems = []
    msgs = run(["pixi", "run", "python", "scripts/msgs.py"] + sorted(str(p) for p in (ROOT / "examples").glob("*/app.mojo")), timeout=120)
    if msgs.returncode != 0:
        problems.append("message collisions: " + msgs.stdout.strip()[-300:])  # (goal 30: the island's messages once sat inside STYLE_ALIGN's)
    ok, msg = g15.ensure_csv()
    if not ok:
        return False, msg
    bad = OUT / "bad.csv"
    OUT.mkdir(parents=True, exist_ok=True)
    bad.write_bytes(b"\x00\x01\x02 not a table \xff\xfe")
    sort = g15.both(g15.OPEN + ";tap:Sort;say:island;tapat:island=995,500;pause:300;say:island", "g30-sort")
    panel = g15.both(g15.OPEN + ";tap:Sort;pause:5500;tapat:island=995,500;pause:400", "g30-panel")
    error = g15.both(f"pick:Choose a file={bad};pause:6000;say:island;tapat:island=995,500;pause:400;say:island", "g30-error")
    for r in (sort, panel, error):
        if r[0] is None:
            return False, r[1]
    for host, k in (("GTK", 0), ("web", 1)):
        s, p, e = sort[k], panel[k], error[k]
        for tag in ("doc-chip", "gpu-chip"):
            if f"BOX: {tag} " in s:
                problems.append(f"{host}: the {tag} is still there")
        if "TOAST: " in s:
            problems.append(f"{host}: Sort still shows a toast")
        w = said(s)
        if len(w) != 2 or not w[0].startswith("Sorted by ") or not w[1].startswith("Sort undone"):
            problems.append(f"{host}: Sort's island and its Undo said {w} (want \"Sorted by …\", then \"Sort undone\")")
        if any(l.startswith("sorted by ") for l in labels(s)):
            problems.append(f"{host}: the island's Undo didn't undo the sort")
        if "POPOVER: Activity" not in p or not {"Recent", "Device"} <= set(labels(p)) or not any(l.startswith("Sorted by ") for l in labels(p)):
            problems.append(f"{host}: tapping the island didn't open its panel with Recent (the sort) and Device")
        w = said(e)
        if len(w) != 2 or not w[0].startswith("Couldn't open bad.csv") or w[1].startswith("Couldn't"):
            problems.append(f"{host}: the error face {w} (want it still there after 6 s, gone once its Show is tapped)")
    if not big().exists():
        return False, f"no 100M-row file at {big()}"
    a = gtk("pick:Choose a file={f};pause:3500;tap:Create table;pause:300;tap:Chart;pause:1500;tap:Data;segment:1=Median;pause:250;say:island;"
            "pause:1500;say:island;pause:4500;say:island;tapat:island=995,500;pause:400".format(f=big()), "g30-m3-big")
    w = said(a)
    gpu = re.search(r"on (NVIDIA[^·]*)", "\n".join(w))
    if len(w) != 3 or not re.match(r"Median amount by region · \d+% · ", w[0]):
        problems.append(f"GTK 100M: the running face read {w[:1]} (want \"Median amount by region · N% · …\")")
    elif not re.match(r"Median amount by region · [\d.]+ s on \S", w[1]):
        problems.append(f"GTK 100M: the done face read {w[1]} (want \"Median amount by region · 0.7 s on <GPU>\")")
    elif not w[2].startswith("big · 100,000,000 rows · "):
        problems.append(f"GTK 100M: 4 s after it landed the island read {w[2]} (want the document at rest)")
    if "POPOVER: Activity" not in a or "p50 · p95" not in labels(a) or not any(re.match(r"[\d.]+ s on ", l) for l in labels(a)):
        problems.append("GTK 100M: the panel has no Recent time or Device p50 · p95")
    return not problems, "; ".join(problems[:6]) or ("no document or GPU chip, no toast: Sort says so in the island and its Undo undoes it; a bad file's "
                                                      "error stays 6 s, until its Show is tapped; the island's panel has Recent and Device; GTK and the "
                                                      "web; at 100M on GTK the island reads \"" + (w[0] if w else "") + "\", then the time on the GPU, then the document")


def m4():
    """The 100M demo: scripts/clips.py island records it; through the 3 s query the island changes in every frame (its
    spinner, drawn by the window's thread: the window never stops); the clip and a still go to docs/img."""
    import shutil
    import numpy as np
    problems = []
    if not big().exists():
        return False, f"no 100M-row file at {big()}"
    r = run(["pixi", "run", "python", "scripts/clips.py", "island"], timeout=900)
    clip, still = BUILD / "clips" / "island-100m.mp4", BUILD / "clips" / "island-100m.png"
    if r.returncode != 0 or not clip.exists() or not still.exists():
        return False, "scripts/clips.py island: " + (r.stdout + r.stderr)[-400:]
    x, y, w, h = 1262, 10, 460, 40  # (the island's place in the 1742 × 876 window: BOX island)
    import subprocess
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(clip), "-vf", f"crop={w}:{h}:{x}:{y},format=gray", "-f", "rawvideo", "-"],
                         capture_output=True, timeout=300)
    frames = np.frombuffer(raw.stdout, dtype=np.uint8)
    n = frames.size // (w * h)
    if n < 300:
        problems.append(f"the clip has {n} frames (want 10 s or more at 30 fps)")
    else:
        f = frames[: n * w * h].reshape(n, h, w).astype(np.int16)
        moving = [int(np.abs(f[k + 1] - f[k]).max()) > 24 for k in range(n - 1)]
        best = run_len = 0
        for m in moving:
            run_len = run_len + 1 if m else 0
            best = max(best, run_len)
        if best < 75:
            problems.append(f"the island's longest stretch changing in every frame is {best / 30:.1f} s (want ≥ 2.5 s: the 3 s query, the window never stopping)")
    img = ROOT / "docs" / "img"
    shutil.copy(clip, img / "clip-island-100m.mp4")
    from PIL import Image
    Image.open(still).convert("RGB").save(img / "clip-island-100m.jpg", quality=88)
    return not problems, "; ".join(problems[:6]) or (f"docs/img/clip-island-100m.mp4 ({n / 30:.0f} s) and .jpg: open 100M rows, a median, a 3 s median by "
                                                      f"month; through it the island changed in every frame for {best / 30:.1f} s straight")


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m5():
    """Goal 29's checks (every earlier goal's inside them), and no host's test wait that can sleep past its deadline."""
    problems = []
    import re
    for f in sorted(list((ROOT / "mojoui").rglob("*.mojo")) + list((ROOT / "examples").rglob("*.mojo"))):  # (D-286: a blocking main-loop turn hung a run 15 minutes)
        text = f.read_text()
        for m in re.finditer(r'g_main_context_iteration"[^\]]*\]\(([^;\n]*(?:\n[^;\n]*)?)', text):  # (a call may span two lines)
            if not re.match(r'\s*\w+\s*,\s*c_int\(0\)\s*\)', m.group(1)):
                problems.append(f"{f.relative_to(ROOT)}:{text[:m.start()].count(chr(10)) + 1} turns the main loop blocking (may_block isn't c_int(0)): use pump(), which never sleeps past a deadline")
        for m in re.finditer(r'"(g_main_loop_run|gtk_main_iteration|gtk_main)"', text):
            problems.append(f"{f.relative_to(ROOT)}:{text[:m.start()].count(chr(10)) + 1} runs a blocking main loop ({m.group(1)})")
    for name, fn in [(f"29-M{i}", getattr(g29, f"m{i}")) for i in range(6)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    return not problems, "; ".join(problems) or "goal 29's M0–M5 (goals 3–28 inside them) pass"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2),
              ("M3", m3), ("M4", m4), ("M5", m5)]


def build_all():
    import shutil
    every = list(dict.fromkeys(list(g20.EXAMPLES) + APPS))
    for ex in every:
        shutil.rmtree(BUILD / ex, ignore_errors=True)
    for ex in every:
        if not (ROOT / "examples" / ex / "app.mojo").exists():
            continue
        b = run(["scripts/build.sh", ex, "all"], timeout=3600)
        if b.returncode != 0:
            print(f"build {ex} failed:\n" + (b.stdout + b.stderr)[-1500:])
        if ex in ("hello", "gallery", "layout", "lens", "todo"):
            a = run(["scripts/build.sh", ex, "android"], timeout=3600)
            if a.returncode != 0:
                print(f"android build {ex} failed:\n" + (a.stdout + a.stderr)[-1500:])


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
    if not only:
        build_all()
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            import traceback
            traceback.print_exc()  # (where it crashed, not only what: a bare IndexError cost a 10-minute rerun)
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
