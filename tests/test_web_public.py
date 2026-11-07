"""The public copy's host rules (goal 62 round 3: each a finding of the round-3 review), on Jot's web build:

  fail closed:  a non-loopback HOST without MOJOUI_PUBLIC=1 doesn't start; MOJOUI_PUBLIC set to anything but 1 or 0
                doesn't start; public mode without prlimit doesn't start
  body limit:   a handler's own ValueError isn't swallowed; a chunked body past its route's limit gets 413, not 500
  sessions:     every session holds a place from the moment it's made (bare loads can't pass the cap); near the cap one
                address (X-Real-IP) can't take the last places; new sessions are rate-limited; a visit ends at the
                longest life; /resize isn't input, so it doesn't keep an idle tab alive
  uploads:      an upload without a length is refused; a visitor's uploads in flight are capped; uploads in flight
                reserve their length, so two at once can't pass the visitor's cap together; a table whose read size is
                past the per-table budget, or past the visitor's tables together, is refused in plain words

Run: pixi run python tests/test_web_public.py [build/jot/web]     Prints `web public: ok`.
"""

import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAV = {"Sec-Fetch-Dest": "document", "Sec-Fetch-Mode": "navigate"}


def load_web():
    spec = importlib.util.spec_from_file_location("web", ROOT / "mojoui/hosts/web.py")
    web = importlib.util.module_from_spec(spec)
    sys.modules["web"] = web
    spec.loader.exec_module(web)
    return web


def start(module_dir, env, seconds=40):
    """web.py as a server would start it: (exit code or None if it was still running after `seconds`, what it said)."""
    p = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), module_dir, "0"], cwd=ROOT, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        out, _ = p.communicate(timeout=seconds)
        return p.returncode, out
    except subprocess.TimeoutExpired:
        p.kill()
        out, _ = p.communicate()
        return None, out


def fail_closed(module_dir, d):
    base = {k: v for k, v in os.environ.items() if not k.startswith("MOJOUI_")}
    base.update(OMXCODE_UPLOADS=str(Path(d) / "fc-uploads"), JOT_DB=str(Path(d) / "fc.db"), JOT_HOME=d, CUDA_VISIBLE_DEVICES="")
    code, out = start(module_dir, dict(base, HOST="0.0.0.0"))
    assert code not in (None, 0) and "MOJOUI_PUBLIC" in out, f"a server on 0.0.0.0 without public mode started ({code}): {out[-300:]}"
    code, out = start(module_dir, dict(base, HOST="0.0.0.0", MOJOUI_PUBLIC="true"))
    assert code not in (None, 0) and "MOJOUI_PUBLIC" in out, f"MOJOUI_PUBLIC=true started a server ({code}): {out[-300:]}"
    empty = Path(d) / "empty-path"
    empty.mkdir(exist_ok=True)
    code, out = start(module_dir, dict(base, HOST="127.0.0.1", MOJOUI_PUBLIC="1", PATH=str(empty)))
    assert code not in (None, 0) and "prlimit" in out, f"public mode without prlimit started ({code}): {out[-300:]}"
    print("fail closed: ok (0.0.0.0 without public mode, MOJOUI_PUBLIC=true and public mode without prlimit each refuse to start)")


def body_limit(web):
    from starlette.testclient import TestClient

    async def boom(scope, receive, send):
        raise ValueError("the handler's own")

    try:
        TestClient(web.BodyLimit(boom, big=100)).post("/e/x", content=b"small")
        raise AssertionError("BodyLimit swallowed a handler's ValueError")
    except ValueError as e:
        assert "the handler's own" in str(e), e

    async def reader(scope, receive, send):
        while (await receive()).get("more_body"):
            pass
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"read"})

    def chunks():
        for _ in range(3):
            yield b"x" * (1 << 20)

    r = TestClient(web.BodyLimit(reader, big=100), raise_server_exceptions=False).post("/e/x", content=chunks())
    assert r.status_code == 413, f"a chunked body over 1 MB got {r.status_code}, not 413"
    r = TestClient(web.BodyLimit(reader, big=100)).post("/e/x", content=b"small")
    assert r.status_code == 200 and r.text == "read"
    print("body limit: ok (a handler's ValueError comes through; a chunked body past the limit gets 413)")


