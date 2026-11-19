"""Goal 77 M7f, D-7840: the web host paints a rebuilt screen laid out at once. examples/stage on the web host in headless
Chromium: the TV opens (the "Ephemeral?" pill), its body arrives by a rebuild of the page, and on every animation frame
from the body's first one the TV head's width is read. With the host's own htmx config (settle delay 0) every frame must
show it at its final width; the same run with htmx's default 20 ms settle (set in the page) is the control: it shows the
squashed head of D-7840 (htmx lends the reused ids the old elements' attributes), so the probe measures what it claims.

    pixi run python scripts/g77_settle_check.py        # prints "settle: ok"; numbers in build/g77/m7f/settle.json
"""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/g77/m7f"
sys.path.insert(0, str(ROOT / "scripts"))
import drive  # noqa: E402

TRIALS = 4
RECORD = """(() => { window.rec = []; const t0 = performance.now(); const f = () => { const h = document.querySelector('[data-tag=stage-tv-head]');
  if (h) { const r = h.getBoundingClientRect(); window.rec.push([Math.round(performance.now() - t0), Math.round(r.width), Math.round(r.left)]); }
  if (window.rec.length < 40) requestAnimationFrame(f); }; requestAnimationFrame(f); })()"""


def run():
    from playwright.sync_api import sync_playwright
    if not (ROOT / "build/stage/web/mojoui_app.so").exists():
        b = subprocess.run(["scripts/build.sh", "stage", "web"], cwd=ROOT, capture_output=True, text=True, timeout=3600)
        if b.returncode:
            raise SystemExit("build: " + (b.stdout + b.stderr)[-600:])
    port = drive.free_port()
    host = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(ROOT / "build/stage/web"), str(port)], cwd=ROOT,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    report = {}
    try:
        for _ in range(600):
            if socket.socket().connect_ex(("127.0.0.1", port)) == 0:
                break
            time.sleep(0.2)
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
            for name, delay in (("host", None), ("control_20ms", 20)):
                trials = []
                for _ in range(TRIALS):
                    page = browser.new_page(viewport={"width": 1280, "height": 820})
                    page.goto(f"http://127.0.0.1:{port}/", timeout=120000)
                    page.wait_for_timeout(2500)
                    if delay is not None:
                        page.evaluate(f"htmx.config.defaultSettleDelay = {delay}")
                    config = page.evaluate("htmx.config.defaultSettleDelay")
                    page.evaluate(RECORD)
                    page.get_by_role("button", name="Ephemeral?").click()
                    page.wait_for_timeout(2500)
                    rec = page.evaluate("window.rec")
                    final = rec[-1][1] if rec else 0
                    off = [r for r in rec if abs(r[1] - final) > 2]
                    trials.append({"settle_delay": config, "frames": len(rec), "final_width": final, "frames_not_final": len(off), "first_frames": rec[:3]})
                    page.close()
                report[name] = trials
            browser.close()
    finally:
        host.terminate()
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "settle.json").write_text(json.dumps(report, indent=1) + "\n")
    host_bad = [t for t in report["host"] if t["frames_not_final"] or t["frames"] < 20 or t["settle_delay"] != 0]
    control_bad = [t for t in report["control_20ms"] if t["frames_not_final"]]
    print(json.dumps({k: [(t["frames_not_final"], t["final_width"], t["first_frames"][:1]) for t in v] for k, v in report.items()}))
    assert not host_bad, f"the host's config painted the TV head at another width first: {host_bad}"
    assert control_bad, "the control (htmx's 20 ms settle) showed no squashed frame: the probe can't tell the difference"
    print(f"settle: ok (host: {TRIALS}/{TRIALS} opens with the head at its final width from its first frame; control 20 ms: "
          f"{len(control_bad)}/{TRIALS} opens show it squashed first)")


if __name__ == "__main__":
    run()
