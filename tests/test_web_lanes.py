"""Answers that carry screen changes are never dropped by the page (D-546).

    pixi run python tests/test_web_lanes.py [web.py]     # default mojoui/hosts/web.py

htmx drops the answer to a request whose source element left the page while the request was out: its out-of-band swaps
never happen. A whole-screen answer replaces #mojoui-root and every view in it, and the server has already handed the
changes over (s.pending is cleared), so an answer lost that way is lost for good: under load the console's logs tab
stayed on "Loading…" because the effects loop sent /pending from #mojoui-root while the route's answer replaced it.

1. The rule, against the bundled htmx: a source replaced in flight loses its answer; a lane (a hidden element outside
   the root) keeps it.
2. Every htmx.ajax in mojoui/hosts/web.py is sent from a lane or document.body, never from the root or a view in it.
Prints "web_lanes: ok".
"""

import http.server
import re
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
WEB = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "mojoui" / "hosts" / "web.py"
SAFE = re.compile(r"source:\s*(?:lane\(|window\.mojouiLane\(|document\.body\b)")

PAGE = b"""<html><head><meta name="htmx-config" content='{"disableInheritance": true}'><script src="/htmx.js"></script></head>
<body><main id="mojoui-root">a screen</main><div id="out">before</div></body></html>"""


def browser_rule():
    import drive
    from playwright.sync_api import sync_playwright
    htmx = (ROOT / "mojoui" / "hosts" / "static" / "htmx.min.js").read_bytes()

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = htmx if self.path == "/htmx.js" else PAGE
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            time.sleep(0.3)  # (out long enough for the root to be replaced meanwhile)
            body = b'<div id="out" hx-swap-oob="true">after</div>'
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    got = {}
    try:
        with sync_playwright() as p:
            b = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
            page = b.new_page()
            page.goto(f"http://127.0.0.1:{srv.server_port}/")
            for source in ("root", "lane"):
                page.evaluate("document.getElementById('out').textContent = 'before'")
                page.evaluate("""(source) => {
                    let lane = document.getElementById('lane');
                    if (!lane) { lane = document.createElement('i'); lane.id = 'lane'; lane.hidden = true; document.body.append(lane); }
                    const root = document.getElementById('mojoui-root');
                    htmx.ajax('POST', '/x', { swap: 'none', source: source === 'lane' ? lane : root });
                    const next = document.createElement('main'); next.id = 'mojoui-root'; next.textContent = 'a newer screen';
                    root.replaceWith(next);  // (a whole-screen answer landing while the request is out)
                }""", source)
                page.wait_for_timeout(1000)
                got[source] = page.evaluate("document.getElementById('out').textContent")
            b.close()
    finally:
        srv.shutdown()
    return got


def main():
    problems = []
    got = browser_rule()
    if got.get("lane") != "after":
        problems.append(f"an answer sent from a lane was dropped ({got})")
    if got.get("root") != "before":
        problems.append(f"htmx no longer drops an answer whose source was replaced ({got}): the rule may be relaxed, not the lint")
    text = WEB.read_text()
    calls = [m.start() for m in re.finditer(r"htmx\.ajax\(", text)]
    for at in calls:
        call = text[at:at + 400].split("source:", 1)
        source = "source:" + call[1][:40] if len(call) == 2 else ""
        if not SAFE.match(source):
            no = text.count("\n", 0, at) + 1
            problems.append(f"web.py:{no} sends htmx.ajax from a source a screen answer can replace ({(source or 'none named').split(chr(10))[0]})")
    if len(calls) < 9:
        problems.append(f"found {len(calls)} htmx.ajax calls in web.py: the lint isn't reading them")
    if problems:
        sys.exit("web_lanes: " + "; ".join(problems))
    print("web_lanes: ok (a replaced source loses its answer, a lane keeps it; every htmx.ajax in web.py from a lane or the body)")


if __name__ == "__main__":
    main()
