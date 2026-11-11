"""Goal 66's proof: the server-side ingredients a Finxplorer-class SaaS needs (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/66-check.py [M0 M1 ...]          (default: every milestone)

Stand-ins only (goal 60's Google, Stripe and SMTP from docs/goals/60-check.py, plus a made-up bank aggregator here):
nothing real is called. Truth is the SQLite files, the SMTP stand-in's messages, what comes back over HTTP and what
headless Chromium shows.

Contracts the code under test keeps (beyond goal 60's server contract):
  tests/static_server.mojo   STATIC_ROOT STATIC_PORT; serves the folder at /; prints "SAAS: listening <port>"
  tests/webhook_server.mojo  WH_DATA WH_PORT; /hooks/stripe (secret whsec_66), /hooks/hex (X-Signature: hex HMAC, secret
                             hex-66), /hooks/b64 (X-Signature: base64 HMAC, secret b64-66), /hooks/svix (Standard
                             Webhooks, secret whsec_<base64 of "svix-66-secret">); a job per new event records
                             processed(source, event, attempts) in host.db; a body holding "fail_once" fails its first try
  tests/schedule_proc.mojo   SCHED_DATA SCHED_T0 SCHED_REAL0 SCHED_SPEED SCHED_RUN_MS: "*/10 * * * *" in America/New_York
                             on a fake clock (t0 + (now - real0) * speed); a run sleeps SCHED_RUN_MS then writes
                             done(slot UNIQUE, catchup) in sched.db
  examples/finance_min       goal 60's env plus SAAS_OPERATORS (emails), SAAS_CONTACT_TO, SAAS_CONTACT_RATE (a minute per
                             client), BANK_API BANK_CLIENT_ID BANK_CLIENT_SECRET BANK_WEBHOOK_SECRET (whsec_…),
                             FIN_DIGEST (schedule text, default "every Monday 08:00"); routes: / /contact /sitemap.xml
                             /robots.txt /manifest.webmanifest /sw.js /app (static JS front end) /health /webhooks/bank
                             /api/bank/connect /api/bank/sync /api/spending /api/transactions /api/transactions/{id}
                             /api/transactions.csv /operator/api/tenants /operator/api/log /operator/api/tenants/{id}/snapshot
"""
import base64
import csv
import gzip
import hashlib
import hmac
import importlib.util
import io
import json
import os
import re
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g66"
FIN = ROOT / "build/finance_min/server"
sys.path.insert(0, str(ROOT / "scripts"))

_spec = importlib.util.spec_from_file_location("g60check", ROOT / "docs/goals/60-check.py")
g60 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(g60)
run, free_port, wait_until, StandIn, Smtp, sign_in = g60.run, g60.free_port, g60.wait_until, g60.StandIn, g60.Smtp, g60.sign_in
g60.OUT = OUT  # (servers' data folders under build/g66)


def mojo_build(src, exe, timeout=2400):
    exe = Path(exe)
    exe.parent.mkdir(parents=True, exist_ok=True)
    b = run(["scripts/mojo_flare.sh", "build", src, "-o", str(exe)], timeout)
    return (b.returncode == 0 and exe.exists()), (b.stdout + b.stderr)[-1500:]


def mojo_test(src, labels, timeout=2400, env=None):
    exe = OUT / "bin" / Path(src).stem
    ok, why = mojo_build(src, exe, timeout)
    if not ok:
        return False, why
    r = run([str(exe)], timeout, env)
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), (f"missing {missing} " if missing else "") + out[-700:]


class Proc:
    """A test server: started with env, waits for "SAAS: listening"."""

    def __init__(self, exe, env, name):
        self.outf = OUT / f"{name}.out"
        self.out = open(self.outf, "a")
        mark = self.outf.stat().st_size
        self.p = subprocess.Popen([str(exe)], cwd=ROOT, env=dict(os.environ, **env), stdout=self.out, stderr=subprocess.STDOUT)
        fresh = lambda: self.outf.read_bytes()[mark:].decode("utf-8", "replace")  # noqa: E731
        wait_until(lambda: "SAAS: listening" in fresh() or self.p.poll() is not None, 60)
        if self.p.poll() is not None or "SAAS: listening" not in fresh():
            raise RuntimeError(f"{name} didn't start: " + fresh()[-1200:])

    def stop(self, sig=signal.SIGTERM):
        if self.p.poll() is None:
            self.p.send_signal(sig)
            try:
                self.p.wait(10)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
        self.out.close()


def raw_get(port, target, headers=""):
    """A request line sent as written (httpx would normalise `..`): (status, head, body)."""
    s = socket.create_connection(("127.0.0.1", port), 10)
    s.sendall(f"GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n{headers}\r\n".encode())
    data = b""
    while True:
        b = s.recv(65536)
        if not b:
            break
        data += b
    s.close()
    head, _, body = data.partition(b"\r\n\r\n")
    m = re.match(rb"HTTP/1\.[01] (\d+)", head)
    return (int(m.group(1)) if m else 0), head.decode("latin-1"), body


def chromium():
    from playwright.sync_api import sync_playwright
    pw = sync_playwright().start()
    br = pw.chromium.launch(executable_path="/usr/bin/chromium", headless=True)
    return pw, br


# ---------------------------------------------------------------- M0 static files

