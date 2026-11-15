"""Goal 71's proof: robot search by example in omxplorer, on omxcore stable 5194d77 (GOAL.md).
Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/71-check.py [M0 M1 ...]          (default: every milestone)

The omxcore checkout ($OMXCORE_REPO, else ~/Projects/mxframe) is only read: `git archive 5194d77`, its `robotics` pixi env
(omxcore's Python `omxcore.robot` and lerobot: the reference) and build/robotics (the pool's index). Outputs under build/g71.
"""
import importlib.util
import json
import os
import random
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g71"
G71 = ROOT / "docs/goals/71"
sys.path.insert(0, str(ROOT / "scripts"))
COMMIT = "5194d77"
PREV = "a9a3c37"
PATCH = ROOT / f"vendor/patches/omxcore-{COMMIT}-mojo12.patch"
K = 24


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g70 = _load("g70check", ROOT / "docs/goals/70-check.py")
g70.OUT = OUT
g70.BIN = OUT / "bin"
run, test_one = g70.run, g70.test_one


def engine_repo():
    return Path(g70.engine_repo())


def index_path():
    return engine_repo() / "build/robotics/index.parquet"


def ref(args, timeout=1800):
    """omxcore's Python reference (docs/goals/71/oracle.py) in the checkout's `robotics` env; JSON on stdout."""
    r = run(["pixi", "run", "--frozen", "--manifest-path", str(engine_repo() / "pixi.toml"), "-e", "robotics", "python", "-I",
             str(G71 / "oracle.py"), *args], timeout, cwd=engine_repo())
    if r.returncode:
        raise RuntimeError("oracle: " + (r.stdout + r.stderr)[-800:])
    return json.loads(r.stdout.strip().splitlines()[-1])


def picks():
    """10 seeded clips and 3 seeded triples over the pool's episodes (build/g71/picks.json, made once from the reference)."""
    p = OUT / "picks.json"
    if not p.exists():
        eps = ref(["episodes", str(index_path())])["episodes"]
        rng = random.Random(71)
        keys = sorted(f"{e['dataset']}:{e['episode']}" for e in eps)
        small = sorted(k for k in keys if k.startswith("lerobot/svla_so100_sorting:"))
        p.write_text(json.dumps({"one": rng.sample(keys, 10), "three": [rng.sample(keys, 3) for _ in range(3)],
                                 "export": rng.sample(small, 3)}, indent=1))
    return json.loads(p.read_text())


def same_ranking(got, want):
    """got, want: [[key, score], ...]; same keys in the same order, scores within 1e-4 (an equal-score tie may swap)."""
    if [k for k, _ in got] == [k for k, _ in want]:
        return all(abs(a[1] - b[1]) <= 1e-4 for a, b in zip(got, want)), "scores differ"
    for i, (a, b) in enumerate(zip(got, want)):
        if a[0] != b[0] and not (abs(a[1] - b[1]) <= 1e-4 and {x[0] for x in got[i:i + 2]} == {x[0] for x in want[i:i + 2]}):
            return False, f"rank {i}: {a} vs {b}"
    return len(got) == len(want), "lengths differ"


# ------------------------------------------------------------------------------------------------------------- M0


