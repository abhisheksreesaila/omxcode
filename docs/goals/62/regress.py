"""M6: nothing regressed. The robot story on GTK (goal 47's scenario: its M0–M3 over the full fleet), the web host's own
tests (tests/test_web_*.py), every goal check that drives web.py (found by grep: each milestone function whose body
drives the web host), and a fresh docs/components.md.

Archived checkers ignore milestone arguments and don't start the headless display (docs/lessons.md): each milestone runs
in its own process through docs/goals/62/milestone.py, which starts it first. A milestone that fails here is run again on
the base (origin/main 882155b, checked out in build/g62/base, sharing this checkout's pixi env).

Round 3 (the review: 38 of round 2's 55 SAME rows never ran on either side): the examples a milestone reads are built in
both trees first (PREBUILD), and a row counts SAME only when it ran on both sides and failed on both. A failure that names
a missing build, file or tool on either side is NOT RUN, which proves nothing. The rows the owner named (REQUIRED) must
run: PASS here, or SAME having run on both sides. Files under docs/ that the archived checks regenerate are put back.

    pixi run python docs/goals/62/regress.py [filter…]            # here, then the base for what fails
    pixi run python docs/goals/62/regress.py --base [filter…]     # the base only, cached (build/g62/m6/base.json)"""

import ast
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from harness import ROOT, G47

PY = sys.executable
BASE = "882155b"
WEB = re.compile(r"web_run\(|hosts/web\.py|drive\.web|web_story|scripts/drive\.py")
SKIP_GOALS = {"62"}  # (this goal)
# the examples each goal's milestones read, built (linux and web) in both trees before any of them runs: a later milestone
# reads what an earlier one built, and here each runs on its own
PREBUILD = {"03": ["hello", "todo", "gallery", "gpu"], "04": ["kitchen", "expenses"], "05": ["layout"], "06": ["lens"], "08": ["gallery"],
            "09": ["workbook", "analytics"], "10": ["workbook"], "11": ["mxstudio"], "12": ["mxstudio"], "13": ["mxstudio"],
            "14": ["mxstudio"]}
REQUIRED = {"03": None, "04": None, "05": None, "06": {"m6"}, "09": {"m3", "m4", "m8"}}  # (None: every web milestone of the goal)
# a failure that says something the milestone reads isn't there: it didn't run, so it proves nothing either way
NOT_RUN = re.compile(r"FileNotFoundError|No such file|cannot open input file|\bno /\S*build/|not built|ModuleNotFoundError|"
                     r"no Mac run|stale: no|ANDROID|emulator|adb\b|xcrun|Xcode")
OUT = ROOT / "build/g62/m6"


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


def prebuild(tree, goals, say):
    """The examples these goals read, built for linux and web in `tree` (once each; a failed build is said, and the
    milestones that read it will then say NOT RUN)."""
    done = set()
    for g in sorted(goals):
        for ex in PREBUILD.get(g, []):
            for plat in ("linux", "web"):
                if (ex, plat) in done or not (tree / "examples" / ex).exists():
                    continue
                done.add((ex, plat))
                t0 = time.time()
                r = subprocess.run(["scripts/build.sh", ex, plat], cwd=tree, capture_output=True, text=True, timeout=3600,
                                   env=dict(os.environ, CUDA_VISIBLE_DEVICES=""))
                if r.returncode:
                    say("BUILD-FAILED", f"{tree.name}: {ex} {plat}: " + ((r.stdout + r.stderr).strip().splitlines() or [""])[-1][:200])
                else:
                    print(f"built {ex} {plat} in {tree.name} ({time.time() - t0:.0f} s)", flush=True)


def required(check, fn):
    goal = check.name.split("-")[0]
    return goal in REQUIRED and (REQUIRED[goal] is None or fn in REQUIRED[goal])


def docs_state():
    """Tracked files under docs/ that differ from HEAD, and untracked ones: what a run can be told apart from."""
    r = subprocess.run(["git", "status", "--porcelain", "--untracked-files=all", "--", "docs"], cwd=ROOT, capture_output=True, text=True)
    return {l[3:] for l in r.stdout.splitlines() if l.strip()}


def put_back(before, say):
    """docs/lessons.md (round 3): a re-run that regenerates other goals' published results doesn't change them. What the
    run changed under docs/, outside this goal's files and docs/components.md, is copied to build/g62/m6/regenerated/
    and put back (tracked files from HEAD; new files moved out)."""
    keep = re.compile(r"^docs/(goals/62|components\.md$)")
    changed = sorted(p for p in docs_state() - before if not keep.match(p))
    for rel in changed:
        src = ROOT / rel
        if not src.exists():
            continue
        dst = OUT / "regenerated" / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        tracked = subprocess.run(["git", "ls-files", "--error-unmatch", rel], cwd=ROOT, capture_output=True).returncode == 0
        if tracked:
            shutil.copy2(src, dst)
            subprocess.run(["git", "checkout", "HEAD", "--", rel], cwd=ROOT, capture_output=True)
        else:
            shutil.move(str(src), str(dst))
    if changed:
        say("RESTORED", f"{len(changed)} files under docs/ the archived checks regenerated (copies in build/g62/m6/regenerated/): "
            + ", ".join(changed[:12]) + (" …" if len(changed) > 12 else ""))


