"""Goal 60 M10: omxcode's SaaS server against fh-saas itself, the same flows, data and machine (D-6006).

    pixi run python scripts/saas_bench.py [--json build/g60/bench.json] [--seconds 4]

Servers: build/saas/server (scripts/saas.sh build) and bench/fhsaas/app.py under uvicorn (the `fhsaas` pixi env).
Flows: me (a signed-in GET /api/me), entries_get (GET /api/entries over the tenant's 50 rows), entries_post (POST
/api/entries), webhook (a freshly signed Stripe event, each new: verify + record once), callback (the sign-in callback:
the token and userinfo calls to the same OAuth stand-in, then the session). Each at 1 and 64 concurrent clients:
p50, p99, requests/s; then each server's peak RSS (VmHWM, its workers included) and cold start (spawn → first answer).
The OAuth stand-in is stateless (signed codes and tokens) and runs as several processes on one port, so neither server
waits on it more than the other; the load comes from processes of raw keep-alive HTTP/1.1 clients (no client library
in the measured path). Writes the JSON and docs/goals/60-bench.md.
"""
import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import multiprocessing as mp
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/g60/bench"
SERVER = ROOT / "build/saas/server"
FH_PY = ROOT / ".pixi/envs/fhsaas/bin/python"
CLIENT_ID, CLIENT_SECRET = "client-bench.apps.example", "secret-bench"
WEBHOOK_SECRET, STRIPE_KEY = "whsec_bench", "sk_test_bench"
SIGN = b"bench-stand-in"
FLOWS = ("me", "entries_get", "entries_post", "webhook", "callback")
CPUS = os.cpu_count() or 8


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ------------------------------------------------------------------ raw HTTP/1.1 (stand-in and clients)

