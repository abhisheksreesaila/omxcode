"""Goal 60's proof: the whole SaaS backend in Mojo (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/60-check.py [M0 M1 ...]          (default: every milestone)

Google, Stripe and an SMTP server are played here (never by the code under test): the OAuth one checks PKCE and the
client secret, the Stripe one the key and the form fields, the SMTP one speaks EHLO / AUTH / STARTTLS / implicit TLS
with this file's own CA and keeps every message it accepts. Truth is the SQLite files, the log file, the messages the
SMTP stand-in received and what comes back over HTTP.

The server's contract is goal 57's (docs/goals/57-check.py's docstring) plus:
  env   SAAS_LOG (JSON-lines file)  SAAS_MIGRATIONS (dir with tenant/NNN_name.sql; default examples/saas/migrations)
        SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM SMTP_TLS (implicit|starttls|off) SMTP_CA_FILE
        SAAS_JOB_BACKOFF_MS SAAS_JOB_MAX_ATTEMPTS  SAAS_TRIAL_DAYS STRIPE_TRIAL_DAYS SAAS_GRACE_DAYS (floats)
        SAAS_INVITE_TTL SAAS_SESSION_IDLE (seconds)  SAAS_RATE (requests a minute per IP on /login, /auth/callback, /api/token)
  host.db   audit(ts, tenant, actor, action, detail)   jobs(id, tenant, kind, payload, status, attempts, max_attempts, run_at, error)
  tenant db schema_migrations(version, checksum, …)
  every reply has X-Request-Id; GET /api/jobs (admin); GET /api/tenants; POST /api/switch {tenant}
  invites: the email holds <base>/invites/<token>; GET shows "Join <tenant>, invited by <name>?"; POST (same origin) accepts
  POST /billing/portal → {url}; /api/me gains `cancels_at` (null unless the subscription ends at its period's end)
  the welcome email's subject names the person
M10 (D-6006): `pixi run python scripts/saas_bench.py --json <file>` writes {"started": <unix s>, "flows": {<flow>: {"omxcode"|"fhsaas":
  {"c1"|"c64": {"p50_ms", "p99_ms", "rps"}}}}, "rss_mb": {...}, "cold_start_ms": {...}} and docs/goals/60-bench.md; flows me,
  entries_get, entries_post, webhook, callback. M11: examples/saas_min/server.mojo, the same env, built here.
"""
import base64
import email
import email.policy
import hashlib
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import socket
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g60"
SERVER = ROOT / "build/saas/server"
APP = ROOT / "build/saas/linux/saas"
MIGRATIONS = ROOT / "examples/saas/migrations"
CLIENT_ID, CLIENT_SECRET = "client-60.apps.example", "secret-60"
STRIPE_KEY, WEBHOOK_SECRET, PRICE = "sk_test_stand_in_60", "whsec_stand_in_60", "price_pro_60"
SMTP_USER, SMTP_PASSWORD, SMTP_FROM = "mailer", "smtp-pass-60-" + secrets.token_hex(4), "omxcode SaaS <hello@saas.example>"
MAC = "bhoomijaprasad@100.76.9.101"  # the owner's Mac: only ~/omxcode-g60 there
MAC_SSH = ["ssh", "-i", str(Path.home() / ".ssh/edx_mac"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
sys.path.insert(0, str(ROOT / "scripts"))

_spec = importlib.util.spec_from_file_location("g57check", ROOT / "docs/goals/57-check.py")
g57 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(g57)
s256, signed_57, event = g57.s256, g57.signed, g57.event


def signed(ev, secret=WEBHOOK_SECRET, age=0):
    return signed_57(ev, secret, age)


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def mojo_test(src, labels, timeout=1800, nofile=0):
    exe = ROOT / "build" / Path(src).stem
    b = run(["scripts/mojo_flare.sh", "build", src, "-o", str(exe)], timeout)
    if b.returncode:
        return False, (b.stdout + b.stderr)[-1500:]
    r = run(["bash", "-c", f"ulimit -n {nofile} && exec {exe}"] if nofile else [str(exe)], timeout)  # (D-6025: a low open-file limit)
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), (f"missing {missing} " if missing else "") + out[-600:]


def wait_until(pred, timeout, step=0.2):
    end = time.time() + timeout
    while time.time() < end:
        v = pred()
        if v:
            return v
        time.sleep(step)
    return pred()


# ---------------------------------------------------------------- Google + Stripe

class StandIn:
    """Google's OAuth endpoints and Stripe's API on one port. `delay_token` / `delay_checkout`: seconds to sit on a reply."""

    def __init__(self):
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.who = ("ada@example.com", "Ada")
        self.codes, self.tokens, self.states, self.sessions, self.portals, self.forms, self.problems = {}, {}, [], {}, [], [], []
        self.delay_token = self.delay_checkout = 0
        me = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, status, body=None, headers=()):
                data = json.dumps(body).encode() if body is not None else b""
                self.send_response(status)
                for k, v in headers:
                    self.send_header(k, v)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def form(self):
                n = int(self.headers.get("Content-Length") or 0)
                return {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode(), keep_blank_values=True).items()}

            def stripe_ok(self):
                a = self.headers.get("Authorization") or ""
                if a.startswith("Bearer "):
                    return a[7:] == STRIPE_KEY
                return a.startswith("Basic ") and base64.b64decode(a[6:]).decode().partition(":")[0] == STRIPE_KEY

            def do_GET(self):
                u = urllib.parse.urlsplit(self.path)
                q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
                if u.path == "/authorize":
                    bad = [k for k, v in {"response_type": "code", "client_id": CLIENT_ID, "code_challenge_method": "S256"}.items() if q.get(k) != v]
                    bad += [k for k in ("redirect_uri", "state", "code_challenge") if not q.get(k)]
                    if bad:
                        me.problems.append(f"authorize: {bad}")
                        return self.reply(400, {"error": "invalid_request"})
                    code = secrets.token_urlsafe(16)
                    me.states.append(q["state"])
                    me.codes[code] = dict(challenge=q["code_challenge"], redirect=q["redirect_uri"], who=me.who)
                    sep = "&" if "?" in q["redirect_uri"] else "?"
                    return self.reply(302, None, [("Location", q["redirect_uri"] + sep + urllib.parse.urlencode({"code": code, "state": q["state"]}))])
                if u.path == "/userinfo":
                    tok = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
                    if tok not in me.tokens:
                        return self.reply(401, {"error": "invalid_token"})
                    em, name = me.tokens[tok]
                    return self.reply(200, {"sub": "sub-" + em, "email": em, "email_verified": True, "name": name})
                m = re.fullmatch(r"/v1/checkout/sessions/(cs_test_\w+)", u.path)
                if m and self.stripe_ok():
                    s = me.sessions.get(m.group(1))
                    return self.reply(200, s) if s else self.reply(404, {"error": {"code": "resource_missing"}})
                return self.reply(404, {})

            def do_POST(self):
                u = urllib.parse.urlsplit(self.path)
                f = self.form()
                if u.path == "/token":
                    time.sleep(me.delay_token)
                    cid, csec = f.get("client_id"), f.get("client_secret")
                    if (self.headers.get("Authorization") or "").startswith("Basic "):
                        cid, _, csec = base64.b64decode(self.headers["Authorization"][6:]).decode().partition(":")
                    if (cid, csec) != (CLIENT_ID, CLIENT_SECRET):
                        return self.reply(401, {"error": "invalid_client"})
                    c = me.codes.pop(f.get("code", ""), None)
                    if f.get("grant_type") != "authorization_code" or not c or f.get("redirect_uri") != c["redirect"] or s256(f.get("code_verifier", "")) != c["challenge"]:
                        return self.reply(400, {"error": "invalid_grant"})
                    tok = secrets.token_urlsafe(24)
                    me.tokens[tok] = c["who"]
                    return self.reply(200, {"access_token": tok, "token_type": "Bearer", "expires_in": 3599, "id_token": "not.checked", "scope": "openid email profile"})
                if not self.stripe_ok():
                    return self.reply(401, {"error": {"type": "invalid_request_error"}})
                if u.path == "/v1/checkout/sessions":
                    time.sleep(me.delay_checkout)
                    me.forms.append(f)
                    bad = [k for k, v in {"mode": "subscription", "line_items[0][price]": PRICE, "line_items[0][quantity]": "1"}.items() if f.get(k) != v]
                    bad += [k for k in ("success_url", "cancel_url", "client_reference_id") if not f.get(k)]
                    if bad:
                        me.problems.append(f"checkout: {bad}")
                        return self.reply(400, {"error": {"type": "invalid_request_error", "param": bad[0]}})
                    sid = "cs_test_" + secrets.token_hex(8)
                    me.sessions[sid] = {"id": sid, "object": "checkout.session", "mode": "subscription", "status": "open", "payment_status": "unpaid",
                                        "client_reference_id": f["client_reference_id"], "customer": None, "subscription": None, "url": f"{me.base}/pay/{sid}"}
                    return self.reply(200, me.sessions[sid])
                if u.path == "/v1/billing_portal/sessions":
                    if not f.get("customer", "").startswith("cus_") or not f.get("return_url"):
                        me.problems.append(f"portal: {f}")
                        return self.reply(400, {"error": {"type": "invalid_request_error"}})
                    me.portals.append(f)
                    pid = "bps_" + secrets.token_hex(6)
                    return self.reply(200, {"id": pid, "object": "billing_portal.session", "customer": f["customer"], "url": f"{me.base}/portal/{pid}"})
                return self.reply(404, {})

        self.http = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    def pay(self, sid):
        s = self.sessions[sid]
        s.update(status="complete", payment_status="paid", customer="cus_" + sid[-6:], subscription="sub_" + sid[-6:])
        return s

    def close(self):
        self.http.shutdown()


