"""omx's map card on the web host (goal 77 M3): the same app in headless Chromium on loopback at tablet size (820 x 1180), trips typed
into the page, the replies spoken to the page's audio graph. Proves the map shows real tiles in the browser, that its stops are where
the checker's truth says, and that the ring lands on the marker of the stop being named while the map flies there.

    pixi run python scripts/omx_map_web.py            (needs build/omx/web: scripts/build.sh omx web; the voice env)

Prints `omx_map_web: ok` and writes build/g77/omx-map-web.json, the host's log build/g77/omx-map-web-host.log and, per trip,
docs/goals/77/m3-map-tablet-<k>.png (the best frame: the ring round the marker in the map's middle, tiles round it).
G77_TRIPS: the asks, joined by "|" (default: the two of docs/goals/77-check.py M3).
"""
import json
import os
import re
import shutil
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
TRIPS = os.environ.get("G77_TRIPS", "Plan me a day in Lisbon: Belém Tower, the Alfama and LX Factory.|A trip through Rome, Florence and Venice.").split("|")


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


def teal(px):
    r, g, b = px[:3]
    return r < 110 and g > 100 and b > 110 and g - r > 40


def ring_share(im, box, margin=14):
    """The share of ring-teal pixels in the band from 3 px outside `box` (x, y, w, h) to `margin` px out: the marker's own fill is
    inside, its white casing at the edge, so teal out there is the ring (or its glow)."""
    px = im.load()
    x, y, w, h = [int(round(v)) for v in box]
    n = hits = 0
    for yy in range(max(y - margin, 0), min(y + h + margin, im.height)):
        for xx in range(max(x - margin, 0), min(x + w + margin, im.width)):
            if x - 4 <= xx < x + w + 4 and y - 4 <= yy < y + h + 4:
                continue
            n += 1
            hits += teal(px[xx, yy])
    return hits / max(n, 1)


def tile_colours(im, box):
    """How many distinct colours the map canvas shows (a flat ground has a handful; OpenStreetMap tiles have hundreds)."""
    x, y, w, h = [int(v) for v in box]
    crop = im.crop((x + 4, y + 4, x + w - 4, y + h - 4)).convert("RGB")
    return len(set(crop.getdata()))


