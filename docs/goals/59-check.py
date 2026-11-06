"""Goal 59's proof: one command to set up, and your own model as a script function (GOAL.md). Prints "Mn: PASS|FAIL  why".

    pixi run python docs/goals/59-check.py [M0 M1 ...]      (default: every milestone)

M0 clones this branch (its last commit) into ~/scratch/omx-g59-fresh, with empty download caches, and runs scripts/setup
there as a newcomer would; the pixi package cache stays warm (GOAL.md's assumptions). The rest run in this worktree.
"""
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g59"
PACKS = ROOT / "build/packs"
DEMO = ROOT / "build/demo"
FRESH = Path.home() / "scratch/omx-g59-fresh"
APP = ROOT / "build/omxplorer/linux/omxplorer"
sys.path.insert(0, str(ROOT / "scripts"))


def run(cmd, timeout=3600, env=None, cwd=ROOT):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def clean_env(extra=None):
    """This environment without pixi's own variables (a nested pixi run in another checkout must find its own env)."""
    e = {k: v for k, v in os.environ.items() if not k.startswith(("CONDA", "PIXI", "PYTHON", "_CE_", "_CONDA"))}
    e.update(extra or {})
    return e


def setup_in(clone, env):
    t0 = time.time()
    r = subprocess.run(["scripts/setup"], cwd=clone, capture_output=True, text=True, timeout=7200, env=env)
    return r, time.time() - t0