def m0():
    ok, why = mojo_test("tests/test_static.mojo", ["types", "etag", "hashed", "gzip", "range", "refuse"])
    if not ok:
        return False, "tests/test_static.mojo: " + why
    exe = OUT / "bin/static_server"
    ok, why = mojo_build("tests/static_server.mojo", exe)
    if not ok:
        return False, "tests/static_server.mojo didn't build: " + why
    site = OUT / "m0/site"
    shutil.rmtree(OUT / "m0", ignore_errors=True)
    (site / "media").mkdir(parents=True)
    (OUT / "m0/outside.txt").write_text("outside the folder")
    (site / "index.html").write_text('<!doctype html><html><head><meta charset="utf-8"><title>m0</title>'
                                     '<link rel="stylesheet" href="/style.css"><script src="/app.js" defer></script></head>'
                                     '<body><h1 id="h">Static files</h1></body></html>')
    js = "document.body.dataset.js = 'ran'; document.title = 'm0 ran';\n" + "// padding so gzip pays\n" * 200
    (site / "app.js").write_text(js)
    (site / "style.css").write_text("@font-face { font-family: Mojo66; src: url(/font.woff2) format('woff2'); }\n"
                                    "body { color: rgb(1, 2, 3); font-family: Mojo66, sans-serif; }\n")
    shutil.copy(ROOT / "docs/omxqua/fonts/geist-variable.woff2", site / "font.woff2")
    media = os.urandom(300_000)
    (site / "media/clip.mp4").write_bytes(media)
    (site / ".env").write_text("SECRET=1")
    (site / "leak.txt").symlink_to(OUT / "m0/outside.txt")
    port = free_port()
    p = Proc(exe, {"STATIC_ROOT": str(site), "STATIC_PORT": str(port)}, "m0-static")
    try:
        base = f"http://127.0.0.1:{port}"
        c = httpx.Client(base_url=base, timeout=20)
        r = c.get("/app.js")
        if r.status_code != 200 or not r.headers.get("content-type", "").startswith("text/javascript"):
            return False, f"/app.js: {r.status_code} {r.headers.get('content-type')}"
        types = {"/style.css": "text/css", "/font.woff2": "font/woff2", "/media/clip.mp4": "video/mp4", "/": "text/html"}
        for path, t in types.items():
            got = c.get(path, headers={"Range": "bytes=0-0"} if path.endswith("mp4") else {}).headers.get("content-type", "")
            if not got.startswith(t):
                return False, f"{path}'s Content-Type is {got!r}, not {t}"
        etag = r.headers.get("etag")
        if not etag or c.get("/app.js", headers={"If-None-Match": etag}).status_code != 304:
            return False, f"no 304 for the ETag {etag!r}"
        if c.get("/app.js", headers={"If-None-Match": '"other"'}).status_code != 200:
            return False, "a stale ETag got a 304"
        h10 = hashlib.sha256(js.encode()).hexdigest()[:10]
        hr = c.get(f"/app.{h10}.js")
        cc = hr.headers.get("cache-control", "")
        if hr.status_code != 200 or "max-age=31536000" not in cc or "immutable" not in cc or hr.text != js:
            return False, f"the hashed URL /app.{h10}.js: {hr.status_code} {cc!r}"
        if c.get("/app.0123456789.js").status_code != 404:
            return False, "a wrong content hash was served"
        if "max-age=31536000" in c.get("/app.js").headers.get("cache-control", ""):
            return False, "the plain URL is cached a year"
        gz = c.get("/app.js", headers={"Accept-Encoding": "gzip"})
        if gz.headers.get("content-encoding") != "gzip" or gz.text != js or int(gz.headers.get("content-length", "0")) >= len(js):
            return False, f"gzip: {gz.headers.get('content-encoding')} length {gz.headers.get('content-length')} vs {len(js)}"
        if "accept-encoding" not in gz.headers.get("vary", "").lower():
            return False, "a gzipped reply lacks Vary: Accept-Encoding"
        st, head, body = raw_get(port, "/app.js", "Accept-Encoding: gzip, br\r\n")
        if st != 200 or "chunked" in head.lower() or gzip.decompress(body).decode() != js:
            return False, "the raw gzip body doesn't inflate to the file"
        if c.get("/app.js", headers={"Accept-Encoding": "identity"}).headers.get("content-encoding"):
            return False, "gzip without Accept-Encoding"
        rg = c.get("/media/clip.mp4", headers={"Range": "bytes=1000-1999"})
        if rg.status_code != 206 or rg.content != media[1000:2000] or rg.headers.get("content-range") != f"bytes 1000-1999/{len(media)}":
            return False, f"Range: {rg.status_code} {rg.headers.get('content-range')} {len(rg.content)} bytes"
        tail = c.get("/media/clip.mp4", headers={"Range": "bytes=-500"})
        if tail.status_code != 206 or tail.content != media[-500:]:
            return False, f"a suffix Range: {tail.status_code}"
        if c.get("/media/clip.mp4", headers={"Range": f"bytes={len(media) + 10}-"}).status_code != 416:
            return False, "an unsatisfiable Range isn't 416"
        if "bytes" not in c.get("/media/clip.mp4").headers.get("accept-ranges", ""):
            return False, "no Accept-Ranges: bytes"
        refused = ["/../outside.txt", "/%2e%2e/outside.txt", "/media/../../outside.txt", "/.env", "/%2eenv", "/leak.txt",
                   "//etc/passwd", "/%2fetc%2fpasswd", "/media/%2e%2e/%2e%2e/outside.txt", "/app.js%00.txt", "/media/..%2f..%2foutside.txt"]
        for t in refused:
            st, _, body = raw_get(port, t)
            if st != 404 or b"outside the folder" in body or b"SECRET" in body or b"root:" in body:
                return False, f"{t} answered {st}"
        pw, br = chromium()
        try:
            page = br.new_page()
            failed = []
            page.on("requestfailed", lambda rq: failed.append(rq.url))
            page.on("response", lambda rs: failed.append(rs.url) if rs.status >= 400 else None)
            page.goto(base + "/")
            page.wait_for_function("document.body.dataset.js === 'ran'", timeout=10000)
            color = page.evaluate("getComputedStyle(document.body).color")
            font = page.evaluate("document.fonts.ready.then(() => document.fonts.check('16px Mojo66'))")
            loaded = page.evaluate("[...document.fonts].filter(f => f.family === 'Mojo66' && f.status === 'loaded').length")
        finally:
            br.close()
            pw.stop()
        if color != "rgb(1, 2, 3)" or not font or loaded < 1 or failed:
            return False, f"Chromium: color {color}, font {font}/{loaded}, failed {failed}"
        return True, (f"tests/test_static.mojo ok; types, ETag 304, /app.{h10}.js a year immutable (a wrong hash 404), gzip "
                      f"{gz.headers.get('content-length')}<{len(js)} B with Vary, Range 206/suffix/416, {len(refused)} escapes 404 "
                      f"(.., %2e%2e, dotfile, symlink out, absolute, NUL); Chromium ran the JS, styled rgb(1, 2, 3), loaded the font")
    finally:
        p.stop()


# ---------------------------------------------------------------- M1 webhooks

WH_SECRETS = {"stripe": "whsec_66", "hex": "hex-66", "b64": "b64-66", "svix": "whsec_" + base64.b64encode(b"svix-66-secret").decode()}


def wh_sign(scheme, body, eid, age=0, secret=None):
    """Headers for `body` signed the way each scheme's sender signs (written here from each scheme's documentation)."""
    secret = secret or WH_SECRETS[scheme]
    ts = str(int(time.time()) - age)
    if scheme == "stripe":
        sig = hmac.new(secret.encode(), f"{ts}.".encode() + body, hashlib.sha256).hexdigest()
        return {"Stripe-Signature": f"t={ts},v1={sig}", "Content-Type": "application/json"}
    if scheme == "hex":
        return {"X-Signature": hmac.new(secret.encode(), body, hashlib.sha256).hexdigest(), "Content-Type": "application/json"}
    if scheme == "b64":
        return {"X-Signature": base64.b64encode(hmac.new(secret.encode(), body, hashlib.sha256).digest()).decode(), "Content-Type": "application/json"}
    key = base64.b64decode(secret.removeprefix("whsec_"))
    sig = base64.b64encode(hmac.new(key, f"{eid}.{ts}.".encode() + body, hashlib.sha256).digest()).decode()
    return {"webhook-id": eid, "webhook-timestamp": ts, "webhook-signature": f"v1,{sig}", "Content-Type": "application/json"}