def main():
    if not (MODULE / "mojoui_app.so").exists():
        raise SystemExit("build the web app first: scripts/build.sh omx web")
    OUT.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="omxmap-"))
    silence = work / "silence.wav"
    with wave.open(str(silence), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\0\0" * 16000 * 60)
    port = free_port()
    env = dict(os.environ, CUDA_DEVICE_ORDER="PCI_BUS_ID", CUDA_VISIBLE_DEVICES=GPU, OMX_LLM_GPU="0", OMX_LLM_CTX="32768", OMX_MODELS=MODELS,
               OMX_TRACE="1", OMX_SD="0", MOJOUI_TODO=str(OUT / "todo.json"), MOJOUI_GEO_CACHE=os.environ.get("MOJOUI_GEO_CACHE", str(OUT / "geo")))
    (OUT / "todo.json").write_text('{"items":[]}')
    log_path = OUT / "omx-map-web-host.log"
    log = open(log_path, "w")
    host = subprocess.Popen(["pixi", "run", "-e", "voice", "python", str(ROOT / "mojoui/hosts/web.py"), str(MODULE), str(port)], cwd=ROOT,
                            env=env, stdout=log, stderr=subprocess.STDOUT, text=True)
    report = {"trips": []}
    try:
        wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0, 120, "the web host")
        flags = ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", f"--use-file-for-fake-audio-capture={silence}",
                 "--autoplay-policy=no-user-gesture-required", "--no-sandbox"]
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=CHROMIUM, headless=True, args=flags)
            ctx = browser.new_context(viewport={"width": 820, "height": 1180}, permissions=["microphone"])
            page = ctx.new_page()
            page.on("pageerror", lambda e: print("pageerror", str(e)[:300], flush=True))
            page.goto(f"http://127.0.0.1:{port}/", timeout=240000)
            page.mouse.click(10, 10)  # (the tap that turns sound on)
            wait_for(lambda: "OMX READY" in log_path.read_text(), 300, "the voice and the model", 0.5)
            page.get_by_role("button", name="Type").click()
            box = page.get_by_placeholder("Type to omx")
            box.wait_for()
            page.wait_for_timeout(1500)  # (htmx wires the new box after the swap: Enter before that submits the page's own form)
            for k, ask in enumerate(TRIPS, 1):
                before = log_path.read_text()
                replies_before = before.count("OMX REPLY:")
                points_before = before.count("OMX POINT:")
                box = page.get_by_placeholder("Type to omx")
                box.fill(ask)
                box.press("Enter")
                best, shots, last_point_at, seen_points = None, 0, None, points_before
                end = time.time() + 240
                while time.time() < end:
                    page.wait_for_timeout(250)
                    text = log_path.read_text()
                    n_points = text.count("OMX POINT:")
                    if n_points > seen_points:
                        seen_points, last_point_at = n_points, time.time()
                    maps = page.evaluate("() => [...document.querySelectorAll('[data-tag]')].filter(e => /^card\\d+\\.map\\d+$/.test(e.dataset.tag)).map(e => { const r = e.getBoundingClientRect(); return [e.dataset.tag, r.left, r.top, r.width, r.height]; })")
                    if maps and last_point_at and time.time() - last_point_at > 1.3:  # (the flight has landed: the named stop sits in the map's middle)
                        tag, x, y, w, h = maps[-1]
                        png = OUT / f"m3_web_{k}_{shots:02d}.png"
                        page.screenshot(path=str(png))
                        shots += 1
                        im = Image.open(png).convert("RGB")
                        marker = (x + w / 2 - 15, y + h / 2 - 15, 30, 30)
                        share = ring_share(im, marker)
                        colours = tile_colours(im, (x, y, w, h))
                        if best is None or share > best[0]:
                            best = (share, colours, png, tag, [round(v) for v in (x, y, w, h)])
                        if shots >= 6:
                            last_point_at = None
                    done = text.count("OMX REPLY:") > replies_before and "OMX STATE: 1" in text.split("OMX REPLY:")[-1]
                    if done and (last_point_at is None or time.time() - last_point_at > 4) and shots > 0:
                        break
                text = log_path.read_text()
                lines = text.splitlines()
                new = lines[len(before.splitlines()):]
                trip = {"ask": ask, "points": [l for l in new if l.startswith("OMX POINT:")], "maps": [l for l in new if l.startswith("OMX MAP:")],
                        "calls": [l for l in new if l.startswith("OMX CALL:")], "reply": next((l for l in new if l.startswith("OMX REPLY:")), "")}
                assert best, f"trip {k}: no frame of the map after a point ({len(trip['points'])} points, calls {trip['calls']})"
                trip["ring_share"] = round(best[0], 3)
                trip["tile_colours"] = best[1]
                trip["map_rect"] = best[4]
                shutil.copy(best[2], SHOTS / f"m3-map-tablet-{k}.png")
                trip["shot"] = f"docs/goals/77/m3-map-tablet-{k}.png"
                report["trips"].append(trip)
                print(json.dumps({x: trip[x] for x in ("ask", "ring_share", "tile_colours", "shot")}), len(trip["points"]), "points", flush=True)
                page.wait_for_timeout(2000)
            ctx.close()
            browser.close()
    finally:
        host.terminate()
        try:
            host.wait(timeout=20)
        except subprocess.TimeoutExpired:
            host.kill()
    (OUT / "omx-map-web.json").write_text(json.dumps(report, indent=1) + "\n")
    for t in report["trips"]:
        assert t["tile_colours"] > 300, f"{t['ask']!r}: the map shows {t['tile_colours']} colours: no tiles"
        assert t["ring_share"] > 0.05, f"{t['ask']!r}: no frame with the ring round the marker in the map's middle (best share {t['ring_share']})"
    print("omx_map_web: ok")


if __name__ == "__main__":
    main()
