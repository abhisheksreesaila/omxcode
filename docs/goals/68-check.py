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


PACKS = ROOT / "build/packs"
HUB_PLUGINS = OUT / "hub-plugins"


def hub_plugin(repo, folder_root):
    """A Hub model as a torch plugin folder (mojoui/plugin_py.py's preflight, download and write_plugin), once."""
    code = ("import importlib.util, json, os, sys, time\n"
            "spec = importlib.util.spec_from_file_location('pp', 'mojoui/plugin_py.py'); pp = importlib.util.module_from_spec(spec); spec.loader.exec_module(pp)\n"
            "root = os.path.abspath(sys.argv[2]); os.makedirs(root, exist_ok=True); repo = sys.argv[1]\n"
            "p = json.loads(pp.preflight(repo)); folder = os.path.join(root, pp.plugin_name(repo)); os.makedirs(folder, exist_ok=True)\n"
            "pp.download(repo, folder, json.dumps(p['files']), p['sha'], False, json.dumps(p['sizes']))\n"
            "while json.loads(pp.job('dl:' + folder))['state'] == 'running': time.sleep(0.5)\n"
            "j = json.loads(pp.job('dl:' + folder)); assert j['state'] == 'done', j\n"
            "print(pp.write_plugin(folder, json.dumps(p), False))\n")
    r = run(["pixi", "run", "-e", "models", "python", "-I", "-c", code, repo, str(folder_root)], 3600)
    if r.returncode:
        raise RuntimeError(f"{repo}: " + (r.stdout + r.stderr)[-600:])
    return r.stdout.strip().splitlines()[-1]


def ensure_packs():
    """The MAX packs as plugins (their builders write plugin.json): e5small, yolox (detect), scene."""
    for name, cmd in (("e5small", ["scripts/packs/e5small.py", str(PACKS / "e5small")]), ("yolox", ["scripts/packs/yolox.py", str(PACKS / "yolox")]),
                      ("scene", ["scripts/packs/from_torch.py", "torchvision:resnet18", str(PACKS / "scene"), "--function", "scene"])):
        if not (PACKS / name / "plugin.json").exists():
            r = run(["pixi", "run", "python", *cmd], 3600)
            if r.returncode:
                raise RuntimeError(f"pack {name}: " + (r.stdout + r.stderr)[-600:])


