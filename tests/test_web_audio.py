"""The web host carries a browser's microphone in and the app's speaker out (goal 72 M5, docs/web-audio.md).

    pixi run python tests/test_web_audio.py [--tailnet]          # needs build/echo/web (scripts/build.sh echo web); prints "web_audio: ok"
    --tailnet: also over https://<this machine>.<tailnet>.ts.net:$MOJOUI_TABLET_PORT (default 8444) through `tailscale serve`,
               which this test adds and turns off again; skipped (and said so) when tailscale isn't running here.

Headless Chromium with a fake microphone playing tests's own .wav (--use-file-for-fake-audio-capture). The app is examples/echo:
  1. Listen: the app's Microphone receives the browser's samples: how many, and how well they match the .wav (normalised
     cross-correlation, mojoui.audio.best_match, shown by the app itself).
  2. Play back: the app's Speaker output reaches the page's audio graph: the scheduled length equals what was recorded.
  3. Tone: the page's AnalyserNode hears 440 Hz at the right level; Stop sound: the page's queue is flushed within 100 ms
     of the click (click -> event -> update() -> Speaker.stop() -> host -> socket -> page), and the graph is silent after.
  4. Over the tailnet name: the page loads and the socket works with the key; without it, 403 (page and socket).
Writes build/g72/web-audio.json.
"""

import json
import math
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
CHROMIUM = "/usr/bin/chromium"
MODULE = ROOT / "build" / "echo" / "web"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def make_wav(path, seconds=3.0, rate=16000):
    """Speech-like and not periodic: syllables (150 ms bursts) of a gliding two-tone voice, so a match can't be a lucky lag."""
    n = int(seconds * rate)
    out = []
    for i in range(n):
        t = i / rate
        syl = int(t / 0.15)
        f0 = 120 + 40 * math.sin(syl * 1.7) + 30 * math.sin(t * 5.0)
        env = max(0.0, math.sin(math.pi * ((t % 0.15) / 0.15))) ** 0.6 * (0.35 + 0.65 * abs(math.sin(syl * 0.9)))
        v = env * (0.5 * math.sin(2 * math.pi * f0 * t) + 0.25 * math.sin(2 * math.pi * 2.7 * f0 * t) + 0.15 * math.sin(2 * math.pi * (900 + 300 * math.sin(syl)) * t))
        out.append(int(max(-1, min(1, 0.6 * v)) * 32767))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<%dh" % n, *out))


def wait_for(fn, seconds, what):
    end = time.time() + seconds
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError("timed out waiting for " + what)


def status_text(page):
    return page.evaluate("() => [...document.querySelectorAll('#mojoui-root .text')].map(e => e.textContent).join(' | ')")


RAW = ("const o = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices); navigator.mediaDevices.getUserMedia = "
       "c => o({audio: Object.assign({}, c.audio, {echoCancellation: false, noiseSuppression: false, autoGainControl: false})});")


def listen(page, seconds):
    """Listen for `seconds`, stop: (samples heard, the screen's text)."""
    page.get_by_role("button", name="Listen").click()
    wait_for(lambda: "listening ·" in status_text(page), 15, "the first microphone samples")
    page.wait_for_timeout(int(seconds * 1000))
    page.get_by_role("button", name="Stop listening").click()
    try:
        text = wait_for(lambda: "heard" in status_text(page) and status_text(page), 10, "the result")
    except AssertionError:
        raise AssertionError("no result: " + status_text(page))
    return int(text.split("heard ")[1].split(" samples")[0]), text


