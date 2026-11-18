"""omx's pointer on the web host (goal 77 M1): the same app in headless Chromium on loopback, a question typed into the page, the reply
spoken to the page's audio graph; proves the ring reaches the browser and sits on its target.

    pixi run python scripts/omx_point_web.py            (needs build/omx/web: scripts/build.sh omx web; the voice env)

Prints `omx_point_web: ok` and writes build/g77/omx-point-web.json and docs/goals/77/web_point.png. What it checks:
  - the page reports where its tagged views are (POST /rects) and the host's `OMX POINT` lines come: >= 3 points, each on a part
    of the card;
  - a screenshot taken while a point shows has the ring (the theme's accent) round the part's own rectangle in the browser
    (the part is found with the browser's own getBoundingClientRect), and not round the others;
  - the lag the app printed for each point (its first draw against the audio's play-clock time).
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

from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/g77"
SHOTS = ROOT / "docs/goals/77"
MODULE = ROOT / "build/omx/web"
CHROMIUM = "/usr/bin/chromium"
GPU = os.environ.get("G77_GPU", "0")
MODELS = os.environ.get("OMX_MODELS") or str(Path.home() / "Projects/omx-local/models")
ASK = os.environ.get("G77_ASK", "What does the word serendipity mean? Show me the card.")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(fn, seconds, what, every=0.05):
    end = time.time() + seconds
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(every)
    raise AssertionError("timed out waiting for " + what)


def ring_share(png, box, margin=12):
    """How many pixels in the band round `box` (x, y, w, h) are ring-teal (the accent), of the band's pixels."""
    im = Image.open(png).convert("RGB")
    px = im.load()
    x, y, w, h = [int(v) for v in box]
    n = hits = 0
    for yy in range(max(y - margin, 0), min(y + h + margin, im.height)):
        for xx in range(max(x - margin, 0), min(x + w + margin, im.width)):
            inside = x + 3 <= xx < x + w - 3 and y + 3 <= yy < y + h - 3
            if inside:
                continue
            n += 1
            r, g, b = px[xx, yy]
            if r < 110 and g > 100 and b > 110 and g - r > 40:
                hits += 1
    return hits / max(n, 1)


def main():
    if not (MODULE / "mojoui_app.so").exists():
        raise SystemExit("build the web app first: scripts/build.sh omx web")
    OUT.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="omxpoint-"))
    silence = work / "silence.wav"
    with wave.open(str(silence), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\0\0" * 16000 * 60)
    port = free_port()
    env = dict(os.environ, CUDA_VISIBLE_DEVICES=GPU, OMX_LLM_GPU="0", OMX_LLM_CTX="32768", OMX_MODELS=MODELS, OMX_TRACE="1", OMX_SD="0")
    log_path = OUT / "omx-point-web-host.log"
    log = open(log_path, "w")
    host = subprocess.Popen(["pixi", "run", "-e", "voice", "python", str(ROOT / "mojoui/hosts/web.py"), str(MODULE), str(port)], cwd=ROOT,
                            env=env, stdout=log, stderr=subprocess.STDOUT, text=True)
    report = {"ask": ASK}
    try:
        wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0, 120, "the web host")
        flags = ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", f"--use-file-for-fake-audio-capture={silence}",
                 "--autoplay-policy=no-user-gesture-required", "--no-sandbox"]
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=CHROMIUM, headless=True, args=flags)
            ctx = browser.new_context(viewport={"width": 820, "height": 1180}, permissions=["microphone"])
            page = ctx.new_page()
            page.goto(f"http://127.0.0.1:{port}/", timeout=240000)
            page.mouse.click(10, 10)  # (the tap that turns sound on)
            wait_for(lambda: "OMX READY" in log_path.read_text(), 240, "the voice and the model", 0.5)
            page.get_by_role("button", name="Type").click()
            box = page.get_by_placeholder("Type to omx")
            box.fill(ASK)
            box.press("Enter")
            shots, best = [], None
            end = time.time() + 90
            while time.time() < end:
                page.wait_for_timeout(250)
                tags = page.evaluate("() => [...document.querySelectorAll('[data-tag]')].map(e => e.dataset.tag).filter(t => t.includes('.'))")
                if not tags:
                    continue
                png = OUT / f"web_{len(shots):02d}.png"
                page.screenshot(path=str(png))
                shots.append(png)
                rects = page.evaluate("() => Object.fromEntries([...document.querySelectorAll('[data-tag]')].filter(e => e.dataset.tag.includes('.')).map(e => { const r = e.getBoundingClientRect(); return [e.dataset.tag, [r.left, r.top, r.width, r.height]]; }))")
                share = {t: ring_share(png, r) for t, r in rects.items()}
                top = max(share, key=share.get) if share else None
                if top and (best is None or share[top] > best[1]):
                    best = (top, share[top], png, share)
                text = log_path.read_text()
                if "STATE 1" in text.split("OMX REPLY")[-1] and "OMX REPLY" in text:
                    break
            report["points"] = [l for l in log_path.read_text().splitlines() if l.startswith("OMX POINT:")]
            sent = [l for l in log_path.read_text().splitlines() if l.startswith("OMX POINT_SENT:")]
            report["sent"] = len(sent)
            assert len(report["points"]) >= 3, f"{len(report['points'])} points shown on the web host (sent {len(sent)})"
            tags = [re.search(r"tag=(\S+)", l).group(1) for l in report["points"]]
            assert all(re.match(r"card\d+\.(word|sounds|meaning|example|origin)$", t) for t in tags), tags
            assert best and best[1] > 0.05, f"no frame with the ring round a part (best {best and best[:2]})"
            report["ring_on"] = best[0]
            report["ring_share"] = round(best[1], 3)
            report["others_share"] = {t: round(v, 3) for t, v in best[3].items() if t != best[0]}
            assert all(v < best[1] for t, v in best[3].items() if t != best[0]), report["others_share"]  # (a part right above or below catches a little of its neighbour's ring)
            import shutil

            shutil.copy(best[2], SHOTS / "web_point.png")
            lags = [int(re.search(r"lag_ms=(-?\d+)", l).group(1)) for l in report["points"]]
            report["lag_ms"] = lags
            ctx.close()
            browser.close()
    finally:
        host.terminate()
        try:
            host.wait(timeout=20)
        except subprocess.TimeoutExpired:
            host.kill()
    (OUT / "omx-point-web.json").write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps(report, indent=1))
    print("omx_point_web: ok")


if __name__ == "__main__":
    main()