def m1():
    ok, why = mojo_test("tests/test_webhooks.mojo", ["stripe", "hex", "b64", "svix", "window", "once", "cap"])
    if not ok:
        return False, "tests/test_webhooks.mojo: " + why
    ok, why = mojo_test("tests/test_billing.mojo", [])
    if not ok:
        return False, "mojoui.billing's Stripe path (tests/test_billing.mojo): " + why
    exe = OUT / "bin/webhook_server"
    ok, why = mojo_build("tests/webhook_server.mojo", exe)
    if not ok:
        return False, "tests/webhook_server.mojo didn't build: " + why
    data = OUT / "m1"
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)
    port = free_port()
    p = Proc(exe, {"WH_DATA": str(data), "WH_PORT": str(port)}, "m1-webhooks")
    try:
        c = httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=20)
        db = lambda: sqlite3.connect(data / "host.db")  # noqa: E731
        processed = lambda src, eid: db().execute("SELECT attempts FROM processed WHERE source = ? AND event = ?", (src, eid)).fetchall()  # noqa: E731
        notes = []
        for scheme in ("stripe", "hex", "b64", "svix"):
            eid = f"evt_{scheme}_{secrets.token_hex(4)}"
            body = json.dumps({"id": eid, "type": "thing.happened", "data": {"n": 1}}).encode()
            h = wh_sign(scheme, body, eid)
            r = c.post(f"/hooks/{scheme}", content=body, headers=h)
            if r.status_code != 200:
                return False, f"{scheme}: a good signature answered {r.status_code} {r.text[:200]}"
            if not wait_until(lambda: processed(scheme, eid), 15):
                return False, f"{scheme}: the event was never processed by a job"
            again = c.post(f"/hooks/{scheme}", content=body, headers=wh_sign(scheme, body, eid))
            time.sleep(1.0)
            n = db().execute("SELECT count(*) FROM webhook_events WHERE source = ? AND id = ?", (scheme, eid)).fetchone()[0]
            if again.status_code != 200 or n != 1 or len(processed(scheme, eid)) != 1 or processed(scheme, eid)[0][0] != 1:
                return False, f"{scheme}: a replay answered {again.status_code}, {n} log rows, processed {processed(scheme, eid)}"
            bad = dict(h)
            k = next(k for k in bad if k.lower() in ("stripe-signature", "x-signature", "webhook-signature"))
            bad[k] = bad[k][:-6] + ("AAAAAA" if scheme in ("b64", "svix") else "000000")
            if c.post(f"/hooks/{scheme}", content=body, headers=bad).status_code != 401:
                return False, f"{scheme}: a bad signature wasn't 401"
            other = wh_sign(scheme, body, eid, secret=("whsec_" + base64.b64encode(b"wrong").decode()) if scheme == "svix" else "wrong")
            if c.post(f"/hooks/{scheme}", content=body, headers=other).status_code != 401:
                return False, f"{scheme}: another secret's signature wasn't 401"
            tampered = body.replace(b'"n": 1', b'"n": 2')
            if c.post(f"/hooks/{scheme}", content=tampered, headers=wh_sign(scheme, body, eid)).status_code != 401:
                return False, f"{scheme}: a changed body passed"
            if scheme in ("stripe", "svix"):
                eid2 = eid + "_old"
                b2 = body.replace(eid.encode(), eid2.encode())
                old = c.post(f"/hooks/{scheme}", content=b2, headers=wh_sign(scheme, b2, eid2, age=600))
                fut = c.post(f"/hooks/{scheme}", content=b2, headers=wh_sign(scheme, b2, eid2, age=-600))
                if old.status_code != 400 or fut.status_code != 400 or processed(scheme, eid2):
                    return False, f"{scheme}: a 10-minute-old signature answered {old.status_code}, a future one {fut.status_code}"
            notes.append(scheme)
        eid = "evt_retry_" + secrets.token_hex(4)
        body = json.dumps({"id": eid, "type": "fail_once"}).encode()
        if c.post("/hooks/hex", content=body, headers=wh_sign("hex", body, eid)).status_code != 200:
            return False, "the retry event was refused"
        got = wait_until(lambda: processed("hex", eid), 30)
        if not got or got[0][0] != 2:
            return False, f"a failing first try wasn't retried once: {got}"
        big = b'{"id": "evt_big", "pad": "' + b"x" * (1024 * 1024) + b'"}'
        r = c.post("/hooks/hex", content=big, headers=wh_sign("hex", big, "evt_big"))
        if r.status_code != 413:
            return False, f"a body over 1 MB answered {r.status_code}"
        if c.post("/hooks/hex", content=b"{}", headers=wh_sign("hex", b"{}", "")).status_code != 400:
            return False, "an event without an id wasn't 400"
        if c.post("/hooks/svix", content=b"{}", headers={"Content-Type": "application/json"}).status_code != 401:
            return False, "an unsigned event wasn't 401"
        return True, (f"tests/test_webhooks.mojo + test_billing.mojo ok; over HTTP {', '.join(notes)}: a good signature 200 → one job → "
                      "processed once; a replay 200 without effect; a bad / other-secret / changed-body signature 401; 10 minutes "
                      "old or ahead 400; a failing first try retried (2 attempts); > 1 MB 413; no id 400")
    finally:
        p.stop()


# ---------------------------------------------------------------- M2 API client

def m2():
    ok, why = mojo_test("tests/test_apiclient.mojo", ["bearer", "basic", "pages", "retry_after", "backoff", "refresh", "timeout", "graphql_error"])
    if not ok:
        return False, "tests/test_apiclient.mojo: " + why
    return True, "tests/test_apiclient.mojo against its in-process stand-in server: " + _oks(why)


def _oks(out):
    return "; ".join(f"{m.group(1)} {m.group(2).strip()}".strip() for m in re.finditer(r"^(\w+): ok(.*)$", out, re.M))[:900]


# ---------------------------------------------------------------- M3 schedules

