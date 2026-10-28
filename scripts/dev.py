"""The developer loop for an app's JavaScript (scripts/dev.sh <app> [--port N]; docs/js.md; goal 34b M1c).

1. Builds the app for the web as a debug build (MOJOUI_DEBUG=1: each bundle with its source map).
2. Serves it with mojoui/hosts/web.py on 127.0.0.1 only, as the dev server (MOJOUI_DEV=1: /dev/* endpoints, source maps;
   a random token so only this script can say "rebuilt").
3. Watches examples/<app>/web/ (widgets/*.js|ts|css, package.json, the lockfile, shared.json) and the shared widgets the
   app picks (mojoui/widgets/<name>.*, its package.json and lockfile): on a save it runs the bundler again
   (scripts/web_assets.py, with the lint) and tells the server, whose open pages load the new bundles and mount those
   widgets again from Mojo's props. The Mojo app keeps running, with its state.
The server's log (JS ERROR: lines, with source files and lines) comes out here. A change to app.mojo needs a restart.
"""

import os
import secrets
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOST = "127.0.0.1"  # never another interface: the dev server is for this machine only


def sources(web):
    files = {}
    shared = []
    try:  # (the shared widgets the app picks: mojoui/widgets/<name>.*, and their packages)
        import json
        names = json.loads((web / "shared.json").read_text()).get("widgets", []) if (web / "shared.json").exists() else []
        shared = [f for n in names if isinstance(n, str) for f in (ROOT / "mojoui" / "widgets").glob(n + ".*")]
        shared += [ROOT / "mojoui" / "widgets" / "package.json", ROOT / "mojoui" / "widgets" / "package-lock.json"] if names else []
    except (ValueError, AttributeError):
        pass  # (the bundler says what's wrong with it)
    for f in list((web / "widgets").glob("*")) + [web / "package.json", web / "package-lock.json", web / "shared.json"] + shared:
        if f.is_file() and (f.suffix in (".js", ".ts", ".css") or f.name.startswith("package") or f.name == "shared.json"):
            files[f] = f.stat().st_mtime_ns
    return files


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 2
    app, port = args[0], 5001
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    web = ROOT / "examples" / app / "web"
    if not web.is_dir():
        print(f"dev: examples/{app} has no web/ folder (no JavaScript to watch)")
        return 2
    env = dict(os.environ, MOJOUI_DEBUG="1")
    print(f"dev: building {app} for the web (debug: source maps)", flush=True)
    b = subprocess.run(["scripts/build.sh", app, "web"], cwd=ROOT, env=env)
    if b.returncode != 0:
        return b.returncode
    token = secrets.token_hex(16)
    server = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(ROOT / "build" / app / "web"), str(port)], cwd=ROOT,
                              env=dict(env, MOJOUI_DEV="1", MOJOUI_DEV_TOKEN=token))
    url = f"http://{HOST}:{port}/"
    for _ in range(600):
        try:
            urllib.request.urlopen(url + "static/htmx.min.js", timeout=1)
            break
        except OSError:
            if server.poll() is not None:
                return 1
            time.sleep(0.1)
    print(f"dev: {url} (open it; save a widget's file to reload it)", flush=True)
    seen = sources(web)
    print(f"dev: watching examples/{app}/web ({len(seen)} files)", flush=True)
    try:
        while server.poll() is None:
            time.sleep(0.25)
            now = sources(web)
            if now == seen:
                continue
            changed = sorted(f.name for f in set(now) | set(seen) if now.get(f) != seen.get(f))
            time.sleep(0.15)  # (an editor writes in steps: let the save finish)
            seen = sources(web)
            t0 = time.time()
            r = subprocess.run([sys.executable, "scripts/web_assets.py", app], cwd=ROOT, env=env, capture_output=True, text=True)
            if r.returncode != 0:
                print(f"dev: {', '.join(changed)}: not rebuilt\n" + (r.stdout + r.stderr)[-2000:], flush=True)
                continue
            body = urllib.parse.urlencode({"token": token}).encode()
            try:
                v = urllib.request.urlopen(urllib.request.Request(url + "dev/reload", data=body), timeout=10).read().decode()
                print(f"dev: rebuilt {', '.join(changed)} in {(time.time() - t0) * 1000:.0f} ms; open pages reload their widgets (version {v})", flush=True)
            except OSError as e:
                print(f"dev: rebuilt {', '.join(changed)}, but the server didn't take it: {e}", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