def m0():
    probs, said = [], []
    first = (ROOT / "vendor/OMXCORE_COMMIT").read_text()
    if not first.startswith(COMMIT) or PATCH.name not in first or not PATCH.exists():
        probs.append(f"vendor/OMXCORE_COMMIT doesn't start with {COMMIT} and name {PATCH.name} (or the patch is missing)")
    g70.COMMIT, g70.PATCH = COMMIT, PATCH
    line = next((l for l in first.splitlines() if l.startswith("rebuild: ")), "")
    if "archive " + COMMIT not in line:
        probs.append("the rebuild line doesn't archive " + COMMIT)
    else:
        # goal 70's rebuild runner writes to build/g70/rebuilt.mojoc; keep its path, compare the size the same way
        (ROOT / "build/g70").mkdir(parents=True, exist_ok=True)
        why = g70.rebuild_engine()
        (probs.append(why) if why else said.append("the rebuild line rebuilds vendor/omxcore.mojoc"))
    from engine_lineage import vendored_at_least

    why = vendored_at_least(PREV)
    (probs.append(f"lineage: {why}") if why else said.append(f"vendor = {COMMIT}'s archive + the patch, at least {PREV} (engine_lineage)"))
    # F-204: no use of the old Query.table field left in the app's code
    # (D-7106: only names that hold an omxcore Query; a mojoui struct's own `table` field, such as LikeResult's, is not
    # F-204's. Every build below compiles against 5194d77, where Query has no `table` field: that is the proof.)
    old = run(["bash", "-c", r"grep -rnE '\b(q|query|qr|Query\([^)]*\))\.table\.' --include=*.mojo mojoui examples tests hosts themes || true"]).stdout.strip()
    if old:
        probs.append("possible old Query.table uses (F-204): " + old[:400])
    exs = sorted(p.parent.name for p in (ROOT / "examples").glob("*/needs") if "omxcore" in p.read_text().split())
    with ThreadPoolExecutor(3) as pool:
        built = list(pool.map(lambda ex: (ex, run(["scripts/build.sh", ex, "linux"], 3600)), exs))
    bad = [f"{ex}: {(r.stdout + r.stderr)[-300:]}" for ex, r in built if r.returncode]
    probs += bad
    said.append(f"{len(exs) - len(bad)}/{len(exs)} omxcore examples build for Linux")
    g70.ensure_bags()
    g70.ensure_g39()
    tests = g70.ENGINE_TESTS + ["test_robot_import"]
    with ThreadPoolExecutor(6) as pool:
        ran = list(pool.map(lambda t: (t, *test_one(t)), tests))
    bad = [f"{t}: {why[-200:]}" for t, ok, why in ran if not ok]
    probs += bad
    said.append(f"{len(tests) - len(bad)}/{len(tests)} engine tests pass (with test_robot_import beside Flare)")
    # Mac: no undefined symbol over goal 70's objects (docs/goals/71/mac-undefined-g70-<app>.json, from main 0cfcdb8a)
    mp, ms = [], []
    for ex in ("jobwake", "jot", "keeper", "omxplorer"):
        linked, got, why = g70.mac_undefined(ex)
        base = G71 / f"mac-undefined-g70-{ex}.json"
        if got is None or not base.exists():
            mp.append(f"{ex}: {why or 'no ' + base.name}")
            continue
        new = sorted(got - set(json.loads(base.read_text())))
        if new:
            mp.append(f"{ex}: new undefined symbols {new}")
        if ex != "omxplorer" and not linked:
            mp.append(f"{ex}: doesn't link")
        ms.append(f"{ex} none new")
    (probs.extend("Mac: " + x for x in mp) if mp else said.append("Mac: " + ", ".join(ms)))
    return (not probs), ("; ".join(probs) if probs else "; ".join(said))


# ------------------------------------------------------------------------------------------------------------- M1


def m1():
    probs, said = [], []
    pk = picks()
    (OUT / "pool").mkdir(parents=True, exist_ok=True)
    env = {"G71_INDEX": str(index_path()), "G71_PICKS": str(OUT / "picks.json"), "G71_OUT": str(OUT / "pool")}
    os.environ.update(env)
    ok, why = test_one("test_robotpool")
    if not ok:
        return False, "test_robotpool: " + why
    got = json.loads((OUT / "pool/pool.json").read_text())
    if got["episodes"] != 1851 or round(got["hours"], 1) != 8.3 or got["datasets"] != 4:
        probs.append(f"pool: {got['episodes']} episodes, {got['hours']} h, {got['datasets']} datasets (want 1851, 8.3, 4)")
    want = ref(["like", str(index_path()), str(OUT / "picks.json"), str(K)])
    bad = 0
    for kind in ("one", "three"):
        for i, (g, w) in enumerate(zip(got[kind], want[kind])):
            same, why = same_ranking(g, w)
            if not same:
                bad += 1
                probs.append(f"{kind}[{i}] {pk[kind][i]}: {why}")
    if not bad:
        said.append(f"{len(want['one'])} clips and {len(want['three'])} triples: top {K} equal omxcore's Python")
    ms = got["warm_ms"]
    (probs.append(f"warm one-clip search {ms:.2f} ms (> 5)") if ms > 5 else said.append(f"warm search {ms:.2f} ms on {got['device']}"))
    if got["device"] != "gpu":
        probs.append(f"searched on {got['device']}, not the GPU")
    ld = ref(["load", got["export"], *pk["export"]])       # with the source episodes: their frame count and tasks
    if ld["episodes"] != 3 or ld["frames"] != ld["source_frames"] or ld["tasks"] != ld["source_tasks"]:
        probs.append(f"export: lerobot read {ld} (want 3 episodes, {got['export_frames']} frames)")
    else:
        said.append(f"export of 3 picks: LeRobotDataset loads {ld['episodes']} episodes, {ld['frames']} frames")
    return (not probs), ("; ".join(probs) if probs else "; ".join(said))


