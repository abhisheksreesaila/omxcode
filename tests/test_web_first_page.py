"""The web host renders a tab's first page whole while its effects run (D-545).

    pixi run python tests/test_web_first_page.py [module_dir] [web.py]   # default build/console/web, mojoui/hosts/web.py

Once GET / registers a new tab with the clock thread, the tab's effects (HTTP replies, timer ticks) can change its
screen at any moment. The page must be rendered from one screen: the clock thread may not poll the app while the page is
being rendered. Under load it did: the console's first page came out torn (its Route missing, so a deep link was never
asked for, and the web shots caught the models page for the logs tab).

How: the real app module (an app with timers or requests out from the start: the console), wrapped so its title() (the
first call of the render) waits 300 ms and marks the render open, its theme() (the last) closes it, and poll() notes if
it ran inside. Prints "web_first_page: ok".
"""

import importlib.util
import os
import socket
import sys
import threading
import time
import types
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    module_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build" / "console" / "web").resolve()
    web_py = Path(sys.argv[2] if len(sys.argv) > 2 else ROOT / "mojoui" / "hosts" / "web.py").resolve()
    os.environ["MXC_URL"] = "http://127.0.0.1:9"  # (nothing listens: its polls fail fast, still effects)

    so = next(module_dir.glob("mojoui_app*.so"))
    spec = importlib.util.spec_from_file_location("mojoui_app", so)
    real = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(real)
    state = {"rendering": False, "polls": 0, "inside": 0}
    wrapped = types.ModuleType("mojoui_app")
    for name in dir(real):
        if not name.startswith("__"):
            setattr(wrapped, name, getattr(real, name))

    def title(h):
        state["rendering"] = True
        time.sleep(0.3)  # (a slow render: the clock thread has every chance to poll meanwhile)
        return real.title(h)

    def theme(h):
        state["rendering"] = False
        return real.theme(h)

    def poll(h):
        state["polls"] += 1
        if state["rendering"]:
            state["inside"] += 1
        return real.poll(h)

    wrapped.title, wrapped.theme, wrapped.poll = title, theme, poll
    if not hasattr(real, "wake_in") or not hasattr(real, "poll"):
        sys.exit(f"web_first_page: {module_dir} has no effects (wake_in/poll): pick an app with timers")
    sys.modules["mojoui_app"] = wrapped

    spec = importlib.util.spec_from_file_location("mojoui_web_host", web_py)
    web = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(web)
    app = web.make_app(module_dir)

    import uvicorn
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    threading.Thread(target=server.run, daemon=True).start()
    for _ in range(100):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/static/htmx.min.js", timeout=1)
            break
        except OSError:
            time.sleep(0.1)

    problems = []
    for i in range(4):
        html = urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=30).read().decode()
        if 'data-kind="route"' not in html:
            problems.append(f"page {i + 1} has no Route")
        time.sleep(0.2)
    server.should_exit = True
    if state["polls"] == 0:
        problems.append("the clock thread never polled (no effects to race with: the test proves nothing)")
    if state["inside"]:
        problems.append(f"the clock thread polled the app {state['inside']} time(s) while a first page was being rendered")
    if problems:
        sys.exit("web_first_page: " + "; ".join(problems))
    print(f"web_first_page: ok ({state['polls']} polls, none inside a render)")


if __name__ == "__main__":
    main()