def page(client, ip="10.0.0.9", boot=False):
    """A page load from `ip` (X-Real-IP, as the platform's proxy sends it): (sid or None, the page)."""
    headers = {"X-Real-IP": ip} | ({} if boot else NAV)
    html = client.get("/?boot=1" if boot else "/", headers=headers).text
    m = re.search(r'data-sid="([0-9a-f]+)"', html)
    return (m.group(1) if m else None), html


def open_sessions(client):
    return client.get("/health").json()["sessions"]


def end_all(client, sids):
    for sid in sids:
        if sid:
            client.post(f"/bye/{sid}")


def wait_gone(client, sid, seconds):
    """The page's /wait until it says the session is gone ("" if it never did within `seconds`; WAIT_S is 1 s here)."""
    t0 = time.time()
    while time.time() - t0 < seconds:
        said = client.get(f"/wait/{sid}").text
        if said.startswith("gone"):
            return said
    return ""


def sessions_rules(web, module_dir):
    from starlette.testclient import TestClient

    web.MAX_SESSIONS, web.NEW_PER_S, web.IP_PER_S, web.PER_IP = 3, 1000.0, 1000.0, 99
    with TestClient(web.make_app(module_dir)) as client:
        # every session holds its place from the start: bare ?boot=1 loads (no page came back yet) count
        sids = [page(client, f"10.1.0.{i}", boot=True)[0] for i in range(3)]
        assert all(sids), "a bare load under the cap got no session"
        sid, html = page(client, "10.1.0.9")
        assert sid is None and "Busy right now" in html, "a fourth session was made past a cap of 3 (bare loads didn't count)"
        assert open_sessions(client) == 3, open_sessions(client)
        r = client.post(f"/e/{sids[0]}", content=(b"x" * (1 << 20) for _ in range(3)))
        assert r.status_code == 413, f"a chunked event body over 1 MB got {r.status_code} from the app, not 413"
        end_all(client, sids)
        # one address holds 2 places at most, at all times (round 4: near the cap only, it held 4 of 6); another still gets in
        web.MAX_SESSIONS, web.PER_IP = 6, 2
        mine = [page(client, "10.2.0.1")[0] for _ in range(3)]
        assert all(mine[:2]) and mine[2] is None, f"one address got {sum(1 for s in mine if s)} of 6 places (2 at most)"
        other, _ = page(client, "10.2.0.2")
        assert other, "another address was refused while places were free"
        end_all(client, mine + [other])
        # new sessions are rate-limited (the whole server and one address): a burst of loads makes a few, the rest wait
        web.NEW_PER_S, web.NEW_BURST, web.IP_PER_S = 0.2, 2.0, 1000.0
        web.reset_rates()
        got = [page(client, f"10.3.0.{i}") for i in range(6)]
        made = [s for s, _ in got if s]
        assert len(made) == 2 and all("Busy right now" in h for s, h in got if not s), f"{len(made)} of 6 rapid loads made a session (2 at most)"
        end_all(client, made)
    web.NEW_PER_S, web.NEW_BURST, web.IP_PER_S = 1000.0, 1000.0, 1000.0
    web.reset_rates()
    # a visit's longest life; /resize isn't input
    web.SESSION_MAX_S, web.IDLE_S, web.WAIT_S = 1.0, 900.0, 1.0
    with TestClient(web.make_app(module_dir)) as client:
        sid, _ = page(client, "10.4.0.1")
        said = wait_gone(client, sid, 6)
        assert said.startswith("gone") and "longest" in said, f"a session past its longest life: {said[:120]!r}"
    web.SESSION_MAX_S, web.IDLE_S = 0.0, 1.5
    with TestClient(web.make_app(module_dir)) as client:
        sid, _ = page(client, "10.4.0.2")
        for _ in range(10):
            client.post(f"/resize/{sid}", data={"w": str(900 + _), "h": "700"})
            time.sleep(0.4)
        said = wait_gone(client, sid, 1)
        assert said.startswith("gone"), f"/resize kept an idle tab alive: {said[:120]!r}"
    web.IDLE_S = 900.0
    print("sessions: ok (bare loads hold places; one address can't take the last ones; loads are rate-limited; a visit "
          "ends at its longest life; /resize isn't input)")


def picker(client, ip):
    sid, html = page(client, ip)
    v = re.search(r'id="mojoui-v"[^>]*value="(-?\d+)"|value="(-?\d+)"[^>]*id="mojoui-v"', html)
    pick = re.search(r'hx-post="/upload/' + sid + r'"[^>]*hx-vals=\'\{"n": (\d+)\}\'', html)
    assert pick, "no FilePicker on the page"
    return sid, int(v.group(1) or v.group(2)), int(pick.group(1))