def m0():
    """One plugin format: decision files evaluated in Mojo match their libraries; plugin folders found at run time,
    unsafe ones refused; the MAX packs (YOLOX, e5, ResNet-18) and OWLv2 (torch) all run as plugin functions with no
    model named in mojoui/models.mojo; a plugin folder copied in after the build is a function."""
    probs = []
    r = run(["pixi", "run", "-e", "models", "python", "-I", "docs/goals/68/tree_fixtures.py", str(OUT / "trees")], 900)
    if r.returncode:
        return False, "tree fixtures: " + (r.stdout + r.stderr)[-500:]
    ok, why = mojo_test("tests/test_treefile.mojo", ["treefile-xgboost-lightgbm", "treefile-refuses"], 1800)
    if not ok:
        return False, "test_treefile: " + why
    worst = re.search(r"treefile-xgboost-lightgbm: ok (\S+)", why).group(1)
    run(["pixi", "run", "python", "-I", "docs/goals/68/make_plugins.py", str(OUT / "trees"), str(OUT / "plugins")])
    ok, why = mojo_test("tests/test_plugins.mojo", ["plugins-found", "plugins-tabular", "plugins-mismatch"], 1800, env_name="models")
    if not ok:
        return False, "test_plugins: " + why
    ensure_packs()
    owl = hub_plugin("google/owlv2-base-patch16-ensemble", HUB_PLUGINS) if not (HUB_PLUGINS / "owlv2_base_patch16_ensemble/plugin.json").exists() else "owlv2_base_patch16_ensemble"
    exe = BIN / "test_plugin_script"
    ok, why = mojo_build("tests/test_plugin_script.mojo", exe)
    if not ok:
        return False, "test_plugin_script: " + why
    late = OUT / "late-plugins"
    shutil.rmtree(late, ignore_errors=True)
    late.mkdir(parents=True)
    shutil.copytree(OUT / "plugins/stops_lgb", late / "late_stops")  # (after the build: found at run time)
    spec = json.loads((late / "late_stops/plugin.json").read_text())
    spec["name"] = "late_stops"
    (late / "late_stops/plugin.json").write_text(json.dumps(spec))
    videos = OUT / "videos/nav15_front.avi"
    if not videos.exists():
        return False, "no NavWareSet video (M3's test_bag writes it)"
    r = run(["pixi", "run", "-e", "models", str(exe)], 1800, {"OMX_PACKS": str(PACKS), "OMX_PLUGINS": f"{HUB_PLUGINS}:{late}", "SCRIPT_VIDEO": str(videos),
                                                        "MOMENTS": str(OUT / "learn/moments.csv"), "OWL": owl, "LATE": "late_stops"})
    out = r.stdout + r.stderr
    (OUT / "m0-script.txt").write_text(out)
    for label in ["plugin-detect", "plugin-scene", f"plugin-{owl}", "plugin-classify", "plugin-late-drop"]:
        if not re.search(rf"^{re.escape(label)}: ok", out, re.M):
            probs.append(f"{label} missing: " + out[-500:])
    # (no model named in the registry: its functions come from plugins; the classify default is a plugin's name)
    src = (ROOT / "mojoui/models.mojo").read_text()
    code = "\n".join(l.split("#")[0] for l in src.splitlines() if not l.lstrip().startswith("#"))
    named = [w for w in ("yolox", "resnet", "owl", "scene\"", "\"/yolox", "Detector(packs_dir", "CLASSIFY_PACK") if w in code]
    if named or 'MODEL_FUNCTIONS: List[String] = ["classify"]' not in src:
        probs.append(f"models.mojo still names models: {named}")
    rows = dict(re.findall(r"^  (\S+): (\d+) rows", out, re.M))
    return (not probs), ("; ".join(probs) if probs else
                         f"XGBoost JSON + LightGBM text in Mojo match their libraries (worst {worst}); ONNX + skops in process; 3 unsafe folders refused "
                         f"(a pickle, a ../ path, a link out: test_plugins checks each); mismatched columns said; as plugin functions: detect (YOLOX, MAX) {rows.get('detect')} boxes, scene (ResNet-18, MAX) "
                         f"{rows.get('scene')} frames, OWLv2 (torch, Hub) {rows.get(owl)} boxes, classify() via e5small; late_stops copied in after the build answered "
                         f"{rows.get('late_stops')} rows; models.mojo names no model")


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


M2_PLUGINS = OUT / "m2-plugins"
STOPWATCH = re.compile(r"^MODEL: (\S+) \((\S+), (\S+)\): paste→first answer ([\d.]+) s; after the download ([\d.]+) s(?: \(([\d.]+ [MG]B) downloaded in ([\d.]+) s\))?(?: \(nothing downloaded\))? · answer on (.+?): (.*)$", re.M)