def drive(page, report, label, url, wav_seconds):
    """The whole round trip with the browser's own processing (echo cancellation, noise suppression, gain control) off, so
    the samples can be compared with the .wav: they match to 100 %."""
    page.add_init_script(RAW)
    page.goto(url)
    page.wait_for_selector("text=Press Listen.")
    # 1. the microphone
    samples, text = listen(page, wav_seconds + 1.5)
    match = int(text.split("match ")[1].split(" %")[0]) / 100
    report[label + "_mic_samples"] = samples
    report[label + "_mic_match"] = match
    assert samples >= 16000 * (wav_seconds + 1.0), (samples, text)
    assert match >= 0.95, text
    # 2. the speaker: what was recorded, played back, is scheduled in the page
    before = page.evaluate("() => window.mojouiAudio.stats().scheduledMs")
    page.get_by_role("button", name="Play back").click()
    want_ms = samples / 16000 * 1000
    got = wait_for(lambda: page.evaluate("() => window.mojouiAudio.stats().scheduledMs") - before >= want_ms * 0.99, 15, "the playback")
    scheduled = page.evaluate("() => window.mojouiAudio.stats().scheduledMs") - before
    report[label + "_playback_scheduled_ms"] = round(scheduled, 1)
    report[label + "_playback_expected_ms"] = round(want_ms, 1)
    assert abs(scheduled - want_ms) <= want_ms * 0.02 + 40, (scheduled, want_ms)
    gaps = page.evaluate("() => window.mojouiAudio.stats().underruns")
    report[label + "_playback_gaps"] = gaps
    assert gaps == 0, gaps
    page.get_by_role("button", name="Stop sound").click()
    page.wait_for_timeout(300)
    # 3. the tone and a stop
    page.evaluate("() => { window.__click = 0; document.addEventListener('click', e => { if (e.target.closest('button') && e.target.closest('button').textContent.includes('Stop sound')) window.__click = performance.now(); }, true); }")
    page.get_by_role("button", name="Tone").click()
    wait_for(lambda: page.evaluate("() => window.mojouiAudio.stats().rms") > 0.05, 10, "the tone in the audio graph")
    page.wait_for_timeout(500)
    s = page.evaluate("() => window.mojouiAudio.stats()")
    report[label + "_tone_rms"] = round(s["rms"], 3)
    report[label + "_tone_hz"] = round(s["hz"], 1)
    assert 0.2 < s["rms"] < 0.5, s["rms"]  # 0.5 amplitude sine: RMS 0.354
    assert abs(s["hz"] - 440) <= 15, s["hz"]
    flushes_before = len(s["flushes"])
    page.get_by_role("button", name="Stop sound").click()
    s = wait_for(lambda: (lambda v: v if len(v["flushes"]) > flushes_before else None)(page.evaluate("() => window.mojouiAudio.stats()")), 5, "the flush")
    clicked = page.evaluate("() => window.__click")
    flush_ms = s["flushes"][-1] - clicked
    report[label + "_stop_flush_ms"] = round(flush_ms, 1)
    assert 0 <= flush_ms <= 100, flush_ms
    page.wait_for_timeout(150)
    after = page.evaluate("() => window.mojouiAudio.stats().rms")
    report[label + "_silent_rms_after_stop"] = round(after, 4)
    assert after < 0.01, after


