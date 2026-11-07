"""M6: nothing regressed. The robot story on GTK (goal 47's scenario: its M0–M3 over the full fleet), the web host's own
tests (tests/test_web_*.py), every goal check that drives web.py (found by grep: each milestone function whose body
drives the web host), and a fresh docs/components.md.

Archived checkers ignore milestone arguments and don't start the headless display (docs/lessons.md): each milestone runs
in its own process through docs/goals/62/milestone.py, which starts it first. A milestone that fails here is run again on
the base (origin/main 882155b, checked out in build/g62/base, sharing this checkout's pixi env): failing there too, it
isn't a regression (printed SAME, with both reasons); passing there, it is (FAIL)."""

import ast
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from harness import ROOT, G47

PY = sys.executable
BASE = "882155b"
WEB = re.compile(r"web_run\(|hosts/web\.py|drive\.web|web_story|scripts/drive\.py")
SKIP_GOALS = {"62"}  # (this goal)


def web_milestones():
    """(check file, milestone function) for every milestone function that drives the web host, by grep over its source."""
    out = []
    for f in sorted((ROOT / "docs/goals").glob("*-check.py")):
        goal = f.name.split("-")[0]
        if goal in SKIP_GOALS:
            continue
        src = f.read_text()
        if not WEB.search(src):
            continue
        try:
            tree = ast.parse(src)
        except SyntaxError:
            continue
        funcs = {n.name: ast.get_source_segment(src, n) or "" for n in tree.body if isinstance(n, ast.FunctionDef)}
        helpers = {k for k, body in funcs.items() if WEB.search(body)}
        for _ in range(3):  # (a milestone may drive the web through a helper of the file's own)
            helpers |= {k for k, body in funcs.items() if any(re.search(rf"\b{h}\(", body) for h in helpers)}
        for name in funcs:
            if re.fullmatch(r"m\d+[a-z]?", name) and name in helpers:
                out.append((f, name))
    return out


def run_milestone(check, fn, cwd=ROOT, timeout=3600):
    t0 = time.time()
    try:
        r = subprocess.run([PY, str(ROOT / "docs/goals/62/milestone.py"), str(check), fn], cwd=cwd, capture_output=True, text=True,
                           timeout=timeout, env=dict(os.environ, CUDA_VISIBLE_DEVICES=os.environ.get("CUDA_VISIBLE_DEVICES", "")))
        line = next((l for l in reversed(r.stdout.splitlines()) if l.startswith("RESULT\t")), None)
        ok, why = json.loads(line.split("\t", 1)[1]) if line else (False, "no result: " + (r.stdout + r.stderr)[-500:])
    except subprocess.TimeoutExpired:
        ok, why = False, f"timed out after {timeout} s"
    return ok, str(why), time.time() - t0


def base_tree():
    """origin/main's goal 59 commit, checked out in build/g62/base (once), using this checkout's pixi env."""
    base = ROOT / "build/g62/base"
    if not (base / ".git").exists():
        subprocess.run(["git", "worktree", "add", "--detach", str(base), BASE], cwd=ROOT, capture_output=True, text=True)
    if not (base / ".pixi").exists():
        os.symlink(ROOT / ".pixi", base / ".pixi")
    for sub in ("build/g47",):
        (base / sub).mkdir(parents=True, exist_ok=True)
    full = base / "build/g47/full"
    if not full.exists():
        os.symlink(G47, full)
    return base


def run_all(out, only=None):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    lines = []

    def say(word, what):
        lines.append(f"{word} {what}")
        print(lines[-1], flush=True)
        (out / "progress.txt").write_text("\n".join(lines))

    full = ROOT / "build/g47/full"  # (goal 47's check reads the fleet there: the other session's, read-only)
    if not full.exists():
        full.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(G47, full)
    todo = [(ROOT / "docs/goals/47-check.py", m) for m in ("m0", "m1", "m2", "m3")] + web_milestones()
    # (test_web_dev.py takes a debug and a release build as arguments: goal 34b's own milestones run it, among the web ones)
    tests = sorted(t for t in (ROOT / "tests").glob("test_web_*.py") if t.name != "test_web_dev.py")
    for ex in ("console", "jot"):  # (the web tests read these builds: made here when missing, as a check makes what it reads)
        if not (ROOT / f"build/{ex}/web").exists():
            subprocess.run(["scripts/build.sh", ex, "web"], cwd=ROOT, capture_output=True, text=True, timeout=1800)
    if only:
        todo = [t for t in todo if any(o in f"{t[0].name}:{t[1]}" for o in only)]
        tests = [t for t in tests if any(o in t.name for o in only)]
    (out / "todo.json").write_text(json.dumps([f"{c.name}:{m}" for c, m in todo] + [t.name for t in tests], indent=1))
    for t in tests:
        r = subprocess.run([PY, str(t)], cwd=ROOT, capture_output=True, text=True, timeout=1800, env=dict(os.environ, CUDA_VISIBLE_DEVICES=""))
        ok = r.returncode == 0
        say("PASS" if ok else "FAIL", f"{t.name}: " + ((r.stdout + r.stderr).strip().splitlines() or [""])[-1][:200])
    for check, fn in todo:
        ok, why, took = run_milestone(check, fn)
        name = f"goal {check.name.split('-')[0]} {fn.upper()}"
        if ok:
            say("PASS", f"{name} ({took:.0f} s): {why[:160]}")
            continue
        bok, bwhy, _ = run_milestone(base_tree() / check.relative_to(ROOT), fn, cwd=base_tree())
        if bok:
            say("FAIL", f"{name}: fails here, passes on {BASE}: {why[:300]}")
        else:
            say("SAME", f"{name}: fails on {BASE} too (not this goal's): here {why[:160]} | base {bwhy[:160]}")
    r = subprocess.run([PY, "scripts/components.py", "--check"], cwd=ROOT, capture_output=True, text=True, timeout=600)
    say("PASS" if r.returncode == 0 else "FAIL", "docs/components.md is fresh: " + ((r.stdout + r.stderr).strip().splitlines() or [""])[-1][:200])
    return not any(l.startswith("FAIL") for l in lines), lines


if __name__ == "__main__":
    ok, lines = run_all(ROOT / "build/g62/m6", sys.argv[1:] or None)
    sys.exit(0 if ok else 1)