def m2():
    """Add a model, like magic: 4 models of 4 kinds the app hasn't seen (a tree file, an image classifier, a detector,
    a text embedder), each answering where you're looking, timed; one that can't run and one with its own code say so
    before anything downloads; Run it on all fills a column or a table; the agent adds one with add-model."""
    sys.path.insert(0, str(ROOT / "docs/goals/68"))
    from gtk import gtk

    probs = []
    shutil.rmtree(M2_PLUGINS, ignore_errors=True)
    M2_PLUGINS.mkdir(parents=True)
    build_app("linux")
    build_app("web")  # (both first: nothing later rebuilds from a tree being edited)
    # (a decision model nobody has seen: XGBoost trained now on the moments' first 20,000 rows, saved as its JSON)
    r = run(["pixi", "run", "-e", "models", "python", "-I", "-c",
             "import xgboost as xgb, numpy as np, csv, json, sys\n"
             "rows=list(csv.DictReader(open(sys.argv[1]))); truth=json.load(open(sys.argv[2]))\n"
             "names=['speed','person_m','turn_rate']; cls=['moving','person ahead','waiting']\n"
             "X=np.array([[float(r[n]) for n in names] for r in rows[:20000]]); y=np.array([cls.index(t) for t in truth[:20000]])\n"
             "b=xgb.train({'objective':'multi:softprob','num_class':3,'max_depth':3}, xgb.DMatrix(X,label=y,feature_names=names), 20)\n"
             "b.set_attr(classes=','.join(cls)); b.save_model(sys.argv[3])\n",
             str(OUT / "learn/moments.csv"), str(OUT / "learn/truth.json"), str(OUT / "stops.xgb.json")], 600)
    if r.returncode:
        return False, "training the tree file: " + r.stderr[-400:]
    env = {"OMX_PLUGINS": str(M2_PLUGINS), "OMX_PACKS": str(PACKS)}
    field = "enter:Paste a model: owner/name, or its huggingface.co link="
    open_moments = [f"pick:Choose a file={OUT / 'learn/moments.csv'}", "waitfor:Create table=60000", "tap:Create table", "wait:1500"]
    video = [ "tap:Video", "wait:300", f"pick:Choose a video…={OUT / 'videos/nav15_front.avi'}", "wait:2500"]
    runs = {
        "m2-tree": open_moments + ["tap:Add a model", "grab:m2-0-empty", f"pick:File or folder…={OUT / 'stops.xgb.json'}", "wait:800", "grab:m2-tree-1-answer",
                                   "tap:run-all", "waitfor:show-result=60000", "grab:m2-tree-2-ran", "tap:show-result", "wait:800", "grab:m2-tree-3-column"],
        "m2-image": open_moments + video + ["tap:Add a model", "wait:300", field + "openai-community/gpt2", "waitfor:add-another=60000", "grab:m2-cant-run",
                                            field + "nomic-ai/nomic-embed-text-v1.5", "waitfor:allow-code=60000", "grab:m2-consent", "tap:add-cancel", "wait:300",
                                            field + "google/vit-base-patch16-224", "waitfor:add-it=60000", "grab:m2-image-1-line", "tap:add-it", "wait:1500",
                                            "grab:m2-image-2-downloading", "waitfor:run-all=1500000", "grab:m2-image-3-answer"],
        "m2-detect": open_moments + video + ["tap:Add a model", "wait:300", field + "hustvl/yolos-tiny", "waitfor:add-it=60000", "tap:add-it",
                                             "waitfor:run-all=1500000", "grab:m2-detect-1-answer", "tap:run-all", "wait:1500", "grab:m2-detect-2-running",
                                             "waitfor:show-result=900000", "grab:m2-detect-3-ran", "tap:show-result", "wait:800", "grab:m2-detect-4-table"],
    }
    timings = []
    for name, steps in runs.items():
        code, out, _ = gtk(steps, name, OUT, env=env, timeout=3600, pixi_env="models")
        bad = [l for l in out.splitlines() if l.startswith("TEST:")]
        if code != 0 or bad:
            probs.append(f"{name}: exit {code} {bad[:3]}")
        timings += STOPWATCH.findall(out)
        if name == "m2-image":
            if "Nothing downloaded" not in out or (M2_PLUGINS / "gpt2").exists() or (M2_PLUGINS / "nomic_embed_text_v1_5").exists():
                probs.append("gpt2 / nomic: something downloaded, or no reason said")
        if name == "m2-tree" and "MODEL: Filled stops" not in out:
            probs.append("the tree file's Run it on all didn't fill the column")
        if name == "m2-detect" and not re.search(r"MODEL: \d+ boxes in", out):
            probs.append("YOLOS's Run it on all made no table")
    # (the agent, on the web build in the models environment: open a table with text, add-model, add-it, the answer)
    from agent_client import Client, open_through_picker

    c = Client(ROOT / "build/omxplorer/web", env=env, python=ROOT / ".pixi/envs/models/bin/python")
    agent = ""
    try:
        open_through_picker(c, ROOT / "build/g47/full/fleet.csv")
        for _ in range(120):
            if "create-table" in c.names():
                break
            time.sleep(0.5)
        c.call("create-table")
        c.call("add-a-model")
        c.call("add-model", text="BAAI/bge-small-en-v1.5", submit=True)
        for _ in range(240):
            if "add-it" in c.names():
                break
            time.sleep(0.5)
        said = c.call("add-it")[0]  # (the agent host settles until the island's work lands: the download, loading, the answer)
        for _ in range(600):
            if "run-all" in c.names() or "add-another" in c.names():
                break
            time.sleep(1)
            said += c.call("screen")[0]
        agent = said
        m = re.search(r"Answered ([\d.]+) s after you asked: ([\d.]+) s downloading ([\d.]+ [MG]B), then ([\d.]+) s", said)
        if not m:
            probs.append("agent: no answer: " + said[-600:])
        else:
            ans = re.findall(r"add-answer: (.+)", said)
            timings.append(("bge_small_en_v1_5", "embed-text", "torch", m.group(1), m.group(4), m.group(3), m.group(2), "row 1 (task)", " | ".join(ans)[:200]))
        said = c.call("run-all")[0]
        for _ in range(600):
            if "show-result" in c.names():
                break
            time.sleep(1)
        said += c.call("screen")[0]
        (OUT / "m2-agent.txt").write_text(agent + "\n----\n" + said)
        if "like row 1" not in said:
            probs.append("agent: Run it on all didn't fill the similarity column: " + said[-300:])
    finally:
        c.close()
    (OUT / "m2-timings.json").write_text(json.dumps(timings, indent=1))
    kinds = {t[1] for t in timings}
    if kinds != {"tabular", "classify-image", "detect", "embed-text"}:
        probs.append(f"stopwatch for kinds {sorted(kinds)}")
    slow = [t[0] for t in timings if float(t[4]) >= 120]
    if slow:
        probs.append(f"over 2 minutes after the download: {slow}")
    table = "; ".join(f"{t[0]} ({t[1]}): paste→answer {t[3]} s, after download {t[4]} s" + (f" ({t[5]} in {t[6]} s)" if t[5] else "") for t in timings)
    return (not probs), ("; ".join(probs) if probs else table + "; gpt2 refused and nomic's own code asked for, nothing downloaded; Run it on all: a column "
                         "(tree), a table (YOLOS), a similarity column (BGE, by the agent)")