# ------------------------------------------------------------------------------------------------------------- M2


def m2():
    probs, said = [], []
    (OUT / "frames").mkdir(parents=True, exist_ok=True)
    os.environ.update({"G71_INDEX": str(index_path()), "G71_PICKS": str(OUT / "picks.json"), "G71_OUT": str(OUT / "frames")})
    picks()
    ok, why = test_one("test_clipframes")
    if not ok:
        return False, "test_clipframes: " + why
    got = json.loads((OUT / "frames/frames.json").read_text())
    cmp = ref(["frames", str(OUT / "frames/frames.json")])
    if cmp["max_diff"] > 3 or cmp["compared"] < 6:
        probs.append(f"frames vs omxcore's ds.decode: {cmp}")
    else:
        said.append(f"{cmp['compared']} frames equal omxcore's decode within {cmp['max_diff']}/255")
    if got["cold_ms"] > 1500 or got["cached_ms"] > 1:
        probs.append(f"24 posters: {got['cold_ms']:.0f} ms cold, {got['cached_ms']:.2f} ms cached (want ≤ 1500, ≤ 1)")
    else:
        said.append(f"24 posters {got['cold_ms']:.0f} ms cold ({got['decoder']}), {got['cached_ms']:.2f} ms cached")
    ok, why = test_one("test_clipgrid")
    (probs.append("test_clipgrid: " + why) if not ok else said.append("test_clipgrid passes"))
    w = run(["pixi", "run", "python", str(G71 / "clipgrid_web.py"), str(OUT / "clipgrid-web.png")], 1800)
    (probs.append("ClipGrid on the web: " + (w.stdout + w.stderr)[-300:]) if w.returncode else said.append("ClipGrid on the web host"))
    c = run(["pixi", "run", "python", "scripts/components.py", "--check"], 1800)
    if c.returncode:
        probs.append("components: " + (c.stdout + c.stderr)[-300:])
    mx = (ROOT / "docs/components.md").read_text()
    row = next((l for l in mx.splitlines() if l.startswith("|") and "ClipGrid" in l.split("|")[1]), "")
    if row.count("✅") < 2:
        probs.append(f"components.md's ClipGrid row isn't ✅ on GTK and the web: {row[:200]!r}")
    return (not probs), ("; ".join(probs) if probs else "; ".join(said))


# ------------------------------------------------------------------------------------------------------------- M3


def m3():
    """The demo screen with real input: docs/goals/71/demo_drive.py builds omxplorer, drives it on GTK (headless) with
    scripts/live.py and writes build/g71/demo/drive.json: the clip and triple it picked, the results the screen shows (read
    from the view tree), the export folder, the shots and each shot's overflow list (texts outside their cards)."""
    probs, said = [], []
    pool = OUT / "pool/pool.json"
    if not pool.exists():
        return False, "run M1 first (build/g71/pool/pool.json)"
    pj = json.loads(pool.read_text())
    pk = picks()
    r = run(["pixi", "run", "python", str(G71 / "demo_drive.py"), str(OUT / "demo"), str(OUT / "picks.json"), str(index_path())], 3600)
    if r.returncode:
        return False, "demo_drive: " + (r.stdout + r.stderr)[-600:]
    d = json.loads((OUT / "demo/drive.json").read_text())
    if d["line"].get("episodes") != 1851 or "8.3" not in d["line"].get("text", ""):
        probs.append(f"pool line: {d['line']}")
    if d["clip"] != pk["one"][0]:
        probs.append(f"clicked {d['clip']}, want {pk['one'][0]}")
    same, why = same_ranking(d["like_one"], pj["one"][0])
    (probs.append("one clip on screen vs M1: " + why) if not same else said.append(f"tap {d['clip']}: the screen's {K} equal M1's"))
    same, why = same_ranking(d["like_three"], pj["three"][0])
    (probs.append("three picks on screen vs M1: " + why) if not same else said.append("pick 3 → More like these: equal M1's"))
    if d.get("search_ms") is None:
        probs.append("the screen doesn't show the search's time")
    lds = [ref(["load", f]) for f in d["export"]]          # one folder per dataset the picks come from
    ld = {"episodes": sum(x["episodes"] for x in lds), "folders": len(lds)}
    if ld["episodes"] != 3:
        probs.append(f"export from the screen: lerobot read {ld}")
    elif not d.get("toast", "").strip():
        probs.append("no toast after Export")
    else:
        said.append(f"Export → '{d['toast']}', lerobot loads {ld['episodes']} episodes")
    for name, size in (("desktop", "1440x900"), ("phone", "390x844")):
        s = d["shots"].get(name)
        if not s or not Path(s["path"]).exists() or s["size"] != size:
            probs.append(f"no {name} shot at {size}")
        elif s["overflow"]:
            probs.append(f"{name}: texts outside their cards {s['overflow'][:5]}")
        else:
            said.append(f"{name} {size}: nothing clipped")
    if d.get("theme") != "liquid-light":
        probs.append(f"theme {d.get('theme')} (want liquid-light)")
    return (not probs), ("; ".join(probs) if probs else "; ".join(said))