def main():
    tailnet = "--tailnet" in sys.argv
    if not (MODULE / "mojoui_app.so").exists():
        raise SystemExit("build the app first: scripts/build.sh echo web")
    work = Path(tempfile.mkdtemp(prefix="webaudio-"))
    wav = work / "in.wav"
    make_wav(wav)
    port = free_port()
    key_file = work / "pair-key"
    env = dict(os.environ, ECHO_WAV=str(wav), MOJOUI_PAIR_KEY_FILE=str(key_file), PORT=str(port))
    machine = tail_port = None
    if tailnet:
        machine = tailnet_name()
        tail_port = int(os.environ.get("MOJOUI_TABLET_PORT", "8444"))
        if machine:
            env["MOJOUI_EXTRA_HOSTS"] = machine
        else:
            print("web_audio: tailscale isn't running here: the tailnet part is skipped")
            tailnet = False
    server = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(MODULE), str(port)], env=env, cwd=ROOT,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    report = {"wav_seconds": 3.0}
    served = False
    try:
        wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0, 60, "the web host")
        flags = ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", f"--use-file-for-fake-audio-capture={wav}",
                 "--autoplay-policy=no-user-gesture-required", "--no-sandbox"]
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=CHROMIUM, headless=True, args=flags)
            # D-7277: one live page per process: a second tab takes over, and the first says so (it doesn't keep a second copy
            # of the app and its model alive)
            ctx = browser.new_context(permissions=["microphone"])
            first = ctx.new_page()
            first.goto(f"http://127.0.0.1:{port}/")
            first.wait_for_selector("text=Press Listen.")
            second = ctx.new_page()
            second.goto(f"http://127.0.0.1:{port}/")
            second.wait_for_selector("text=Press Listen.")
            wait_for(lambda: "belong to one page at a time" in first.inner_text("body"), 15, "the first tab's notice")
            assert "Press Listen." in second.inner_text("body")
            report["second_tab_notice"] = True
            ctx.close()
            ctx = browser.new_context(viewport={"width": 820, "height": 1180}, permissions=["microphone"])
            page = ctx.new_page()
            drive(page, report, "local", f"http://127.0.0.1:{port}/", 3.0)
            page.screenshot(path=str(ROOT / "build" / "g72" / "web-audio-tablet.png"))
            ctx.close()
            # the page's default capture (echo cancellation, noise suppression, gain control on): the processed signal still
            # reaches the app (its match with the .wav is lower: the browser's own filters change a synthetic voice)
            ctx = browser.new_context(permissions=["microphone"])
            page = ctx.new_page()
            page.goto(f"http://127.0.0.1:{port}/")
            page.wait_for_selector("text=Press Listen.")
            samples, text = listen(page, 3.0)
            report["local_default_mic_samples"] = samples
            report["local_default_mic_match"] = int(text.split("match ")[1].split(" %")[0]) / 100
            assert samples >= 16000 * 2.5 and report["local_default_mic_match"] >= 0.2, text
            ctx.close()
            if tailnet:
                key = key_file.read_text().strip()
                subprocess.run(["tailscale", "serve", "--bg", f"--https={tail_port}", f"http://127.0.0.1:{port}"], check=True, capture_output=True)
                served = True
                base = f"https://{machine}:{tail_port}"
                import ssl
                import urllib.error
                import urllib.request
                try:
                    urllib.request.urlopen(base + "/")
                    raise AssertionError("the tailnet name answered without the key")
                except urllib.error.HTTPError as e:
                    report["tailnet_no_key_status"] = e.code
                    assert e.code == 403
                try:
                    import websockets.sync.client as wsc
                    wsc.connect(f"wss://{machine}:{tail_port}/audio", open_timeout=10).close()
                    raise AssertionError("the tailnet socket opened without the key")
                except Exception as e:  # noqa: BLE001
                    status = getattr(getattr(e, "response", None), "status_code", None)
                    report["tailnet_ws_no_key_status"] = status
                    assert status == 403, repr(e)
                ctx = browser.new_context(viewport={"width": 820, "height": 1180}, permissions=["microphone"])
                page = ctx.new_page()
                drive(page, report, "tailnet", base + f"/?k={key}", 3.0)
                assert "?k=" not in page.url and page.url.startswith(base), page.url  # (the key is moved into a cookie, off the address bar)
                cookies = ctx.cookies()
                assert [c for c in cookies if c["name"] == "mojoui_pair" and c["httpOnly"] and c["secure"]]
                ctx.close()
            browser.close()
    finally:
        if served:
            subprocess.run(["tailscale", "serve", f"--https={tail_port}", "off"], capture_output=True)
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
        shutil.rmtree(work, ignore_errors=True)
    out = ROOT / "build" / "g72" / "web-audio.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps(report, indent=1))
    print("web_audio: ok")


def tailnet_name():
    """This machine's tailnet DNS name, or "" when tailscale isn't up."""
    if not shutil.which("tailscale"):
        return ""
    try:
        out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=10).stdout
        return json.loads(out)["Self"]["DNSName"].rstrip(".").lower()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return ""


if __name__ == "__main__":
    main()
