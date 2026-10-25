"""Shoot the console's ten screens at two sizes in headless Chromium, and compare two shots (goal 33 M0, M7).

    pixi run python scripts/console_side.py [run_id]     # the original on the fixtures -> docs/goals/33/orig/<run_id>/

shoot(base_url, out_dir, frozen_at) is general: M0 points it at the original console served by
scripts/console_fixture.py; M7 points it at ours. Each shot gets its own fresh browser context (no localStorage carried
over from the screen before), light colours, en-US in UTC, prefers-reduced-motion, Date frozen at the fixtures'
recording time (the screens show "3 min ago" and clock times), Math.random seeded, and Playwright's
animations="disabled" at the moment of the shot. It waits for the fonts, then for two polls (the console polls every
3 s, the system every 5 s) and for no fetch to be in flight.

differing(a, b): the share of pixels where any channel differs by more than TOLERANCE (8 of 255): anti-aliasing
noise below that isn't counted. Pictures of different sizes differ everywhere (1.0).
"""

import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import drive  # noqa: E402  (CHROMIUM: the repo's headless Chromium)

OUT = ROOT / "docs" / "goals" / "33"
MODEL = "qwen2.5-0.5b"  # the model the model page's four tabs show (loaded and serving in the fixtures)
SCREENS = [
    ("models", "#/"),
    ("overview", f"#/models/{MODEL}/overview"),
    ("bench", f"#/models/{MODEL}/benchmark"),
    ("logs", f"#/models/{MODEL}/logs"),
    ("notebook", f"#/models/{MODEL}/notebook"),
    ("add", "#/add"),
    ("keys", "#/keys"),
    ("gateway", "#/gateway"),
    ("security", "#/security"),
    ("settings", "#/settings"),
]
SIZES = [(1440, 900), (390, 844)]
TOLERANCE = 8  # per channel, of 255
SETTLE_S = 6.5  # two console polls (3 s) and one system poll (5 s) after the page's first fetches

# Before any page script: a seeded Math.random, and a count of fetches in flight to wait on.
INIT = """
(() => {
  let s = 0x2545F491;
  Math.random = () => { s ^= s << 13; s ^= s >>> 17; s ^= s << 5; return ((s >>> 0) % 1e9) / 1e9; };
  window.__inflight = 0;
  const f = window.fetch;
  window.fetch = (...a) => { window.__inflight++; return f(...a).finally(() => { window.__inflight--; }); };
})();
"""


def shoot(base_url, out_dir, frozen_at=None, screens=SCREENS, sizes=SIZES, path="/console", settle_s=SETTLE_S, wait_idle=True):
    """Shoot every screen at every size; returns {(screen, (w, h)): png path}. frozen_at: epoch seconds for Date.
    wait_idle: wait for no fetch in flight (the original's polls); False for a page that always keeps one open (ours:
    the web host's /wait long-poll while the app has timers), which settles by time alone."""
    from playwright.sync_api import sync_playwright

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    shots = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
        try:
            for w, h in sizes:
                phone = w < 600
                for name, route in screens:
                    ctx = browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=1,
                                              is_mobile=phone, has_touch=phone, reduced_motion="reduce",
                                              color_scheme="light", locale="en-US", timezone_id="UTC")
                    ctx.add_init_script(INIT)
                    page = ctx.new_page()
                    if frozen_at is not None:
                        page.clock.set_fixed_time(frozen_at)  # Date only: timers (the polls) keep running
                    page.goto(base_url + path + route, wait_until="load")
                    page.evaluate("document.fonts.ready.then(() => true)")
                    time.sleep(settle_s)
                    if wait_idle:
                        page.wait_for_function("window.__inflight === 0", timeout=10000)
                    page.evaluate("document.fonts.ready.then(() => true)")
                    png = out_dir / f"{name}-{w}x{h}.png"
                    page.screenshot(path=str(png), animations="disabled", caret="hide")
                    shots[(name, (w, h))] = png
                    ctx.close()
        finally:
            browser.close()
    return shots


def shoot_original(run_id):
    """The original console on the recorded replies: ({(screen, (w, h)): png path}, [requests not in the fixtures])."""
    import console_fixture

    fx = console_fixture.Fixtures()
    server, url = console_fixture.serve(fx)
    try:
        shots = shoot(url, OUT / "orig" / run_id, frozen_at=fx.recorded_at)
    finally:
        server.shutdown()
    return shots, list(fx.misses)


def differing(png_a, png_b, tolerance=TOLERANCE):
    """Share of pixels (0–1) where any channel differs by more than `tolerance`."""
    import numpy as np
    from PIL import Image

    a = np.asarray(Image.open(png_a).convert("RGBA"), dtype=np.int16)
    b = np.asarray(Image.open(png_b).convert("RGBA"), dtype=np.int16)
    if a.shape != b.shape:
        return 1.0
    return float((np.abs(a - b) > tolerance).any(axis=2).mean())


if __name__ == "__main__":
    shots, misses = shoot_original(sys.argv[1] if len(sys.argv) > 1 else "a")
    for key, png in sorted(shots.items()):
        print(key, png)
    print("misses:", sorted(set(misses)))