def m0():
    probs = []
    head = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    if run(["git", "status", "--porcelain", "--untracked-files=no"]).stdout.strip():
        probs.append("(uncommitted changes here: the clone has the last commit only)")
    if FRESH.exists():
        shutil.rmtree(FRESH)  # (this check's own scratch clone, made by the last run)
    FRESH.mkdir(parents=True)
    clone = FRESH / "omxcode"
    r = run(["git", "clone", "-q", "--no-hardlinks", str(ROOT), str(clone)])
    if r.returncode:
        return False, "clone: " + r.stderr[-400:]
    run(["git", "checkout", "-q", head], cwd=clone)
    caches = {"OMX_CACHE": FRESH / "cache-omx", "HF_HOME": FRESH / "cache-hf", "TORCH_HOME": FRESH / "cache-torch"}
    for p in caches.values():
        p.mkdir()
    env = clean_env({k: str(v) for k, v in caches.items()})
    r, took = setup_in(clone, env)
    (OUT).mkdir(parents=True, exist_ok=True)
    (OUT / "m0-setup-1.txt").write_text(r.stdout + r.stderr)
    if r.returncode:
        return False, f"scripts/setup failed after {took:.0f} s: " + (r.stdout + r.stderr)[-1200:]
    steps = [l for l in r.stdout.splitlines() if re.match(r"^(env|build|data|e5small|yolox|scene)\s", l)]
    for s in ("env", "build", "data", "e5small", "yolox", "scene"):
        line = next((l for l in steps if l.startswith(s)), "")
        if not re.search(r"done \(\d+ s\)|skipped", line):
            probs.append(f"step {s}: {line or 'not printed'}")
    demo = clone / "build/demo"
    import csv
    rows = list(csv.DictReader(open(demo / "fleet.csv"))) if (demo / "fleet.csv").exists() else []
    clips = [r_ for r_ in rows if r_["clip"] and (demo / r_["clip"]).exists()]
    if len(clips) < 100:
        probs.append(f"{len(clips)} episodes with clips")
    for f in ("telemetry.parquet", "limits.csv", "ATTRIBUTION.txt", "truth.json", "paper/droid-paper.pdf"):
        if not (demo / f).exists():
            probs.append(f"no build/demo/{f}")
    for p in ("e5small/e5small.mef", "yolox/yolox.mef", "scene/scene.mef", "scene/model.json"):
        if not (clone / "build/packs" / p).exists():
            probs.append(f"no build/packs/{p}")
    for name, p in caches.items():
        if not any(p.rglob("*")) and name != "TORCH_HOME":
            probs.append(f"{name} stayed empty: something came from elsewhere")
    # the models scenario (goal 51), in the clone, over its own demo data and packs
    sc = subprocess.run(["pixi", "run", "python", "scripts/scenario.py", "models", "--media", "build/demo", "--out", "build/m0-models"],
                        cwd=clone, capture_output=True, text=True, timeout=3600, env=env)
    (OUT / "m0-models.txt").write_text(sc.stdout + sc.stderr)
    cards = {}
    try:
        cards = json.loads((clone / "build/m0-models/models.json").read_text())["cards"]
    except Exception:
        probs.append("models scenario: " + (sc.stdout + sc.stderr)[-500:])
    for c in ("table-classified", "table-apply-1"):
        rows_ = (cards.get(c) or {}).get("rows", 0)
        if not rows_:
            probs.append(f"models scenario: {c} has {rows_} rows")
    # a second run skips everything
    r2, took2 = setup_in(clone, env)
    (OUT / "m0-setup-2.txt").write_text(r2.stdout + r2.stderr)
    done2 = [l for l in r2.stdout.splitlines() if " done (" in l]
    if r2.returncode or done2 or took2 >= 60:
        probs.append(f"second run: exit {r2.returncode}, {took2:.0f} s, ran {done2}")
    # a broken environment: a package record emptied (what an install stopped midway leaves)
    recs = sorted((clone / ".pixi/envs/default/conda-meta").glob("*.json"))
    recs[len(recs) // 2].write_text("")
    r3, took3 = setup_in(clone, env)
    (OUT / "m0-setup-3.txt").write_text(r3.stdout + r3.stderr)
    if r3.returncode or not re.search(r"^env .*done", r3.stdout, re.M) or run(["pixi", "run", "true"], 300, cwd=clone).returncode:
        probs.append(f"broken env: exit {r3.returncode}: " + r3.stdout[-400:])
    first = {l.split()[0]: l for l in steps}
    times = ", ".join(f"{k} {re.search(r'\((\d+) s\)', v).group(1)} s" for k, v in first.items() if re.search(r"\((\d+) s\)", v))
    return (not probs), ("; ".join(probs)[:1200] if probs else
                         f"fresh clone, empty caches: setup in {took:.0f} s ({times}); {len(rows)} episodes, {len(clips)} with clips; "
                         f"models scenario: classified {cards['table-classified']['rows']} rows, detect {cards['table-apply-1']['rows']} boxes; "
                         f"second run {took2:.0f} s, all skipped; an emptied package record repaired in {took3:.0f} s")


def from_torch(model, out, *extra):
    return run(["pixi", "run", "python", "scripts/packs/from_torch.py", model, str(out), *extra], 3600)


def m1():
    probs, said = [], []
    if not (PACKS / "scene/check.json").exists():
        r = from_torch("torchvision:resnet18", PACKS / "scene", "--function", "scene")
        if r.returncode:
            return False, "resnet18: " + (r.stdout + r.stderr)[-800:]
    for name, path in [("resnet18", PACKS / "scene"), ("tiny", OUT / "tiny")]:
        if name == "tiny":
            shutil.rmtree(path, ignore_errors=True)
            r = from_torch("tests/fixtures/models/tiny_cnn.py:tiny", path, "--function", "tiny", "--size", "64")
            if r.returncode:
                probs.append("tiny: " + (r.stdout + r.stderr)[-600:])
                continue
        c = json.loads((path / "check.json").read_text())
        if c["same_top1"] != c["pictures"] or c["worst_logit"] > 0.05 or len(set(c["top1"])) < 2:
            probs.append(f"{name}: {c}")
        said.append(f"{name} {c['same_top1']}/{c['pictures']} top labels, logits (up to {c['largest_logit']:.2f}) within {c['worst_logit']:.2g}")
    r = from_torch("tests/fixtures/models/tiny_cnn.py:unsupported", OUT / "unsupported", "--function", "bad", "--size", "64")
    msg = (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else ""
    if r.returncode == 0 or "can't convert Upsample" not in msg:
        probs.append(f"unsupported: exit {r.returncode}, said {msg[:200]!r}")
    return (not probs), ("; ".join(probs)[:1200] if probs else "; ".join(said) + f"; an Upsample stops it: {msg[:90]}…")


def imagemodel_test(packs):
    exe = ROOT / "build/test_imagemodel"
    if not exe.exists() or any(p.stat().st_mtime > exe.stat().st_mtime for p in [ROOT / "tests/test_imagemodel.mojo", *ROOT.glob("mojoui/*.mojo")]):
        b = run(["scripts/mxbuild.sh", "tests/test_imagemodel.mojo", "-o", str(exe)], 1800)
        if b.returncode:
            raise RuntimeError("build: " + (b.stdout + b.stderr)[-800:])
    r = run([str(exe)], 900, {"OMX_PACKS": str(packs), "SCENE_VIDEO": str(DEMO / "clips/F00118.mp4")})
    return r.stdout + r.stderr


def m2():
    import numpy as np
    probs = []
    out = imagemodel_test(PACKS)
    (OUT).mkdir(parents=True, exist_ok=True)
    (OUT / "m2-with.txt").write_text(out)
    if not re.search(r"^PACKS:.* scene image-labels", out, re.M):
        probs.append("pack_functions didn't find scene")
    if not re.search(r"^FRAME_MODELS: detect scene$", out, re.M):
        probs.append("Apply's list: " + (re.search(r"^FRAME_MODELS:.*$", out, re.M) or [""])[0])
    refs = np.load(PACKS / "scene/work/refs.npz")["outputs"]
    pics = re.findall(r"^PICTURE (\S+): (\d+) (\S+) (\S+)", out, re.M)
    if len(pics) != len(refs):
        probs.append(f"{len(pics)} pictures read, {len(refs)} references")
    worst = 0.0
    for (name, k, logit, _), t in zip(pics, refs):
        if int(k) != int(np.argmax(t)):
            probs.append(f"{name}: label {k}, torch's {int(np.argmax(t))}")
        worst = max(worst, abs(float(logit) - float(t[int(k)])))
    if worst > 0.25:
        probs.append(f"top logits differ from torch's by up to {worst:.3f}")
    m = re.search(r"^SCENE: (\d+) rows label score frame t", out, re.M)
    if not m or int(m.group(1)) != 15:
        probs.append("scene(clip, 3, 4): " + (re.search(r"^SCENE.*$", out, re.M) or ["no SCENE line"])[0])
    per = re.findall(r"^PER_LABEL (.+) (\d+)$", out, re.M)
    if sum(int(n) for _, n in per) != 15:
        probs.append(f"per_label (the page's second line) counts {per}")
    if "HAS scene: True" not in out:
        probs.append("has(scene) False with the pack")
    # without the pack: the function is gone (the packs folder holds only classify's and detect's)
    bare = OUT / "packs-without-scene"
    shutil.rmtree(bare, ignore_errors=True)
    bare.mkdir(parents=True)
    for p in ("e5small", "yolox"):
        if (PACKS / p).exists():
            (bare / p).symlink_to(PACKS / p)
    out2 = imagemodel_test(bare)
    (OUT / "m2-without.txt").write_text(out2)
    if "HAS scene: False" not in out2 or not re.search(r"^FRAME_MODELS: detect$", out2, re.M):
        probs.append("without the pack: " + " | ".join(l for l in out2.splitlines() if l.startswith(("HAS", "FRAME"))))
    rows = re.findall(r"^ROW .*$", out, re.M)
    return (not probs), ("; ".join(probs)[:1200] if probs else
                         f"found from model.json alone; Apply offers detect, scene; {len(pics)} pictures with torch's top label (top logits within {worst:.3f}); "
                         f"scene(clip, 3, 4): 15 rows ({rows[0][4:] if rows else ''}); without the pack: no scene")


def gtk(steps, name, size=(1440, 900)):
    import headless
    headless.ensure()
    home = OUT / name
    for d in ("docs", "config"):
        (home / d).mkdir(parents=True, exist_ok=True)
    (home / "config/settings.txt").write_text("appearance=dark\n")
    shot = OUT / f"{name}.png"
    env = {"OMX_DOCUMENTS": str(home / "docs"), "OMX_CONFIG": str(home / "config"), "MOJOUI_TEST": steps, "MOJOUI_WINDOW": f"{size[0]}x{size[1]}",
           "MOJOUI_SHOT": str(shot), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": "50", "OMX_PACKS": str(PACKS)}
    r = run([str(APP)], 1800, env)
    out = r.stdout + r.stderr
    (OUT / f"{name}.log").write_text(out)
    return r.returncode, out, shot


def m3():
    if not APP.exists():
        b = run(["scripts/build.sh", "omxplorer", "linux"], 1800)
        if b.returncode:
            return False, "build: " + (b.stdout + b.stderr)[-600:]
    clip = DEMO / "clips/F00118.mp4"
    steps = ";".join([f"pick:Choose a file={DEMO / 'fleet.csv'}", "waitfor:Create table=60000", "tap:Create table", "wait:800",
                      "tap:Video", "wait:300", f"pick:Choose a video…={clip}", "wait:2500",
                      "tap:Script", "wait:600", "type:from s=3", "type:to s=8", "tap:apply-scene",
                      "waitfor:close-apply-1=300000", "tap:script-close", "wait:600", "tap:close-rows", "wait:1500"])
    code, out, shot = gtk(steps, "m3-scene")
    probs = []
    if code != 0 or "TEST: " in out:
        probs.append(f"exit {code}: " + " | ".join(l for l in out.splitlines() if "TEST" in l or "rror" in l)[-600:])
    scr = [l for l in out.splitlines() if l.startswith("SCRIPT:")]
    if not any("scene(" in l for l in scr):
        probs.append(f"no scene( call in the trace: {scr[-3:]}")
    if any("problem" in l for l in scr):
        probs.append(next(l for l in scr if "problem" in l))
    if not shot.exists():
        probs.append("no picture")
    else:
        shutil.copyfile(shot, ROOT / "docs/img/models-scene.png")
    return (not probs), ("; ".join(probs)[:1200] if probs else f"Apply scene on 3–8 s: {[l[:140] for l in scr if 'scene' in l][-1]}; picture {shot.name} (look at it)")


def m4():
    probs = []
    page = (ROOT / "docs/models.html").read_text() if (ROOT / "docs/models.html").exists() else ""
    if not page:
        return False, "no docs/models.html"
    import textwrap
    blocks = re.findall(r'<pre[^>]*\bdata-file="([^"]+)"[^>]*>(.*?)</pre>', page, re.S)
    if len(blocks) < 3:
        probs.append(f"{len(blocks)} code blocks tied to a file")
    for src, code in blocks:  # (scripts/tutorials.py's rule: a block is a run of the file's whole lines, give or take indent)
        want = textwrap.dedent(html.unescape(re.sub(r"<[^>]+>", "", code))).strip("\n").split("\n")
        have = (ROOT / src).read_text().split("\n") if (ROOT / src).exists() else []
        n = len(want)
        if not any(textwrap.dedent("\n".join(have[i:i + n])).split("\n") == want for i in range(len(have) - n + 1)):
            probs.append(f"{src}: the block isn't a run of its lines")
    for img in re.findall(r'<img[^>]+src="([^"]+)"', page):
        if not (ROOT / "docs" / img).exists():
            probs.append(f"no {img}")
    if "models-scene.png" not in page:
        probs.append("the M3 picture isn't on the page")
    for word in ("Linux", "NVIDIA", "Upsample"):
        if word not in page:
            probs.append(f"the limits don't say {word}")
    readme = (ROOT / "README.md").read_text()
    if "scripts/setup" not in readme.split("## Try it")[1].split("## ")[0]:
        probs.append("README's Try it doesn't run scripts/setup")
    for f in ("docs/start.html", "docs/learn/index.html", "docs/llms.txt"):
        if "models.html" not in (ROOT / f).read_text():
            probs.append(f"{f} doesn't link models.html")
    return (not probs), ("; ".join(probs)[:1200] if probs else f"{len(blocks)} code blocks, every line found in its file; the picture; limits; README, start, learn, llms.txt link it")


def m5():
    said, probs = [], []
    for check, ms in [("51", ["M2", "M3", "M4"]), ("54", ["M1"]), ("58", ["M0"])]:
        r = run([sys.executable, f"docs/goals/{check}-check.py", *ms], 5400)
        for m in ms:
            line = next((l for l in r.stdout.splitlines() if l.startswith(m + ":")), f"{m}: no line")
            (said if " PASS" in line else probs).append(f"goal {check} {line[:160]}")
    return (not probs), ("; ".join(probs)[:1500] if probs else "; ".join(s.split("  ")[0] for s in said))


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5}

if __name__ == "__main__":
    wanted = sys.argv[1:] or list(MILESTONES)
    bad = 0
    OUT.mkdir(parents=True, exist_ok=True)
    for k in wanted:
        try:
            ok, why = MILESTONES[k]()
        except Exception as e:  # a crashing proof is a failing proof
            ok, why = False, f"crashed: {e!r}"
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {why}", flush=True)
        bad += not ok
    sys.exit(1 if bad else 0)
