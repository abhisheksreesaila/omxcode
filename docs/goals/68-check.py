"""Goal 68's proof: add a model like magic, and open a robot fleet's bags (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/68-check.py [M0 M1 ...]          (default: every milestone)

Data: scripts/fetch_bags.py (r2b 2024 and NavWareSet slices, CC BY 4.0) into build/bags; models: the ones each milestone
names, from the Hugging Face Hub into $OMX_CACHE (else ~/.cache/omxcode). Outputs under build/g68.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g68"
BIN = OUT / "bin"
BAGS = ROOT / "build/bags"
sys.path.insert(0, str(ROOT / "scripts"))


def run(args, timeout=1800, env=None, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, env=dict(os.environ, **(env or {})), capture_output=True, text=True, timeout=timeout)


def mojo_build(src, exe, timeout=2400, env_name="default"):  # (env_name: where the program runs)
    exe = Path(exe)
    exe.parent.mkdir(parents=True, exist_ok=True)
    b = run(["scripts/mxbuild.sh", src, "-o", str(exe)], timeout)  # (-I vendor: omxcore; its codecs linked)
    return (b.returncode == 0 and exe.exists()), (b.stdout + b.stderr)[-1500:]


def mojo_test(src, labels, timeout=2400, env=None, env_name="default"):
    """Build and run a test program; every label must print "<label>: ok"."""
    exe = BIN / Path(src).stem
    ok, why = mojo_build(src, exe, timeout, env_name)
    if not ok:
        return False, why
    r = run(["pixi", "run", "-e", env_name, str(exe)], timeout, env)
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), (f"missing {missing} " if missing else "") + out[-900:]


def fetch_bags():
    r = run(["pixi", "run", "-e", "bagcheck", "python", "-I", "scripts/fetch_bags.py", str(BAGS)], 7200)
    if r.returncode != 0:
        raise RuntimeError("fetch_bags: " + (r.stdout + r.stderr)[-800:])
    return r.stdout.strip().splitlines()[-1]


def bag_dirs():
    return sorted(p for p in BAGS.iterdir() if p.is_dir() and any(f.suffix in (".mcap", ".db3") for f in p.iterdir()))


# ------------------------------------------------------------------------------------------------------------- M0


def m0():
    return None, "not built yet"


def build_app(platform="linux"):
    b = run(["scripts/build.sh", "omxplorer", platform], 2400)
    if b.returncode:
        raise RuntimeError(f"build omxplorer {platform}: " + (b.stdout + b.stderr)[-800:])


def twenty_labels():
    """The first rows a person scrolling would label: up to 7 of each kind, 20 in all, by truth.json's rule."""
    truth = json.loads((OUT / "learn/truth.json").read_text())
    have, lines = {}, []
    for i, t in enumerate(truth):
        if have.get(t, 0) < 7 and len(lines) < 20:
            have[t] = have.get(t, 0) + 1
            lines.append(f"{i + 1} {t}")
    return lines, truth


def m1():
    """Learn from my labels: the tree and the sheet glue (100k rows), then omxplorer on GTK (label, Learn, a changed
    label relearns) and the agent over MCP (label-rows, learn) on the web build."""
    from importlib import import_module

    sys.path.insert(0, str(ROOT / "docs/goals/68"))
    probs = []
    ok, why = mojo_test("tests/test_tree.mojo", ["tree-round", "tree-learn", "tree-words"], 1800)
    if not ok:
        return False, "test_tree: " + why
    ok, why = mojo_test("tests/test_learn.mojo", ["learn-add", "learn-fill", "learn-relearn", "learn-panel"], 1800)
    if not ok:
        return False, "test_learn: " + why
    relearn_ms = float(re.search(r"RELEARN_MS: ([\d.]+)", why).group(1))
    run(["pixi", "run", "python", "-I", "docs/goals/68/make_stops.py", str(OUT / "learn")])
    build_app("linux")
    lines, truth = twenty_labels()
    gtk = import_module("gtk").gtk
    shots = OUT / "shots"
    shots.mkdir(exist_ok=True)
    steps = [f"pick:Choose a file={OUT / 'learn/moments.csv'}", "waitfor:Create table=60000", "tap:Create table", "wait:1500", "tap:Learn from labels",
             "wait:500", f"shot:{shots / 'm1-1-empty.png'}", "enter:Label column, e.g. cause=cause", "wait:800",
             f"shot:{shots / 'm1-2-label-column.png'}", "enter:12 person ahead, 40 waiting=" + ", ".join(lines), "wait:600",
             f"shot:{shots / 'm1-3-labelled.png'}", "tap:learn", "wait:1500", f"shot:{shots / 'm1-4-learned.png'}",
             "tap:label-pick-2", "wait:1500", f"shot:{shots / 'm1-5-relearned.png'}"]
    code, out, shot = gtk(steps, "m1-learn", OUT)
    learns = re.findall(r"^LEARN: (.+) \| held (\d+)/(\d+) \| (\d+) rows \| (\d+) ms", out, re.M)
    bad_steps = [l for l in out.splitlines() if l.startswith("TEST:")]
    if code != 0 or bad_steps or len(learns) < 2:
        return False, f"GTK exit {code}, {len(learns)} learns, {bad_steps[:4]}"
    rule, right, tried, rows, ms = learns[0]
    if not ("speed <" in rule and "person_m" in rule) or int(tried) != 20 or int(right) < 15 or int(rows) != 100_000:
        probs.append(f"first learn: {learns[0]}")
    worst_ms = max(int(l[4]) for l in learns)
    if worst_ms >= 1000:
        probs.append(f"a learn took {worst_ms} ms")
    for k in range(1, 6):
        if not list(shots.glob(f"m1-{k}-*.png")):
            probs.append(f"no screenshot m1-{k}")
    # (the agent: the same over MCP on the web build)
    build_app("web")
    from agent_client import Client, open_through_picker

    c = Client(ROOT / "build/omxplorer/web")
    try:
        open_through_picker(c, OUT / "learn/moments.csv")
        for _ in range(60):
            if "create-table" in c.names():
                break
            time.sleep(0.5)
        c.call("create-table")
        c.call("learn-from-labels")
        c.call("label-name", text="cause", submit=True)
        c.call("label-rows", text=", ".join(lines), submit=True)
        said, _, err = c.call("learn")
        agent_rule = " | ".join(re.findall(r"learn-rule: (.+)", said))
        held = re.search(r"Right on (\d+) of (\d+)", said)
    finally:
        c.close()
    if err or "speed <" not in agent_rule or not held:
        probs.append(f"agent: {said[-400:]}")
    (OUT / "m1.json").write_text(json.dumps({"gtk": learns, "agent_rule": agent_rule, "relearn_ms_100k": relearn_ms}, indent=1))
    return (not probs), ("; ".join(probs) if probs else
                         f"GTK: 20 labels → \"{rule}\", right on {right}/{tried} held out, 100,000 rows filled in {ms} ms; a changed label relearned in "
                         f"{learns[-1][4]} ms (component: {relearn_ms:.0f} ms on 100k); agent over MCP: label-rows + learn → \"{agent_rule}\" "
                         f"({held.group(1)}/{held.group(2)}); shots build/g68/shots/m1-*.png")