def m3():
    ok, why = mojo_test("tests/test_schedule.mojo", ["cron", "words", "tz", "spring", "autumn", "wildcard", "catchup"])
    if not ok:
        return False, "tests/test_schedule.mojo: " + why
    unit = _oks(why)
    exe = OUT / "bin/schedule_proc"
    ok, why = mojo_build("tests/schedule_proc.mojo", exe)
    if not ok:
        return False, "tests/schedule_proc.mojo didn't build: " + why
    data = OUT / "m3"
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)
    t0 = 1_772_323_200  # 2026-03-01 00:00 UTC (fake clock start); 10 fake minutes a real second
    env = {"SCHED_DATA": str(data), "SCHED_T0": str(t0), "SCHED_REAL0": f"{time.time():.3f}", "SCHED_SPEED": "600", "SCHED_RUN_MS": "700"}
    db = lambda: sqlite3.connect(data / "sched.db")  # noqa: E731
    host = lambda: sqlite3.connect(data / "host.db")  # noqa: E731
    fake = lambda: t0 + (time.time() - float(env["SCHED_REAL0"])) * 600  # noqa: E731
    p = Proc(exe, env, "m3-sched")
    try:
        time.sleep(4)
        running = wait_until(lambda: host().execute("SELECT id, payload FROM jobs WHERE status = 'running'").fetchall(), 10, 0.02)
        if not running:
            return False, "no run was ever seen running"
        killed_slot = json.loads(running[0][1])["slot"]
        p.stop(signal.SIGKILL)
        killed_at = fake()
        time.sleep(0.3)
        p = Proc(exe, env, "m3-sched")
        time.sleep(4)
        p.stop()
        down_from = fake()
        time.sleep(5)  # ~50 fake minutes: five slots missed
        down_to = fake()
        p = Proc(exe, env, "m3-sched")
        time.sleep(3)
        p.stop()
        done = db().execute("SELECT slot, catchup FROM done ORDER BY slot").fetchall()
        jobs = host().execute("SELECT payload FROM jobs").fetchall()
        slots = [json.loads(j[0])["slot"] for j in jobs]
        dup = {s for s in slots if slots.count(s) > 1}
        if dup:
            return False, f"a slot was queued twice: {sorted(dup)[:3]}"
        done_slots = [d[0] for d in done]
        if len(done_slots) != len(set(done_slots)):
            return False, "a slot ran twice"
        if killed_slot not in done_slots:
            return False, f"the slot killed mid-run ({killed_slot}) was lost"
        pend = host().execute("SELECT count(*) FROM jobs WHERE status != 'done'").fetchone()[0]
        if pend:
            return False, f"{pend} jobs never finished"
        ups = db().execute("SELECT count(*) FROM done WHERE catchup = 1").fetchone()[0]
        down_slots = [s for s in done_slots if down_from + 1 < _slot_epoch(s) < down_to - 1]
        if len(down_slots) != 1 or ups < 1:
            return False, f"downtime of {int((down_to - down_from) / 60)} fake minutes caught up as {down_slots} ({ups} catch-ups)"
        gaps = _gaps(done_slots, down_from, down_to, killed_at)
        if gaps:
            return False, f"slots missing while running: {gaps[:3]}"
        return True, (f"tests/test_schedule.mojo ok ({unit}); a process on a fake clock: {len(done_slots)} slots each run once, the run "
                      f"killed -9 at {killed_slot} finished after the restart (no slot queued twice), {int((down_to - down_from) / 600)} "
                      f"slots missed in downtime caught up once ({down_slots[0]})")
    finally:
        p.stop()