# ---------------------------------------------------------------- SMTP

def make_ca(folder):
    """A CA and a certificate for 127.0.0.1 signed by it (openssl); returns (ca.pem, cert.pem, key.pem)."""
    folder.mkdir(parents=True, exist_ok=True)
    ca, cak, crt, key, csr, ext = (folder / n for n in ("ca.pem", "ca.key", "cert.pem", "key.pem", "cert.csr", "ext.cnf"))
    if not crt.exists():
        sh = lambda *a: subprocess.run(a, check=True, capture_output=True)  # noqa: E731
        sh("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", "/CN=goal60 test CA", "-addext", "basicConstraints=critical,CA:TRUE",
           "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", str(cak), "-out", str(ca))
        sh("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1", "-keyout", str(key), "-out", str(csr))
        ext.write_text("subjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
        sh("openssl", "x509", "-req", "-in", str(csr), "-CA", str(ca), "-CAkey", str(cak), "-CAcreateserial", "-days", "30", "-extfile", str(ext), "-out", str(crt))
    return ca, crt, key


class Smtp:
    """An SMTP server: mode "off" | "starttls" | "implicit"; AUTH PLAIN/LOGIN must match; `refuse_next` sessions get 451 at
    MAIL; `refuse_always` addresses get 451 at RCPT; `hold` seconds before answering DATA's end. Keeps parsed messages."""

    def __init__(self, mode="off"):
        self.mode, self.port = mode, free_port()
        self.messages, self.rcpts, self.problems, self.connections = [], [], [], 0
        self.refuse_next, self.refuse_always, self.hold = 0, set(), 0
        self.ctx = None
        if mode != "off":
            _, crt, key = make_ca(OUT / "ca")
            self.ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
            self.ctx.load_cert_chain(str(crt), str(key))
        me = self

        class H(socketserver.StreamRequestHandler):
            def setup(self):
                me.connections += 1
                if me.mode == "implicit":
                    try:
                        self.request = me.ctx.wrap_socket(self.request, server_side=True)
                    except OSError:
                        self.request.close()
                        self.request = None
                super().setup() if self.request else None

            def finish(self):
                if self.request:
                    try:
                        super().finish()
                    except OSError:
                        pass

            def say(self, line):  # (the handler's reply to each command)
                self.wfile.write((line + "\r\n").encode())
                self.wfile.flush()

            def handle(self):
                if not self.request:
                    return
                try:
                    self.talk()
                except (OSError, ValueError, IndexError):  # a client that hangs up or speaks nonsense: the session ends
                    pass

            def talk(self):
                self.say("220 stand-in ESMTP")
                authed, tls = False, me.mode == "implicit"
                rcpts, mail = [], None
                while True:
                    raw = self.rfile.readline()
                    if not raw:
                        return
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    verb = line.split(" ", 1)[0].upper()
                    if verb in ("EHLO", "HELO"):
                        caps = ["250-stand-in"]
                        if me.mode == "starttls" and not tls:
                            caps.append("250-STARTTLS")
                        if tls or me.mode == "off":
                            caps.append("250-AUTH PLAIN LOGIN")
                        caps.append("250 8BITMIME")
                        for c in caps:
                            self.say(c)
                    elif verb == "STARTTLS" and me.mode == "starttls":
                        self.say("220 go ahead")
                        self.request = me.ctx.wrap_socket(self.request, server_side=True)
                        self.rfile, self.wfile = self.request.makefile("rb"), self.request.makefile("wb")
                        tls = True
                    elif verb == "AUTH":
                        parts = line.split(" ")
                        if me.mode == "starttls" and not tls:
                            self.say("530 STARTTLS first")
                            continue
                        if parts[1].upper() == "PLAIN":
                            blob = parts[2] if len(parts) > 2 else (self.say("334 ") or self.rfile.readline().decode().strip())
                            _, u, p = base64.b64decode(blob).decode().split("\0")
                        else:
                            self.say("334 VXNlcm5hbWU6")
                            u = base64.b64decode(self.rfile.readline().strip()).decode()
                            self.say("334 UGFzc3dvcmQ6")
                            p = base64.b64decode(self.rfile.readline().strip()).decode()
                        authed = (u, p) == (SMTP_USER, SMTP_PASSWORD)
                        self.say("235 ok" if authed else "535 bad credentials")
                    elif verb == "MAIL":
                        if not authed:
                            self.say("530 auth first")
                        elif me.refuse_next > 0:
                            me.refuse_next -= 1
                            self.say("451 try again later")
                        else:
                            mail, rcpts = line, []
                            self.say("250 ok")
                    elif verb == "RCPT":
                        addr = re.search(r"<([^>]*)>", line).group(1)
                        if addr in me.refuse_always:
                            self.say("451 mailbox busy")
                        else:
                            rcpts.append(addr)
                            self.say("250 ok")
                    elif verb == "DATA":
                        if not mail or not rcpts:
                            self.say("503 sequence")
                            continue
                        self.say("354 go")
                        buf = []
                        while True:
                            l = self.rfile.readline()
                            if l in (b".\r\n", b".\n", b""):
                                break
                            buf.append(l[1:] if l.startswith(b"..") else l)
                        time.sleep(me.hold)
                        msg = email.message_from_bytes(b"".join(buf), policy=email.policy.default)
                        me.messages.append(msg)
                        me.rcpts.append(list(rcpts))
                        self.say("250 queued")
                        mail = None
                    elif verb == "RSET":
                        mail, rcpts = None, []
                        self.say("250 ok")
                    elif verb == "QUIT":
                        self.say("221 bye")
                        return
                    else:
                        self.say("502 unknown")

        class S(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = S(("127.0.0.1", self.port), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def env(self):
        e = dict(SMTP_HOST="127.0.0.1", SMTP_PORT=str(self.port), SMTP_USER=SMTP_USER, SMTP_PASSWORD=SMTP_PASSWORD, SMTP_FROM=SMTP_FROM, SMTP_TLS=self.mode)
        if self.mode != "off":
            e["SMTP_CA_FILE"] = str(OUT / "ca/ca.pem")
        return e

    def to(self, addr):
        return [m for m, r in zip(self.messages, self.rcpts) if addr in r]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


# ---------------------------------------------------------------- the server

FAST = dict(SAAS_JOB_BACKOFF_MS="200", SAAS_JOB_MAX_ATTEMPTS="4")
_built = False


class Server:
    def __init__(self, name, stand, smtp=None, extra=None, keep=False, expect_fail=False, exe=None):
        global _built
        if exe is None and not _built:
            b = run(["scripts/saas.sh", "build"], 3600)
            if b.returncode or not SERVER.exists():
                raise RuntimeError("the server didn't build: " + (b.stdout + b.stderr)[-1500:])
            _built = True
        self.data = OUT / name
        if not keep:
            shutil.rmtree(self.data, ignore_errors=True)
        self.data.mkdir(parents=True, exist_ok=True)
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.logfile = self.data / "saas.log"
        env = dict(SAAS_PORT=str(self.port), SAAS_DATA=str(self.data), SAAS_BASE=self.base, SAAS_SECRET="k" * 64, SAAS_LOG=str(self.logfile),
                   GOOGLE_CLIENT_ID=CLIENT_ID, GOOGLE_CLIENT_SECRET=CLIENT_SECRET, SAAS_OAUTH_AUTHORIZE=stand.base + "/authorize",
                   SAAS_OAUTH_TOKEN=stand.base + "/token", SAAS_OAUTH_USERINFO=stand.base + "/userinfo", SAAS_STRIPE_API=stand.base,
                   STRIPE_SECRET_KEY=STRIPE_KEY, STRIPE_WEBHOOK_SECRET=WEBHOOK_SECRET, STRIPE_PRICE_PRO=PRICE, **FAST)
        env.update(smtp.env() if smtp else {})
        env.update(extra or {})
        outf = self.data / "server.out"
        mark = outf.stat().st_size if outf.exists() else 0
        self.out = open(outf, "a")
        self.p = subprocess.Popen([str(exe or SERVER)], cwd=ROOT, env=dict(os.environ, **env), stdout=self.out, stderr=subprocess.STDOUT)
        fresh = lambda: outf.read_bytes()[mark:].decode("utf-8", "replace")  # noqa: E731 (this run's output only)
        wait_until(lambda: "SAAS: listening" in fresh() or self.p.poll() is not None, 30)
        self.started = "SAAS: listening" in fresh() and self.p.poll() is None
        if not self.started and not expect_fail:
            raise RuntimeError("the server didn't start: " + fresh()[-1500:])

    def client(self):
        return httpx.Client(base_url=self.base, follow_redirects=False, timeout=30)

    def db(self, rel):
        return sqlite3.connect(self.data / rel)

    def stop(self, sig=signal.SIGTERM):
        if self.out.closed:
            return
        if self.p.poll() is None:
            self.p.send_signal(sig)
            try:
                self.p.wait(10)
            except subprocess.TimeoutExpired:
                self.p.kill()
        self.out.close()


def sign_in(srv, stand, who, nxt="/app"):
    """The browser through /login → the provider → /auth/callback: (client, the callback reply)."""
    stand.who = who
    c = srv.client()
    r = c.get("/login", params={"next": nxt})
    assert r.status_code in (302, 303), f"/login answered {r.status_code}: {r.text[:200]}"
    a = httpx.get(r.headers["location"], follow_redirects=False, timeout=30)
    assert a.status_code == 302, f"the provider refused: {a.text}"
    cb = urllib.parse.urlsplit(a.headers["location"])
    back = c.get(cb.path + "?" + cb.query)
    return c, back


def pay(srv, stand, cl):
    url = cl.post("/billing/checkout").json()["url"]
    s = stand.pay(url.rsplit("/", 1)[1])
    body, h = signed(event("checkout.session.completed", s))
    assert srv.client().post("/billing/webhook", content=body, headers=h).status_code == 200
    return s


def invite_link(smtp, addr):
    msgs = wait_until(lambda: smtp.to(addr), 20)
    for m in msgs or []:
        for part in m.walk():
            if part.get_content_type() in ("text/plain", "text/html"):
                found = re.search(r"https?://127\.0\.0\.1:\d+/invites/[A-Za-z0-9_\-\.~%]+", part.get_content())
                if found:
                    return found.group(0)
    return None


# ---------------------------------------------------------------- milestones

def m0():
    env = ROOT / ".pixi"
    if env.is_symlink() or not env.is_dir():
        return False, ".pixi isn't this worktree's own directory"
    if " 1.2" not in run(["pixi", "run", "mojo", "--version"]).stdout:
        return False, "mojo isn't 1.2"
    r = run(["pixi", "run", "python", "docs/goals/57-check.py", "M1", "M2", "M3", "M4"], 5400)
    (OUT / "m0-57.txt").write_text(r.stdout + r.stderr)
    res = {k: re.search(rf"^{k}: (\w+)  (.*)$", r.stdout, re.M) for k in ("M1", "M2", "M3", "M4")}
    for k in ("M1", "M3", "M4"):
        if not res[k] or res[k].group(1) != "PASS":
            return False, f"goal 57's {k}: {res[k].group(0) if res[k] else 'no result'}"
    m2 = res["M2"]
    if not m2 or not (m2.group(1) == "PASS" or (m2.group(1) == "FAIL" and m2.group(2).startswith("the invited viewer"))):
        return False, f"goal 57's M2 may fail only at the silent invite: {m2.group(0) if m2 else 'no result'}"
    return True, f"own env, Mojo 1.2; goal 57 M1, M3, M4 PASS, M2 {m2.group(1)} ({'at the silent invite, replaced by M5' if m2.group(1) == 'FAIL' else 'whole'})"


def scenario(name, smtp_mode="off", extra=None):
    stand, smtp = StandIn(), Smtp(smtp_mode)
    return stand, smtp, Server(name, stand, smtp, extra)


def m1():
    ok, why = mojo_test("tests/test_log.mojo", ["json", "redact", "rotate", "secrets"])
    if not ok:
        return False, "tests/test_log.mojo: " + why
    stand, smtp, srv = scenario("m1")
    try:
        ada, back = sign_in(srv, stand, ("ada@example.com", "Ada"))
        rid = back.headers.get("x-request-id", "")
        ada.post("/api/entries", json={"text": "coffee", "amount_cents": 450})
        ada.post("/api/invites", json={"email": "cy@example.com", "role": "viewer"})
        pay(srv, stand, ada)
        wait_until(lambda: smtp.to("cy@example.com"), 15)
        time.sleep(1)
        if not srv.logfile.exists():
            return False, "no $SAAS_LOG file"
        lines = [l for l in srv.logfile.read_text().splitlines() if l.strip()]
        recs = []
        for l in lines:
            try:
                recs.append(json.loads(l))
            except ValueError:
                return False, f"a log line isn't JSON: {l[:120]}"
        reqs = [r for r in recs if r.get("method") and r.get("path") is not None]
        need = {"ts", "level", "rid", "method", "path", "status", "ms"}
        if not reqs or any(need - set(r) for r in reqs):
            return False, f"request lines lack {need - set(reqs[0]) if reqs else need}"
        if any("?" in r["path"] for r in reqs):
            return False, "a request line's path keeps its query"
        if not rid or rid not in {r["rid"] for r in reqs}:
            return False, f"X-Request-Id {rid!r} isn't a logged rid"
        text = srv.logfile.read_text() + (srv.data / "server.out").read_text()
        secrets_seen = [ada.cookies.get("saas") or "", CLIENT_SECRET, STRIPE_KEY, SMTP_PASSWORD, WEBHOOK_SECRET] + list(stand.tokens) + stand.states
        leaked = [s[:6] + "…" for s in secrets_seen if s and len(s) >= 8 and s in text]
        if leaked:
            return False, f"the logs hold secrets: {leaked}"
        with srv.db("host.db") as c:
            acts = {a for (a,) in c.execute("select action from audit where tenant is not null and actor is not null")}
        if not {"sign_in", "invite", "plan_change"} <= acts:
            return False, f"audit actions: {sorted(acts)}"
        return True, f"{len(reqs)} JSON request lines with rids, no secrets in either log, audit {sorted(acts)}"
    finally:
        srv.stop()
        stand.close()
        smtp.close()


def m2():
    ok, why = mojo_test("tests/test_migrate.mojo", ["apply", "idempotent", "broken", "checksum", "down", "race"])
    if not ok:
        return False, "tests/test_migrate.mojo: " + why
    src = MIGRATIONS / "tenant"
    if not src.is_dir() or not list(src.glob("[0-9][0-9][0-9]_*.sql")):
        return False, "no examples/saas/migrations/tenant/NNN_name.sql"
    mig = OUT / "m2-migrations"
    shutil.rmtree(mig, ignore_errors=True)
    shutil.copytree(MIGRATIONS, mig)
    top = max(int(p.name[:3]) for p in (mig / "tenant").glob("[0-9][0-9][0-9]_*.sql"))
    extra = {"SAAS_MIGRATIONS": str(mig)}
    stand, smtp = StandIn(), Smtp()
    srv = Server("m2", stand, smtp, extra)
    try:
        tenants = []
        for who in (("ada@example.com", "Ada"), ("ben@example.com", "Ben")):
            cl, _ = sign_in(srv, stand, who)
            tenants.append(cl.get("/api/me").json()["tenant"])
        srv.stop()

        def state(t):
            with srv.db(f"tenants/{t}.db") as c:
                cols = [r[1] for r in c.execute("pragma table_info(entries)")]
                vers = [v for (v,) in c.execute("select version from schema_migrations order by version")]
                tables = {n for (n,) in c.execute("select name from sqlite_master where type='table'")}
            return cols, vers, tables

        nxt = mig / "tenant" / f"{top + 1:03d}_category.sql"
        nxt.write_text("-- up\nALTER TABLE entries ADD COLUMN category TEXT;\n-- down\nALTER TABLE entries DROP COLUMN category;\n")
        srv = Server("m2", stand, smtp, extra, keep=True)
        srv.stop()
        for t in tenants:
            cols, vers, _ = state(t)
            if "category" not in cols or vers[-1] != top + 1 or len(vers) != top + 1:
                return False, f"after {nxt.name}: columns {cols}, versions {vers}"
        with srv.db(f"tenants/{tenants[0]}.db") as c:
            if any(not cs for (cs,) in c.execute("select checksum from schema_migrations")):
                return False, "schema_migrations has an empty checksum"
        before = [(srv.data / "tenants" / f"{t}.db").read_bytes() for t in tenants]
        broken = mig / "tenant" / f"{top + 2:03d}_broken.sql"
        broken.write_text("-- up\nCREATE TABLE half_done(x);\nCREATE TABLE oops(;\n-- down\nDROP TABLE half_done;\n")
        srv = Server("m2", stand, smtp, extra, keep=True, expect_fail=True)
        started = srv.started
        srv.stop()
        if started:
            return False, "the server started with a broken migration"
        for t, b in zip(tenants, before):
            _, vers, tables = state(t)
            if vers[-1] != top + 1 or "half_done" in tables or (srv.data / "tenants" / f"{t}.db").read_bytes() != b:
                return False, f"a broken migration changed {t}: versions {vers}, half_done {'half_done' in tables}"
        broken.unlink()
        nxt.write_text(nxt.read_text().replace("category TEXT", "category  TEXT"))
        srv = Server("m2", stand, smtp, extra, keep=True, expect_fail=True)
        started = srv.started
        srv.stop()
        if started:
            return False, "the server started after an applied migration was edited"
        return True, f"{nxt.name} reached both tenants on restart; a broken {broken.name} and an edited {nxt.name} each refused, files unchanged"
    finally:
        srv.stop()
        stand.close()
        smtp.close()


def m3():
    stand, smtp = StandIn(), Smtp()
    srv = Server("m3", stand, smtp)
    try:
        ada, _ = sign_in(srv, stand, ("ada@example.com", "Ada"))
        ben, _ = sign_in(srv, stand, ("ben@example.com", "Ben"))

        def fast_while(slow, label):
            t = threading.Thread(target=slow, daemon=True)
            t.start()
            time.sleep(0.5)
            times = []
            for _ in range(20):
                t0 = time.perf_counter()
                st = ben.get("/api/me").status_code
                times.append(time.perf_counter() - t0)
                if st != 200:
                    return f"{label}: /api/me answered {st}"
            t.join(30)
            return f"{label}: slowest /api/me {max(times) * 1000:.0f} ms" if max(times) >= 0.3 else None

        stand.delay_checkout = 8
        bad = fast_while(lambda: ada.post("/billing/checkout"), "a slow Stripe")
        stand.delay_checkout = 0
        if bad:
            return False, bad
        stand.delay_token = 8
        bad = fast_while(lambda: sign_in(srv, stand, ("cat@example.com", "Cat")), "a slow Google")
        stand.delay_token = 0
        if bad:
            return False, bad
        jobs = ada.get("/api/jobs")
        if jobs.status_code != 200 or "ben@example.com" in jobs.text:
            return False, f"/api/jobs for ada: {jobs.status_code} {jobs.text[:200]}"
        # a pending job survives kill -9
        smtp.hold = 6
        base_conns = smtp.connections
        sign_in(srv, stand, ("dee@example.com", "Dee"))
        if not wait_until(lambda: smtp.connections > base_conns, 10):
            return False, "no email job started"
        time.sleep(1)
        srv.stop(signal.SIGKILL)
        smtp.hold = 0
        srv = Server("m3", stand, smtp, keep=True)
        got = wait_until(lambda: smtp.to("dee@example.com"), 60)
        if not got or len(smtp.to("dee@example.com")) > 2:
            return False, f"after kill -9 dee's welcome arrived {len(smtp.to('dee@example.com'))} times"
        time.sleep(1)
        with srv.db("host.db") as c:
            rows = c.execute("select status, attempts from jobs where json_extract(payload, '$.user') = (select id from users where email = ?)", ("dee@example.com",)).fetchall()  # (D-6022)
        if not rows or any(s != "done" for s, _ in rows):
            return False, f"dee's job rows: {rows}"
        return True, "20 × /api/me < 300 ms while Stripe and Google each sat 8 s; /api/jobs per tenant; a job resumed after kill -9 (delivered, done)"
    finally:
        srv.stop()
        stand.close()
        smtp.close()


def m4():
    ok, why = mojo_test("tests/test_mail.mojo", ["dotstuff", "header_inject", "encode", "multipart", "deadline"])
    if not ok:
        return False, "tests/test_mail.mojo: " + why
    notes = []
    stand, smtp, srv = scenario("m4", "implicit")
    try:
        sign_in(srv, stand, ("zoe@example.com", "Zoë Ångström"))
        got = wait_until(lambda: smtp.to("zoe@example.com"), 20)
        if not got:
            return False, f"no welcome email over implicit TLS ({smtp.connections} connections; {srv.data / 'server.out'})"
        m = got[0]
        if "hello@saas.example" not in str(m["From"]) or "zoe@example.com" not in str(m["To"]):
            return False, f"From/To: {m['From']} / {m['To']}"
        if "Zoë" not in str(m["Subject"]):
            return False, f"the subject doesn't name the person: {m['Subject']!r}"
        raw_subject = [l for l in m.as_bytes().split(b"\n") if l.lower().startswith(b"subject:")][0]
        if any(b > 127 for b in raw_subject):
            return False, "the raw Subject header isn't ASCII (RFC 2047)"
        kinds = {p.get_content_type() for p in m.walk()}
        if not {"text/plain", "text/html"} <= kinds:
            return False, f"parts: {kinds}"
        # refused twice, then delivered; refused always → dead
        smtp.refuse_next = 2
        sign_in(srv, stand, ("fay@example.com", "Fay"))
        if not wait_until(lambda: smtp.to("fay@example.com"), 30):
            return False, "after two 451s fay's email never arrived"
        smtp.refuse_always.add("never@example.com")
        sign_in(srv, stand, ("never@example.com", "Never"))
        time.sleep(1)

        def row(addr):
            with srv.db("host.db") as c:
                return c.execute("select status, attempts, error from jobs where json_extract(payload, '$.user') = (select id from users where email = ?) order by rowid desc", (addr,)).fetchone()  # (D-6022)

        fay = wait_until(lambda: (r := row("fay@example.com")) and r[0] == "done" and r, 10)
        if not fay or fay[1] != 3:
            return False, f"fay's job: {row('fay@example.com')} (want done after 3 attempts)"
        dead = wait_until(lambda: (r := row("never@example.com")) and r[0] == "dead" and r, 30)
        if not dead or "451" not in (dead[2] or "") or dead[1] != 4:
            return False, f"the always-refused job: {row('never@example.com')} (want dead, 4 attempts, the 451 kept)"
        # CR/LF in a name adds no header
        sign_in(srv, stand, ("eve@example.com", "Eve\r\nBcc: spy@evil.example"))
        got = wait_until(lambda: smtp.to("eve@example.com"), 20)
        if not got:
            return False, "no email for the CR/LF name"
        if got[0]["Bcc"] or any("spy@evil.example" in r for r in smtp.rcpts[-1]):
            return False, "a CR/LF in the name added a header or a recipient"
    finally:
        srv.stop()
        stand.close()
        smtp.close()
    stand, smtp, srv = scenario("m4s", "starttls")
    try:
        sign_in(srv, stand, ("sam@example.com", "Sam"))
        notes.append("STARTTLS " + ("delivers" if wait_until(lambda: smtp.to("sam@example.com"), 20) else "does not deliver"))
    finally:
        srv.stop()
        stand.close()
        smtp.close()
    doc = (ROOT / "docs/saas.md").read_text() if (ROOT / "docs/saas.md").exists() else ""
    if "STARTTLS" not in doc:
        return False, "docs/saas.md doesn't say where STARTTLS stands (" + notes[0] + ")"
    return True, "implicit TLS with AUTH, text + HTML, encoded UTF-8 subject, 3rd-attempt delivery, dead with the 451, no header injection; " + notes[0]


def m5():
    stand, smtp, srv = scenario("m5", "off", {"SAAS_INVITE_TTL": "10"})
    try:
        ada, _ = sign_in(srv, stand, ("ada@example.com", "Ada"))
        at = ada.get("/api/me").json()["tenant"]
        ada.post("/api/entries", json={"text": "ada's coffee", "amount_cents": 450})
        if ada.post("/api/invites", json={"email": "cy@example.com", "role": "viewer"}).status_code not in (200, 201):
            return False, "the admin's invite was refused"
        link = invite_link(smtp, "cy@example.com")
        if not link:
            return False, "no invite email with a /invites/ link"
        cy, _ = sign_in(srv, stand, ("cy@example.com", "Cy"))
        cme = cy.get("/api/me").json()
        if cme["tenant"] == at:
            return False, "the invited person was joined without accepting"
        cy.post("/api/entries", json={"text": "cy's own", "amount_cents": 7})
        path = urllib.parse.urlsplit(link).path
        page = cy.get(path)
        if page.status_code != 200 or "Join" not in page.text or "Ada" not in page.text:
            return False, f"the accept page: {page.status_code} {page.text[:200]}"
        if cy.post(path, headers={"Origin": "https://evil.example"}).status_code not in (403, 400):
            return False, "a cross-origin accept wasn't refused"
        if cy.post(path, headers={"Origin": srv.base}).status_code not in (200, 201, 303):
            return False, "the same-origin accept failed"
        if cy.get(path).status_code != 410 or cy.post(path, headers={"Origin": srv.base}).status_code != 410:
            return False, "a used invite link isn't 410"
        ts = cy.get("/api/tenants").json()
        ids = {t["tenant"] if isinstance(t, dict) else t for t in (ts.get("tenants", ts) if isinstance(ts, dict) else ts)}
        if not {at, cme["tenant"]} <= ids:
            return False, f"/api/tenants: {ts}"
        if cy.post("/api/switch", json={"tenant": at}).status_code != 200:
            return False, "switching to ada's tenant failed"
        me2 = cy.get("/api/me").json()
        rows = cy.get("/api/entries").text
        if me2["tenant"] != at or me2["role"] != "viewer" or "ada's coffee" not in rows or "cy's own" in rows:
            return False, f"after the switch: {me2}, rows {rows[:120]}"
        if cy.post("/api/entries", json={"text": "x", "amount_cents": 1}).status_code != 403:
            return False, "the viewer could write after the switch"
        cy.post("/api/switch", json={"tenant": cme["tenant"]})
        if "ada's coffee" in cy.get("/api/entries").text:
            return False, "ada's rows followed cy home"
        ben, _ = sign_in(srv, stand, ("ben@example.com", "Ben"))
        if ben.post("/api/switch", json={"tenant": at}).status_code != 403:
            return False, "ben switched into ada's tenant"
        ada.post("/api/invites", json={"email": "dan@example.com", "role": "editor"})
        dlink = urllib.parse.urlsplit(invite_link(smtp, "dan@example.com") or "/none").path
        if ben.get(dlink).status_code != 403 or ben.post(dlink, headers={"Origin": srv.base}).status_code != 403:
            return False, "another person could open or accept dan's invite"
        ada.post("/api/invites", json={"email": "eve@example.com", "role": "viewer"})
        elink = urllib.parse.urlsplit(invite_link(smtp, "eve@example.com") or "/none").path
        time.sleep(11)
        eve, _ = sign_in(srv, stand, ("eve@example.com", "Eve"))
        if eve.get(elink).status_code != 410:
            return False, "an expired invite isn't 410"
        with srv.db("host.db") as c:
            if not c.execute("select 1 from audit where action='invite_accept'").fetchone():
                return False, "no invite_accept audit row"
        return True, "invite by email, no silent join, same-origin accept only, 403 for others, 410 used/expired, two tenants listed and switched without leaks"
    finally:
        srv.stop()
        stand.close()
        smtp.close()


def m6():
    stand, smtp, srv = scenario("m6", "off", {"SAAS_TRIAL_DAYS": "0.0001", "STRIPE_TRIAL_DAYS": "14", "SAAS_GRACE_DAYS": "0.0001"})
    try:
        ada, _ = sign_in(srv, stand, ("ada@example.com", "Ada"))
        if ada.get("/api/pro").status_code != 200 or ada.get("/api/me").json().get("plan") != "trial":
            return False, f"a new tenant isn't on a trial: {ada.get('/api/me').text}"
        time.sleep(10)
        if ada.get("/api/pro").status_code != 402:
            return False, "the trial didn't expire"
        s = pay(srv, stand, ada)
        if stand.forms[-1].get("subscription_data[trial_period_days]") != "14":
            return False, f"checkout lacks the Stripe trial: {stand.forms[-1]}"
        if ada.get("/api/pro").status_code != 200:
            return False, "paid but not Pro"
        r = ada.post("/billing/portal")
        if r.status_code != 200 or not r.json().get("url", "").startswith(stand.base + "/portal/") or stand.portals[-1]["customer"] != s["customer"]:
            return False, f"/billing/portal: {r.status_code} {r.text[:200]} {stand.problems}"
        end = int(time.time()) + 30 * 86400
        sub = {"id": s["subscription"], "object": "subscription", "customer": s["customer"], "status": "active", "cancel_at_period_end": True, "current_period_end": end}
        body, h = signed(event("customer.subscription.updated", sub))
        srv.client().post("/billing/webhook", content=body, headers=h)
        me = ada.get("/api/me").json()
        if ada.get("/api/pro").status_code != 200 or not me.get("cancels_at"):
            return False, f"cancel at period end: {me}"
        sub.update(status="past_due", cancel_at_period_end=False)
        body, h = signed(event("customer.subscription.updated", sub))
        srv.client().post("/billing/webhook", content=body, headers=h)
        if ada.get("/api/pro").status_code != 200:
            return False, "past_due cut Pro off before the grace period"
        time.sleep(10)
        if ada.get("/api/pro").status_code != 402:
            return False, "past_due still Pro after the grace period"
        return True, "trial on first sign-in that expires, Stripe trial days, customer portal, cancel at period end, past_due after grace"
    finally:
        srv.stop()
        stand.close()
        smtp.close()


def m7():
    stand, smtp, srv = scenario("m7", "off", {"SAAS_RATE": "10", "SAAS_SESSION_IDLE": "4"})
    try:
        codes = [srv.client().get("/login").status_code for _ in range(13)]
        last = srv.client().get("/login")
        if 429 not in codes or last.status_code != 429 or not last.headers.get("retry-after"):
            return False, f"/login 14 times: {codes + [last.status_code]}, Retry-After {last.headers.get('retry-after')}"
        tok = [srv.client().post("/api/token", json={"code": "x", "verifier": "y" * 43}).status_code for _ in range(13)]
        if tok[-1] != 429:
            return False, f"/api/token 13 times: {tok}"
        time.sleep(61)
        cl, _ = sign_in(srv, stand, ("ada@example.com", "Ada"))
        for _ in range(5):
            if cl.get("/api/me").status_code != 200:
                return False, "an active session expired"
            time.sleep(2)
        time.sleep(6)
        if cl.get("/api/me").status_code != 401:
            return False, "an idle session didn't expire"
        doc = (ROOT / "docs/saas.md").read_text()
        if "Known limits" not in doc:
            return False, "docs/saas.md lost its Known limits"
    finally:
        srv.stop()
        stand.close()
        smtp.close()
    ok, why = m7_proxies()
    if not ok:
        return False, why
    return True, "429 + Retry-After over the per-IP limit, sliding sessions (use extends, idle ends); " + why


def m7_proxies():
    """D-6025: behind a trusted proxy each client has its own limit (IPv6 by /64); an untrusted peer's header is ignored."""
    def logins(srv, xff, n):
        out = []
        for _ in range(n):
            out.append(srv.client().get("/login", headers={"X-Forwarded-For": xff} if xff else {}).status_code)
        return out
    stand, smtp, srv = scenario("m7p", "off", {"SAAS_RATE": "3", "SAAS_TRUSTED_PROXIES": "127.0.0.1/32"})
    try:
        a = logins(srv, "198.51.100.7, 203.0.113.5", 4)
        if a != [303, 303, 303, 429]:
            return False, f"a client behind the trusted proxy, 4 sign-ins: {a} (want 3 × 303, then 429)"
        b = logins(srv, "203.0.113.6", 1)
        if b != [303]:
            return False, f"another client behind the same proxy shared the first one's limit: {b}"
        v6 = logins(srv, "2001:db8:1:2::1", 3) + logins(srv, "2001:db8:1:2::ffff", 1)
        if v6 != [303, 303, 303, 429]:
            return False, f"one IPv6 /64, 4 sign-ins: {v6}"
        if logins(srv, "2001:db8:1:3::1", 1) != [303]:
            return False, "the next /64 shared the first one's limit"
        two = [srv.client().get("/login", headers=[("X-Forwarded-For", f"198.51.100.{i}"), ("X-Forwarded-For", "203.0.113.77")]).status_code for i in range(4)]
        if two != [303, 303, 303, 429]:
            return False, f"a client rotating its own X-Forwarded-For line before the proxy's: {two} (D-6027: every line is read)"
    finally:
        srv.stop()
        stand.close()
        smtp.close()
    stand, smtp, srv = scenario("m7c", "off", {"SAAS_RATE": "0", "SAAS_TRUSTED_PROXIES": "127.0.0.1/32"})
    try:
        held = [srv.client().get("/login", headers={"X-Forwarded-For": "203.0.113.90"}).status_code for _ in range(21)]
        other = srv.client().get("/login", headers={"X-Forwarded-For": "203.0.113.91"}).status_code
        if held[:20] != [303] * 20 or held[20] != 429 or other != 303:
            return False, f"pending sign-ins per client: one client's 21 → {held[-2:]}, another's → {other} (D-6027)"
    finally:
        srv.stop()
        stand.close()
        smtp.close()
    stand, smtp, srv = scenario("m7u", "off", {"SAAS_RATE": "3", "SAAS_TRUSTED_PROXIES": "10.0.0.0/8"})
    try:
        u = [srv.client().get("/login", headers={"X-Forwarded-For": f"203.0.113.{i}"}).status_code for i in range(4)]
        if u != [303, 303, 303, 429]:
            return False, f"an untrusted peer rotating X-Forwarded-For: {u} (its header must be ignored)"
    finally:
        srv.stop()
        stand.close()
        smtp.close()
    stand, smtp = StandIn(), Smtp("off")
    bad = Server("m7b", stand, smtp, {"SAAS_TRUSTED_PROXIES": "proxy.internal"}, expect_fail=True)
    try:
        if bad.started:
            return False, "a proxy list it can't read (a name) started anyway"
    finally:
        bad.stop()
        stand.close()
        smtp.close()
    return True, "trusted proxy: a client per X-Forwarded-For, IPv6 per /64; an untrusted peer's header ignored; two X-Forwarded-For lines read whole; 20 pending sign-ins a client; a bad list refuses to start"


def m8():
    doc = (ROOT / "docs/saas.md").read_text()
    for mod in ("utils_auth", "db_host", "db_tenant", "utils_billing", "utils_stripe", "utils_webhook", "utils_email", "utils_bgtsk", "utils_migrate", "utils_log"):
        row = next((l for l in doc.splitlines() if l.startswith(f"| `{mod}`")), "")
        if "✅" not in row or "❌" in row:
            return False, f"docs/saas.md's {mod} row isn't ✅: {row[:160]}"
    if "SMTP_HOST" not in (ROOT / "scripts/saas_keys.sh").read_text():
        return False, "scripts/saas_keys.sh doesn't ask for SMTP"
    # the demo on GTK: a trial, the billing button
    import headless
    headless.ensure()
    b = run(["scripts/build.sh", "saas", "linux"], 3600)
    if b.returncode or not APP.exists():
        return False, "the app didn't build: " + (b.stdout + b.stderr)[-800:]
    stand, smtp, srv = scenario("m8", "off", {"SAAS_TRIAL_DAYS": "14"})
    opened, seen, stop = OUT / "m8-opened.txt", [], threading.Event()
    opened.write_text("")
    opener = OUT / "m8-opener.sh"
    opener.write_text(f'#!/bin/sh\necho "$1" >> {opened}\n')
    opener.chmod(0o755)
    t = threading.Thread(target=g57.play_browser, args=(srv, stand, opened, seen, stop), daemon=True)
    t.start()
    try:
        shot = OUT / "m8.png"
        r = run([str(APP)], 600, {"MOJOUI_TEST": "tap:Sign in with Google;waitfor:Sign out=20000;waitfor:Manage billing=10000", "MOJOUI_OPENER": str(opener),
                                  "SAAS_SERVER": srv.base, "MOJOUI_SHOT": str(shot), "MOJOUI_WINDOW": "900x700"})
        out = r.stdout + r.stderr
        (OUT / "m8.out").write_text(out)
        if not re.search(r"^LABEL:? .*Trial", out, re.M) or not re.search(r"^BUTTON:? .*Manage billing", out, re.M):
            return False, "the demo shows no Trial label or Manage billing button (build/g60/m8.out)"
    finally:
        stop.set()
        srv.stop()
        stand.close()
        smtp.close()
    if not re.search(r"looked at.*m8\.png", (ROOT / "docs/journal.md").read_text()):
        return False, "build/g60/m8.png isn't recorded as looked at in docs/journal.md"
    # the owner's Mac
    ssh = MAC_SSH + [MAC]
    if subprocess.run(ssh + ["true"], capture_output=True, timeout=30).returncode:
        return None, "the Mac isn't reachable over SSH"
    sync = subprocess.run(["rsync", "-az", "--delete", "-e", " ".join(MAC_SSH), "--exclude=/build", "--exclude=/.pixi", "--exclude=/dist", "--exclude=/.git",
                           "--exclude=node_modules", "--exclude=__pycache__", f"{ROOT}/", f"{MAC}:omxcode-g60/"], capture_output=True, text=True, timeout=600)
    if sync.returncode:
        return False, "rsync to the Mac: " + sync.stderr[-300:]
    r = subprocess.run(ssh + ["cd ~/omxcode-g60 && export PATH=$HOME/.pixi/bin:$PATH && pixi install >/dev/null && pixi run python docs/goals/60-check.py M1 M3 M5 M6"],
                       capture_output=True, text=True, timeout=5400)
    (OUT / "m8-mac.out").write_text(r.stdout + r.stderr)
    res = {k: re.search(rf"^{k}: (\w+)  (.*)$", r.stdout, re.M) for k in ("M1", "M3", "M5", "M6")}
    bad = [f"{k}: {m.group(1)} {m.group(2)[:200]}" if m else f"{k}: no result" for k, m in res.items() if not m or m.group(1) != "PASS"]
    if bad:
        return False, "on the Mac: " + "; ".join(bad)
    return True, "parity rows ✅, keys wizard asks for SMTP, GTK demo shows the trial and billing (shot looked at); M1, M3, M5, M6 pass on the Mac"


def m9():
    r = run(["pixi", "run", "python", "docs/goals/57-check.py", "M6", "M7", "M8"], 5400)
    (OUT / "m9-57.txt").write_text(r.stdout + r.stderr)
    for k in ("M6", "M7", "M8"):
        m = re.search(rf"^{k}: (\w+)  (.*)$", r.stdout, re.M)
        if m and k == "M8" and m.group(1) == "FAIL" and re.fullmatch(r"on the Mac: M2: FAIL the invited viewer: [^;]*", m.group(2)):
            continue  # (D-6013: only goal 57's silent invite, which M5 replaced on purpose, as M0 allows)
        if not m or m.group(1) != "PASS":
            return False, f"goal 57's {k}: {m.group(0) if m else 'no result'}"
    tests = {"tests/test_crypto.mojo": [], "tests/test_accounts.mojo": ["accounts", "identity", "outbox", "cookies", "sweep", "per_client"],
             "tests/test_billing.mojo": ["out_of_order"], "tests/test_ui_thread.mojo": [], "tests/test_served.mojo": [],
             # (D-6025: round 3's tests in the goal's checker)
             "tests/test_handler.mojo": ["handler", "offload", "header_inject", "body_cap", "client_ip"],
             "tests/test_ratelimit.mojo": ["limit", "window", "flood"],
             "tests/test_queue.mojo": ["claim_race", "backoff", "resume", "outbox", "sweep"],
             "tests/test_clientip.mojo": ["parse", "trusted", "untrusted", "ipv6"]}
    for src, labels in tests.items():
        ok, why = mojo_test(src, labels)
        if not ok:
            return False, f"{src}: {why}"
    ok, why = mojo_test("tests/test_pool.mojo", ["tenants", "held", "threads"], nofile=256)
    if not ok:
        return False, f"tests/test_pool.mojo (ulimit -n 256): {why}"
    for lint in ("scripts/libc_lint.py", "scripts/decisions_lint.py"):
        rr = run(["pixi", "run", "python", lint])
        if rr.returncode:
            return False, f"{lint}: " + (rr.stdout + rr.stderr)[-300:]
    return True, "goal 57's M6–M8, the crypto/accounts/billing/ui-thread/served/handler/ratelimit/queue/clientip tests, the pool under ulimit -n 256, libc and decision lints"


FLOWS = ("me", "entries_get", "entries_post", "webhook", "callback")


def m10():
    t0 = time.time()
    out = OUT / "bench.json"
    r = run(["pixi", "run", "python", "scripts/saas_bench.py", "--json", str(out)], 5400)
    (OUT / "m10.out").write_text(r.stdout + r.stderr)
    if r.returncode or not out.exists():
        return False, "scripts/saas_bench.py failed: " + (r.stdout + r.stderr)[-600:]
    res = json.loads(out.read_text())
    if res.get("started", 0) < t0 - 1:
        return False, "the bench's numbers aren't from this run"
    page = ROOT / "docs/goals/60-bench.md"
    if not page.exists() or page.stat().st_mtime < t0:
        return False, "docs/goals/60-bench.md wasn't written by this run"
    slower = []
    for f in FLOWS:
        try:
            o, b = res["flows"][f]["omxcode"]["c64"], res["flows"][f]["fhsaas"]["c64"]
        except KeyError:
            return False, f"no 64-client numbers for {f}"
        if not o["p50_ms"] < b["p50_ms"]:
            slower.append(f"{f} p50 {o['p50_ms']:.2f} vs {b['p50_ms']:.2f} ms")
        if not o["p99_ms"] < b["p99_ms"]:
            slower.append(f"{f} p99 {o['p99_ms']:.2f} vs {b['p99_ms']:.2f} ms")
        if not o["rps"] > b["rps"]:
            slower.append(f"{f} {o['rps']:.0f} vs {b['rps']:.0f} req/s")
    if slower:
        return False, "omxcode isn't faster at 64 clients: " + "; ".join(slower)
    worst = min(res["flows"][f]["omxcode"]["c64"]["rps"] / max(res["flows"][f]["fhsaas"]["c64"]["rps"], 1e-9) for f in FLOWS)
    return True, f"faster than fh-saas on p50, p99 and req/s for {', '.join(FLOWS)} at 64 clients (the closest: {worst:.1f}x the throughput); docs/goals/60-bench.md"


def mojo_imports(path):
    """The mojoui modules a .mojo file imports (from mojoui.x import / from mojoui import x, y / import mojoui.x)."""
    text = path.read_text(errors="replace")
    mods = set(re.findall(r"^\s*from\s+mojoui\.(\w+)", text, re.M)) | set(re.findall(r"^\s*import\s+mojoui\.(\w+)", text, re.M))
    for names in re.findall(r"^\s*from\s+mojoui\s+import\s+([\w, ]+)", text, re.M):
        mods |= {n.strip() for n in names.split(",") if n.strip()}
    return mods


def closure(files):
    seen, todo = set(), set()
    for f in files:
        todo |= mojo_imports(f)
    while todo:
        m = todo.pop()
        if m in seen:
            continue
        seen.add(m)
        src = ROOT / "mojoui" / f"{m}.mojo"
        if src.exists():
            todo |= mojo_imports(src) - seen
    return seen


def m11():
    src = sorted((ROOT / "examples/saas_min").glob("*.mojo"))
    if not src:
        return False, "no examples/saas_min/*.mojo"
    lines = sum(1 for f in src for l in f.read_text().splitlines() if l.strip() and not l.strip().startswith("#"))
    if lines > 80:
        return False, f"examples/saas_min has {lines} lines of code (> 80)"
    used = closure(src)
    if not {"accounts", "mail", "jobs"} <= used:
        return False, f"saas_min doesn't use accounts, mail and jobs: {sorted(used)}"
    if "billing" in used:
        return False, "billing is linked into saas_min: " + " → ".join(sorted(used))
    for mod, banned in (("accounts", {"billing", "mail"}), ("mail", {"billing", "accounts"}), ("jobs", {"billing", "accounts", "mail"}),
                        ("migrate", {"billing", "accounts", "mail", "jobs"}), ("log", {"billing", "accounts", "mail", "jobs"})):
        extra = closure([ROOT / "mojoui" / f"{mod}.mojo"]) & banned
        if extra:
            return False, f"mojoui.{mod} pulls in {sorted(extra)}"
    doc = (ROOT / "docs/saas.md").read_text()
    for mod in ("accounts", "billing", "mail", "jobs", "migrate", "log"):
        sec = re.search(rf"^### `?mojoui\.{mod}`?.*?\n(.*?)(?=^### |^## |\Z)", doc, re.M | re.S)
        if not sec or "```" not in sec.group(1):
            return False, f"docs/saas.md has no API section with a snippet for mojoui.{mod}"
    exe = ROOT / "build/saas_min/server"
    exe.parent.mkdir(parents=True, exist_ok=True)
    exe.unlink(missing_ok=True)
    b = run(["scripts/mojo_flare.sh", "build", "examples/saas_min/server.mojo", "-o", str(exe)], 3600)
    if b.returncode or not exe.exists():
        return False, "saas_min didn't build: " + (b.stdout + b.stderr)[-800:]
    stand, smtp = StandIn(), Smtp()
    srv = Server("m11", stand, smtp, exe=exe)
    try:
        cl, back = sign_in(srv, stand, ("min@example.com", "Min"))
        me = cl.get("/api/me")
        if me.status_code != 200 or me.json().get("email") != "min@example.com" or not me.json().get("tenant"):
            return False, f"saas_min's /api/me: {me.status_code} {me.text[:200]}"
        got = wait_until(lambda: smtp.to("min@example.com"), 20)
        if not got or "Min" not in str(got[0]["Subject"]):
            return False, "saas_min sent no welcome email naming the person"
        return True, f"saas_min: {lines} lines on accounts + mail + jobs (billing not linked), sign-in, a tenant and a welcome email; API documented"
    finally:
        srv.stop()
        stand.close()
        smtp.close()


# ---------------------------------------------------------------- M12: hardening after goal 60 (2026-11-11)

def desktop_login(srv, stand, who, verifier, app_state="app-state-1"):
    """A browser (one cookie jar, as a real one) through a desktop /login → the provider → /auth/callback:
    (browser, the callback's reply, the app's loopback URL, the callback's path and query)."""
    stand.who = who
    loop = f"http://127.0.0.1:{free_port()}/done"
    br = srv.client()
    r = br.get("/login", params={"client": "desktop", "redirect": loop, "challenge": s256(verifier), "app_state": app_state})
    assert r.status_code == 303, f"desktop /login answered {r.status_code}: {r.text[:200]}"
    a = httpx.get(r.headers["location"], follow_redirects=False, timeout=30)
    assert a.status_code == 302, f"the provider refused: {a.text}"
    cb = urllib.parse.urlsplit(a.headers["location"])
    path = cb.path + "?" + cb.query
    return br, br.get(path), loop, path


def confirm_form(page):
    """The confirm page's form: (action, {hidden fields})."""
    act = re.search(r"<form[^>]*action=['\"]?([^'\" >]+)", page)
    fields = dict(re.findall(r"<input type=hidden name=['\"]?(\w+)['\"]? value=['\"]?([^'\" >]*)", page))
    return (act.group(1) if act else None), fields


def m12_desktop():
    """Item 1 (RFC 8252's phishing risk): a desktop sign-in's code is released only by a same-origin POST from a
    "Sign in to <app> on this computer?" page; a GET never puts it in the address bar."""
    stand, smtp, srv = scenario("m12d")
    try:
        codes = lambda: srv.db("host.db").execute("select count(*) from desktop_codes").fetchone()[0]  # noqa: E731
        v = "v" * 20 + secrets.token_urlsafe(24)
        br, back, loop, path = desktop_login(srv, stand, ("ada@example.com", "Ada"), v)
        page = back.text
        if back.status_code != 200 or "location" in back.headers or "on this computer" not in page or "omxcode SaaS" not in page:
            return False, f"the desktop callback didn't answer the confirm page: {back.status_code} {back.headers.get('location', '')[:80]} {page[:200]}"
        if "code=" in str(back.headers) or loop in str(back.headers) or codes() != 0:
            return False, f"the callback's GET released a code ({codes()} rows, headers {dict(back.headers)})"
        if "no-store" not in back.headers.get("cache-control", "") or "frame-ancestors 'none'" not in back.headers.get("content-security-policy", ""):
            return False, f"the confirm page can be cached or framed: {dict(back.headers)}"
        act, fields = confirm_form(page)
        if act != "/auth/desktop" or not fields.get("confirm"):
            return False, f"no confirm form posting to /auth/desktop: {act} {fields}"
        if br.get(path).status_code < 400:
            return False, "the callback's URL worked twice"
        for label, h in (("cross-site", {"Origin": "https://evil.example"}), ("no Origin", {}), ("Sec-Fetch-Site cross-site", {"Sec-Fetch-Site": "cross-site"})):
            r = br.post(act, data=dict(fields, do="yes"), headers=h)
            if r.status_code != 403 or "location" in r.headers or codes() != 0:
                return False, f"a {label} confirm: {r.status_code} {r.headers.get('location', '')[:80]} ({codes()} codes)"
        r = br.post(act, data=dict(fields, do="yes"), headers={"Origin": srv.base})
        loc = r.headers.get("location", "")
        q = {k: x[0] for k, x in urllib.parse.parse_qs(urllib.parse.urlsplit(loc).query).items()}
        if r.status_code != 303 or not loc.startswith(loop + "?") or not q.get("code") or q.get("state") != "app-state-1":
            return False, f"the same-origin confirm: {r.status_code} {loc[:120]}"
        if br.post(act, data=dict(fields, do="yes"), headers={"Origin": srv.base}).status_code < 400:
            return False, "the confirm worked twice"
        tok = srv.client().post("/api/token", json={"code": q["code"], "verifier": v})
        if tok.status_code != 200 or srv.client().get("/api/me", headers={"Authorization": "Bearer " + tok.json()["token"]}).json().get("email") != "ada@example.com":
            return False, f"the released code didn't trade for ada's token: {tok.status_code} {tok.text[:200]}"
        # cancelled: no code, ever
        br2, back2, loop2, _ = desktop_login(srv, stand, ("ada@example.com", "Ada"), v)
        act2, f2 = confirm_form(back2.text)
        no = br2.post(act2, data=dict(f2, do="no"), headers={"Origin": srv.base})
        yes = br2.post(act2, data=dict(f2, do="yes"), headers={"Origin": srv.base})
        if no.status_code != 200 or "location" in no.headers or yes.status_code < 400 or "location" in yes.headers or codes() != 0:
            return False, f"cancel then confirm: {no.status_code}/{yes.status_code} {yes.headers.get('location', '')[:80]} ({codes()} codes)"
        return True, "desktop: the confirm page (no code on GET, no-store, never framed), cross-site / Origin-less confirms 403, one same-origin confirm releases the code, cancel releases none"
    finally:
        srv.stop()
        stand.close()
        smtp.close()


def m12():
    for step in (m12_desktop,):
        ok, why = step()
        if not ok:
            return False, f"{step.__name__}: {why}"
    return True, "hardening: desktop confirm page"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7, "M8": m8, "M9": m9, "M10": m10, "M11": m11, "M12": m12}

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
