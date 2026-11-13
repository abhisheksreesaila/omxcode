"""Goal 70's proof: the newest omxcore engine under omxplorer, and goal 68's robotics compute on it where it wins
(GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/70-check.py [M0 M1 ...]          (default: every milestone)

Data: build/bags (scripts/fetch_bags.py, goal 68), build/g47/full (scripts/robot_data.py, goal 47), build/tpch_sf1
(docs/goals/70/make_tpch.py); each made when missing. The omxcore checkout ($OMXCORE_REPO, else ~/Projects/mxframe) is
only read (git archive). Outputs under build/g70.
"""
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g70"
BIN = OUT / "bin"
sys.path.insert(0, str(ROOT / "scripts"))
COMMIT = "a9a3c37"
PATCH = ROOT / f"vendor/patches/omxcore-{COMMIT}-mojo12.patch"
# The tests that import the engine (or the sheet over it) and run without arguments: the dump tools and benches need
# arguments; addmodel, plugins, plugin_script, robot_follow and csvio need data goal 68's checker makes (it runs in M3).
# Goal 39's generated media (scripts/media_data.py, no download) is made first for tablejobs (QueryJob / ScriptJob, which
# this goal changed), videojobs, trackcard, videocard, asksql and videotable.
ENGINE_TESTS = ["test_block_style", "test_calendar", "test_cellstyle", "test_chartask", "test_chart_job", "test_chartspec", "test_devgroup",
                "test_devrows", "test_engine_flare", "test_float_column", "test_jobs", "test_learn", "test_linkui", "test_omx_files",
                "test_parquet_import", "test_public_rules", "test_report_stats", "test_script", "test_sheetjobs_wake", "test_sheetpage",
                "test_streamed", "test_tableprep", "test_text_order", "test_fleet", "test_ui_thread", "test_local_agent", "test_imagemodel",
                "test_add_sheet", "test_tablejobs", "test_videojobs", "test_trackcard", "test_videocard", "test_asksql", "test_videotable"]
G39_ENV = {"G39_MEDIA": str(ROOT / "build/g39/media"), "G39_OUT": str(ROOT / "build/g39")}


def run(args, timeout=1800, env=None, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, env=dict(os.environ, **(env or {})), capture_output=True, text=True, timeout=timeout)


def engine_repo():
    from engine_lineage import engine_repo as repo

    return repo()


def ensure_bags():
    bags = ROOT / "build/bags"
    if not (bags / "ATTRIBUTION.txt").exists():
        r = run(["pixi", "run", "-e", "bagcheck", "python", "-I", "scripts/fetch_bags.py", str(bags)], 7200)
        if r.returncode:
            raise RuntimeError("fetch_bags: " + (r.stdout + r.stderr)[-600:])


def ensure_g39():
    if not (ROOT / "build/g39/media/truth.json").exists():
        r = run(["pixi", "run", "python", "scripts/media_data.py", str(ROOT / "build/g39/media")], 3600)
        if r.returncode:
            raise RuntimeError("media_data: " + (r.stdout + r.stderr)[-600:])


def ensure_g47():
    full = ROOT / "build/g47/full"
    if not (full / "telemetry.parquet").exists():
        r = run(["pixi", "run", "python", "-I", "scripts/robot_data.py", str(full)], 7200)
        if r.returncode:
            raise RuntimeError("robot_data: " + (r.stdout + r.stderr)[-600:])


def ensure_fleet68():
    """build/g68/fleet (runs, moments, stops): tests/test_fleet over build/bags, as goal 68's M4 writes it."""
    if not (ROOT / "build/g68/fleet/moments.csv").exists():
        ok, why = test_one("test_fleet", "build/eng-after")
        if not ok:
            raise RuntimeError("test_fleet: " + why)


