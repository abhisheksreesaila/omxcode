"""Milestone checker for GOAL.md (goal 50: the framework serves, fetches and supervises; omxconsole's daemon in Mojo on it).
Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M2)
Each proof was written before its work started, from GOAL.md's words (never weaker). The real ~/.mxc and the running
Python daemon are never touched: M4/M5 use a copy of ~/.mxc/mst.db under build/g50/ and their own ports.
"""

import importlib.util
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
sys.path.insert(0, str(ROOT / "scripts"))
BUILD = ROOT / "build"
G50 = BUILD / "g50"
OUT = ROOT / "docs" / "goals" / "50"
FIXTURES = ROOT / "docs" / "goals" / "33" / "fixtures"
MODEL_REPO = "Qwen/Qwen2.5-0.5B-Instruct"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(cmd, env=None, timeout=1800):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=dict(os.environ, **(env or {})), timeout=timeout)


def mojo_build(src, exe):
    """`scripts/mxbuild.sh`-style build of a Mojo program with mojoui, vendor/ (flare, json, omxcore) on the path."""
    exe.parent.mkdir(parents=True, exist_ok=True)
    b = run(["scripts/mojo_flare.sh", "build", src, "-o", str(exe)])
    if b.returncode != 0:
        return f"{src} doesn't build: " + (b.stdout + b.stderr)[-800:]
    return None