def follow(html, sid, v, n):
    """The screen's version and the picker's node after an answer that changed the screen (as the page follows them)."""
    m = re.search(r'id="mojoui-v"[^>]*value="(-?\d+)"|value="(-?\d+)"[^>]*id="mojoui-v"', html)
    pick = re.search(r'hx-post="/upload/' + sid + r'"[^>]*hx-vals=\'\{"n": (\d+)\}\'', html)
    return (int(m.group(1) or m.group(2)) if m else v), (int(pick.group(1)) if pick else n)


def send(client, sid, v, n, name, body, out=None, key=None):
    r = client.post(f"/upload/{sid}", data={"n": str(n), "v": str(v)}, files=[("file", (name, body, "text/csv"))])
    if out is not None:
        out[key] = r
    return r


def uploads(web, module_dir, d):
    from starlette.testclient import TestClient

    # a stand-in for hosts/validate_main.mojo: says a table's read size from its first line, after a pause (a check takes time)
    fake = Path(d) / "validate"
    fake.write_text('#!/bin/sh\nsleep 1.5\nkb=$(head -c 40 "$1" | sed -n "s/^#kb=\\([0-9]*\\).*/\\1/p")\n'
                    'echo "10 rows, 2 columns, ${kb:-1} KB once read"\n')
    fake.chmod(0o755)
    os.environ["MOJOUI_VALIDATE"] = str(fake)
    os.environ["OMXCODE_VISITOR_MAX"] = str(10 << 20)
    web.TABLE_KB, web.VISITOR_TABLES_KB = 150_000, 200_000
    with TestClient(web.make_app(module_dir)) as client:
        sid, v, n = picker(client, "10.5.0.1")
        # an upload without a length (chunked) is refused before anything is read
        r = client.post(f"/upload/{sid}", content=(c for c in [b"--x\r\n"]), headers={"Content-Type": "multipart/form-data; boundary=x"})
        assert r.status_code == 411, f"an upload with no length got {r.status_code}"
        # a table past the per-table budget, then past the visitor's tables together
        r = send(client, sid, v, n, "big.csv", b"#kb=160000\na,b\n1,2\n")
        assert "one table" in r.text, f"a table over the per-table budget: {r.text[:200]}"
        r = send(client, sid, v, n, "first.csv", b"#kb=120000\na,b\n1,2\n")
        assert "wasn't" not in r.text, f"a table within both budgets was refused: {r.text[:200]}"
        v, n = follow(r.text, sid, v, n)  # (the pick changed Jot's screen)
        r = send(client, sid, v, n, "second.csv", b"#kb=120000\na,b\n1,2\n")
        assert "your tables" in r.text, f"a second table past the visitor's tables together: {r.text[:200]}"
        # in flight: two at once, each 6 MB under a 10 MB visitor cap: one is taken, the other refused for the cap
        sid, v, n = picker(client, "10.5.0.2")
        got, threads = {}, []
        body = b"#kb=1\n" + b"1,2\n" * ((6 << 20) // 4)
        for k in range(2):
            threads.append(threading.Thread(target=send, args=(client, sid, v, n, f"part{k}.csv", body, got, k)))
            threads[-1].start()
            time.sleep(0.2)
        for t in threads:
            t.join(60)
        refused = [k for k, r in got.items() if "would pass" in r.text]
        assert len(refused) == 1, f"two 6 MB uploads at once under a 10 MB cap: {len(refused)} refused ({[r.text[:80] for r in got.values()]})"
        # a third upload while two are in flight is refused at once
        sid, v, n = picker(client, "10.5.0.3")
        got, threads = {}, []
        for k in range(3):
            threads.append(threading.Thread(target=send, args=(client, sid, v, n, f"t{k}.csv", b"#kb=1\na,b\n", got, k)))
            threads[-1].start()
            time.sleep(0.3)
        for t in threads:
            t.join(60)
        assert "other uploads" in got[2].text, f"a third upload in flight: {got[2].status_code} {got[2].text[:160]}"
    print("uploads: ok (no length refused; 2 in flight at most; in-flight uploads reserve their length; per-table and "
          "per-visitor read budgets refuse in plain words)")


def round4(web, module_dir, d):
    """Round 4: an upload for no session is refused before its body is read; every upload in flight together is
    budgeted; X-Real-IP keys are valid addresses (IPv6 by its /64); a session no page came back to says so; BodyLimit's
    own answers carry the security headers."""
    from starlette.testclient import TestClient

    class Req:
        def __init__(self, peer):
            self.client = type("C", (), {"host": peer})()
    assert web.client_address(Req("127.0.0.1"), {"x-real-ip": "203.0.113.7"}) == "203.0.113.7"
    assert web.client_address(Req("127.0.0.1"), {"x-real-ip": "x" * 5000}) == "127.0.0.1", "a junk X-Real-IP became a key"
    a = web.client_address(Req("127.0.0.1"), {"x-real-ip": "2001:db8:1:2:aaaa::1"})
    b = web.client_address(Req("127.0.0.1"), {"x-real-ip": "2001:db8:1:2:bbbb::9"})
    assert a == b == "2001:db8:1:2::/64", (a, b)
    web.reset_rates()
    for i in range(20000):
        web.rate_ok(f"198.51.{i // 250}.{i % 250}")
    assert len(web.RATES) <= 10001, f"the address table grew to {len(web.RATES)}"
    web.reset_rates()
    web.MAX_SESSIONS, web.PER_IP, web.UNTOUCHED_S, web.WAIT_S = 6, 99, 1.0, 1.0
    web.UPLOADS_IN_FLIGHT = 8 << 20
    os.environ["OMXCODE_VISITOR_MAX"] = str(100 << 20)
    with TestClient(web.make_app(module_dir)) as client:
        t0 = time.time()
        r = client.post("/upload/" + "0" * 32, data={"n": "1", "v": "0"}, files=[("file", ("x.csv", b"a,b\n" * (4 << 20), "text/csv"))])
        assert "expired" in r.text and time.time() - t0 < 5, f"an upload for no session: {r.status_code} {r.text[:100]}"
        r = client.post("/e/x", content=(b"x" * (1 << 20) for _ in range(3)))
        assert r.status_code == 413 and r.headers.get("x-content-type-options"), f"413 without the security headers: {dict(r.headers)}"
        # two visitors' 6 MB uploads at once under an 8 MB server-wide budget: one is refused
        got, threads = {}, []
        for k in range(2):
            sid, v, n = picker(client, f"10.6.0.{k}")
            threads.append(threading.Thread(target=send, args=(client, sid, v, n, f"w{k}.csv", b"#kb=1\n" + b"1,2\n" * ((6 << 20) // 4), got, k)))
            threads[-1].start()
            time.sleep(0.2)
        for t in threads:
            t.join(60)
        assert sum(1 for r in got.values() if "other visitors' uploads" in r.text) == 1, [r.text[:80] for r in got.values()]
        # a session no page came back to ends in 1 s here, and says why truthfully
        sid, _ = page(client, "10.6.0.9", boot=True)
        time.sleep(2)
        said = client.get(f"/wait/{sid}").text
        assert "never came back" in said, f"an untouched session ended saying {said[:120]!r}"
    web.UNTOUCHED_S, web.UPLOADS_IN_FLIGHT = 45.0, 512 << 20
    os.environ["OMXCODE_VISITOR_MAX"] = str(10 << 20)
    print("round 4: ok (no-session upload refused at once; uploads in flight budgeted server-wide; address keys bounded, "
          "IPv6 by /64; an untouched session says why; 413 carries the security headers)")


def check_words(web, d):
    fake = Path(d) / "validate-bomb"
    fake.write_text('#!/bin/sh\necho "120000000 rows, 1 columns, 983040 KB once read"\n')
    fake.chmod(0o755)
    web.TABLE_KB = 256 << 10
    why, kb = web.check_upload(Path(d) / "bomb.parquet", str(fake))
    assert "one table" in why and kb >= 900_000, (why, kb)
    print(f"check_upload: ok ({why})")


def main():
    module_dir = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "build/jot/web")
    with tempfile.TemporaryDirectory() as d:
        fail_closed(module_dir, d)
        os.environ.update(MOJOUI_PUBLIC="1", OMXCODE_UPLOADS=str(Path(d) / "uploads"), JOT_DB=str(Path(d) / "jot.db"), JOT_HOME=d)
        web = load_web()
        (Path(d) / "bomb.parquet").write_bytes(b"PAR1")
        body_limit(web)
        check_words(web, d)
        sessions_rules(web, module_dir)
        uploads(web, module_dir, d)
        round4(web, module_dir, d)
    print("web public: ok")


if __name__ == "__main__":
    main()