def run_base(rows, say):
    """Runs rows on the base, cached in base.json (the base doesn't change: 882155b)."""
    cache_file = OUT / "base.json"
    cache = json.loads(cache_file.read_text()) if cache_file.exists() else {}
    base = base_tree()
    todo = [(c, f) for c, f in rows if f"{c.name}:{f}" not in cache]
    prebuild(base, {c.name.split("-")[0] for c, _ in todo}, say)
    for check, fn in todo:
        ok, why, took = run_milestone(base / check.relative_to(ROOT), fn, cwd=base)
        cache[f"{check.name}:{fn}"] = [ok, why, round(took)]
        cache_file.write_text(json.dumps(cache, indent=1))
        print(f"base {check.name}:{fn}: {'pass' if ok else 'fail'} ({took:.0f} s): {why[:160]}", flush=True)
    return cache


def run_all(only=None, base_only=False):
    OUT.mkdir(parents=True, exist_ok=True)
    lines = []

    def say(word, what):
        lines.append(f"{word} {what}")
        print(lines[-1], flush=True)
        (OUT / ("base-progress.txt" if base_only else "progress.txt")).write_text("\n".join(lines))

    before = docs_state()
    full = ROOT / "build/g47/full"  # (goal 47's check reads the fleet there: the other session's, read-only)
    if not full.exists():
        full.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(G47, full)
    todo = [(ROOT / "docs/goals/47-check.py", m) for m in ("m0", "m1", "m2", "m3")] + web_milestones()
    # (test_web_dev.py takes a debug and a release build as arguments: goal 34b's own milestones run it, among the web ones)
    tests = sorted(t for t in (ROOT / "tests").glob("test_web_*.py") if t.name != "test_web_dev.py")
    if only:
        todo = [t for t in todo if any(o in f"{t[0].name}:{t[1]}" for o in only)]
        tests = [t for t in tests if any(o in t.name for o in only)]
    if base_only:
        run_base(todo, say)
        put_back(before, say)
        return True, lines
    for ex in ("console", "jot"):  # (the web tests read these builds: made here when missing, as a check makes what it reads)
        if not (ROOT / f"build/{ex}/web").exists():
            subprocess.run(["scripts/build.sh", ex, "web"], cwd=ROOT, capture_output=True, text=True, timeout=1800)
    prebuild(ROOT, {c.name.split("-")[0] for c, _ in todo}, say)
    (OUT / "todo.json").write_text(json.dumps([f"{c.name}:{m}" for c, m in todo] + [t.name for t in tests], indent=1))
    for t in tests:
        r = subprocess.run([PY, str(t)], cwd=ROOT, capture_output=True, text=True, timeout=1800, env=dict(os.environ, CUDA_VISIBLE_DEVICES=""))
        ok = r.returncode == 0
        say("PASS" if ok else "FAIL", f"{t.name}: " + ((r.stdout + r.stderr).strip().splitlines() or [""])[-1][:200])
    failed = []
    for check, fn in todo:
        ok, why, took = run_milestone(check, fn)
        name = f"goal {check.name.split('-')[0]} {fn.upper()}" + (" (required)" if required(check, fn) else "")
        if ok:
            say("PASS", f"{name} ({took:.0f} s): {why[:160]}")
        else:
            failed.append((check, fn, name, why))
    cache = run_base([(c, f) for c, f, _, _ in failed], say) if failed else {}
    for check, fn, name, why in failed:
        bok, bwhy, _ = cache[f"{check.name}:{fn}"]
        if bok:
            say("FAIL", f"{name}: fails here, passes on {BASE}: {why[:300]}")
        elif NOT_RUN.search(why) or NOT_RUN.search(bwhy):
            say("NOT-RUN", f"{name}: something it reads isn't there (here or on {BASE}), so it proves nothing: here {why[:160]} | base {bwhy[:160]}")
        else:
            say("SAME", f"{name}: ran on both sides and fails on {BASE} too (not this goal's): here {why[:160]} | base {bwhy[:160]}")
    r = subprocess.run([PY, "scripts/components.py", "--check"], cwd=ROOT, capture_output=True, text=True, timeout=600)
    say("PASS" if r.returncode == 0 else "FAIL", "docs/components.md is fresh: " + ((r.stdout + r.stderr).strip().splitlines() or [""])[-1][:200])
    put_back(before, say)
    unproven = [l for l in lines if l.startswith("NOT-RUN") and "(required)" in l]
    for l in unproven:
        say("FAIL", "a required row didn't run: " + l[8:200])
    counts = {w: sum(1 for l in lines if l.startswith(w + " ")) for w in ("PASS", "SAME", "NOT-RUN", "FAIL")}
    say("SUMMARY", ", ".join(f"{n} {w}" for w, n in counts.items()))
    return not any(l.startswith("FAIL") for l in lines), lines


if __name__ == "__main__":
    args = sys.argv[1:]
    base_only = "--base" in args
    args = [a for a in args if a != "--base"]
    ok, lines = run_all(args or None, base_only)
    sys.exit(0 if ok else 1)