# ------------------------------------------------------------------------------------------------------------- M4


def m4():
    probs, said = [], []
    md = G71 / "cold-open.md"
    if not md.exists():
        return False, "no docs/goals/71/cold-open.md"
    text = md.read_text()
    report = run(["git", "-C", str(engine_repo()), "show", f"{COMMIT}:docs/goals/robotics/report.md"]).stdout
    nums = set(re.findall(r"(?<![\w.])\d[\d,]*(?:\.\d+)?(?:\s?(?:ms|h|s|x|%))?", text.split("## Shots", 1)[-1]))
    nums = {n for n in nums if not re.fullmatch(r"\d{1,2}(\s?s)?", n)}  # shot numbers and timings (e.g. "3", "12 s") are not claims
    missing = sorted(n for n in nums if n.replace(" ", "") not in report.replace(" ", ""))
    (probs.append(f"numbers not in omxcore's robotics report: {missing}") if missing else said.append(f"{len(nums)} numbers, each in the report"))
    mp4 = OUT / "cold-open.mp4"
    if not mp4.exists():
        return False, "; ".join(probs + ["no build/g71/cold-open.mp4"])
    pr = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration", "-of", "json", str(mp4)])
    info = json.loads(pr.stdout or "{}")
    dur = float(info.get("format", {}).get("duration", 0))
    st = (info.get("streams") or [{}])[0]
    if not 30 <= dur <= 60 or (st.get("width"), st.get("height")) != (1920, 1080):
        probs.append(f"cold-open.mp4: {dur:.1f} s, {st.get('width')}x{st.get('height')} (want 30-60 s, 1920x1080)")
    else:
        said.append(f"cold-open.mp4 {dur:.1f} s 1920x1080")
    scenes = [float(x) for x in re.findall(r"^\|\s*\d+\s*\|\s*([\d.]+)\s*s", text, re.M)]
    if len(scenes) < 4:
        probs.append(f"the shot list gives {len(scenes)} scene start times (want ≥ 4 rows '| n | t s | ...')")
    else:
        r = run(["pixi", "run", "python", str(G71 / "scenes.py"), str(mp4), *map(str, scenes)])
        (probs.append("scenes: " + (r.stdout + r.stderr)[-300:]) if r.returncode else said.append(f"{len(scenes)} scenes present, none blank, all different"))
    return (not probs), ("; ".join(probs) if probs else "; ".join(said))


# ------------------------------------------------------------------------------------------------------------- M5


def m5():
    g70.OUT = ROOT / "build/g70"
    (ROOT / "build/g70").mkdir(parents=True, exist_ok=True)
    return g70.m3()


MILESTONES = {f"M{i}": f for i, f in enumerate([m0, m1, m2, m3, m4, m5])}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    picked = sys.argv[1:] or list(MILESTONES)
    failed = False
    for name in picked:
        try:
            ok, why = MILESTONES[name]()
        except Exception as e:  # noqa: BLE001 (a crash is a FAIL with its reason)
            import traceback

            traceback.print_exc()
            ok, why = False, f"{type(e).__name__}: {e}"
        word = "PASS" if ok else ("BLOCKED" if ok is None else "FAIL")
        failed |= ok is False
        print(f"{name}: {word}  {why}", flush=True)
    sys.exit(1 if failed else 0)
