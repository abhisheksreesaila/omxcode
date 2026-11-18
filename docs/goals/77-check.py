"""Goal 77's proof: omx shows and points (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/77-check.py [M6 ...]

This file holds M6, the camera (the pointer, word, map, iso, visual-first and polish milestones are the other threads' and are
added to it when the branches merge). The models run on GPU $G77_GPU (default 1, PCI order as nvidia-smi counts: another
thread's model sits on GPU 0). M6 builds the shim with image input, draws (once) the scene's objects with the image model,
runs the model's own tests (tests/test_llm_vision: reading words and grounding with the real Qwen3.8-27B and its projector),
the camera's (tests/test_camera: the browser's hub, and this machine's webcam when there is one), genui's Sight component,
and then the whole app: scripts/g77_camera_check.py drives examples/omx on the web host with Chromium's fake camera.
Numbers: build/g77/m6.json, pictures: docs/goals/77/.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g77"
GPU = os.environ.get("G77_GPU", "1")
ENV = {"CUDA_DEVICE_ORDER": "PCI_BUS_ID", "LLM_GPU": GPU}


def sh(cmd, timeout=3600, env=None, **kw):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=ROOT, env=e, capture_output=True, text=True, timeout=timeout, **kw)


def tail(r, n=700):
    return (r.stdout + r.stderr)[-n:]


def free_mib(index):
    out = sh(["nvidia-smi", "--query-gpu=index,memory.free", "--format=csv,noheader,nounits"]).stdout.splitlines()
    for line in out:
        i, _, free = line.partition(",")
        if i.strip() == str(index):
            return int(free)
    return 0


def m6():
    need_mib = 21000
    if free_mib(GPU) < need_mib:
        return "BLOCKED", f"GPU {GPU} has {free_mib(GPU)} MiB free; the 27B model, its projector and the voice need {need_mib}"
    for step in (["scripts/build_llm_shim.sh"], ["pixi", "run", "python", "scripts/g77_scene.py"]):
        r = sh(step)
        if r.returncode:
            return "FAIL", f"{' '.join(step)}: {tail(r)}"
    numbers = {}
    # the framework's own tests
    for name, extra in (("test_grounding", {}), ("test_camera", {}), ("test_llm_vision", ENV), ("test_genui", {})):
        b = sh(["scripts/mxbuild.sh", f"tests/{name}.mojo", "-o", f"build/{name}"])
        if b.returncode:
            return "FAIL", f"{name} doesn't build: {tail(b, 900)}"
        r = sh([f"build/{name}"], env=extra, timeout=1800)
        if r.returncode:
            return "FAIL", f"{name}: {tail(r, 900)}"
        numbers[name] = [l for l in r.stdout.splitlines() if re.match(r"(vision|camera|grounding|sight|picture)\b", l)]
    desk = [l for l in numbers["test_camera"] if l.startswith("camera desktop")]
    desk_note = "" if desk and ": ok" in desk[0] else " (the desktop camera: BLOCKED, " + (desk[0] if desk else "no camera on this machine") + ")"
    # the whole app, on the web host
    b = sh(["scripts/build.sh", "omx", "web"], 3600)
    if b.returncode:
        return "FAIL", "build omx web: " + tail(b, 900)
    r = sh(["pixi", "run", "python", "scripts/g77_camera_check.py", "all"], 3600, ENV)
    if r.returncode or "camera: all ok" not in r.stdout:
        return "FAIL", tail(r, 1200)
    rep = json.loads((OUT / "camera.json").read_text())
    s, t = rep["scene"], rep["text"]
    vision = " ".join(numbers["test_llm_vision"])
    m = re.search(r"worst IoU ([\d.]+) , mean answer time ([\d.]+) ms, mean image encode ([\d.]+) ms", vision)
    (OUT / "m6.json").write_text(json.dumps({"camera": rep, "tests": numbers}, indent=1))
    return "PASS", (f"\"Where is the banana?\" through the tablet's fake camera: the card's banana box IoU {s['iou']} (limit 0.4) with the truth, "
                    f"the reply \"{s['reply']}\", the part on the banana at {s['spot_pts'][0]:.0f},{s['spot_pts'][1]:.0f} pt; look {s['ms']} ms "
                    f"(frame {s['frame_ms']}, image encode {s['image_ms']} for {s['image_tokens']} tokens, model {s['read_ms']}); "
                    f"{s['outward_bytes_sent']} bytes outward; the sign read \"{t['reply']}\"; in-process grounding on all three objects "
                    f"(worst IoU {float(m.group(1)):.2f}, {float(m.group(2)):.0f} ms an answer); docs/goals/77/m6-camera-banana.png" + desk_note)


MILESTONES = {"M6": m6}


def main():
    want = [a.upper() for a in sys.argv[1:]] or list(MILESTONES)
    bad = 0
    for k in want:
        t0 = time.time()
        try:
            state, why = MILESTONES[k]()
        except Exception as e:  # shown, never swallowed
            state, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"{k}: {state}  {why}  ({time.time() - t0:.0f} s)", flush=True)
        bad += state == "FAIL"
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