def m2():
    return None, "not built yet"


# ------------------------------------------------------------------------------------------------------------- M3


def m3():
    """mojoui.bag: every fetched bag (3–6, MCAP and sqlite3), the first 1,000 messages per topic field for field against
    the official readers (mcap + mcap_ros2, and rosbags), a planted difference caught, camera topics as videos."""
    got = fetch_bags()
    total = sum(p.stat().st_size for p in BAGS.rglob("*") if p.is_file())
    attribution = (BAGS / "ATTRIBUTION.txt").read_text()
    if "CC BY 4.0" not in attribution or total > 2e9:
        return False, f"data {total / 1e9:.2f} GB, attribution {attribution[:80]!r}"
    ok, why = mojo_build("tests/bag_dump.mojo", BIN / "bag_dump")
    if not ok:
        return False, "bag_dump: " + why
    bags = bag_dirs()
    if not 3 <= len(bags) <= 6:
        return False, f"{len(bags)} bags"
    lines, bad, msgs, fields, formats, secs = [], 0, 0, 0, set(), 0.0
    for b in bags:
        dump = OUT / f"bag-{b.name}.jsonl"
        r = run([str(BIN / "bag_dump"), str(b), "-1", str(dump)], 600)
        m = re.search(r"BAG: (\w+) (\d+) topics (\d+) rows ([\d.e-]+) s", r.stdout)
        if r.returncode != 0 or not m:
            return False, f"{b.name}: " + (r.stdout + r.stderr)[-400:]
        formats.add(m.group(1))
        secs += float(m.group(4))
        ref = run(["pixi", "run", "-e", "bagcheck", "python", "-I", "docs/goals/68/bagref.py", str(b), str(dump), "1000"], 1800)
        (OUT / f"bagref-{b.name}.txt").write_text(ref.stdout + ref.stderr)
        s = re.search(r"BAGREF: (\d+) topics, (\d+) messages, (\d+) rows, (\d+) fields compared, (\d+) differences", ref.stdout)
        if not s:
            return False, f"{b.name}: reference " + (ref.stdout + ref.stderr)[-600:]
        bad += int(s.group(5))
        msgs += int(s.group(2))
        fields += int(s.group(4))
        lines.append(f"{b.name} {s.group(1)} topics {s.group(5)} diffs")
    # (the comparison must be able to fail: one value changed in a copy of a dump)
    first = OUT / f"bag-{bags[0].name}.jsonl"
    planted = OUT / "bag-planted.jsonl"
    text = first.read_text().splitlines()
    for i, line in enumerate(text):
        if line.startswith("[") and i > 1:
            row = json.loads(line)
            row[0] += 1
            text[i] = json.dumps(row)
            break
    planted.write_text("\n".join(text) + "\n")
    ref = run(["pixi", "run", "-e", "bagcheck", "python", "-I", "docs/goals/68/bagref.py", str(bags[0]), str(planted), "1000"], 1800)
    caught = re.search(r"(\d+) differences$", ref.stdout.strip())
    if not caught or int(caught.group(1)) < 1:
        return False, "a planted difference wasn't caught: " + ref.stdout[-300:]
    # (camera topics → videos: an H.264 one (r2b) and a JPEG one (NavWareSet), opened by mojoui.video)
    ok, why = mojo_test("tests/test_bag.mojo", ["bag-video-h264", "bag-video-jpeg", "bag-table", "bag-errors"], 1800)
    if not ok:
        return False, "test_bag: " + why
    good = bad == 0 and formats == {"mcap", "sqlite3"}
    return good, (f"{len(bags)} bags ({', '.join(sorted(formats))}, {total / 1e9:.2f} GB, CC BY 4.0), {msgs} messages, {fields} fields "
                  f"vs mcap+mcap_ros2 and rosbags: {bad} differences; a planted one caught; read in {secs:.1f} s; "
                  f"H.264 and JPEG cameras → videos ({'; '.join(lines)})")


def m4():
    return None, "not built yet"


def m5():
    return None, "not built yet"


def m6():
    return None, "not built yet"


MILESTONES = {f"M{i}": f for i, f in enumerate([m0, m1, m2, m3, m4, m5, m6])}

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
