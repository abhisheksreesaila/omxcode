"""Goal 81, M9: nothing got slower or broke. Goal 80's held-out scenes against 2571778d (goal 80's own comparison, D-8030:
the card held awake, a scene a process, base and now alternated; results in docs/goals/81/held-ab.json); goal 80's
renderer tests and goal 81's; apps built for Linux, AppKit apps cross-built; the components matrix current. The held-out
part is a GPU run: docs/goals/81-check.py starts this only on a quiet machine.
Run: pixi run python tests/test_g81_regress.py [held] [tests] [builds]
"""
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = "2571778d"
TESTS = ["test_gpu2d", "test_gpu2d_gl", "test_gpu2d_waste", "test_gpu2d_clear", "test_gpu2d_shadow", "test_gpu2d_cull", "test_gpu2d_tiles", "test_cpu_reference", "test_cpu_threads",
         "test_keptpatch", "test_keptops", "test_scene", "test_objectlayer", "test_textfast", "test_diff_keep", "test_diff_random", "test_diff_long", "test_gpu2d_image", "test_hangmarks", "test_mojoui"]
PYTESTS = ["test_gtk_random", "test_gtk_lists", "test_gtk_input", "test_hang", "test_field_queue", "test_gaps_stall", "test_step_verbs", "test_agent_secret", "test_agent_widgets", "test_pnote_store"]
LINUX = ["pnote", "omxplorer", "keeper", "kitchen", "gallery", "expenses"]
MAC = ["kitchen", "gallery", "expenses"]


def run(cmd, timeout):
    try:
        return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timeout")


def held():
    spec = importlib.util.spec_from_file_location("g80", ROOT / "docs/goals/80-check.py")
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    g.BASE_REV = g.HELD_REV = BASE
    g.OUT = ROOT / "build" / "g81" / "held"
    g.OMX = g.OUT / "omxbench"
    g.DOCS = ROOT / "docs" / "goals" / "81"
    g.DOCS.mkdir(parents=True, exist_ok=True)
    base, now, err = g.held_ab()
    if err:
        print("  held-out:", err)
        return None
    worst, cells = 0.0, 0
    for s in g.HELD:
        for k in ("frame_med", "gpu_med"):
            r = now[s][k] / max(base[s][k], 1e-9)
            cells += 1
            worst = max(worst, r)
            print(f"  {s} {k}: {base[s][k]} -> {now[s][k]} ({r:.3f}x)")
    return worst, cells


def main():
    parts = sys.argv[1:] or ["held", "tests", "builds"]
    ok = True
    if "held" in parts:
        h = held()
        ok &= h is not None
        if h:
            print("FACT held_worst", round(h[0], 4))
            print("FACT held_cells", h[1])
    if "tests" in parts:
        failed = []
        for t in TESTS:
            r = run(["pixi", "run", "mojo", "run", "-I", ".", "-I", "vendor", f"tests/{t}.mojo"], 900)
            if r.returncode != 0:
                failed.append(t)
                print("  ", t, (r.stdout + r.stderr)[-200:].replace("\n", " "))
        for t in PYTESTS:
            r = run(["pixi", "run", "python", f"tests/{t}.py"], 1800)
            if r.returncode != 0:
                failed.append(t)
                print("  ", t, (r.stdout + r.stderr)[-300:].replace("\n", " "))
        print("FACT tests", len(TESTS) + len(PYTESTS))
        print("FACT tests_failed", len(failed))
        ok &= not failed
    if "builds" in parts:
        failed = []
        for what, apps in (("linux", LINUX), ("mac", MAC)):
            for a in apps:
                r = run(["scripts/build.sh", a, what], 1800)
                if r.returncode != 0:
                    failed.append(f"{a} {what}")
                    print("  ", a, what, (r.stdout + r.stderr)[-300:].replace("\n", " "))
        # each Linux app opens (headless) and ends by itself; the AppKit examples do on the Mac, unshown (or it can't be reached: said, not judged)
        sys.path.insert(0, str(ROOT / "scripts"))
        import headless
        headless.ensure()
        for a in LINUX:
            exe = ROOT / "build" / a / "linux" / a
            env = dict(os.environ, MOJOUI_TEST="pause:500", OMX_CONFIG=str(ROOT / "build" / "g81" / "config"), HOME=str(ROOT / "build" / "g81" / "home"))
            (ROOT / "build" / "g81" / "home").mkdir(parents=True, exist_ok=True)
            try:
                r = subprocess.run([str(exe)], cwd=ROOT, capture_output=True, text=True, timeout=120, env=env)
                bad = r.returncode != 0 or "CRITICAL" in r.stderr
                why = [x for x in (r.stdout + r.stderr).splitlines() if "CRITICAL" in x or "rror" in x][:2] or [f"exit {r.returncode}"]
            except Exception as x:
                bad, why = True, [str(x)[:200]]
            if bad:
                failed.append(f"{a} runs")
                print("  ", a, "run:", why)
        m = run(["scripts/mac81", "apps"], 900)
        if m.returncode == 75 or "UNREACHABLE" in m.stdout:
            print("   the Mac couldn't be reached: its apps weren't run")
        elif "mac_apps: ok" not in m.stdout:
            failed.append("mac apps")
            print("   mac apps:", m.stdout[-300:])
        else:
            print("   mac apps: 3 built and run")
        print("FACT builds", len(LINUX) * 2 + len(MAC) + 1)
        print("FACT builds_failed", len(failed))
        m = run(["pixi", "run", "python", "scripts/components.py", "--check"], 300)
        print("FACT matrix", 1 if m.returncode == 0 else 0)
        if m.returncode != 0:
            print("  matrix", (m.stdout + m.stderr)[-200:])
        ok &= not failed and m.returncode == 0
    print("g81_regress: ok" if ok else "g81_regress: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