async def read_head(reader):
    head = await reader.readuntil(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    return lines[0], {k.strip().lower(): v.strip() for k, _, v in (l.partition(":") for l in lines[1:] if l)}, lines


async def read_body(reader, h):
    if "content-length" in h:
        n = int(h["content-length"])
        return await reader.readexactly(n) if n else b""
    if h.get("transfer-encoding", "").lower() == "chunked":
        out = b""
        while True:
            size = int((await reader.readuntil(b"\r\n")).strip().split(b";")[0], 16)
            if size == 0:
                await reader.readuntil(b"\r\n")
                return out
            out += await reader.readexactly(size)
            await reader.readexactly(2)
    return b""


def blob(d):
    raw = json.dumps(d, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=") + "." + hmac.new(SIGN, raw, hashlib.sha256).hexdigest()[:32]


def unblob(s):
    try:
        b, _, tag = s.partition(".")
        raw = base64.urlsafe_b64decode(b + "=" * (-len(b) % 4))
        if hmac.compare_digest(hmac.new(SIGN, raw, hashlib.sha256).hexdigest()[:32], tag):
            return json.loads(raw)
    except Exception:  # noqa: BLE001
        pass
    return None


def s256(v):
    return base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).decode().rstrip("=")


async def standin_conn(reader, writer):
    try:
        while True:
            try:
                line, h, _ = await read_head(reader)
            except (asyncio.IncompleteReadError, ConnectionError):
                return
            body = await read_body(reader, h)
            method, target, _ = line.split(" ", 2)
            u = urllib.parse.urlsplit(target)
            q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
            status, out, extra = 404, b"{}", ""
            if method == "GET" and u.path == "/authorize":
                who = "u%02d@example.com" % (int(hashlib.sha256(q.get("state", "").encode()).hexdigest(), 16) % 64)
                code = blob({"who": who, "ch": q.get("code_challenge", ""), "ru": q.get("redirect_uri", "")})
                sep = "&" if "?" in q["redirect_uri"] else "?"
                status, out = 302, b""
                extra = "Location: " + q["redirect_uri"] + sep + urllib.parse.urlencode({"code": code, "state": q.get("state", "")}) + "\r\n"
            elif method == "POST" and u.path == "/token":
                f = {k: v[0] for k, v in urllib.parse.parse_qs(body.decode()).items()}
                cid, csec = f.get("client_id"), f.get("client_secret")
                if h.get("authorization", "").startswith("Basic "):
                    cid, _, csec = base64.b64decode(h["authorization"][6:]).decode().partition(":")
                c = unblob(f.get("code", ""))
                if (cid, csec) != (CLIENT_ID, CLIENT_SECRET):
                    status, out = 401, b'{"error":"invalid_client"}'
                elif not c or c["ru"] != f.get("redirect_uri") or (c["ch"] and s256(f.get("code_verifier", "")) != c["ch"]):
                    status, out = 400, b'{"error":"invalid_grant"}'
                else:
                    status, out = 200, json.dumps({"access_token": blob({"who": c["who"]}), "token_type": "Bearer", "expires_in": 3599, "scope": "https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email openid"}).encode()
            elif method == "GET" and u.path == "/userinfo":
                t = unblob(h.get("authorization", "").removeprefix("Bearer "))
                if t:
                    status, out = 200, json.dumps({"sub": "sub-" + t["who"], "email": t["who"], "email_verified": True, "name": t["who"].split("@")[0]}).encode()
                else:
                    status, out = 401, b'{"error":"invalid_token"}'
            writer.write((f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {len(out)}\r\n{extra}\r\n").encode() + out)
            await writer.drain()
            if h.get("connection", "").lower() == "close":
                return
    finally:
        writer.close()


def standin_main(port):
    async def run():
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        s.bind(("127.0.0.1", port))
        s.listen(1024)
        srv = await asyncio.start_server(standin_conn, sock=s)
        async with srv:
            await srv.serve_forever()
    asyncio.run(run())


class Conn:
    """One keep-alive client connection (it reconnects after a `Connection: close`) with its own cookie jar."""

    def __init__(self, host, port):
        self.host, self.port, self.r, self.w, self.jar = host, port, None, None, {}

    async def request(self, method, target, body=b"", headers=None):
        for attempt in range(2):
            if self.w is None:
                self.r, self.w = await asyncio.open_connection(self.host, self.port)
            hs = f"{method} {target} HTTP/1.1\r\nHost: {self.host}:{self.port}\r\n"
            if self.jar:
                hs += "Cookie: " + "; ".join(f"{k}={v}" for k, v in self.jar.items()) + "\r\n"
            for k, v in (headers or {}).items():
                hs += f"{k}: {v}\r\n"
            if body or method == "POST":
                hs += f"Content-Length: {len(body)}\r\n"
            try:
                self.w.write(hs.encode() + b"\r\n" + body)
                await self.w.drain()
                line, h, lines = await read_head(self.r)
                data = await read_body(self.r, h)
            except (asyncio.IncompleteReadError, ConnectionError, OSError):
                self.close()
                if attempt:
                    raise
                continue
            for l in lines[1:]:
                if l.lower().startswith("set-cookie:"):
                    kv = l.split(":", 1)[1].strip().split(";", 1)[0]
                    k, _, v = kv.partition("=")
                    if v and "max-age=0" not in l.lower():
                        self.jar[k.strip()] = v.strip()
            if h.get("connection", "").lower() == "close":
                self.close()
            return int(line.split(" ")[1]), h, data
        raise ConnectionError("no answer")

    def close(self):
        if self.w is not None:
            self.w.close()
        self.r = self.w = None


# ------------------------------------------------------------------ flows

def stripe_sig(body):
    t = int(time.time())
    return f"t={t},v1=" + hmac.new(WEBHOOK_SECRET.encode(), f"{t}.{body}".encode(), hashlib.sha256).hexdigest()


async def sign_in_flow(conn, oauth_port, timed=None):
    """/login → the stand-in's /authorize → /auth/callback (only the callback timed into `timed`)."""
    st, h, _ = await conn.request("GET", "/login")
    loc = h.get("location", "")
    if st not in (302, 303, 307) or "/authorize" not in loc:
        raise RuntimeError(f"/login answered {st} {loc[:120]}")
    u = urllib.parse.urlsplit(loc)
    prov = Conn("127.0.0.1", oauth_port)
    st, h2, _ = await prov.request("GET", u.path + "?" + u.query)
    prov.close()
    cb = urllib.parse.urlsplit(h2["location"])
    t0 = time.perf_counter()
    st, h3, body = await conn.request("GET", cb.path + "?" + cb.query)
    dt = time.perf_counter() - t0
    if st not in (302, 303, 307):
        raise RuntimeError(f"the callback answered {st} {body[:200]}")
    if timed is not None:
        timed.append(dt)
    return dt


async def one(flow, conn, impl, oauth_port, n, lat):
    if flow == "callback":
        await sign_in_flow(conn, oauth_port, lat)
        return
    t0 = time.perf_counter()
    if flow == "me":
        st, _, _ = await conn.request("GET", "/api/me")
    elif flow == "entries_get":
        st, _, _ = await conn.request("GET", "/api/entries")
    elif flow == "entries_post":
        st, _, _ = await conn.request("POST", "/api/entries", json.dumps({"text": f"bench {n}", "amount_cents": n}).encode(), {"Content-Type": "application/json"})
    else:
        ev = json.dumps({"id": f"evt_b{os.getpid()}_{n}_{time.time_ns()}", "object": "event", "type": "invoice.created", "created": int(time.time()),
                         "data": {"object": {"id": "in_x", "object": "invoice"}}})
        path = "/billing/webhook" if impl == "omxcode" else "/stripe/webhook"
        st, _, _ = await conn.request("POST", path, ev.encode(), {"Content-Type": "application/json", "Stripe-Signature": stripe_sig(ev)})
    if st >= 400:
        raise RuntimeError(f"{flow} answered {st}")
    lat.append(time.perf_counter() - t0)  # (successes only: a failed request counts as an error, never as speed)


def worker(args):
    flow, impl, port, oauth_port, cookies, tasks, seconds, warm = args

    async def run():
        lat, errors, end = [], [], 0.0

        async def loop(k):
            conn = Conn("127.0.0.1", port)
            if flow != "callback":
                conn.jar = dict(cookies)
            n = k * 1_000_000
            while time.perf_counter() < end:
                n += 1
                try:
                    sink = lat if time.perf_counter() > warm_until else []
                    await one(flow, conn, impl, oauth_port, n, sink)
                except Exception as e:  # noqa: BLE001
                    errors.append(str(e)[:200])
                    conn.close()
                    if len(errors) > 100_000:
                        return
                if flow == "callback":
                    conn.jar = {}
            conn.close()

        start = time.perf_counter()
        warm_until = start + warm
        end = warm_until + seconds
        await asyncio.gather(*(loop(k) for k in range(tasks)))
        return lat, errors

    return asyncio.run(run())


def measure(flow, impl, port, oauth_port, cookies, conc, seconds, warm=0.5):
    procs = 1 if conc == 1 else min(conc, max(4, CPUS // 3))
    per = [conc // procs + (1 if i < conc % procs else 0) for i in range(procs)]
    with mp.get_context("fork").Pool(procs) as pool:
        res = pool.map(worker, [(flow, impl, port, oauth_port, cookies, t, seconds, warm) for t in per])
    lat = sorted(x for r in res for x in r[0])
    errors = [e for r in res for e in r[1]]
    if errors and impl == "omxcode":
        raise RuntimeError(f"{impl} {flow} c{conc}: {len(errors)} errors, e.g. {errors[0]}")
    if not lat:
        if impl == "omxcode" or not errors:
            raise RuntimeError(f"{impl} {flow} c{conc}: no requests ({errors[:1]})")
        return {"p50_ms": float("inf"), "p99_ms": float("inf"), "rps": 0.0, "n": 0, "errors": len(errors), "error_example": errors[0]}  # (every request failed)
    q = lambda p: lat[min(len(lat) - 1, int(p * len(lat)))] * 1000  # noqa: E731
    return {"p50_ms": q(0.50), "p99_ms": q(0.99), "rps": len(lat) / seconds, "n": len(lat), "errors": len(errors), "error_example": errors[0] if errors else ""}


# ------------------------------------------------------------------ servers

def answers(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2) as s:
            s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            return s.recv(12).startswith(b"HTTP/1.1")
    except OSError:
        return False


def vm_hwm_mb(pid):
    """Peak RSS of a process and its children (uvicorn's workers), in MB."""
    total = 0
    pids = [pid]
    try:
        pids += [int(p) for p in subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()]
    except OSError:
        pass
    for p in pids:
        try:
            for l in Path(f"/proc/{p}/status").read_text().splitlines():
                if l.startswith("VmHWM:"):
                    total += int(l.split()[1])
        except OSError:
            pass
    return total / 1024


def start(impl, oauth_port):
    port = free_port()
    data = OUT / impl
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)
    base = f"http://127.0.0.1:{port}"
    common = dict(GOOGLE_CLIENT_ID=CLIENT_ID, GOOGLE_CLIENT_SECRET=CLIENT_SECRET, STRIPE_SECRET_KEY=STRIPE_KEY, STRIPE_WEBHOOK_SECRET=WEBHOOK_SECRET)
    if impl == "omxcode":
        env = dict(os.environ, SAAS_PORT=str(port), SAAS_DATA=str(data), SAAS_BASE=base, SAAS_SECRET="k" * 64, SAAS_LOG=str(data / "saas.log"),
                   SAAS_OAUTH_AUTHORIZE=f"http://127.0.0.1:{oauth_port}/authorize", SAAS_OAUTH_TOKEN=f"http://127.0.0.1:{oauth_port}/token",
                   SAAS_OAUTH_USERINFO=f"http://127.0.0.1:{oauth_port}/userinfo", STRIPE_PRICE_PRO="price_bench", SAAS_RATE="0", SAAS_OFFLOAD_PER_CLIENT="0", **common)
        cmd, cwd = [str(SERVER)], ROOT
    else:
        env = dict(os.environ, FH_OAUTH_BASE=f"http://127.0.0.1:{oauth_port}", FH_SECRET="k" * 64, DB_TYPE="SQLITE", DB_NAME=str(data / "app_host"),
                   STRIPE_MONTHLY_PRICE_ID="price_bench", STRIPE_BASE_URL=base, ENVIRONMENT="production", OAUTHLIB_INSECURE_TRANSPORT="1", **common)
        workers = str(min(8, CPUS))
        cmd, cwd = [str(FH_PY), "-m", "uvicorn", "--app-dir", str(ROOT / "bench/fhsaas"), "app:app", "--host", "127.0.0.1", "--port", str(port), "--workers", workers], data
    log = open(data / "server.out", "w")
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    while not answers(port):
        if p.poll() is not None or time.perf_counter() - t0 > 60:
            raise RuntimeError(f"{impl} didn't start: {(data / 'server.out').read_text()[-1500:]}")
        time.sleep(0.005)
    cold = (time.perf_counter() - t0) * 1000
    return p, port, cold, log


def stop(p, log):
    try:
        os.killpg(p.pid, signal.SIGTERM)
        p.wait(10)
    except (OSError, subprocess.TimeoutExpired):
        os.killpg(p.pid, signal.SIGKILL)
    log.close()


async def setup(port, oauth_port):
    """A signed-in person with 50 entries in their tenant: the session's cookies."""
    c = Conn("127.0.0.1", port)
    await sign_in_flow(c, oauth_port)
    jar = dict(c.jar)
    for i in range(50):
        st, _, body = await c.request("POST", "/api/entries", json.dumps({"text": f"seed {i}", "amount_cents": 100 + i}).encode(), {"Content-Type": "application/json"})
        if st not in (200, 201):
            raise RuntimeError(f"seeding answered {st} {body[:200]}")
    st, _, body = await c.request("GET", "/api/me")
    if st != 200:
        raise RuntimeError(f"/api/me after sign-in answered {st} {body[:200]}")
    c.close()
    return jar


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default=str(ROOT / "build/g60/bench.json"))
    ap.add_argument("--seconds", type=float, default=4)
    a = ap.parse_args()
    started = time.time()
    OUT.mkdir(parents=True, exist_ok=True)
    if not SERVER.exists() or subprocess.run(["scripts/saas.sh", "build"], cwd=ROOT, capture_output=True).returncode:
        sys.exit("the omxcode server didn't build")
    if not FH_PY.exists():
        sys.exit("no fhsaas env: pixi install -e fhsaas")
    oauth_port = free_port()
    oauth = [mp.get_context("fork").Process(target=standin_main, args=(oauth_port,), daemon=True) for _ in range(max(4, CPUS // 4))]
    for o in oauth:
        o.start()
    while not answers(oauth_port):
        time.sleep(0.01)
    res = {"started": started, "machine": f"{CPUS} CPUs, {os.uname().sysname} {os.uname().release}", "seconds": a.seconds, "flows": {f: {} for f in FLOWS},
           "rss_mb": {}, "cold_start_ms": {}}
    try:
        for impl in ("omxcode", "fhsaas"):
            colds = []
            for _ in range(3):  # (cold start: the best of three fresh starts)
                p, port, cold, log = start(impl, oauth_port)
                colds.append(cold)
                stop(p, log)
            p, port, cold, log = start(impl, oauth_port)
            try:
                cookies = asyncio.run(setup(port, oauth_port))
                for f in FLOWS:
                    res["flows"][f][impl] = {}
                    for conc in (1, 64):
                        r = measure(f, impl, port, oauth_port, cookies, conc, a.seconds)
                        res["flows"][f][impl][f"c{conc}"] = r
                        print(f"{impl:8} {f:13} c{conc:<3} p50 {r['p50_ms']:8.2f} ms  p99 {r['p99_ms']:8.2f} ms  {r['rps']:9.0f} req/s  errors {r['errors']}", flush=True)
                res["rss_mb"][impl] = vm_hwm_mb(p.pid)
                res["cold_start_ms"][impl] = min(colds)
            finally:
                stop(p, log)
    finally:
        for o in oauth:
            o.terminate()
    Path(a.json).parent.mkdir(parents=True, exist_ok=True)
    Path(a.json).write_text(json.dumps(res, indent=1))
    write_page(res)


def write_page(res):
    rows = []
    for f in FLOWS:
        for conc in ("c1", "c64"):
            o, b = res["flows"][f]["omxcode"][conc], res["flows"][f]["fhsaas"][conc]
            ms = lambda v: "— (none answered)" if v == float("inf") else f"{v:.2f}"  # noqa: E731
            ratio = f"{o['rps'] / b['rps']:.1f}×" if b["rps"] > 0 else "∞ (fh-saas answered none)"
            rows.append(f"| {f} | {conc[1:]} | {ms(o['p50_ms'])} | {ms(b['p50_ms'])} | {ms(o['p99_ms'])} | {ms(b['p99_ms'])} | {o['rps']:,.0f} | {b['rps']:,.0f} | {ratio} | {o['errors']} / {b['errors']} |")
    page = f"""# Goal 60 M10: omxcode SaaS vs fh-saas, measured

Generated by `scripts/saas_bench.py` (run by `docs/goals/60-check.py M10`) on {time.strftime('%Y-%m-%d %H:%M', time.localtime(res['started']))},
{res['machine']}; {res['seconds']:.0f} s a measurement after a 0.5 s warm-up. As measured, nothing edited.

- omxcode: `build/saas/server` (examples/saas/server.mojo on mojoui.serve's concurrent Handler, one reactor per core up
  to 16, per-thread SQLite connections, blocking calls offloaded), `SAAS_RATE=0` and `SAAS_OFFLOAD_PER_CLIENT=0` (no per-client limits: fh-saas has none, and every bench client is one address; a pending sign-in is a sealed cookie, D-6031, D-6037).
- fh-saas 0.9.14: `bench/fhsaas/app.py`, the standard app shape from its docs, under uvicorn with {min(8, CPUS)} worker processes, every SQLite connection in WAL with synchronous=NORMAL (omxcode's durability, D-6026).
- Same data (a signed-in person, their tenant holding 50 entries), the same stateless OAuth stand-in (several processes
  on one port), the same load generator (processes of raw keep-alive HTTP/1.1 clients).
- Flows: `me` GET /api/me; `entries_get` GET /api/entries (50 rows); `entries_post` POST /api/entries; `webhook` a
  freshly signed Stripe event each time (verify + record once; omxcode /billing/webhook, fh-saas's billing route
  /stripe/webhook); `callback` the sign-in callback (code → token → userinfo at the stand-in, then the session).
- Latencies and req/s count successful answers only; errors are counted apart. fh-saas's errors under load come from
  fh-saas itself (its host database connection is shared by uvicorn's threadpool: SQLite "bad parameter or other API
  misuse" and spurious "Access denied" PermissionErrors in its membership check; build/g60/bench/fhsaas/server.out).

| flow | clients | omxcode p50 ms | fh-saas p50 ms | omxcode p99 ms | fh-saas p99 ms | omxcode req/s | fh-saas req/s | throughput | errors (omxcode / fh-saas) |
|---|---|---|---|---|---|---|---|---|---|
""" + "\n".join(rows) + f"""

| | omxcode | fh-saas |
|---|---|---|
| peak RSS (MB, workers included) | {res['rss_mb']['omxcode']:.0f} | {res['rss_mb']['fhsaas']:.0f} |
| cold start (ms, best of 3: spawn → first answer) | {res['cold_start_ms']['omxcode']:.0f} | {res['cold_start_ms']['fhsaas']:.0f} |
"""
    (ROOT / "docs/goals/60-bench.md").write_text(page)


if __name__ == "__main__":
    main()