# ------------------------------------------------------------------------------------------------------------- M3


def m3():
    """mojoui.bag: every fetched bag (3–6, MCAP and sqlite3), the first 1,000 messages per topic field for field against
    the official readers (mcap + mcap_ros2, and rosbags), a planted difference caught, camera topics as videos."""
    got = fetch_bags()
    total = sum(p.stat().st_size for p in BAGS.rglob("*") if p.is_file() and "fleet" not in p.relative_to(BAGS).parts[:1])  # (the data, not M4's fleet/)
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
    """A fleet in one sheet: build/bags opened in omxplorer (GTK) as runs + moments (every topic joined on time) + stops,
    the hero run's cameras on the moments' cursor, a story.json with questions; then 20 stops labelled and Learn names
    the rest (component: by a stated rule; app: the same labels through label-rows)."""
    sys.path.insert(0, str(ROOT / "docs/goals/68"))
    from gtk import gtk

    probs = []
    fetch_bags()
    ok, why = mojo_test("tests/test_fleet.mojo", ["fleet-read", "fleet-story", "fleet-learn"], 1800)
    if not ok:
        return False, "test_fleet: " + why
    fleet = re.search(r"FLEET: (\d+) runs, (\d+) moments x (\d+) columns, (\d+) stop rows, read in ([\d.]+) ms", why)
    learnt = re.search(r"STOPS_LEARN: (\d+) of (\d+) unlabelled stops right; held out (\d+) of (\d+)", why)
    rule = re.search(r"STOPS_RULE: (.*)", why).group(1)
    build_app("linux")
    shutil.rmtree(BAGS / "fleet", ignore_errors=True)
    # (the app: open the folder; the story lands; a moment picked moves every camera; stops become the sheet; labels; Learn)
    rows = [l for l in (OUT / "fleet/stops.csv").read_text().splitlines()[1:]]
    import csv as _csv

    stops = list(_csv.DictReader((OUT / "fleet/stops.csv").open()))

    def cause(r):
        if r["person_m"] and float(r["person_m"]) < 1.5:
            return "person ahead"
        return "not started" if float(r["moved_m"] or 0) < 0.2 else "waiting"

    step = max(len(stops) // 20, 1)
    labels = ", ".join(f"{i + 1} {cause(stops[i])}" for i in range(0, len(stops), step)[:20])
    steps = ["tap:Start", "wait:500", "grab:m4-0-start", f"pick:Open robot bags…={BAGS}", "wait:400", "grab:m4-1-reading", "waitfor:question-1=600000",
             "wait:2500", "grab:m4-2-fleet", "tapat:table-moments=60,95", "wait:1500", "grab:m4-3-one-cursor", "tap:label-stops", "wait:1500",
             "grab:m4-4-stops-sheet", "enter:12 person ahead, 40 waiting=" + labels, "wait:800", "tap:learn", "wait:1500", "grab:m4-5-learned"]
    code, out, _ = gtk(steps, "m4-fleet", OUT, timeout=3600)
    bad = [l for l in out.splitlines() if l.startswith("TEST:")]
    if code != 0 or bad:
        probs.append(f"GTK exit {code} {bad[:4]}")
    read = re.search(r"FLEET: read (\d+) runs, (\d+) cameras in ([\d.]+) s", out)
    follows = [l for l in out.splitlines() if l.startswith("FOLLOW:") and ("seek" in l.lower() or " at " in l)]
    learn = re.search(r"^LEARN: (.+) \| held (\d+)/(\d+) \| (\d+) rows \| (\d+) ms", out, re.M)
    story = BAGS / "fleet/story.json"
    if not read or not story.exists():
        probs.append("the fleet wasn't read / no story.json: " + " | ".join(l for l in out.splitlines() if l.startswith(("FLEET", "STORY")))[-500:])
    else:
        sj = json.loads(story.read_text())
        if len(sj.get("questions", [])) < 3 or not sj.get("videos"):
            probs.append(f"story.json: {len(sj.get('questions', []))} questions, videos {sj.get('videos')}")
    cams = len(json.loads(story.read_text()).get("videos", [])) if story.exists() else 0
    if len(follows) < cams or cams == 0:
        probs.append(f"one cursor: {len(follows)} cameras followed the moment, {cams} cameras: " + " | ".join(l for l in out.splitlines() if l.startswith("FOLLOW"))[-400:])
    if not learn or "person_m" not in learn.group(1):
        probs.append("Learn on the stops: " + (learn.group(0) if learn else "no LEARN line"))
    return (not probs), ("; ".join(probs) if probs else
                         f"{fleet.group(1)} runs (MCAP + sqlite3), {fleet.group(2)} moments × {fleet.group(3)} columns (every topic joined at 10 Hz), {fleet.group(4)} stop rows, "
                         f"read in {float(fleet.group(5)) / 1000:.1f} s; story.json with {len(json.loads(story.read_text())['questions'])} questions; app: "
                         f"{read.group(2)} cameras made videos in {read.group(3)} s, a picked moment moved all {len(follows)} of the hero run's cameras; "
                         f"20 stops labelled → \"{learn.group(1)}\" ({learn.group(2)}/{learn.group(3)} held out); component: {learnt.group(1)}/{learnt.group(2)} of the "
                         f"unlabelled stops right (\"{rule}\")")


def _rects(text):
    """drive.py's RECTS lines → {tag: (x, y, w, h)} (the first of each tag)."""
    out = {}
    for m in re.finditer(r"^\S+ #(\S+) @ (-?\d+),(-?\d+) (\d+)x(\d+)", text, re.M):
        out.setdefault(m.group(1), tuple(int(v) for v in m.groups()[1:]))
    return out


def m5():
    """Polish: the four flows (learn, add a model, open bags, the fleet) in headless Chromium on the web host, a
    screenshot of every state (empty, loading, done, error), what's already on screen doesn't move when an answer
    arrives, and each flow by the agent over MCP."""
    import drive

    probs, shots = [], []
    build_app("web")
    web = ROOT / "build/omxplorer/web"
    S = OUT / "shots"
    S.mkdir(exist_ok=True)
    lines, _ = twenty_labels()
    moments = OUT / "learn/moments.csv"
    open_moments = f"pick:Choose a file={moments};wait:Create table;tap:Create table;wait:1500"
    env = {"OMX_PLUGINS": str(OUT / "m5-plugins"), "OMX_PACKS": str(PACKS)}
    shutil.rmtree(OUT / "m5-plugins", ignore_errors=True)

    def web_run(name, steps, rects=False, extra_env=None):
        r, out = drive.web_run(web, steps, shot=str(S / f"{name}.png"), viewport=(1440, 900), rects=str(OUT / f"{name}.rects") if rects else None,
                               env=dict(env, **(extra_env or {})))
        (OUT / f"{name}.web.txt").write_text(out)
        bad = [l for l in out.splitlines() if l.startswith(("TEST:", "PAGE ERRORS", "CONSOLE ERRORS")) or (l.startswith("CSP:") and not l.startswith("CSP: 0"))]
        if r.returncode or bad:
            probs.append(f"{name}: {bad[:3] or out[-300:]}")
        shots.append(name)
        return out, (_rects((OUT / f"{name}.rects").read_text()) if rects and (OUT / f"{name}.rects").exists() else {})

    # 1. Learn: empty, error (Learn with one kind of label), labelled (before), learned (after: nothing above moved)
    web_run("m5-learn-1-empty", f"{open_moments};tap:Learn from labels;wait:500")
    out, _ = web_run("m5-learn-2-error", f"{open_moments};tap:Learn from labels;enter:Label column, e.g. cause=cause;wait:500;"
                                          "enter:12 person ahead, 40 waiting=1 moving, 2 moving;tap:learn;wait:500")
    if "at least two different labels" not in out:
        probs.append("Learn with one kind of label didn't say what to do")
    base = f"{open_moments};tap:Learn from labels;enter:Label column, e.g. cause=cause;wait:500;enter:12 person ahead, 40 waiting=" + ", ".join(lines) + ";wait:500"
    _, before = web_run("m5-learn-3-labelled", base, rects=True)
    out, after = web_run("m5-learn-4-learned", base + ";tap:learn;wait:1500", rects=True)
    moved = [t for t in ("label-rows", "label-count", "learn") if t in before and t in after and before[t][:2] != after[t][:2]]
    if moved or "learn-rule" not in after:
        probs.append(f"Learn's answer moved {moved} (or no rule shown)")
    # 2. Add a model: empty, error (can't run, said before anything downloads), checking, the answer + run on all
    xgb = OUT / "stops.xgb.json"
    web_run("m5-add-1-empty", f"{open_moments};tap:Add a model;wait:500")
    out, _ = web_run("m5-add-2-error", f"{open_moments};tap:Add a model;enter:Paste a model: owner/name, or its huggingface.co link=openai-community/gpt2;wait:add-model-close;wait:4000")
    if "Nothing downloaded" not in out:
        probs.append("Add a model: a model that can't run didn't say why")
    _, before = web_run("m5-add-3-before", f"{open_moments};tap:Add a model;wait:500", rects=True)
    out, after = web_run("m5-add-4-answer", f"{open_moments};tap:Add a model;pick:File or folder…={xgb};wait:1500;tap:run-all;wait:1500", rects=True)
    moved = [t for t in ("add-model",) if t in before and t in after and before[t][:2] != after[t][:2]]
    if moved or "add-answer" not in after or "Filled" not in out:
        probs.append(f"Add a model's answer: moved {moved}, answer {'add-answer' in after}, filled {'Filled' in out}")
    # 3. Open bags (the fleet's story in the browser: OMX_STARTER) and 4. the fleet: label stops, Learn
    fleet = BAGS / "fleet"
    if not (fleet / "story.json").exists():
        probs.append("no fleet story (M4 writes build/bags/fleet)")
    else:
        story = {"OMX_STARTER": str(fleet)}
        web_run("m5-bags-1-start", "wait:1000", extra_env=story)
        out, _ = web_run("m5-bags-2-fleet", "tap:story-start;wait:question-1;wait:3000", extra_env=story)
        if "label-stops" not in out:
            probs.append("the fleet's story didn't offer Label and learn on the stops")
        out, _ = web_run("m5-fleet-1-stops", "tap:story-start;wait:question-1;wait:3000;tap:label-stops;wait:1500", extra_env=story)
        stops = list(__import__("csv").DictReader((fleet / "stops.csv").open()))
        cause = lambda r: "person ahead" if r["person_m"] and float(r["person_m"]) < 1.5 else ("not started" if float(r["moved_m"] or 0) < 0.2 else "waiting")  # noqa: E731
        step = max(len(stops) // 20, 1)
        labels = ", ".join(f"{i + 1} {cause(stops[i])}" for i in range(0, len(stops), step)[:20])
        out, _ = web_run("m5-fleet-2-learned", "tap:story-start;wait:question-1;wait:3000;tap:label-stops;wait:1500;"
                                               f"enter:12 person ahead, 40 waiting={labels};wait:600;tap:learn;wait:1500", extra_env=story)
        if "person_m" not in out:
            probs.append("the fleet's Learn didn't name person_m")
    # (the agent over MCP: open bags by path, label the stops, learn)
    from agent_client import Client

    c = Client(web, env=env)
    agent = ""
    try:
        c.call("open-bags", path=str(BAGS))
        said = ""
        for _ in range(600):
            said = c.call("screen")[0]
            if "label-stops" in said:
                break
            time.sleep(1)
        c.call("label-stops")
        c.call("label-rows", text=labels, submit=True)
        said = c.call("learn")[0]
        agent = " | ".join(re.findall(r"learn-rule: (.+)", said))
    finally:
        c.close()
    if "person_m" not in agent:
        probs.append("agent: open-bags → label-stops → learn: " + said[-400:])
    return (not probs), ("; ".join(probs) if probs else
                         f"{len(shots)} Chromium screenshots (build/g68/shots/m5-*.png): Learn empty/error/labelled/learned, Add a model empty/can't-run/"
                         f"answer + run on all, the fleet's start/open/stops/learned; what was on screen stayed put when answers arrived; the agent opened "
                         f"the bags by path, labelled 20 stops and Learn said \"{agent}\"")


def m6():
    """Nothing regressed: goal 47's check, goal 59's packs (M1, M2), goal 62's starter (M1), the component matrix, the
    message ranges and the seek lint (scripts/seek_lint.py)."""
    probs, said = [], []
    for goal, ms in (("47", [f"M{i}" for i in range(0, 9)]), ("59", ["M1", "M2"]), ("62", ["M1"])):
        r = run(["pixi", "run", "python", "docs/goals/68/regress.py", goal, *ms], 7200)
        (OUT / f"m6-{goal}.txt").write_text(r.stdout + r.stderr)
        res = dict(re.findall(r"^(M\d+): (PASS|FAIL|BLOCKED)", r.stdout, re.M))
        bad = {k: v for k, v in res.items() if v != "PASS"}
        if len(res) < len(ms) or bad:
            probs.append(f"goal {goal}: {res} " + " | ".join(l for l in r.stdout.splitlines() if re.match(r"^M\d+: (FAIL|BLOCKED)", l))[:600])
        said.append(f"goal {goal} {'/'.join(ms) if len(ms) < 4 else 'M0–M8'} PASS" if not bad and len(res) == len(ms) else f"goal {goal} {res}")
    for name, cmd in (("components", ["pixi", "run", "python", "scripts/components.py", "--check"]), ("msgs", ["pixi", "run", "python", "scripts/msgs.py"]),
                      ("seek lint", ["pixi", "run", "python", "scripts/seek_lint.py"])):
        r = run(cmd, 1800)
        if r.returncode:
            probs.append(f"{name}: " + (r.stdout + r.stderr)[-400:])
        said.append(f"{name} ok" if not r.returncode else f"{name} FAIL")
    return (not probs), ("; ".join(probs) if probs else "; ".join(said))


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
