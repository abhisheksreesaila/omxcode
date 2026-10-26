"""On a phone the web host tells the app the screen's size, whatever the page's content is (D-547).

    pixi run python tests/test_web_viewport.py [module_dir] [web.py]   # default build/console/web, mojoui/hosts/web.py

A phone browser widens the layout viewport (innerWidth, innerHeight) to fit content wider than the screen. The app's first
page is laid out before the page has told it the window's size, so on a 390 pt phone it can be wider than the screen;
under load the page measured itself in that moment, told the app 780x1688, and the app's 780-wide layout kept the page
that wide (the keys shot at 390 came out a desktop layout, 85 % equal).

How: the real host and app (the console, its daemon unreachable) in Chromium as a 390x844 phone; a view
780 px wide is added to the page and the window says it resized: the size the page posts (/resize) stays 390x844. Prints
"web_viewport: ok".
"""

import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def main():
    import drive
    from playwright.sync_api import sync_playwright
    module_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build" / "console" / "web").resolve()
    web_py = Path(sys.argv[2] if len(sys.argv) > 2 else ROOT / "mojoui" / "hosts" / "web.py").resolve()
    port = drive.free_port()
    env = dict(os.environ, MXCONSOLE_URL=os.environ.get("MXCONSOLE_URL", "http://127.0.0.1:9"))
    web = subprocess.Popen([sys.executable, str(web_py), str(module_dir), str(port)], cwd=ROOT, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sizes = []
    try:
        for _ in range(300):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/static/htmx.min.js", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        with sync_playwright() as p:
            b = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
            ctx = b.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True, device_scale_factor=1)
            page = ctx.new_page()
            page.on("request", lambda r: sizes.append(r.post_data) if "/resize/" in r.url else None)
            page.goto(f"http://127.0.0.1:{port}/", wait_until="load")
            page.wait_for_timeout(1000)
            page.evaluate("""() => { const v = document.createElement('div'); v.style.cssText = 'width: 780px; height: 10px';
                document.body.append(v); dispatchEvent(new Event('resize')); }""")
            page.wait_for_timeout(1000)
            inner = page.evaluate("[innerWidth, innerHeight]")
            b.close()
    finally:
        web.terminate()
        try:
            web.wait(timeout=10)
        except subprocess.TimeoutExpired:
            web.kill()
            web.wait(timeout=10)
    problems = []
    if not sizes:
        problems.append("the page never posted its size")
    elif any(s != "w=390&h=844" for s in sizes):
        problems.append(f"the page posted {sizes} for a 390x844 phone (innerWidth, innerHeight {inner})")
    if len(sizes) < 2 and inner != [390, 844]:
        problems.append(f"after the wide view the page reads its window as {inner}")
    if problems:
        sys.exit("web_viewport: " + "; ".join(problems))
    print(f"web_viewport: ok (posted {sizes}; the window read {inner} with a 780 px view in it)")


if __name__ == "__main__":
    main()