def _slot_epoch(slot):
    """The schedule's slot key is the slot's UTC instant as ISO text (2026-03-01T05:10:00Z)."""
    import datetime as dt
    return dt.datetime.strptime(slot, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()


def _gaps(slots, down_from, down_to, killed_at):
    ep = sorted(_slot_epoch(s) for s in slots)
    out = []
    for a, b in zip(ep, ep[1:]):
        if b - a > 600 and not (a <= down_to and b >= down_from) and not (a - 1200 <= killed_at <= b + 1200):
            out.append((a, b))
    return out


# ---------------------------------------------------------------- M4 bulk data

def m4():
    csv_out = OUT / "m4.csv"
    csv_out.unlink(missing_ok=True)
    ok, why = mojo_test("tests/test_bulk.mojo", ["upsert", "keep_edited", "one_tx", "speed", "csv_quote", "csv_guard", "csv_stream"],
                        env={"BULK_CSV_OUT": str(csv_out), "BULK_DIR": str(OUT / "m4")})
    if not ok:
        return False, "tests/test_bulk.mojo: " + why
    ms = re.search(r"^speed: ok (\d+) ms", why, re.M)
    if not ms or int(ms.group(1)) >= 2000:
        return False, f"100k rows took {ms.group(1) if ms else '?'} ms"
    rows = list(csv.reader(io.StringIO(csv_out.read_text(newline=""), newline="")))
    want = {"1": "plain", "2": 'a "quoted", comma', "3": "two\nlines", "4": "'=HYPERLINK(\"http://x\")", "5": "'+1", "6": "'-2", "7": "'@sum", "8": "-3.5"}
    got = {r[0]: r[1] for r in rows[1:]}
    if rows[0] != ["id", "text"] or any(got.get(k) != v for k, v in want.items()):
        return False, f"the streamed CSV read back by Python's csv: {rows[:9]}"
    return True, f"tests/test_bulk.mojo ok ({_oks(why)}); Python's csv reads the streamed file back with quotes, commas, newlines and the =+-@ guard"


# ---------------------------------------------------------------- finance_min (M5, M6, M7, M9)

_fin_built = False


def fin_build():
    global _fin_built
    if not _fin_built:
        ok, why = mojo_build("examples/finance_min/server.mojo", FIN)
        if not ok:
            raise RuntimeError("examples/finance_min didn't build: " + why)
        _fin_built = True


def fin(name, stand, smtp=None, extra=None, keep=False, expect_fail=False):
    fin_build()
    return g60.Server(name, stand, smtp, extra, keep=keep, expect_fail=expect_fail, exe=FIN)


def mail_text(m):
    """A message's decoded text parts (its raw form is base64 or quoted-printable)."""
    return "\n".join(str(p.get_content()) for p in m.walk() if p.get_content_type() in ("text/plain", "text/html")) + "\n" + str(m["Subject"])


def csrf_of(page):
    m = re.search(r'name="csrf" value="([^"]+)"', page)
    return m.group(1) if m else ""


def m5():
    ok, why = mojo_test("tests/test_pages.mojo", ["escape", "sitemap", "robots", "csrf", "manifest"])
    if not ok:
        return False, "tests/test_pages.mojo: " + why
    stand, smtp = StandIn(), Smtp()
    srv = fin("m5", stand, smtp, {"SAAS_CONTACT_TO": "owner@saas.example", "SAAS_CONTACT_RATE": "5"})
    try:
        c = srv.client()
        home = c.get("/")
        if home.status_code != 200 or "text/html" not in home.headers.get("content-type", "") or "where your money goes" not in home.text:
            return False, f"the landing page: {home.status_code} {home.text[:200]}"
        sm = c.get("/sitemap.xml")
        locs = re.findall(r"<loc>([^<]+)</loc>", sm.text)
        if "xml" not in sm.headers.get("content-type", "") or srv.base + "/" not in locs or srv.base + "/contact" not in locs:
            return False, f"sitemap.xml: {sm.headers.get('content-type')} {locs}"
        rb = c.get("/robots.txt").text
        if f"Sitemap: {srv.base}/sitemap.xml" not in rb or "Disallow: /api/" not in rb or "Disallow: /operator/" not in rb:
            return False, f"robots.txt: {rb!r}"
        mf = c.get("/manifest.webmanifest")
        mj = mf.json()
        if mf.headers.get("content-type", "").split(";")[0] != "application/manifest+json" or not mj.get("name") or mj.get("start_url") != "/app" or not mj.get("icons"):
            return False, f"the manifest: {mf.headers.get('content-type')} {mj}"
        sw = c.get("/sw.js")
        if sw.headers.get("content-type", "").split(";")[0] != "text/javascript" or "no-cache" not in sw.headers.get("cache-control", "") or sw.headers.get("service-worker-allowed") != "/":
            return False, f"sw.js: {sw.headers}"
        form = c.get("/contact")
        tok = csrf_of(form.text)
        if not tok or 'name="website"' not in form.text:
            return False, "the contact form lacks its CSRF token or honeypot"
        msg = {"name": "Ben <b>", "email": "ben@example.com", "message": "Hello from the form 66", "website": "", "csrf": tok}
        hdr = {"Origin": srv.base}
        if c.post("/contact", data=dict(msg, csrf="forged"), headers=hdr).status_code != 403:
            return False, "a forged CSRF token wasn't 403"
        if httpx.post(srv.base + "/contact", data=msg, headers=hdr, timeout=20).status_code != 403:
            return False, "a token without its cookie wasn't 403"
        if c.post("/contact", data=msg, headers={"Origin": "https://evil.example"}).status_code != 403:
            return False, "another site's POST wasn't 403"
        r = c.post("/contact", data=msg, headers=hdr)
        if r.status_code not in (200, 303):
            return False, f"the contact POST answered {r.status_code} {r.text[:200]}"
        got = wait_until(lambda: smtp.to("owner@saas.example"), 20)
        if not got or "Hello from the form 66" not in mail_text(got[0]) or "ben@example.com" not in mail_text(got[0]):
            return False, f"the message never reached SMTP: {got}"
        tok = csrf_of(c.get("/contact").text)
        c.post("/contact", data=dict(msg, csrf=tok, website="http://spam.example", message="SPAM 66"), headers=hdr)
        time.sleep(3)
        if any("SPAM 66" in mail_text(m) for m in smtp.to("owner@saas.example")):
            return False, "the honeypot's message was sent"
        codes = []
        for _ in range(6):
            tok = csrf_of(c.get("/contact").text)
            codes.append(c.post("/contact", data=dict(msg, csrf=tok, message="burst"), headers=hdr).status_code)
        if 429 not in codes:
            return False, f"no rate limit on the form: {codes}"
        pw, br = chromium()
        try:
            ctx = br.new_context(java_script_enabled=False)
            pg = ctx.new_page()
            pg.goto(srv.base + "/")
            text = pg.inner_text("body")
            ctx.close()
            pg = br.new_page()
            pg.goto(srv.base + "/")
            scope = pg.evaluate("navigator.serviceWorker.register('/sw.js').then(() => navigator.serviceWorker.ready).then(r => r.scope)")
        finally:
            br.close()
            pw.stop()
        if "where your money goes" not in text:
            return False, f"with JS off the page has no text: {text[:200]!r}"
        if scope != srv.base + "/":
            return False, f"the service worker's scope: {scope}"
        return True, (f"tests/test_pages.mojo ok; landing, sitemap ({len(locs)} URLs), robots, manifest and sw.js with their headers; "
                      f"contact: forged / cookieless / cross-site 403, delivered through mojoui.mail, honeypot dropped, burst {codes}; "
                      f"Chromium with JS off reads the text; the service worker registers at {scope}")
    finally:
        srv.stop()
        stand.close()
        smtp.close()


OPS = "op@saas.example"


def m6():
    stand, smtp = StandIn(), Smtp()
    srv = fin("m6", stand, smtp, {"SAAS_OPERATORS": f"{OPS}, second-op@saas.example"})
    try:
        ada, _ = sign_in(srv, stand, ("ada@example.com", "Ada"))
        ada.post("/api/transactions", json={"date": "2026-11-01", "amount": -12.5, "merchant": "Cafe", "category": "Food"})
        ben, _ = sign_in(srv, stand, ("ben@example.com", "Ben"))
        op, _ = sign_in(srv, stand, (OPS, "Op"))
        tenant = ada.get("/api/me").json()["tenant"]
        anon = srv.client()
        for who, cl in (("anonymous", anon), ("a tenant admin", ada), ("another tenant's admin", ben)):
            for path in ("/operator/api/tenants", "/operator/api/log", f"/operator/api/tenants/{tenant}/snapshot"):
                st = cl.get(path).status_code
                if st not in (401, 403):
                    return False, f"{who} reached {path}: {st}"
        r = op.get("/operator/api/tenants")
        rows = r.json().get("tenants", []) if r.status_code == 200 else []
        mine = [t for t in rows if t.get("id") == tenant]
        if not mine or "plan" not in mine[0] or not mine[0].get("last_activity") or len(rows) < 3:
            return False, f"the operator's tenant list: {r.status_code} {r.text[:300]}"
        lg = op.get("/operator/api/log", params={"path": "/api/me", "limit": "5"})
        lines = lg.json().get("lines", []) if lg.status_code == 200 else []
        if not lines or any(l.get("path") != "/api/me" for l in lines) or len(lines) > 5:
            return False, f"the log tail filtered by path: {lg.status_code} {lg.text[:300]}"
        lv = op.get("/operator/api/log", params={"level": "warn", "limit": "50"}).json().get("lines", [])
        if any(l.get("level") != "warn" for l in lv):
            return False, "the level filter let other levels through"
        sp = op.get(f"/operator/api/tenants/{tenant}/snapshot")
        snap = OUT / "m6-snapshot.db"
        snap.write_bytes(sp.content)
        if sp.status_code != 200 or "attachment" not in sp.headers.get("content-disposition", "") or not sp.content.startswith(b"SQLite format 3"):
            return False, f"the snapshot: {sp.status_code} {sp.headers.get('content-type')} {sp.content[:40]!r}"
        s = sqlite3.connect(snap)
        if s.execute("PRAGMA integrity_check").fetchone()[0] != "ok" or s.execute("SELECT count(*) FROM transactions WHERE merchant = 'Cafe'").fetchone()[0] != 1:
            return False, "the snapshot isn't a whole copy of the tenant"
        for bad in ("../host", "..%2Fhost", "nope", tenant + "%00"):
            st = op.get(f"/operator/api/tenants/{bad}/snapshot").status_code
            if st not in (400, 404):
                return False, f"a snapshot of {bad!r} answered {st}"
        audit = srv.db("host.db").execute("SELECT actor, action, detail FROM audit WHERE action LIKE 'operator_%'").fetchall()
        acts = {a[1] for a in audit if a[0] == OPS}
        if not {"operator_tenants", "operator_log", "operator_snapshot"} <= acts:
            return False, f"audit rows: {audit}"
        refused = srv.db("host.db").execute("SELECT count(*) FROM audit WHERE action = 'operator_refused'").fetchone()[0]
        return True, (f"{len(rows)} tenants with plan and last activity, the log filtered by path and level, a VACUUM INTO snapshot "
                      f"(integrity ok, the tenant's rows), traversal ids 400/404; anonymous, a tenant admin and another tenant's admin "
                      f"401/403 on all three ({refused} refusals audited); audit rows {sorted(acts)}")
    finally:
        srv.stop()
        stand.close()
        smtp.close()


# ---------------------------------------------------------------- M7 leaving fh-saas

def m7():
    work = OUT / "m7-fh"  # (not under the server's own folder, which a fresh server wipes)
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    seed = run(["pixi", "run", "-e", "fhsaas", "python", "scripts/fhsaas_seed.py", str(work)], 600)
    if seed.returncode:
        return False, "fh-saas itself didn't make the host database: " + (seed.stdout + seed.stderr)[-800:]
    try:
        made = json.loads(seed.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return False, "the seed printed no summary: " + seed.stdout[-400:]
    stand, smtp = StandIn(), Smtp()
    srv = fin("m7", stand, smtp)  # (a fresh omxcode host.db, migrated, then stopped)
    srv.stop()
    host = srv.data / "host.db"
    before = hashlib.sha256(host.read_bytes()).hexdigest()
    args = ["pixi", "run", "python", "scripts/fhsaas_import.py", "--from", made["host_db"], "--tenants", made["tenants_dir"], "--to", str(srv.data)]
    dry = run(args + ["--dry-run"], 300)
    if dry.returncode or hashlib.sha256(host.read_bytes()).hexdigest() != before or list((srv.data / "tenants").glob("*.db")):
        return False, "the dry run changed something or failed: " + (dry.stdout + dry.stderr)[-600:]
    first = run(args, 300)
    if first.returncode:
        return False, "the import failed: " + (first.stdout + first.stderr)[-800:]
    h = sqlite3.connect(host)
    snap = lambda: [h.execute(f"SELECT * FROM {t} ORDER BY 1, 2").fetchall() for t in ("users", "tenants", "members", "billing")]  # noqa: E731
    once = snap()
    again = run(args, 300)
    if again.returncode or snap() != once:
        return False, "a second import changed host.db: " + again.stdout[-400:]
    for t in made["tenants"]:
        f = srv.data / "tenants" / f"{t['id']}.db"
        if not f.exists() or sqlite3.connect(f).execute("SELECT count(*) FROM fh_rows").fetchone()[0] != t["rows"]:
            return False, f"tenant {t['id']}'s database wasn't copied whole"
    srv = fin("m7", stand, smtp, keep=True)
    try:
        notes = []
        for u in made["users"]:
            cl, back = sign_in(srv, stand, (u["email"], u["name"]))
            me = cl.get("/api/me").json()
            if me.get("tenant") != u["tenant"] or me.get("role") != u["role"] or me.get("plan") != u["plan"]:
                return False, f"{u['email']} signed in to {me}, expected tenant {u['tenant']} role {u['role']} plan {u['plan']}"
            if u.get("trial_ends") and not me.get("trial_ends"):
                return False, f"{u['email']}'s trial end was lost: {me}"
            notes.append(f"{u['role']}/{u['plan']}")
        cust = h.execute("SELECT customer, subscription FROM billing WHERE customer IS NOT NULL").fetchall()
        if not cust:
            return False, "no Stripe ids were carried"
        return True, (f"fh-saas {made['version']} made {len(made['users'])} users, {len(made['tenants'])} tenants; the dry run wrote "
                      f"nothing; the import twice gives the same host.db; tenant files copied; each person signs in to their own "
                      f"tenant, role and plan ({', '.join(notes)}); Stripe ids carried ({len(cust)})")
    finally:
        srv.stop()
        stand.close()
        smtp.close()


# ---------------------------------------------------------------- M8 the image

def m8():
    if not (ROOT / "Dockerfile").exists() or not (ROOT / "scripts/saas_image.sh").exists():
        return False, "no Dockerfile or scripts/saas_image.sh"
    info = run(["docker", "info", "--format", "{{.ServerVersion}}"], 60)
    if info.returncode:
        bundle = run(["scripts/saas_image.sh", "bundle"], 3600)
        if bundle.returncode:
            return False, "the image's folder didn't assemble: " + (bundle.stdout + bundle.stderr)[-800:]
        ok, why = _bundle_runs(ROOT / "build/saas_image/rootfs")
        if not ok:
            return False, "the image's folder: " + why
        return None, (f"docker can't be reached by this user ({(info.stderr or info.stdout).strip()[:120]}): add the user to the "
                      f"docker group (sudo usermod -aG docker $USER, then log in again). The image's folder (the same files the "
                      f"Dockerfile copies) runs on its own with no pixi: {why}")
    b = run(["scripts/saas_image.sh", "build"], 3600)
    if b.returncode:
        return False, "the image didn't build: " + (b.stdout + b.stderr)[-800:]
    stand = StandIn()
    port = free_port()
    vol = OUT / "m8-volume"
    shutil.rmtree(vol, ignore_errors=True)
    vol.mkdir(parents=True)
    env = dict(SAAS_PORT=str(port), SAAS_BASE=f"http://127.0.0.1:{port}", SAAS_SECRET="k" * 64, GOOGLE_CLIENT_ID=g60.CLIENT_ID,
               GOOGLE_CLIENT_SECRET=g60.CLIENT_SECRET, SAAS_OAUTH_AUTHORIZE=stand.base + "/authorize", SAAS_OAUTH_TOKEN=stand.base + "/token",
               SAAS_OAUTH_USERINFO=stand.base + "/userinfo")
    name = "g66-m8-" + secrets.token_hex(3)
    cmd = ["docker", "run", "-d", "--rm", "--name", name, "--network", "host", "-v", f"{vol}:/data"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    r = run(cmd + ["omxcode-saas:g66"], 120)
    if r.returncode:
        return False, "docker run: " + r.stderr[-400:]
    try:
        if not wait_until(lambda: _health(port), 30):
            return False, "/health never answered: " + run(["docker", "logs", name]).stdout[-600:]
        health = wait_until(lambda: "healthy" in run(["docker", "inspect", "-f", "{{.State.Health.Status}}", name]).stdout, 90, 2)
        srv = type("S", (), {"base": f"http://127.0.0.1:{port}", "client": lambda self: httpx.Client(base_url=self.base, timeout=30)})()
        cl, back = sign_in(srv, stand, ("ada@example.com", "Ada"))
        me = cl.get("/api/me")
        if me.status_code != 200 or not (vol / "host.db").exists():
            return False, f"sign-in in the container: {me.status_code}; host.db on the volume: {(vol / 'host.db').exists()}"
        return True, f"the image runs: /health 200, Docker's health check {'healthy' if health else 'not yet healthy'}, a sign-in against the stand-ins, host.db on the volume"
    finally:
        run(["docker", "stop", name], 60)
        stand.close()


def _health(port):
    try:
        return httpx.get(f"http://127.0.0.1:{port}/health", timeout=2).status_code == 200
    except httpx.HTTPError:
        return False


def _bundle_runs(rootfs):
    """The image's files run with an empty environment and only the bundle's own libraries (as in the container)."""
    stand = StandIn()
    port = free_port()
    data = OUT / "m8-data"
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)
    env = dict(SAAS_PORT=str(port), SAAS_DATA=str(data), SAAS_BASE=f"http://127.0.0.1:{port}", SAAS_SECRET="k" * 64,
               GOOGLE_CLIENT_ID=g60.CLIENT_ID, GOOGLE_CLIENT_SECRET=g60.CLIENT_SECRET, SAAS_OAUTH_AUTHORIZE=stand.base + "/authorize",
               SAAS_OAUTH_TOKEN=stand.base + "/token", SAAS_OAUTH_USERINFO=stand.base + "/userinfo", PATH="/usr/bin:/bin",
               SAAS_STATIC=str(rootfs / "app/static"))
    exe = rootfs / "app/server"
    ldd = run(["ldd", str(exe)], 60).stdout
    if ".pixi" in ldd or "not found" in ldd:
        stand.close()
        return False, "the server still needs pixi's libraries: " + ldd[-400:]
    p = subprocess.Popen([str(exe)], cwd=str(rootfs / "app"), env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        if not wait_until(lambda: _health(port), 30):
            return False, "/health never answered"
        srv = type("S", (), {"base": f"http://127.0.0.1:{port}", "client": lambda self: httpx.Client(base_url=self.base, timeout=30)})()
        cl, _ = sign_in(srv, stand, ("ada@example.com", "Ada"))
        if cl.get("/api/me").status_code != 200:
            return False, "no sign-in"
        hc = run([str(rootfs / "app/server"), "--health", f"http://127.0.0.1:{port}/health"], 30)
        return hc.returncode == 0, f"/health 200, the health-check command exits {hc.returncode}, a sign-in against the stand-ins, no pixi library linked"
    finally:
        p.terminate()
        p.wait(10)
        stand.close()


# ---------------------------------------------------------------- M9 the finance sample

class Bank:
    """A made-up bank aggregator: OAuth client credentials (tokens live 3 s), GraphQL transactions paged by cursor (2 a
    page), a 429 with Retry-After on the first query of each sync, and Standard Webhooks events it sends."""

    def __init__(self):
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.client_id, self.client_secret = "bank-client-66", "bank-secret-66"
        self.secret = "whsec_" + base64.b64encode(b"bank-webhook-secret-66").decode()
        self.txns = {}  # connection -> [txn]
        self.tokens, self.calls, self.problems, self.throttled = {}, [], [], set()
        me = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, st, body, headers=()):
                data = json.dumps(body).encode()
                self.send_response(st)
                for k, v in headers:
                    self.send_header(k, v)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n).decode()
                if self.path == "/oauth/token":
                    auth = self.headers.get("Authorization", "")
                    want = "Basic " + base64.b64encode(f"{me.client_id}:{me.client_secret}".encode()).decode()
                    if auth != want or "grant_type=client_credentials" not in body:
                        me.problems.append("token: bad client auth")
                        return self.reply(401, {"error": "invalid_client"})
                    tok = secrets.token_hex(8)
                    me.tokens[tok] = time.time() + 3
                    me.calls.append("token")
                    return self.reply(200, {"access_token": tok, "token_type": "Bearer", "expires_in": 3})
                if self.path == "/graphql":
                    tok = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
                    if me.tokens.get(tok, 0) < time.time():
                        me.calls.append("expired")
                        return self.reply(401, {"errors": [{"message": "token expired"}]})
                    q = json.loads(body)
                    conn = q["variables"]["connection"]
                    if conn not in me.throttled:
                        me.throttled.add(conn)
                        me.calls.append("429")
                        return self.reply(429, {"errors": [{"message": "slow down"}]}, [("Retry-After", "1")])
                    after = q["variables"].get("after")
                    rows = me.txns.get(conn, [])
                    i = int(after) if after else 0
                    page = rows[i:i + 2]
                    me.calls.append(f"page:{i}")
                    return self.reply(200, {"data": {"transactions": {"nodes": page, "pageInfo": {"hasNextPage": i + 2 < len(rows), "endCursor": str(i + 2)}}}})
                self.reply(404, {})

        self.httpd = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def env(self):
        return {"BANK_API": self.base, "BANK_CLIENT_ID": self.client_id, "BANK_CLIENT_SECRET": self.client_secret, "BANK_WEBHOOK_SECRET": self.secret}

    def send_event(self, url, connection):
        eid = "msg_" + secrets.token_hex(6)
        body = json.dumps({"type": "transactions.updated", "data": {"connection": connection}}).encode()
        ts = str(int(time.time()))
        key = base64.b64decode(self.secret.removeprefix("whsec_"))
        sig = base64.b64encode(hmac.new(key, f"{eid}.{ts}.".encode() + body, hashlib.sha256).digest()).decode()
        return httpx.post(url, content=body, headers={"webhook-id": eid, "webhook-timestamp": ts, "webhook-signature": f"v1,{sig}",
                                                     "Content-Type": "application/json"}, timeout=20)

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def txn(i, amount, merchant, category):
    return {"id": f"t{i}", "date": f"2026-11-{1 + i % 9:02d}", "amount": amount, "merchant": merchant, "category": category}


def m9():
    stand, smtp, bank = StandIn(), Smtp(), Bank()
    conn = "conn-" + secrets.token_hex(3)
    bank.txns[conn] = [txn(0, -40.0, "Grocer", "Groceries"), txn(1, -12.0, "Cafe", "Dining"), txn(2, -60.0, "Grocer", "Groceries"),
                       txn(3, 2500.0, "Employer", "Income"), txn(4, -9.99, "Stream, Inc", "Subscriptions"), txn(5, -30.0, "=cmd|' /C calc'!A0", "Dining")]
    extra = dict(bank.env(), FIN_DIGEST="* * * * *", SAAS_TIMEZONE="UTC")
    srv = fin("m9", stand, smtp, extra)
    try:
        pw, br = chromium()
        try:
            ctx = br.new_context()
            page = ctx.new_page()
            page.goto(srv.base + "/")
            if "where your money goes" not in page.inner_text("body"):
                return False, "the landing page in Chromium has no text"
            stand.who = ("ada@example.com", "Ada")
            page.click("text=Sign in")
            page.wait_for_url(re.compile(r".*/app.*"), timeout=20000)
            page.wait_for_selector("#status", timeout=10000)
            cookies = {c["name"]: c["value"] for c in ctx.cookies()}
            cl = httpx.Client(base_url=srv.base, cookies=cookies, timeout=30)
            r = cl.post("/api/bank/connect", json={"connection": conn}, headers={"Origin": srv.base})
            if r.status_code != 200:
                return False, f"connect: {r.status_code} {r.text[:200]}"
            ev = bank.send_event(srv.base + "/webhooks/bank", conn)
            if ev.status_code != 200:
                return False, f"the bank's webhook: {ev.status_code} {ev.text[:200]}"
            n = wait_until(lambda: len(cl.get("/api/transactions").json().get("transactions", [])) == 6, 40)
            if not n:
                return False, f"the sync didn't land 6 transactions: {cl.get('/api/transactions').text[:300]}; bank calls {bank.calls}"
            pages = [c for c in bank.calls if c.startswith("page:")]
            if "429" not in bank.calls or len(pages) < 3:
                return False, f"the API client's calls: {bank.calls}"
            first = cl.get("/api/transactions").json()["transactions"]
            cafe = next(t for t in first if t["merchant"] == "Cafe")
            if cl.patch(f"/api/transactions/{cafe['id']}", json={"category": "Coffee"}, headers={"Origin": srv.base}).status_code != 200:
                return False, "editing a category failed"
            time.sleep(3.5)  # (the bank's token expires: the next sync refreshes it once)
            bank.txns[conn][1]["amount"] = -13.0
            bank.txns[conn].append(txn(6, -5.0, "Bakery", "Dining"))
            bank.throttled.discard(conn)
            if bank.send_event(srv.base + "/webhooks/bank", conn).status_code != 200:
                return False, "the second webhook was refused"
            wait_until(lambda: len(cl.get("/api/transactions").json().get("transactions", [])) == 7, 40)
            rows = {t["merchant"]: t for t in cl.get("/api/transactions").json()["transactions"]}
            if len(rows) < 6 or rows["Cafe"]["category"] != "Coffee" or rows["Cafe"]["amount"] != -13.0 or "Bakery" not in rows:
                return False, f"the re-sync: {rows.get('Cafe')}, Bakery {'Bakery' in rows}"
            if bank.calls.count("token") < 2:
                return False, f"the expired token wasn't refreshed: {bank.calls}"
            sp = cl.get("/api/spending").json()
            cats = {s["category"]: s["total"] for s in sp.get("categories", [])}
            if abs(cats.get("Groceries", 0) + 100.0) > 0.001 or abs(cats.get("Coffee", 0) + 13.0) > 0.001 or "Income" in cats:
                return False, f"spending by category: {sp}"
            page.reload()
            page.wait_for_function("document.querySelectorAll('#spending tr').length >= 3", timeout=10000)
            shown = page.inner_text("#spending")
            if "Groceries" not in shown or "Coffee" not in shown:
                return False, f"the JS front end shows: {shown[:200]}"
            with page.expect_download() as dl:
                page.click("#export")
            path = dl.value.path()
            rows_csv = list(csv.reader(open(path, newline="")))
            evil = [r for r in rows_csv if "cmd|" in ",".join(r)]
            if len(rows_csv) != 8 or not evil or not any(c.startswith("'=") for c in evil[0]):
                return False, f"the CSV export: {len(rows_csv)} rows, {evil}"
        finally:
            br.close()
            pw.stop()
        digest = wait_until(lambda: [m for m in smtp.to("ada@example.com") if "digest" in m["Subject"].lower()], 75)
        if not digest or "Groceries" not in mail_text(digest[0]):
            return False, f"no weekly digest email: {[m['Subject'] for m in smtp.to('ada@example.com')]}"
        h = srv.db("host.db")
        hooks = h.execute("SELECT count(*) FROM webhook_events").fetchone()[0]
        sched = h.execute("SELECT count(*) FROM schedule_runs").fetchone()[0]
        return True, (f"Chromium: landing → Sign in → /app (the static JS front end); a bank webhook (Standard Webhooks) → a job → the "
                      f"API client (token, a 429 honoured, {len(pages)} GraphQL pages, the token refreshed once expired) → bulk upsert "
                      f"keeping the edited category; spending by category; the CSV download with the formula guard; a digest email on "
                      f"the schedule ({hooks} webhook rows, {sched} schedule slots)")
    finally:
        srv.stop()
        stand.close()
        smtp.close()
        bank.close()


# ---------------------------------------------------------------- M10 nothing regressed

def m10():
    out = []
    ok_all = True
    for goal, ms, rule in (("60", [f"M{i}" for i in range(1, 13)], _g60_rule), ("57", ["M1", "M2", "M3", "M4", "M5", "M8"], _g57_rule),
                           ("64", None, _g64_rule)):
        args = ["pixi", "run", "python", f"docs/goals/{goal}-check.py"] + (ms or [])
        r = run(args, 7200)
        (OUT / f"m10-{goal}.txt").write_text(r.stdout + r.stderr)
        res = dict(re.findall(r"^(M\d+): (PASS|FAIL|BLOCKED)", r.stdout, re.M))
        good, why = rule(res, r.stdout)
        ok_all &= good
        out.append(f"goal {goal}: {why}")
    return ok_all, "; ".join(out)


def _g60_rule(res, text):
    bad = {k: v for k, v in res.items() if v != "PASS"}
    if len(res) < 12 or bad:
        return False, f"{len(res)} ran, not passing {bad}"
    return True, "M1–M12 PASS (M0 checks the env's own .pixi and Mojo 1.2: this worktree links ../mojo-ui-m60's, see D-6602)"


def _g57_rule(res, text):
    allowed = {"M5": ("BLOCKED",), "M2": ("PASS", "FAIL"), "M8": ("PASS", "FAIL")}
    bad = {k: v for k, v in res.items() if v not in allowed.get(k, ("PASS",))}
    for k in ("M2", "M8"):
        if res.get(k) == "FAIL" and not re.search(rf"^{k}: FAIL .*invit", text, re.M):
            bad[k] = "FAIL (not at the invite)"
    return (not bad and len(res) >= 6), f"{res}" + (f" bad {bad}" if bad else "")


def _g64_rule(res, text):
    bad = {k: v for k, v in res.items() if v != "PASS" and not (k == "M5" and v == "BLOCKED")}
    return (not bad and len(res) > 0), f"{res}" + (f" bad {bad}" if bad else "")


MILESTONES = {f"M{i}": f for i, f in enumerate([m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10])}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    picked = sys.argv[1:] or list(MILESTONES)
    failed = False
    for name in picked:
        try:
            ok, why = MILESTONES[name]()
        except Exception as e:  # noqa: BLE001 (a crash is a FAIL with its reason)
            ok, why = False, f"{type(e).__name__}: {e}"
        word = "PASS" if ok else ("BLOCKED" if ok is None else "FAIL")
        failed |= ok is False
        print(f"{name}: {word}  {why}", flush=True)
    sys.exit(1 if failed else 0)
