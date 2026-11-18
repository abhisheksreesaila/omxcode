"""omx on a tablet (goal 72 M5): the same app, in a browser, through the tailnet's name. Prints `omx_tablet: ok` and writes
build/g72/omx-tablet.json and the tablet-width picture docs/goals/72/tablet.png.

    pixi run python scripts/omx_tablet_check.py            (needs build/g72/wav from docs/goals/72-check.py M4, the voice env)

What it does: starts examples/omx on the web host (in the `voice` pixi environment, loopback only), puts it on the tailnet with
`tailscale serve` (its own entry on the first free https port from 8444, removed at the end), and drives headless Chromium with a
fake microphone that plays the recorded question (--use-file-for-fake-audio-capture, looped, so the file is the question
followed by silence). Proves:
  - no key: the page and the audio socket answer 403 on the tailnet name; with the key the page loads (key moved into a cookie);
  - the question is heard and answered aloud: the page's audio graph receives the reply, and the time from the question's last
    voiced sample (the file's own clock, from when the page's microphone opened) to the first reply audio scheduled in the page is
    at most 2 s (the app's own stamp is in the json beside it);
  - a tablet-width picture of the screen.
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

import numpy as np
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/g72"
SHOTS = ROOT / "docs/goals/72"
MODULE = ROOT / "build/omx/web"
CHROMIUM = "/usr/bin/chromium"
GPU = os.environ.get("G72_GPU", "1")
MODELS = os.environ.get("OMX_MODELS") or str(Path.home() / "Projects/omx-local/models")
LIMIT_S = 2.0


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


def tailnet_name():
    out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=10).stdout
    return json.loads(out)["Self"]["DNSName"].rstrip(".").lower()


def question_wav(work):
    """q1 with a second of lead and four of silence after it (the fake microphone loops the file): (path, the last voiced
    sample's time in the file)."""
    with wave.open(str(OUT / "wav/q1.wav"), "rb") as w:
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    voiced = np.nonzero(np.abs(pcm) > 0.02 * 32768)[0]
    lead = 16000
    full = np.concatenate([np.zeros(lead, "<i2"), pcm, np.zeros(4 * 16000, "<i2")])
    path = work / "question.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(full.tobytes())
    return path, (lead + int(voiced[-1])) / 16000


def main():
    if not (OUT / "wav/q1.wav").exists():
        raise SystemExit("run docs/goals/72-check.py M4 first (it makes build/g72/wav)")
    r = subprocess.run([str(ROOT / "scripts/build.sh"), "omx", "web"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit("build omx web failed:\n" + (r.stdout + r.stderr)[-2000:])
    work = Path(tempfile.mkdtemp(prefix="omxtablet-"))
    wav, speech_end = question_wav(work)
    port, machine = free_port(), tailnet_name()
    https = int(os.environ.get("MOJOUI_TABLET_PORT", "8444"))
    key_file = work / "pair-key"
    env = dict(os.environ, CUDA_VISIBLE_DEVICES=GPU, OMX_LLM_GPU="0", OMX_MODELS=MODELS, MOJOUI_PAIR_KEY_FILE=str(key_file),
               MOJOUI_EXTRA_HOSTS=machine, OMX_TRACE="1")
    if os.environ.get("G72_LAYOUT") == "split":  # the brain on card 0, the voice on card 1 (docs/goals/72-check.py's SPLIT)
        env.update(CUDA_DEVICE_ORDER="PCI_BUS_ID", CUDA_VISIBLE_DEVICES=os.environ.get("G72_VOICE_GPU", "1") + "," + os.environ.get("G72_BRAIN_GPU", "0"), OMX_LLM_GPU="1")
    log = open(OUT / "omx-tablet-host.log", "w")
    host = subprocess.Popen(["pixi", "run", "-e", "voice", "python", str(ROOT / "mojoui/hosts/web.py"), str(MODULE), str(port)], cwd=ROOT,
                            env=env, stdout=log, stderr=subprocess.STDOUT, text=True)
    report = {"machine": machine, "speech_ends_in_file_s": round(speech_end, 3)}
    served = False
    try:
        wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0, 120, "the web host")
        key = wait_for(lambda: key_file.exists() and key_file.read_text().strip(), 30, "the pairing key")
        subprocess.run(["tailscale", "serve", "--bg", f"--https={https}", f"http://127.0.0.1:{port}"], check=True, capture_output=True)
        served = True
        base = f"https://{machine}:{https}"
        import urllib.error
        import urllib.request

        try:
            urllib.request.urlopen(base + "/")
            raise AssertionError("the tailnet name answered without the key")
        except urllib.error.HTTPError as e:
            report["no_key_page_status"] = e.code
            assert e.code == 403, e.code
        import websockets.sync.client as wsc

        try:
            wsc.connect(f"wss://{machine}:{https}/audio", open_timeout=10).close()
            raise AssertionError("the audio socket opened without the key")
        except Exception as e:  # noqa: BLE001
            status = getattr(getattr(e, "response", None), "status_code", None)
            report["no_key_socket_status"] = status
            assert status == 403, repr(e)
        flags = ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", f"--use-file-for-fake-audio-capture={wav}",
                 "--autoplay-policy=no-user-gesture-required", "--no-sandbox"]
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=CHROMIUM, headless=True, args=flags)
            ctx = browser.new_context(viewport={"width": 820, "height": 1180}, permissions=["microphone"])
            page = ctx.new_page()
            # when the page's microphone opened: the fake file's clock starts there
            page.add_init_script("""
              const o = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
              navigator.mediaDevices.getUserMedia = c => o(c).then(s => { window.__micOpen = window.__micOpen || performance.now(); return s; });
            """)
            page.on("response", lambda r: print("response", r.status, r.url[:80], flush=True))
            page.goto(base + f"/?k={key}", timeout=180000)  # (the app is made on the first visit: the models load first)
            page.mouse.click(10, 10)  # the tap that turns sound on (D-7234)
            assert "?k=" not in page.url and page.url.startswith(base), page.url
            assert [c for c in ctx.cookies() if c["name"] == "mojoui_pair" and c["httpOnly"] and c["secure"]]
            report["key_moved_to_cookie"] = True
            opened = wait_for(lambda: page.evaluate("() => window.__micOpen"), 180, "the page's microphone to open", 0.1)
            # the first reply audio scheduled in the page, by the page's own clock
            t_audio = None
            end = time.time() + 40
            while time.time() < end and t_audio is None:
                v = page.evaluate("() => [performance.now(), window.mojouiAudio ? window.mojouiAudio.stats().scheduledMs : 0]")
                if v[1] > 0:
                    t_audio = v[0]
                time.sleep(0.01)
            assert t_audio, "the page never received a reply to play"
            answer_s = (t_audio - opened) / 1000 - speech_end
            report["question_to_first_audio_s"] = round(answer_s, 3)
            report["limit_s"] = LIMIT_S
            assert answer_s <= LIMIT_S, f"{answer_s:.2f} s after the question's last word (limit {LIMIT_S})"
            texts = []
            for _ in range(40):  # (the page shows the answer words: the app's updates reach it as patches)
                page.wait_for_timeout(500)
                t = page.evaluate("() => document.body.innerText")
                texts.append(t[:60].replace(chr(10), ' | '))
                if 'paris' in t.lower():
                    break
            report['page_text_over_time'] = texts[::4]
            SHOTS.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=str(SHOTS / "tablet.png"))
            shutil.copy(SHOTS / "tablet.png", OUT / "tablet.png")
            text = page.evaluate("() => document.body.innerText")
            report["page_text"] = " | ".join(t.strip() for t in text.splitlines() if t.strip())[:300]
            assert "paris" in text.lower(), text[:300]
            ctx.close()
            browser.close()
        report["host_log_lines"] = [l for l in open(OUT / "omx-tablet-host.log").read().splitlines() if l.startswith("OMX")][:8]
    finally:
        if served:
            subprocess.run(["tailscale", "serve", f"--https={https}", "off"], capture_output=True)
        host.terminate()
        try:
            host.wait(timeout=15)
        except subprocess.TimeoutExpired:
            host.kill()
        shutil.rmtree(work, ignore_errors=True)
    (OUT / "omx-tablet.json").write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps(report, indent=1))
    print("omx_tablet: ok")


if __name__ == "__main__":
    main()