def test_one(name, eng="vendor", out=None):
    """Build tests/<name>.mojo against the engine in `eng` (with Flare's flags when it uses mojoui.serve) and run it:
    (passed, the end of its output)."""
    out = out or BIN / "tests"
    out.mkdir(parents=True, exist_ok=True)
    src = ROOT / f"tests/{name}.mojo"
    flare = bool(re.search(r"mojoui\.serve|http_flare|from flare", src.read_text()))
    link = run(["bash", "-c", "source scripts/mxlink.sh; printf '%s\\n' \"${LINK[@]}\""]).stdout.split()
    extra = []
    if flare:
        run(["bash", "scripts/flare_ffi.sh"])
        extra = ["-D", "MOJOUI_FLARE", "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "build/flare/lib")]
    exe = out / name
    b = run(["pixi", "run", "mojo", "build", "--disable-warnings", "-I", ".", "-I", eng, str(src), "-o", str(exe), *link, *extra], 2400)
    if b.returncode or not exe.exists():
        return False, "build: " + "\n".join(l for l in (b.stdout + b.stderr).splitlines() if "error" in l)[-1500:]
    try:
        r = run(["pixi", "run", str(exe)], 900, env=G39_ENV)
    except subprocess.TimeoutExpired:
        return False, "timed out (900 s)"
    text = r.stdout + r.stderr
    (out / f"{name}.log").write_text(text)
    return r.returncode == 0 and "Unhandled exception" not in text, text[-400:]


# ------------------------------------------------------------------------------------------------------------- M0


def rebuild_engine():
    """vendor/OMXCORE_COMMIT's rebuild line, run as written (<omxcore>: the checkout; only its last step's copy goes to
    build/g70/rebuilt.mojoc instead of vendor/): build/omxcore-src becomes a9a3c37's archive + the patch, and the
    package it builds is vendor's size within 0.1 % (builds of one commit differ by bytes, D-269)."""
    line = next(l for l in (ROOT / "vendor/OMXCORE_COMMIT").read_text().splitlines() if l.startswith("rebuild: "))[len("rebuild: "):]
    want = "cp build/omxcore-src/build/omxcore.mojoc vendor/"
    if not line.endswith(want):
        return f"the rebuild line doesn't end by copying the package into vendor/: {line[-120:]}"
    line = line[: -len(want)] + "cp build/omxcore-src/build/omxcore.mojoc build/g70/rebuilt.mojoc"
    r = run(["bash", "-c", "set -e; " + line.replace("<omxcore>", str(engine_repo()))], 3600)
    out = ROOT / "build/g70/rebuilt.mojoc"
    if r.returncode or not out.exists():
        return "rebuild line: " + (r.stdout + r.stderr)[-600:]
    vs, bs = (ROOT / "vendor/omxcore.mojoc").stat().st_size, out.stat().st_size
    return None if abs(vs - bs) <= bs * 0.001 else f"the rebuild line builds {bs:,} bytes, vendor/omxcore.mojoc is {vs:,}"


def patch_files():
    return re.findall(r"^diff --git a/(\S+) ", PATCH.read_text(), re.M)


def minimal_patch_conflicts():
    """The engine with only the patch's accelerator hunks (kernels_aot_gpu, pipeline_gpu, gpu.mojo) beside Flare:
    tests/test_engine_flare must fail with "conflicting signature" (why the libc hunks stay, D-7002)."""
    src = OUT / "omxcore-min"
    pkg = OUT / "eng-min/omxcore.mojoc"
    if not pkg.exists():
        parts = re.split(r"(?m)^(?=diff --git )", PATCH.read_text())
        keep = "".join(p for p in parts if re.match(r"diff --git a/(kernels_aot/kernels_aot_gpu|kernels_aot/pipeline_gpu|mojo/omxcore/gpu)\.mojo", p))
        (OUT / "min.patch").write_text(keep)
        cmd = (f"rm -rf {src} && mkdir -p {src} && git -C {engine_repo()} archive {COMMIT} mojo kernels_aot scripts/build_mojo_pkg.sh | tar -x -C {src} && "
               f"cd {src} && patch -p1 -s < {OUT / 'min.patch'} && sed -i 's/^build_one mxframe$//' scripts/build_mojo_pkg.sh && "
               f"pixi run --manifest-path {ROOT}/pixi.toml bash scripts/build_mojo_pkg.sh && mkdir -p {pkg.parent} && cp build/omxcore.mojoc {pkg}")
        r = run(["bash", "-c", cmd], 3600)
        if r.returncode:
            return False, "the accelerator-only engine didn't build: " + (r.stdout + r.stderr)[-400:]
    for sub in ("json", "flare"):
        if not (pkg.parent / sub).exists():
            (pkg.parent / sub).symlink_to(ROOT / "vendor" / sub)
    ok, why = test_one("test_engine_flare", str(pkg.parent), OUT / "min-bin")
    return (not ok and "conflicting signature" in why), why[-200:]


def mac_undefined(ex):
    """scripts/build.sh <ex> mac (cross-built objects): (linked, the objects' undefined symbols, the build's errors)."""
    r = run(["scripts/build.sh", ex, "mac"], 3600)
    objs = sorted(str(p.resolve()) for p in (ROOT / f"build/{ex}/mac").glob("*.o"))  # (absolute: llvm-nm runs from ROOT)
    if not any(o.endswith("/app.o") for o in objs):
        return False, None, "no Mac objects: " + (r.stdout + r.stderr)[-300:]
    u = run(["pixi", "run", "llvm-nm", "-u", "-j", *objs]).stdout.split()
    d = set(run(["pixi", "run", "llvm-nm", "-j", "--defined-only", *objs]).stdout.split())
    return r.returncode == 0, {x for x in u if x not in d and not x.endswith(":")}, ""


def mac_apps():
    """Every Mac app that uses the engine (platforms say mac, needs say omxcore: jobwake, jot, keeper, omxplorer),
    cross-built: its objects need no undefined symbol that main's (9e3e9d0f with 834ef9a, measured by goal 70:
    docs/goals/70/mac-undefined-main-<app>.json) didn't, and it links if main's did. Goal 5's ALLOWED list is behind
    main (D-792's pthread_attr_*, mojoui's setenv, fcntl, time: the Mac stub has them), so main is the reference. omxplorer's
    link fails on main since goal 68 (the CPython interop and mojoui.maxrt's symbols): its objects are compared, its link
    not (D-7004)."""
    probs, said = [], []
    for ex in ("jobwake", "jot", "keeper", "omxplorer"):
        linked, got, why = mac_undefined(ex)
        if got is None:
            probs.append(f"{ex}: {why}")
            continue
        main = set(json.loads((ROOT / f"docs/goals/70/mac-undefined-main-{ex}.json").read_text()))
        new = sorted(got - main)
        if new:
            probs.append(f"{ex}: new undefined symbols {new}")
        if ex != "omxplorer" and not linked:
            probs.append(f"{ex}: doesn't link")
        said.append(f"{ex} {len(got)} undefined, none new" + (", links" if linked else ", link fails as on main"))
    return (not probs), "; ".join(probs or said)


def m0():
    probs, said = [], []
    first = (ROOT / "vendor/OMXCORE_COMMIT").read_text()
    if not first.startswith(COMMIT) or "NOT on GitHub" not in first or PATCH.name not in first:
        probs.append("vendor/OMXCORE_COMMIT doesn't name a9a3c37, say it isn't on GitHub, or name the patch")
    why = rebuild_engine()
    if why:
        probs.append(why)
    else:
        said.append("vendor/OMXCORE_COMMIT's rebuild line rebuilds it")
    from engine_lineage import vendored_at_least

    why = vendored_at_least("834ef9a")
    if why or "a9a3c37" not in first.split("(")[0]:
        probs.append(f"lineage: {why}")
    else:
        said.append("vendor = a9a3c37's archive + the patch (engine_lineage)")
    report = (ROOT / "docs/goals/70-report.md").read_text() if (ROOT / "docs/goals/70-report.md").exists() else ""
    missing = [f for f in patch_files() if f not in report]
    if missing:
        probs.append(f"the report doesn't give a reason for {missing}")
    else:
        said.append(f"{len(patch_files())} patched files, each with its reason")
    ok, why = minimal_patch_conflicts()
    if not ok:
        probs.append("an engine without the libc hunks should clash with Flare: " + why)
    else:
        said.append("without the libc hunks: conflicting signature (they stay)")
    # every example whose needs say omxcore, for Linux
    exs = sorted(p.parent.name for p in (ROOT / "examples").glob("*/needs") if "omxcore" in p.read_text().split())

    def build(ex):
        r = run(["scripts/build.sh", ex, "linux"], 3600)
        return ex, r.returncode == 0, (r.stdout + r.stderr)[-300:]

    with ThreadPoolExecutor(3) as pool:
        built = list(pool.map(build, exs))
    bad = [f"{ex}: {why}" for ex, ok, why in built if not ok]
    probs += bad
    said.append(f"{len(exs) - len(bad)}/{len(exs)} omxcore examples build for Linux")
    ensure_bags()
    ensure_g39()
    with ThreadPoolExecutor(6) as pool:
        ran = list(pool.map(lambda t: (t, *test_one(t)), ENGINE_TESTS))
    bad = [f"{t}: {why[-200:]}" for t, ok, why in ran if not ok]
    probs += bad
    said.append(f"{len(ENGINE_TESTS) - len(bad)}/{len(ENGINE_TESTS)} engine tests pass")
    ok, why = mac_apps()
    (probs if not ok else said).append("Mac: " + why)
    return (not probs), ("; ".join(probs) if probs else "; ".join(said))


# ------------------------------------------------------------------------------------------------------------- M1


def m1():
    ensure_bags()
    ensure_g47()
    ensure_fleet68()
    r = run(["pixi", "run", "python", "-I", "docs/goals/70/bench_m1.py", "2"], 7200)
    (OUT / "m1.log").write_text(r.stdout + r.stderr)
    res = json.loads((OUT / "m1.json").read_text()) if (OUT / "m1.json").exists() else None
    if r.returncode or not res:
        return False, (r.stdout + r.stderr)[-600:]
    if res["differ"]:
        return False, f"answers differ: {res['differ'][:8]}"
    if res["errors"]:
        return False, f"refused (an error is no answer to compare): {res['errors'][:8]}"

    def summary(key):
        rows = [x for x in res["rows"] if x[key]]
        faster = sum(1 for x in rows if x[key] > 1.0)
        slower = [x for x in rows if x[key] < 1.0]
        big = [x for x in rows if x["main_ms"] >= 10]
        gm = 1.0
        for x in big:
            gm *= x[key]
        gm = gm ** (1 / len(big)) if big else 1.0
        return faster, slower, gm

    ef, es, egm = summary("engine_ratio")
    bf, bs, bgm = summary("branch_ratio")
    worst = sorted(bs, key=lambda x: x["branch_ratio"])[:3]
    return True, (f"{res['answers']} answers byte-equal on all three builds, no refusals; the engine alone: {ef} steps faster, {len(es)} slower, "
                  f"{egm:.2f}× over steps of 10 ms or more; the branch vs main: {bf} faster, {len(bs)} slower, {bgm:.2f}× "
                  f"(slowest: {', '.join(f'{x['step']} {x['branch_ratio']:.2f}×' for x in worst)}; docs/goals/70-bench.md)")


# ------------------------------------------------------------------------------------------------------------- M2


PATHS = ["asof", "asof_1m", "stops", "learn_reads", "similarity_all", "similarity_top10"]


def m2():
    """Every robotics path measured both ways with equal answers; the report says moved where the engine won and stays
    where it lost, and the code agrees (mojoui.fleet's as-of join and stops, Learn's reads, the similarity column)."""
    ensure_bags()
    exe = BIN / "bench_robotics"
    link = run(["bash", "-c", "source scripts/mxlink.sh; printf '%s\\n' \"${LINK[@]}\""]).stdout.split()
    b = run(["pixi", "run", "mojo", "build", "--disable-warnings", "-I", ".", "-I", "vendor", "tests/bench_robotics.mojo", "-o", str(exe), *link], 2400)
    if b.returncode:
        return False, "build: " + (b.stdout + b.stderr)[-600:]
    rob = OUT / "robotics"
    s = run(["pixi", "run", "python", "-I", "docs/goals/70/similarity.py", "write", str(rob), "100000"], 1800)
    r = run(["pixi", "run", str(exe), "build/bags", str(rob / "emb.parquet"), str(rob), "5"], 3600)
    c = run(["pixi", "run", "python", "-I", "docs/goals/70/similarity.py", "compare", str(rob)], 600)
    text = s.stdout + r.stdout + r.stderr + c.stdout + c.stderr
    (OUT / "m2.log").write_text(text)
    times = {}
    for path, way, ms in re.findall(r"^TIME (\S+) (\S+) median=(\S+)", text, re.M):
        times.setdefault(path, {})[way] = float(ms)
    same = dict(re.findall(r"^SAME (\S+) (yes|no)", text, re.M))
    probs = []
    for p in ["asof", "asof_1m", "stops", "learn_reads", "similarity"]:
        if same.get(p) != "yes":
            probs.append(f"{p}: answers {'differ' if p in same else 'not compared'}")
    report = (ROOT / "docs/goals/70-report.md").read_text() if (ROOT / "docs/goals/70-report.md").exists() else ""
    verdicts = []
    for p in PATHS:
        t = times.get(p, {})
        app = t.get("app", t.get("numpy_f32"))
        eng = t.get("engine")
        if app is None or eng is None:
            probs.append(f"{p}: not timed both ways ({t})")
            continue
        wins = eng < app
        verdicts.append(f"{p} app {app:.1f} / engine {eng:.1f} ms → {'moves' if wins else 'stays'}")
        m = re.search(rf"^\| {re.escape(p)} \|.*\| (moved|stays) \|", report, re.M)
        if not m or (m.group(1) == "moved") != wins:
            probs.append(f"{p}: the report's row doesn't say {'moved' if wins else 'stays'}")
    if "## Asks for omxcore" not in report:
        probs.append("the report has no '## Asks for omxcore'")
    # the code: a path that stays keeps the app's own code (mojoui.fleet's _asof and stop loop, learn's features_of, plugin_py.similar)
    fleet = (ROOT / "mojoui/fleet.mojo").read_text()
    if "def _asof(" not in fleet or "still % STOP_ROWS == 0" not in fleet:
        probs.append("mojoui.fleet's as-of join or stop loop changed")
    return (not probs), ("; ".join(probs) if probs else "; ".join(verdicts))


# ------------------------------------------------------------------------------------------------------------- M3


def m3():
    """Nothing regressed: goal 68's checker M0–M6 (its M6 runs goal 47 M0–M8, 59 M1–M2, 62 M1, the component matrix, the
    message ranges and the seek lint), then the decisions and libc lints."""
    probs, said = [], []
    r = run(["pixi", "run", "python", "docs/goals/68/regress.py", "68", *[f"M{i}" for i in range(7)]], 6 * 3600)
    (OUT / "m3-68.txt").write_text(r.stdout + r.stderr)
    res = dict(re.findall(r"^(M\d+): (PASS|FAIL|BLOCKED)", r.stdout, re.M))
    bad = {k: v for k, v in res.items() if v != "PASS"}
    if len(res) < 7 or bad:
        probs.append(f"goal 68: {res} " + " | ".join(l[:300] for l in r.stdout.splitlines() if re.match(r"^M\d+: (FAIL|BLOCKED)", l)))
    else:
        said.append("goal 68 M0–M6 PASS (with 47 M0–M8, 59 M1–M2, 62 M1, components, msgs, seek lint)")
    for name, cmd in (("decisions lint", ["pixi", "run", "python", "scripts/decisions_lint.py"]), ("libc lint", ["pixi", "run", "python", "scripts/libc_lint.py"]),
                      ("components", ["pixi", "run", "python", "scripts/components.py", "--check"])):
        x = run(cmd, 1800)
        if x.returncode:
            probs.append(f"{name}: " + (x.stdout + x.stderr)[-300:])
        else:
            said.append(f"{name} ok")
    return (not probs), ("; ".join(probs) if probs else "; ".join(said))


MILESTONES = {f"M{i}": f for i, f in enumerate([m0, m1, m2, m3])}

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