def mojo_test(name, mark, env=None, timeout=600):
    """Build and run tests/<name>.mojo; None when its output has `mark`, else why."""
    src = f"tests/{name}.mojo"
    if not (ROOT / src).exists():
        return f"no {src}"
    exe = BUILD / name
    err = mojo_build(src, exe)
    if err:
        return err
    r = run([str(exe)], env=env, timeout=timeout)
    out = r.stdout + r.stderr
    if r.returncode != 0 or mark not in out:
        return f"{name}: exit {r.returncode}, no '{mark}': {out[-600:]}"
    return None


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_port(port, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
            return True
        except OSError:
            time.sleep(0.2)
    return False


def http(method, url, body=None, headers=None, timeout=30):
    """(status, bytes, headers)."""
    data = json.dumps(body).encode() if body is not None else None
    h = dict(headers or {})
    if data is not None:
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def shape_diff(want, got, where="$"):
    """Where `got` doesn't have `want`'s shape: every key `want` has (recursively), the same JSON kind (null matches
    anything; int and float are both numbers); lists compare their first items when both have one."""
    def kind(v):
        if v is None:
            return None
        if isinstance(v, bool):
            return "bool"
        if isinstance(v, (int, float)):
            return "number"
        return type(v).__name__
    kw, kg = kind(want), kind(got)
    if kw is None or kg is None:
        return []
    if kw != kg:
        return [f"{where}: {kg}, not {kw}"]
    if isinstance(want, dict):
        out = []
        for k, v in want.items():
            if k not in got:
                out.append(f"{where}.{k}: missing")
            else:
                out += shape_diff(v, got[k], f"{where}.{k}")
        return out
    if isinstance(want, list) and want and got:
        return shape_diff(want[0], got[0], f"{where}[0]")
    return []


# ---------------------------------------------------------------------------------------------------------------- M0

def m0():
    """Flare v0.12.0 and its json vendored with licences and NOTICE; scripts/flare_ffi.sh builds its shims; mojoui and
    flare link in one binary."""
    problems = []
    for p in ("vendor/flare/__init__.mojo", "vendor/json/__init__.mojo", "vendor/LICENSES/flare.txt", "vendor/LICENSES/json.txt"):
        if not (ROOT / p).exists():
            problems.append(f"no {p}")
    ver = ROOT / "vendor/FLARE_VERSION"
    if not ver.exists() or "v0.12.0" not in ver.read_text():
        problems.append("vendor/FLARE_VERSION doesn't name v0.12.0")
    notice = (ROOT / "NOTICE").read_text() if (ROOT / "NOTICE").exists() else ""
    if "flare" not in notice.lower():
        problems.append("NOTICE doesn't name Flare")
    if problems:
        return False, "; ".join(problems)
    r = run(["bash", "scripts/flare_ffi.sh"], timeout=900)
    if r.returncode != 0:
        return False, "scripts/flare_ffi.sh failed: " + (r.stdout + r.stderr)[-500:]
    src = (ROOT / "tests/test_flare_link.mojo").read_text() if (ROOT / "tests/test_flare_link.mojo").exists() else ""
    for mod in ("mojoui.http", "mojoui.effects", "mojoui.sqlite", "mojoui.app", "flare"):
        if mod not in src:
            problems.append(f"tests/test_flare_link.mojo doesn't import {mod}")
    if problems:
        return False, "; ".join(problems)
    err = mojo_test("test_flare_link", "link: ok")
    return err is None, err or "flare v0.12.0 vendored; shims built; mojoui + flare link in one binary"


# ---------------------------------------------------------------------------------------------------------------- M1

def m1():
    """A Flare transport behind mojoui.http's Transport seam; test_http on both transports; HTTPS to Hugging Face;
    iOS and Android keep the socket transport."""
    problems = []
    import http_server
    with http_server.TestServer() as srv:  # (as goal 33's M1 runs it: the URL, a dead URL, the secret's value)
        for transport in ("socket", "flare"):
            err = mojo_test("test_http", "test_http: all passed", env={"MOJOUI_HTTP_TRANSPORT": transport, "HTTP_TEST_URL": srv.url,
                                                                      "HTTP_TEST_DEAD": srv.dead, "HTTP_TEST_SECRET": os.urandom(12).hex()})
            if err:
                problems.append(f"{transport}: {err[:400]}")
    err = mojo_test("test_https", "https: ok", timeout=300)
    if err:
        problems.append(err[:400])
    src = (ROOT / "mojoui/http.mojo").read_text() + "".join(p.read_text() for p in (ROOT / "mojoui").glob("http_*.mojo"))
    if "FlareTransport" not in src:
        problems.append("no FlareTransport in mojoui/http*.mojo")
    for example, host in (("kit", "ios"), ("todo", "android")):
        b = run(["scripts/build.sh", example, host], timeout=1800)
        if b.returncode != 0:
            problems.append(f"{example} {host} doesn't build: " + (b.stdout + b.stderr)[-300:])
    return not problems, "; ".join(problems) or "both transports pass test_http; HTTPS to Hugging Face; iOS + Android build on sockets"


# ---------------------------------------------------------------------------------------------------------------- M2

def m2():
    """mojoui.serve: test_serve, then from outside: curl reads a route and the OpenAI SDK streams a scripted chat."""
    err = mojo_test("test_serve", "serve: ok")
    if err:
        return False, err
    exe = BUILD / "serve_demo"
    err = mojo_build("tests/serve_demo.mojo", exe)
    if err:
        return False, err
    port = free_port()
    p = subprocess.Popen([str(exe), str(port)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        if not wait_port(port):
            return False, "serve_demo didn't listen: " + (p.stdout.read() if p.poll() is not None else "")[-300:]
        c = run(["curl", "-s", "-w", "\n%{http_code}", f"http://127.0.0.1:{port}/items/42?x=1"])
        body, _, code = c.stdout.rpartition("\n")
        if code != "200":
            return False, f"curl /items/42: {code} {body[:200]}"
        try:
            got = json.loads(body)
        except ValueError:
            return False, f"curl /items/42: not JSON: {body[:200]}"
        if got.get("id") != "42" or got.get("x") != "1":
            return False, f"curl /items/42?x=1: {got} (want id 42, x 1 from the path and query)"
        c = run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", f"http://127.0.0.1:{port}/nope"])
        if c.stdout != "404":
            return False, f"unknown route answered {c.stdout}, not 404"
        code = (f"from openai import OpenAI\nc = OpenAI(base_url='http://127.0.0.1:{port}/v1', api_key='k')\n"
                "s = c.chat.completions.create(model='demo', messages=[{'role': 'user', 'content': 'hi'}], stream=True)\n"
                "parts = [ch.choices[0].delta.content or '' for ch in s if ch.choices]\n"
                "print(len(parts), repr(''.join(parts)))\n")
        r = run(["pixi", "run", "python", "-c", code], timeout=60)
        if r.returncode != 0:
            return False, "OpenAI SDK stream failed: " + (r.stdout + r.stderr)[-500:]
        n, _, text = r.stdout.strip().partition(" ")
        if not n.isdigit() or int(n) < 3 or len(text) < 5:
            return False, f"OpenAI SDK read {r.stdout.strip()!r}: want ≥ 3 streamed pieces of words"
        return True, f"test_serve ok; curl read /items/42; the OpenAI SDK streamed {n} pieces: {text[:60]}"
    finally:
        p.terminate()


# ---------------------------------------------------------------------------------------------------------------- M3

def m3():
    err = mojo_test("test_process", "process: ok", timeout=300)
    return err is None, err or "mojoui.process: start, probe, crash tail, stop, idle stop"


# ---------------------------------------------------------------------------------------------------------------- M4/M5

def store_copy():
    """A consistent copy of the real ~/.mxc/mst.db (sqlite's backup API, read only) in a fresh MXC_HOME under build/."""
    home = G50 / "mxc"
    shutil.rmtree(home, ignore_errors=True)
    home.mkdir(parents=True)
    src = Path.home() / ".mxc" / "mst.db"
    if not src.exists():
        return None, "no ~/.mxc/mst.db to copy"
    a = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    b = sqlite3.connect(home / "mst.db")
    a.backup(b)
    a.close()
    b.close()
    return home, None


class Daemon:
    def __init__(self, home, extra=None):
        self.home, self.extra = home, extra or {}
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.admin = "g50-admin-" + os.urandom(4).hex()
        self.p = None

    def start(self):
        env = dict(os.environ, MXC_HOME=str(self.home), MXC_PORT=str(self.port), MXC_ADMIN_KEY=self.admin, **self.extra)
        self.log = open(G50 / "consoled.log", "a")
        self.p = subprocess.Popen([str(BUILD / "consoled")], cwd=ROOT, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        return wait_port(self.port, 30)

    def stop(self):
        if self.p and self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(15)
            except subprocess.TimeoutExpired:
                self.p.kill()
        self.p = None

    def call(self, method, path, body=None, admin=True, headers=None):
        h = dict(headers or {})
        if admin:
            h["X-Mst-Admin"] = self.admin
        return http(method, self.url + path, body, h)


def build_consoled():
    if (ROOT / "examples/consoled").exists() and list((ROOT / "examples/consoled").rglob("*.py")):
        return "examples/consoled has Python files"
    return mojo_build("examples/consoled/main.mojo", BUILD / "consoled")


def m4():
    """consoled answers the console's 18 recorded GETs with the original's shape from a copy of the real store; labels
    and keys persist across a restart, keys stored hashed; the console on GTK shows the store's models."""
    err = build_consoled()
    if err:
        return False, err
    home, err = store_copy()
    if err:
        return False, err
    manifest = json.loads((FIXTURES / "_manifest.json").read_text())["replies"]
    d = Daemon(home)
    problems = []
    try:
        if not d.start():
            return False, "consoled didn't listen: " + (G50 / "consoled.log").read_text()[-400:]
        st, _, _ = d.call("GET", "/admin/models", admin=False)
        if st not in (401, 403):
            problems.append(f"GET /admin/models without the admin key: {st}, not 401/403")
        for key, rec in manifest.items():
            method, target = key.split(" ", 1)
            st, body, hdr = d.call(method, target)
            if st != rec["status"]:
                problems.append(f"{key}: {st}, not {rec['status']}")
                continue
            if rec["type"].startswith("application/json"):
                try:
                    got = json.loads(body)
                except ValueError:
                    problems.append(f"{key}: not JSON")
                    continue
                want = json.loads((FIXTURES / rec["file"]).read_text())
                diff = shape_diff(want, got)
                if diff:
                    problems.append(f"{key}: " + ", ".join(diff[:3]))
            elif not hdr.get("Content-Type", "").startswith("text/plain"):
                problems.append(f"{key}: {hdr.get('Content-Type')}, not text/plain")
        # store's models are listed
        con = sqlite3.connect(home / "mst.db")
        names = sorted(r[0] for r in con.execute("select name from models"))
        con.close()
        st, body, _ = d.call("GET", "/admin/models")
        listed = sorted(m.get("name") for m in json.loads(body).get("models", [])) if st == 200 else []
        if names and listed != names:
            problems.append(f"/admin/models lists {listed[:5]}, the store has {names[:5]}")
        # writes
        label = "g50-" + os.urandom(2).hex()
        st, _, _ = d.call("POST", "/admin/labels", {"name": label})
        if st not in (200, 201):
            problems.append(f"POST /admin/labels: {st}")
        if names:
            d.call("POST", f"/admin/labels/{label}/add", {"models": names[:1]})
        st, body, _ = d.call("POST", "/admin/keys", {"app": "g50app"})
        secret = json.loads(body).get("key", "") if st in (200, 201) else ""
        if st not in (200, 201) or len(secret) < 20:
            problems.append(f"POST /admin/keys: {st} {body[:120]!r}")
        st, body, _ = d.call("POST", "/admin/keys/g50app/rotate")
        rotated = json.loads(body).get("key", "") if st == 200 else ""
        if not rotated or rotated == secret:
            problems.append(f"rotate: {st} {body[:120]!r}")
        d.call("POST", "/admin/keys", {"app": "g50gone"})
        st, _, _ = d.call("DELETE", "/admin/keys/g50gone")
        if st not in (200, 204):
            problems.append(f"DELETE /admin/keys/g50gone: {st}")
        d.stop()
        raw = b"".join(p.read_bytes() for p in home.glob("mst.db*"))
        for s in (secret, rotated):
            if s and s.encode() in raw:
                problems.append("a key's secret is in the store as plain text")
        import hashlib
        con = sqlite3.connect(home / "mst.db")
        row = con.execute("select key_hash from keys where app = 'g50app'").fetchone()
        con.close()
        if not row or row[0] != hashlib.sha256(rotated.encode()).hexdigest():
            problems.append("g50app's key_hash isn't the SHA-256 hex of its secret (the original's keys.py)")
        if not d.start():
            return False, "consoled didn't restart"
        st, body, _ = d.call("GET", "/admin/labels")
        if label not in body.decode(errors="replace"):
            problems.append(f"label {label} gone after a restart")
        st, body, _ = d.call("GET", "/admin/keys")
        txt = body.decode(errors="replace")
        try:
            rows = {k["app"]: k for k in json.loads(txt)}
        except (ValueError, TypeError, KeyError):
            rows = {}
        if rows.get("g50app", {}).get("status") != "active" or rows.get("g50gone", {}).get("status") != "revoked":
            problems.append("keys after a restart: want g50app active and g50gone revoked (the original revokes)")
        if problems:
            return False, "; ".join(problems[:8])
        # the console on GTK against it
        b = run(["scripts/build.sh", "console", "linux"], timeout=1800)
        if b.returncode != 0:
            return False, "console doesn't build: " + (b.stdout + b.stderr)[-300:]
        import headless
        headless.ensure()
        OUT.mkdir(parents=True, exist_ok=True)
        exe = BUILD / "console" / "linux" / "console"
        steps = {"models": "pause:2500", "keys": "pause:1500;tap:Keys;pause:2500"}
        if names:
            steps["overview"] = f"pause:1500;tap:{names[0]};pause:2500"
        for page, s in steps.items():
            shot = OUT / f"console-{page}-consoled-gtk.png"
            r = run([str(exe)], env={"MXC_URL": d.url, "MXC_ADMIN_KEY": d.admin, "MOJOUI_TEST": s,
                                     "MOJOUI_WINDOW": "1440x900", "MOJOUI_SHOT": str(shot)}, timeout=300)
            out = r.stdout + r.stderr
            if r.returncode != 0 or "TEST: " in out or not shot.exists():
                problems.append(f"console {page}: exit {r.returncode} {out[-200:]}")
                continue
            words = " ".join(l for l in out.splitlines() if l.startswith(("LABEL: ", "BUTTON: ")))
            if page == "models" and names and names[0] not in words:
                problems.append(f"console models page doesn't show {names[0]}")
            if page == "keys" and "g50app" not in words:
                problems.append("console keys page doesn't show g50app")
    finally:
        d.stop()
    return not problems, "; ".join(problems[:8]) or f"18 GETs in the original's shape; {len(names)} models from the store; labels + hashed keys persist; console shots in docs/goals/50"


def model_name(home):
    """The store's name for MODEL_REPO (the console's own name, e.g. qwen2.5-0.5b)."""
    con = sqlite3.connect(home / "mst.db")
    rows = list(con.execute("select * from models"))
    cols = [c[1] for c in con.execute("pragma table_info(models)")]
    con.close()
    for r in rows:
        row = dict(zip(cols, r))
        if MODEL_REPO.lower() in json.dumps(row, default=str).lower():
            return row.get("name")
    return None


def tree(pid):
    """(pid, command line) for pid and everything under it."""
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        try:
            cmd = Path(f"/proc/{p}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
        except OSError:
            continue
        out.append((p, cmd))
        kids = run(["pgrep", "-P", str(p)]).stdout.split()
        todo += [int(k) for k in kids]
    return out


def chat_through(d, name, key, seen=None):
    """The OpenAI SDK streams a chat from consoled; (pieces, text) or raises. `seen`: called once mid-stream."""
    code = (f"from openai import OpenAI\nc = OpenAI(base_url='{d.url}/v1', api_key='{key}')\n"
            f"s = c.chat.completions.create(model='{name}', messages=[{{'role': 'user', 'content': 'Say hello in five words.'}}], stream=True, max_tokens=40)\n"
            "parts = []\nfor ch in s:\n    parts.append(ch.choices[0].delta.content or '' if ch.choices else '')\n"
            "    if len(parts) == 3: print('MID', flush=True)\n"
            "print(len(parts), repr(''.join(parts)), flush=True)\n")
    p = subprocess.Popen(["pixi", "run", "python", "-c", code], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []
    for line in p.stdout:
        lines.append(line.rstrip())
        if line.startswith("MID") and seen:
            seen()
    p.wait(600)
    if p.returncode != 0:
        raise RuntimeError("OpenAI SDK: " + "\n".join(lines)[-500:])
    n, _, text = lines[-1].partition(" ")
    return int(n), text


_m5_state = {}


def m5():
    """max serve on mojoui.process behind consoled's /v1 gateway with a key check; the SDK streams; the request is
    logged and in metrics; idle unload stops the child."""
    err = build_consoled()
    if err:
        return False, err
    home, err = store_copy()
    if err:
        return False, err
    name = model_name(home)
    if not name:
        return False, f"the store has no model for {MODEL_REPO}"
    d = Daemon(home, {"MXC_IDLE_SECONDS": "45"})
    problems = []
    try:
        if not d.start():
            return False, "consoled didn't listen"
        st, body, _ = d.call("POST", "/admin/keys", {"app": "g50chat"})
        key = json.loads(body).get("key", "") if st in (200, 201) else ""
        if not key:
            return False, f"no key: {st} {body[:200]!r}"
        st, _, _ = http("GET", d.url + "/v1/models")
        if st != 401:
            problems.append(f"/v1/models without a key: {st}, not 401")
        st, body, _ = http("GET", d.url + "/v1/models", headers={"Authorization": f"Bearer {key}"})
        if st != 200 or name not in body.decode(errors="replace"):
            problems.append(f"/v1/models with a key: {st} {body[:200]!r}")
        snap = {}

        def seen():
            snap["tree"] = tree(d.p.pid)
        n, text = chat_through(d, name, key, seen)
        if n < 3 or len(text) < 5:
            problems.append(f"the SDK read {n} pieces {text!r}")
        _m5_state["tree"] = snap.get("tree", [])
        if not any("max" in c and "serve" in c for _, c in snap.get("tree", [])):
            problems.append("no `max serve` under consoled while the chat ran")
        st, body, _ = d.call("GET", "/admin/requests?limit=40")
        if st != 200 or name not in body.decode(errors="replace"):
            problems.append(f"/admin/requests doesn't show the chat: {st}")
        st, body, _ = d.call("GET", "/admin/metrics")
        if st != 200:
            problems.append(f"/admin/metrics: {st}")
        end = time.time() + 180
        while time.time() < end and any("serve" in c for _, c in tree(d.p.pid)[1:]):
            time.sleep(3)
        if any("serve" in c for _, c in tree(d.p.pid)[1:]):
            problems.append("max serve still running 180 s after the chat (idle 45 s)")
    except RuntimeError as e:
        problems.append(str(e))
    finally:
        d.stop()
    return not problems, "; ".join(problems) or f"{name}: 401 without a key; the SDK streamed {n} pieces {text[:50]}; logged; idle unload"


def m6():
    """No Python but max serve under consoled (M5's mid-chat tree) or the console; goal 48's M0 and goal 33's M5 pass;
    the matrix fresh with serve, process, the Flare transport."""
    problems = []
    if not _m5_state.get("tree"):
        ok, msg = m5()
        if not ok:
            return False, f"M5 first: {msg}"
    for pid, cmd in _m5_state["tree"]:
        if "python" in cmd.lower() and not ("max" in cmd and "serve" in cmd):
            problems.append(f"Python under consoled: {cmd[:120]}")
    exe = BUILD / "console" / "linux" / "console"
    if not exe.exists():
        problems.append("no console build (M4 first)")
    else:
        libs = run(["ldd", str(exe)]).stdout
        if "libpython" in libs:
            problems.append("the console links libpython")
    g48 = load("goal48", "docs/goals/48-check.py")
    ok, msg = g48.m0()
    if not ok:
        problems.append("48-M0: " + msg[:300])
    g33 = load("goal33", "docs/goals/33-check.py")
    ok, msg = g33.m5()
    if not ok:
        problems.append("33-M5: " + msg[:300])
    r = run(["pixi", "run", "python", "scripts/components.py", "--check"])
    if r.returncode != 0:
        problems.append("docs/components.md is stale")
    comp = (ROOT / "docs/components.md").read_text()
    for need in ("Serve", "Process", "FlareTransport"):
        if need not in comp:
            problems.append(f"docs/components.md has no {need}")
    return not problems, "; ".join(problems) or "no Python but max serve; 48-M0 and 33-M5 pass; the matrix is fresh"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M6", m6)]


def main():
    import headless
    headless.ensure()
    G50.mkdir(parents=True, exist_ok=True)
    only = sys.argv[1:]
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
