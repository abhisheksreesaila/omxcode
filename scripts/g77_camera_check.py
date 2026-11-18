"""Goal 77 M6, the camera, through the whole app: examples/omx on the web host, a headless Chromium as the tablet whose camera is
a file (--use-file-for-fake-video-capture: the scenes of scripts/g77_scene.py), the person typing a question.

    pixi run python scripts/g77_camera_check.py [scene|text|all]        (needs build/omx/web: scripts/build.sh omx web)

Proves, for the scene (a mug, a banana and a bottle at known places):
  - "Where is the banana?": the app calls `look`, the page's camera gives a still, the model reads it in this process, the card's
    box for the banana overlaps the truth (IoU >= 0.4), the card's part "banana" (App.spot, the pointer's way in) is on the
    banana, and the spoken reply names it;
  - the frame never leaves the machine: during the turn the host process opens no connection to anything but loopback and
    sends fewer bytes outward than a tenth of the frame's size, and the page makes no request to another origin;
and for a picture of words ("What does the sign say?"): PURPLE OTTER 42 read through the same path.
Numbers go to build/g77/camera.json, the pictures to docs/goals/77/.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/g77"
SHOTS = ROOT / "docs/goals/77"
MODULE = ROOT / "build/omx/web"
CHROMIUM = "/usr/bin/chromium"
GPU = os.environ.get("G77_GPU", "1")
MODELS = os.environ.get("OMX_MODELS") or str(Path.home() / "Projects/omx-local/models")
IOU_MIN = 0.4


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(fn, seconds, what, every=0.1):
    end = time.time() + seconds
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(every)
    raise AssertionError("timed out waiting for " + what)


def iou(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return 0.0
    inter = w * h
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)


def silence(path, seconds=8):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\0\0" * 16000 * seconds)


def lines(log_path, kind):
    """The OMX <kind> lines the host printed (the text after the colon)."""
    text = Path(log_path).read_text(errors="replace") if Path(log_path).exists() else ""
    return [m.group(1) for m in re.finditer(rf"^OMX {kind}: (.*)$", text, re.M)]


def parse_look(line):
    head, _, text = line.partition(" text=")
    kv = dict(re.findall(r"(\w+)=(\S+)", head))
    kv["text"] = text
    kv["boxes"] = {}
    for item in kv.get("where", "").split("|"):
        if ":" in item:
            label, nums = item.split(":")
            kv["boxes"][label.replace("_", " ")] = [int(n) for n in nums.split(",")]
    kv["labels"] = ", ".join(kv["boxes"])
    return kv


class Host:
    """examples/omx on the web host in the voice environment, on GPU $G77_GPU (PCI order, as nvidia-smi counts), loopback only."""

    def __init__(self, tag):
        self.port = free_port()
        self.log = OUT / f"camera-{tag}-host.log"
        env = dict(os.environ, CUDA_DEVICE_ORDER="PCI_BUS_ID", CUDA_VISIBLE_DEVICES=GPU, OMX_LLM_GPU="0", OMX_LLM_CTX="32768", OMX_MODELS=MODELS,
                   OMX_SD="0", OMX_TRACE="1", MOJOUI_PAIR_KEY_FILE=str(Path(tempfile.mkdtemp(prefix="g77key-")) / "k"))
        env.pop("MOJOUI_PUBLIC", None)
        self.proc = subprocess.Popen(["pixi", "run", "-e", "voice", "python", str(ROOT / "mojoui/hosts/web.py"), str(MODULE), str(self.port)],
                                     cwd=ROOT, env=env, stdout=open(self.log, "w"), stderr=subprocess.STDOUT)
        wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", self.port)) == 0, 180, "the web host", 0.5)

    def pids(self):
        kids = subprocess.run(["pgrep", "-P", str(self.proc.pid)], capture_output=True, text=True).stdout.split()
        return {self.proc.pid} | {int(p) for p in kids}

    def outward(self):
        """{(local, peer): bytes sent} of this host's established TCP connections to anything but this machine's loopback."""
        out = subprocess.run(["ss", "-tniH", "state", "established"], capture_output=True, text=True).stdout.splitlines()
        pids, found, current = self.pids(), {}, None
        for line in out:
            if not line.startswith((" ", "\t")):
                cols = line.split()
                m = re.search(r"pid=(\d+)", line)
                loop = len(cols) > 3 and cols[3].startswith(("127.", "[::1]", "[::ffff:127."))
                current = (cols[2], cols[3]) if m and int(m.group(1)) in pids and not loop and len(cols) > 3 else None
            elif current is not None:
                m = re.search(r"bytes_sent:(\d+)", line)
                found[current] = int(m.group(1)) if m else 0
        return found

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(30)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def tablet(host, video, shot, question, spot_name=None):
    """One page as the tablet (camera = `video`) and one typed question; what the host printed and the page showed."""
    quiet = Path(tempfile.mkdtemp(prefix="g77sil-")) / "silence.wav"
    silence(quiet)
    flags = ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", f"--use-file-for-fake-video-capture={video}",
             f"--use-file-for-fake-audio-capture={quiet}", "--autoplay-policy=no-user-gesture-required", "--no-sandbox"]
    foreign, result = [], {}
    first_look = len(lines(host.log, "LOOK"))
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=CHROMIUM, headless=True, args=flags)
        ctx = browser.new_context(viewport={"width": 820, "height": 1180}, permissions=["camera", "microphone"])
        page = ctx.new_page()
        origin = f"http://127.0.0.1:{host.port}"
        local = (origin, origin.replace("http", "ws"), "data:", "blob:")
        page.on("request", lambda r: foreign.append(r.url) if not r.url.startswith(local) else None)
        page.goto(origin + "/", timeout=240000)
        page.mouse.click(10, 10)  # the tap that makes this page the one the app listens and looks through
        try:
            page.wait_for_function("() => document.body.innerText.includes('Listening')", timeout=240000)
        except Exception:
            raise AssertionError("the app never said Listening; the page says: " + page.evaluate("() => document.body.innerText")[:300] + " | host log: " + Path(host.log).read_text()[-500:])
        page.wait_for_timeout(1500)
        page.get_by_role("button", name="Type").click()
        page.wait_for_timeout(500)
        before = host.outward()
        box = page.get_by_placeholder("Type to omx")
        box.fill(question)
        t0 = time.time()
        box.press("Enter")
        seen = {}

        def done():
            for k, v in host.outward().items():
                seen[k] = max(v, seen.get(k, 0))
            return len(lines(host.log, "LOOK")) > first_look and lines(host.log, "REPLY")

        wait_for(done, 240, "the answer to the question", 0.2)
        page.wait_for_timeout(1500)
        result["turn_s"] = round(time.time() - t0, 1)
        SHOTS.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(SHOTS / shot))
        canvases = page.locator("[data-kind=canvas]")
        card = None
        for i in range(canvases.count()):
            bb = canvases.nth(i).bounding_box()
            if bb and bb["height"] == 240:  # (mojoui.looker's CANVAS_HEIGHT: the camera card; the orb is 84)
                card = canvases.nth(i)
                result["canvas"] = bb
        if card is not None and spot_name:
            node, sid = card.get_attribute("data-node"), card.get_attribute("data-sid")
            at = page.evaluate("async ([sid, n, name]) => (await fetch(`/spot/${sid}/${n}?name=${encodeURIComponent(name)}`)).text()", [sid, node, spot_name])
            sx, sy = (float(v) for v in at.strip('"').split(","))
            result["spot"] = [sx, sy]
            if sx >= 0:  # a crosshair where the part is (the checker's own, not the pointer's), for the picture
                page.evaluate("([x, y]) => { const d = document.createElement('div'); d.style.cssText = `position:fixed;left:${x - 14}px;top:${y - 14}px;width:28px;height:28px;border:3px solid #e11;border-radius:50%;pointer-events:none;z-index:99999`; document.body.appendChild(d); }",
                              [result["canvas"]["x"] + sx, result["canvas"]["y"] + sy])
                page.screenshot(path=str(SHOTS / shot.replace(".png", "-spot.png")))
        browser.close()
    new = {k: v for k, v in seen.items() if k not in before}
    grown = {k: v - before[k] for k, v in seen.items() if k in before and v > before[k]}
    result["new_outward_connections"] = list(new)
    result["outward_bytes_sent"] = sum(grown.values()) + sum(new.values())
    result["foreign_requests"] = foreign
    result["look"] = [parse_look(l) for l in lines(host.log, "LOOK")[first_look:]]
    result["reply"] = lines(host.log, "REPLY")[-1].partition(" text=")[2] if lines(host.log, "REPLY") else ""
    return result


def scene(report):
    truth = json.loads((OUT / "truth.json").read_text())
    want = {o["name"]: o["box"] for o in truth["objects"]}
    host = Host("scene")
    try:
        r = tablet(host, OUT / "scene.y4m", "m6-camera-banana.png", "Where is the banana?", "banana")
    finally:
        host.close()
    look = r["look"][-1]
    frame = (OUT / "scene.jpg").stat().st_size
    assert "banana" in look["boxes"], "no box labelled banana: " + str(look["boxes"])
    score = iou(look["boxes"]["banana"], want["banana"])
    assert score >= IOU_MIN, f"IoU {score:.2f} < {IOU_MIN}"
    assert "banana" in r["reply"].lower(), "the reply doesn't name the banana: " + r["reply"]
    assert look["source"] == "browser"
    k = min(r["canvas"]["width"] / 1280, r["canvas"]["height"] / 720)  # the card's picture is fitted in its canvas
    left, top = (r["canvas"]["width"] - 1280 * k) / 2, (r["canvas"]["height"] - 720 * k) / 2
    tb = want["banana"]
    sx, sy = r["spot"]
    assert left + tb[0] * k <= sx <= left + tb[2] * k and top + tb[1] * k <= sy <= top + tb[3] * k, f"the part 'banana' is at {r['spot']}, off the banana's {tb}"
    assert not r["new_outward_connections"], "the host opened connections outward: " + str(r["new_outward_connections"])
    assert r["outward_bytes_sent"] < frame // 10, f"{r['outward_bytes_sent']} bytes went outward during the turn (a frame is {frame})"
    assert not r["foreign_requests"], r["foreign_requests"]
    report["scene"] = {"question": "Where is the banana?", "iou": round(score, 3), "reply": r["reply"], "card_text": look["text"], "labels": look["labels"],
                       "boxes": look["boxes"], "truth": want, "spot_pts": r["spot"], "turn_s": r["turn_s"], "ms": int(look["ms"]),
                       "frame_ms": int(look["frame_ms"]), "read_ms": int(look["read_ms"]), "image_ms": int(look["image_ms"]),
                       "image_tokens": int(look["image_tokens"]), "outward_bytes_sent": r["outward_bytes_sent"], "frame_bytes": frame}
    return f"banana IoU {score:.2f}, reply \"{r['reply']}\", look {look['ms']} ms (frame {look['frame_ms']}, image encode {look['image_ms']}, read {look['read_ms']}), spot {r['spot']} on the banana, {r['outward_bytes_sent']} bytes outward"


def text(report):
    host = Host("text")
    try:
        r = tablet(host, OUT / "otter.y4m", "m6-camera-text.png", "What does the sign say?")
    finally:
        host.close()
    look = r["look"][-1]
    said = (look["text"] + " " + r["reply"]).upper()
    assert "PURPLE" in said and "OTTER" in said and "42" in said, "the words weren't read: " + look["text"] + " | " + r["reply"]
    assert "PURPLE OTTER 42" in r["reply"].upper().replace(",", "").replace(".", ""), "the reply doesn't say the words: " + r["reply"]
    assert not r["new_outward_connections"] and not r["foreign_requests"]
    report["text"] = {"question": "What does the sign say?", "reply": r["reply"], "card_text": look["text"], "turn_s": r["turn_s"], "ms": int(look["ms"])}
    return f"read \"{r['reply']}\" ({look['ms']} ms)"


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    report_path = OUT / "camera.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    for name, fn in (("scene", scene), ("text", text)):
        if which in (name, "all"):
            print(f"camera {name}: ok, {fn(report)}", flush=True)
            report_path.write_text(json.dumps(report, indent=1))
    print("camera: all ok")
