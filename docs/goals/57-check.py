"""Goal 57's proof: SaaS building blocks in omxcode, Mojo only (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/57-check.py [M0 M1 ...]          (default: every milestone)

Google and Stripe are played by stand-ins written here, not by the code under test: the OAuth server checks PKCE, the
client secret and the redirect; the Stripe one checks the key and the form fields; webhooks are signed by this file's
own HMAC. Truth is the SQLite files the server writes and what comes back over HTTP, never the server's word for it.

The contract the server keeps (build/saas/server, built by `scripts/saas.sh build`):
  env   SAAS_PORT SAAS_DATA SAAS_BASE SAAS_SECRET GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
        SAAS_OAUTH_AUTHORIZE SAAS_OAUTH_TOKEN SAAS_OAUTH_USERINFO (default: Google's)
        SAAS_STRIPE_API (default https://api.stripe.com) STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET STRIPE_PRICE_PRO
        prints `SAAS: listening <port>` once it answers
  GET  /login[?next=]                     303 to the provider (response_type=code, client_id, redirect_uri=<base>/auth/callback,
                                          scope with openid email, state, code_challenge, code_challenge_method=S256)
  GET  /login?client=desktop&redirect=<loopback>&challenge=<S256>&app_state=<s>   the same, for a native app (RFC 8252)
  GET  /auth/callback?code&state          web: 303 to next with Set-Cookie saas=…; desktop: 200 "Sign in to <app> on this computer?"
  POST /auth/desktop {confirm, do=yes}    desktop, same origin only: 303 to redirect?code=<once>&state=<app_state> (hardening, D-6029)
  POST /api/token {code, verifier}        desktop: {token}; `Authorization: Bearer <token>` then works on /api/*
  GET  /api/me                            {email, tenant, role, plan} | 401
  GET  /api/entries   POST /api/entries {text, amount_cents}     the tenant's tenants/<tenant>.db, table entries(text, amount_cents)
  POST /api/invites {email, role}         admin only
  GET  /api/pro                           200 for Pro, 402 otherwise
  POST /logout                            ends the session server-side (same site, or a bearer token); GET /logout: a page with
                                          the button, signing nobody out (hardening, D-6034)
  POST /billing/checkout                  {url}       GET /billing/return?session_id=   POST /billing/webhook
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
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
OUT = ROOT / "build/g57"
SERVER = ROOT / "build/saas/server"
APP = ROOT / "build/saas/linux/saas"
MAC_APP = ROOT / "build/saas/mac/SaasMojo.app/Contents/MacOS/SaasMojo"
KEYS = Path.home() / ".config/omxcode/saas.env"
MAC = "bhoomijaprasad@100.76.9.101"  # the owner's Mac (M8, D-5708): only ~/omxcode-g57 there
MAC_SSH = ["ssh", "-i", str(Path.home() / ".ssh/edx_mac"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
CLIENT_ID, CLIENT_SECRET = "client-57.apps.example", "secret-57"
STRIPE_KEY, WEBHOOK_SECRET, PRICE = "sk_test_stand_in_57", "whsec_stand_in_57", "price_pro_57"
sys.path.insert(0, str(ROOT / "scripts"))


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def mojo_test(src, labels, timeout=1800):
    exe = ROOT / "build" / Path(src).stem
    b = run(["scripts/mojo_flare.sh", "build", src, "-o", str(exe)], timeout)
    if b.returncode:
        return False, (b.stdout + b.stderr)[-1500:]
    r = run([str(exe)], timeout)
    out = r.stdout + r.stderr
    missing = [l for l in labels if not re.search(rf"^{re.escape(l)}: ok", out, re.M)]
    return (r.returncode == 0 and not missing), (f"missing {missing}" if missing else "") + out[-600:]


# ---------------------------------------------------------------- the stand-ins

def s256(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


class StandIn:
    """One HTTP server playing Google's OAuth endpoints and Stripe's API. `who` is the person the next consent signs in."""

    def __init__(self):
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.who = ("ada@example.com", "Ada")
        self.codes, self.tokens, self.sessions, self.problems, self.forms = {}, {}, {}, [], []
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
                return urllib.parse.parse_qs(self.rfile.read(n).decode(), keep_blank_values=True)

            def do_GET(self):
                u = urllib.parse.urlsplit(self.path)
                q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
                if u.path == "/authorize":
                    need = {"response_type": "code", "client_id": CLIENT_ID, "code_challenge_method": "S256"}
                    bad = [k for k, v in need.items() if q.get(k) != v] + [k for k in ("redirect_uri", "state", "code_challenge") if not q.get(k)]
                    if "openid" not in q.get("scope", "").split() or "email" not in q.get("scope", "").split():
                        bad.append("scope")
                    if bad:
                        me.problems.append(f"authorize: {bad}")
                        return self.reply(400, {"error": "invalid_request", "bad": bad})
                    code = secrets.token_urlsafe(16)
                    me.codes[code] = dict(challenge=q["code_challenge"], redirect=q["redirect_uri"], who=me.who)
                    loc = q["redirect_uri"] + ("&" if "?" in q["redirect_uri"] else "?") + urllib.parse.urlencode({"code": code, "state": q["state"]})
                    return self.reply(302, None, [("Location", loc)])
                if u.path == "/userinfo":
                    tok = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
                    if tok not in me.tokens:
                        return self.reply(401, {"error": "invalid_token"})
                    email, name = me.tokens[tok]
                    return self.reply(200, {"sub": "sub-" + email, "email": email, "email_verified": True, "name": name})
                m = re.fullmatch(r"/v1/checkout/sessions/(cs_test_\w+)", u.path)
                if m:
                    if not me.stripe_auth(self):
                        return self.reply(401, {"error": {"type": "invalid_request_error"}})
                    s = me.sessions.get(m.group(1))
                    return self.reply(200, s) if s else self.reply(404, {"error": {"code": "resource_missing"}})
                return self.reply(404, {})

            def do_POST(self):
                u = urllib.parse.urlsplit(self.path)
                f = {k: v[0] for k, v in self.form().items()}
                if u.path == "/token":
                    cid, csec = f.get("client_id"), f.get("client_secret")
                    if self.headers.get("Authorization", "").startswith("Basic "):
                        cid, _, csec = base64.b64decode(self.headers["Authorization"][6:]).decode().partition(":")
                    if (cid, csec) != (CLIENT_ID, CLIENT_SECRET):
                        return self.reply(401, {"error": "invalid_client"})
                    c = me.codes.pop(f.get("code", ""), None)
                    if f.get("grant_type") != "authorization_code" or not c:
                        return self.reply(400, {"error": "invalid_grant"})
                    if f.get("redirect_uri") != c["redirect"] or s256(f.get("code_verifier", "")) != c["challenge"]:
                        me.problems.append("token: redirect_uri or PKCE verifier wrong")
                        return self.reply(400, {"error": "invalid_grant"})
                    tok = secrets.token_urlsafe(24)
                    me.tokens[tok] = c["who"]
                    return self.reply(200, {"access_token": tok, "token_type": "Bearer", "expires_in": 3599, "id_token": "not.checked.here", "scope": "openid email profile"})
                if u.path == "/v1/checkout/sessions":
                    if not me.stripe_auth(self):
                        return self.reply(401, {"error": {"type": "invalid_request_error", "message": "Invalid API Key"}})
                    me.forms.append(f)
                    need = {"mode": "subscription", "line_items[0][price]": PRICE, "line_items[0][quantity]": "1"}
                    bad = [k for k, v in need.items() if f.get(k) != v] + [k for k in ("success_url", "cancel_url", "client_reference_id") if not f.get(k)]
                    if bad:
                        me.problems.append(f"checkout: {bad}")
                        return self.reply(400, {"error": {"type": "invalid_request_error", "param": bad[0]}})
                    sid = "cs_test_" + secrets.token_hex(8)
                    me.sessions[sid] = {"id": sid, "object": "checkout.session", "mode": "subscription", "status": "open", "payment_status": "unpaid",
                                        "client_reference_id": f["client_reference_id"], "customer": None, "subscription": None,
                                        "url": f"{me.base}/pay/{sid}", "success_url": f["success_url"]}
                    return self.reply(200, me.sessions[sid])
                return self.reply(404, {})

        self.http = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    def stripe_auth(self, h):
        a = h.headers.get("Authorization") or ""
        if a.startswith("Bearer "):
            return a[7:] == STRIPE_KEY
        if a.startswith("Basic "):
            return base64.b64decode(a[6:]).decode().partition(":")[0] == STRIPE_KEY
        return False

    def pay(self, sid):
        s = self.sessions[sid]
        s.update(status="complete", payment_status="paid", customer="cus_" + sid[-6:], subscription="sub_" + sid[-6:])
        return s

    def close(self):
        self.http.shutdown()


def signed(event, secret=WEBHOOK_SECRET, age=0):
    """A Stripe webhook body and its Stripe-Signature header, signed the way Stripe documents it."""
    body = json.dumps(event)
    t = int(time.time()) - age
    sig = hmac.new(secret.encode(), f"{t}.{body}".encode(), hashlib.sha256).hexdigest()
    return body, {"Stripe-Signature": f"t={t},v1={sig}", "Content-Type": "application/json"}


def event(kind, obj, eid=None):
    return {"id": eid or "evt_" + secrets.token_hex(8), "object": "event", "type": kind, "created": int(time.time()), "data": {"object": obj}}


# ---------------------------------------------------------------- the server

class Server:
    def __init__(self, name, stand=None, live=None):
        b = run(["scripts/saas.sh", "build"], 3600)
        if b.returncode or not SERVER.exists():
            raise RuntimeError("the server didn't build: " + (b.stdout + b.stderr)[-1500:])
        self.data = OUT / name
        subprocess.run(["rm", "-rf", str(self.data)])
        self.data.mkdir(parents=True)
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        env = dict(SAAS_PORT=str(self.port), SAAS_DATA=str(self.data), SAAS_BASE=self.base, SAAS_SECRET=secrets.token_hex(32))
        if stand:
            env.update(GOOGLE_CLIENT_ID=CLIENT_ID, GOOGLE_CLIENT_SECRET=CLIENT_SECRET, SAAS_OAUTH_AUTHORIZE=stand.base + "/authorize",
                       SAAS_OAUTH_TOKEN=stand.base + "/token", SAAS_OAUTH_USERINFO=stand.base + "/userinfo",
                       SAAS_STRIPE_API=stand.base, STRIPE_SECRET_KEY=STRIPE_KEY, STRIPE_WEBHOOK_SECRET=WEBHOOK_SECRET, STRIPE_PRICE_PRO=PRICE)
        env.update(live or {})
        self.log = open(self.data / "server.log", "w")
        self.p = subprocess.Popen([str(SERVER)], cwd=ROOT, env=dict(os.environ, **env), stdout=self.log, stderr=subprocess.STDOUT)
        end = time.time() + 30
        while time.time() < end:
            if "SAAS: listening" in (self.data / "server.log").read_text():
                return
            if self.p.poll() is not None:
                break
            time.sleep(0.1)
        raise RuntimeError("the server didn't start: " + (self.data / "server.log").read_text()[-1500:])

    def client(self):
        return httpx.Client(base_url=self.base, follow_redirects=False, timeout=20)

    def tenant_rows(self, tenant):
        db = self.data / "tenants" / f"{tenant}.db"
        if not db.exists():
            return None
        with sqlite3.connect(db) as c:
            return c.execute("select text, amount_cents from entries order by rowid").fetchall()

    def stop(self):
        self.p.send_signal(signal.SIGTERM)
        try:
            self.p.wait(10)
        except subprocess.TimeoutExpired:
            self.p.kill()
        self.log.close()


def sign_in(srv, stand, who, nxt="/app"):
    """Plays the browser through /login → the provider → /auth/callback; returns (client, the provider's query, the callback reply)."""
    stand.who = who
    c = srv.client()
    r = c.get("/login", params={"next": nxt})
    assert r.status_code in (302, 303), f"/login answered {r.status_code}"
    loc = r.headers["location"]
    q = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlsplit(loc).query).items()}
    a = httpx.get(loc, follow_redirects=False)
    assert a.status_code == 302, f"the provider refused: {a.text}"
    cb = urllib.parse.urlsplit(a.headers["location"])
    back = c.get(cb.path + "?" + cb.query)
    return c, q, back


# ---------------------------------------------------------------- milestones

def m0():
    env = ROOT / ".pixi"
    if env.is_symlink() or not env.is_dir():
        return False, ".pixi isn't this worktree's own directory"
    v = run(["pixi", "run", "mojo", "--version"]).stdout
    if " 1.2" not in v:
        return False, "mojo is " + v.strip()
    for src, labels in [("tests/test_serve.mojo", []), ("tests/test_https.mojo", []), ("tests/test_hash.mojo", [])]:
        ok, why = mojo_test(src, labels)
        if not ok:
            return False, f"{src}: {why}"
    return True, "own env, Mojo 1.2, serve/https/hash pass"


def m1():
    ok, why = mojo_test("tests/test_crypto.mojo", ["hmac", "random", "base64url", "compare", "seal"])
    return ok, "hmac, random, base64url, compare, seal" if ok else why


def m2():
    stand = StandIn()
    srv = Server("m2", stand)
    try:
        c0 = srv.client()
        if c0.get("/api/me").status_code != 401:
            return False, "/api/me without a session isn't 401"
        # the redirect to the provider
        r = c0.get("/login")
        q = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlsplit(r.headers.get("location", "")).query).items()}
        if not r.headers.get("location", "").startswith(stand.base + "/authorize") or q.get("code_challenge_method") != "S256" or len(q.get("state", "")) < 16:
            return False, f"/login's redirect lacks the provider, S256 or a real state: {r.headers.get('location')}"
        if q.get("redirect_uri") != srv.base + "/auth/callback":
            return False, f"redirect_uri is {q.get('redirect_uri')}"
        # a wrong state
        a = httpx.get(r.headers["location"], follow_redirects=False)
        cb = urllib.parse.urlsplit(a.headers["location"])
        forged = urllib.parse.urlencode({"code": urllib.parse.parse_qs(cb.query)["code"][0], "state": "x" * 22})
        if srv.client().get("/auth/callback?" + forged).status_code < 400:
            return False, "a callback with a wrong state was accepted"
        # ada, then ben
        ada, _, back = sign_in(srv, stand, ("ada@example.com", "Ada"))
        if back.status_code not in (302, 303) or "saas=" not in back.headers.get("set-cookie", ""):
            return False, f"the callback set no session cookie ({back.status_code})"
        sc = back.headers["set-cookie"].lower()
        if "httponly" not in sc or "samesite" not in sc:
            return False, "the session cookie isn't HttpOnly + SameSite"
        me = ada.get("/api/me").json()
        if me.get("email") != "ada@example.com" or me.get("role") != "admin" or me.get("plan") != "free":
            return False, f"/api/me: {me}"
        ben, _, _ = sign_in(srv, stand, ("ben@example.com", "Ben"))
        bme = ben.get("/api/me").json()
        if bme["tenant"] == me["tenant"]:
            return False, "ben landed in ada's tenant"
        for k, (cl, text) in enumerate([(ada, "ada's coffee"), (ben, "ben's rent")]):
            if cl.post("/api/entries", json={"text": text, "amount_cents": 450 + k}).status_code not in (200, 201):
                return False, "a write was refused"
        if srv.tenant_rows(me["tenant"]) != [("ada's coffee", 450)] or srv.tenant_rows(bme["tenant"]) != [("ben's rent", 451)]:
            return False, f"the tenant files hold {srv.tenant_rows(me['tenant'])} / {srv.tenant_rows(bme['tenant'])}"
        leak = [ada.get("/api/entries", params={"tenant": bme["tenant"]}).text, ada.get("/api/entries", headers={"X-Tenant": bme["tenant"]}).text]
        if any("ben's rent" in t for t in leak):
            return False, "ada read ben's rows"
        # a tampered cookie
        val = ada.cookies.get("saas")
        flip = val[:-3] + ("A" if val[-3] != "A" else "B") + val[-2:]
        if httpx.get(srv.base + "/api/me", cookies={"saas": flip}).status_code != 401:
            return False, "a tampered cookie was accepted"
        # roles: ada invites cy as viewer; cy reads ada's rows and can't write
        if ada.post("/api/invites", json={"email": "cy@example.com", "role": "viewer"}).status_code not in (200, 201):
            return False, "the admin's invite was refused"
        cy, _, _ = sign_in(srv, stand, ("cy@example.com", "Cy"))
        cme = cy.get("/api/me").json()
        if cme.get("tenant") != me["tenant"] or cme.get("role") != "viewer":
            return False, f"the invited viewer: {cme}"
        if "ada's coffee" not in cy.get("/api/entries").text:
            return False, "the viewer can't read the tenant's rows"
        if cy.post("/api/entries", json={"text": "cy", "amount_cents": 1}).status_code != 403:
            return False, "a viewer's write isn't 403"
        if cy.post("/api/invites", json={"email": "eve@example.com", "role": "admin"}).status_code != 403:
            return False, "a viewer could invite"
        # desktop: a non-loopback redirect is refused (no open redirect)
        if srv.client().get("/login", params={"client": "desktop", "redirect": "https://evil.example/done", "challenge": s256("v" * 43), "app_state": "s"}).status_code < 400:
            return False, "a desktop sign-in to a non-loopback redirect was accepted"
        # sign-out ends the session on the server
        old = ada.cookies.get("saas")
        ada.post("/logout", headers={"Origin": srv.base})  # (D-6034: sign-out is the site's own POST; a GET signs nobody out)
        if httpx.get(srv.base + "/api/me", cookies={"saas": old}).status_code != 401:
            return False, "the old cookie still works after /logout"
        if stand.problems:
            return False, f"the provider saw: {stand.problems}"
        return True, "PKCE + state, sealed HttpOnly cookie, one SQLite per tenant, no cross-tenant reads, roles, server-side sign-out"
    finally:
        srv.stop()
        stand.close()


def m3():
    stand = StandIn()
    srv = Server("m3", stand)
    try:
        ada, _, _ = sign_in(srv, stand, ("ada@example.com", "Ada"))
        ben, _, _ = sign_in(srv, stand, ("ben@example.com", "Ben"))
        at = ada.get("/api/me").json()["tenant"]
        if ben.get("/api/pro").status_code != 402 or ada.get("/api/pro").status_code != 402:
            return False, "a free tenant's Pro route isn't 402"
        r = ada.post("/billing/checkout")
        url = r.json().get("url", "") if r.status_code == 200 else ""
        if not url.startswith(stand.base + "/pay/cs_test_"):
            return False, f"/billing/checkout: {r.status_code} {r.text[:200]} {stand.problems}"
        sid = url.rsplit("/", 1)[1]
        if stand.sessions[sid]["client_reference_id"] != at:
            return False, "the session doesn't carry ada's tenant"
        s = stand.pay(sid)
        done = event("checkout.session.completed", s, "evt_done_1")
        body, h = signed(done, "whsec_wrong")
        if srv.client().post("/billing/webhook", content=body, headers=h).status_code != 400:
            return False, "a webhook signed with the wrong secret wasn't 400"
        body, h = signed(done, age=360)
        if srv.client().post("/billing/webhook", content=body, headers=h).status_code != 400:
            return False, "a 6-minute-old signature wasn't 400"
        if ada.get("/api/pro").status_code != 402:
            return False, "a refused webhook changed the plan"
        body, h = signed(done)
        codes = [srv.client().post("/billing/webhook", content=body, headers=h).status_code for _ in range(2)]
        if codes[0] != 200 or codes[1] not in (200, 202):
            return False, f"the good webhook (twice): {codes}"
        if ada.get("/api/pro").status_code != 200 or ada.get("/api/me").json().get("plan") != "pro":
            return False, "the paid tenant isn't Pro"
        if ben.get("/api/pro").status_code != 402:
            return False, "ben became Pro too"
        applied = (srv.data / "server.log").read_text().count("evt_done_1 applied")
        if applied != 1:
            return False, f"the event was applied {applied} times (the server logs `<event id> applied` once per change)"
        gone = event("customer.subscription.deleted", {"id": s["subscription"], "object": "subscription", "customer": s["customer"], "status": "canceled"})
        body, h = signed(gone)
        srv.client().post("/billing/webhook", content=body, headers=h)
        if ada.get("/api/pro").status_code != 402:
            return False, "a cancelled subscription is still Pro"
        return True, "checkout session, signed webhooks (bad/old refused, once only), Pro for ada only, cancel → free"
    finally:
        srv.stop()
        stand.close()


def m4():
    import headless
    headless.ensure()
    stand = StandIn()
    srv = Server("m4", stand)
    opened = OUT / "m4-opened.txt"
    opened.write_text("")
    opener = OUT / "m4-opener.sh"
    opener.write_text(f'#!/bin/sh\necho "$1" >> {opened}\n')
    opener.chmod(0o755)
    stop, seen = threading.Event(), []

    def browser():
        stand.who = ("ada@example.com", "Ada")
        while not stop.is_set():
            lines = [l for l in opened.read_text().splitlines() if l]
            for url in lines[len(seen):]:
                seen.append(url)
                try:
                    if url.startswith(srv.base + "/login"):
                        browse(url, srv.base)  # /login → provider → callback → confirm → the app's loopback
                    elif "/pay/cs_test_" in url:
                        s = stand.pay(url.rsplit("/", 1)[1])
                        body, h = signed(event("checkout.session.completed", s))
                        httpx.post(srv.base + "/billing/webhook", content=body, headers=h)
                except Exception as e:  # noqa: BLE001 (the app's own waitfor reports what didn't arrive)
                    seen.append(f"error {e}")
            time.sleep(0.1)

    t = threading.Thread(target=browser, daemon=True)
    t.start()
    try:
        b = run(["scripts/build.sh", "saas", "linux"], 3600)
        if b.returncode or not APP.exists():
            return False, "the app didn't build: " + (b.stdout + b.stderr)[-1200:]
        ot = run(["scripts/mojo_flare.sh", "build", "tests/test_open_url.mojo", "-o", str(ROOT / "build/test_open_url")])
        r = run([str(ROOT / "build/test_open_url")], 300, {"MOJOUI_OPENER": str(opener)}) if not ot.returncode else ot
        if r.returncode or "open_url: ok" not in r.stdout:
            return False, "tests/test_open_url.mojo: " + (r.stdout + r.stderr)[-600:]
        opened.write_text("")
        seen.clear()
        steps = "tap:Sign in with Google;waitfor:Sign out=20000;type:Note=Coffee;type:Amount=4.50;tap:Add;waitfor:Coffee=10000;tap:Upgrade;waitfor:Manage plan=20000"
        shot = OUT / "m4.png"
        r = run([str(APP)], 600, {"MOJOUI_TEST": steps, "MOJOUI_OPENER": str(opener), "SAAS_SERVER": srv.base, "MOJOUI_SHOT": str(shot), "MOJOUI_WINDOW": "900x700"})
        out = r.stdout + r.stderr
        (OUT / "m4.out").write_text(out)
        for want in ("Signed in as ada@example.com", "Plan: Pro"):
            if not re.search(rf"^LABEL:? .*{re.escape(want)}", out, re.M):
                return False, f"no label `{want}` (build/g57/m4.out; browser saw {seen})"
        tenants = list((srv.data / "tenants").glob("*.db"))
        rows = [srv.tenant_rows(p.stem) for p in tenants]
        if rows != [[("Coffee", 450)]]:
            return False, f"the server's tenant files hold {rows}"
        if not any(u.startswith(srv.base + "/login?") and "client=desktop" in u for u in seen):
            return False, f"the app didn't open a desktop sign-in: {seen}"
        if stand.problems:
            return False, f"the stand-ins saw: {stand.problems}"
        return True, "native sign-in via the system browser + loopback, an entry in ada's SQLite, upgrade → Pro; shot build/g57/m4.png"
    finally:
        stop.set()
        srv.stop()
        stand.close()


def m5():
    if not KEYS.exists():
        return None, f"no {KEYS}: the owner runs scripts/saas_keys.sh (Google OAuth client + Stripe test key)"
    live = {}
    for line in KEYS.read_text().splitlines():
        k, _, v = line.partition("=")
        if k.strip() and not k.startswith("#"):
            live[k.strip()] = v.strip()
    need = ["GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "STRIPE_SECRET_KEY", "STRIPE_PRICE_PRO"]
    if [k for k in need if not live.get(k)]:
        return None, f"{KEYS} lacks {[k for k in need if not live.get(k)]}"
    live.setdefault("STRIPE_WEBHOOK_SECRET", "whsec_unused_live")
    live["SAAS_TEST_HOOK"] = "1"
    srv = Server("m5", None, live)
    try:
        r = srv.client().get("/login")
        loc = r.headers.get("location", "")
        if not loc.startswith("https://accounts.google.com/"):
            return False, f"/login doesn't go to Google: {loc[:80]}"
        g = httpx.get(loc, follow_redirects=True, timeout=20)
        if g.status_code != 200 or "invalid_client" in g.text or "Error 400" in g.text or "Error 401" in g.text:
            return False, f"Google's consent page answered an error ({g.status_code})"
        tok = httpx.post("https://oauth2.googleapis.com/token", data=dict(grant_type="authorization_code", code="4/made-up", client_id=live["GOOGLE_CLIENT_ID"],
                         client_secret=live["GOOGLE_CLIENT_SECRET"], redirect_uri=srv.base + "/auth/callback", code_verifier="v" * 43), timeout=20)
        if tok.json().get("error") != "invalid_grant":
            return False, f"Google's token endpoint said {tok.json().get('error')} (invalid_client: the client id/secret are wrong)"
        # Stripe, for real (test mode): a tenant needs a session, so one is made by the server's own test hook
        hook = srv.client().post("/api/test-session", json={"email": "live@example.com"})
        if hook.status_code != 200:
            return False, "the server has no test-only session hook (/api/test-session, only when SAAS_TEST_HOOK=1 and STRIPE_SECRET_KEY is sk_test_)"
        c = srv.client()
        c.cookies.set("saas", hook.json()["cookie"])
        r = c.post("/billing/checkout")
        url = r.json().get("url", "") if r.status_code == 200 else ""
        if not url.startswith("https://checkout.stripe.com/"):
            return False, f"no real Checkout Session: {r.status_code} {r.text[:200]}"
        from playwright.sync_api import sync_playwright
        with sync_playwright() as pw:
            br = pw.chromium.launch()
            pg = br.new_page()
            pg.goto(url)
            pg.fill("#email", "live@example.com")
            pg.fill("#cardNumber", "4242424242424242")
            pg.fill("#cardExpiry", "12 / 34")
            pg.fill("#cardCvc", "123")
            if pg.locator("#billingName").count():
                pg.fill("#billingName", "Live Test")
            if pg.locator("#billingPostalCode").count():
                pg.fill("#billingPostalCode", "10001")
            pg.click("button[type=submit]")
            pg.wait_for_url(re.compile(re.escape(srv.base) + r"/.*"), timeout=60000)
            pg.screenshot(path=str(OUT / "m5-return.png"))
            br.close()
        if c.get("/api/pro").status_code != 200:
            return False, "paid with 4242, but /billing/return didn't make the tenant Pro"
        return True, "Google accepts the client; a real test-mode checkout paid and read back over Mojo HTTPS → Pro"
    finally:
        srv.stop()


def m6():
    doc = ROOT / "docs/saas.md"
    if not doc.exists():
        return False, "no docs/saas.md"
    text = doc.read_text()
    for mod in ("utils_auth", "db_host", "db_tenant", "utils_billing", "utils_webhook", "utils_email", "utils_bgtsk", "utils_migrate"):
        if mod not in text:
            return False, f"docs/saas.md doesn't map fh-saas's {mod}"
    comp = (ROOT / "docs/components.md").read_text()
    for m in ("mojoui.crypto", "mojoui.accounts", "mojoui.billing"):
        if m not in comp:
            return False, f"docs/components.md doesn't list {m}"
    r = run(["pixi", "run", "python", "scripts/components.py", "--check"])
    if r.returncode:
        return False, "the components matrix is stale: " + (r.stdout + r.stderr)[-300:]
    shot = ROOT / "docs/gallery/img/saas.png"
    if not shot.exists() or "saas" not in (ROOT / "docs/gallery/index.html").read_text():
        return False, "no gallery card with docs/gallery/img/saas.png"
    if not re.search(r"looked at.*saas\.png", (ROOT / "docs/journal.md").read_text()):
        return False, "the gallery shot isn't recorded as looked at in docs/journal.md"
    p = run(["scripts/package.sh", "saas", "linux"], 3600)
    if p.returncode:
        return False, "scripts/package.sh saas linux: " + (p.stdout + p.stderr)[-400:]
    return True, "parity map, components listed, gallery card, Linux download"


def m7():
    for src in ("tests/test_ui_thread.mojo", "tests/test_served.mojo"):
        ok, why = mojo_test(src, [])
        if not ok:
            return False, f"{src}: {why}"
    for lint in ("scripts/libc_lint.py", "scripts/decisions_lint.py"):
        r = run(["pixi", "run", "python", lint])
        if r.returncode:
            return False, f"{lint}: " + (r.stdout + r.stderr)[-300:]
    return True, "ui thread, served, libc and decision lints"


def form_post_headers(page, base):
    """What a browser sends with a form POST from `page` (a reply from `base`) back to the same site, by the Fetch
    standard: Origin is "null" when the page's Referrer-Policy is no-referrer, else the site's origin; Sec-Fetch-Site
    same-origin. (Headless Chromium sends exactly these, D-6035.) Never the site's Origin by hand."""
    policy = page.headers.get("referrer-policy", "").split(",")[-1].strip().lower()
    return {"Origin": "null" if policy == "no-referrer" else base.rstrip("/"), "Sec-Fetch-Site": "same-origin"}


def browse(url, base):
    """The system browser on a sign-in URL, as a person drives it: redirects followed with one cookie jar, and on the
    desktop sign-in's "Sign in to … on this computer?" page the Sign in button pressed (its form POSTed from the page
    with the headers a browser sends from it, form_post_headers). Ends at the first page that is neither (the app's
    loopback)."""
    with httpx.Client(follow_redirects=False, timeout=20) as br:
        r = br.get(url)
        for _ in range(8):
            if r.status_code in (301, 302, 303, 307):
                url = urllib.parse.urljoin(url, r.headers["location"])
                r = br.get(url)
                continue
            form = re.search(r"<form[^>]*action=['\"]?(/auth/desktop)", r.text) if r.status_code == 200 and url.startswith(base) else None
            if not form:
                return r
            fields = dict(re.findall(r"<input type=hidden name=['\"]?(\w+)['\"]? value=['\"]?([^'\" >]*)", r.text))
            url = urllib.parse.urljoin(url, form.group(1))
            r = br.post(url, data=dict(fields, do="yes"), headers=form_post_headers(r, base))
        return r


def play_browser(srv, stand, opened, seen, stop):
    """The system browser, as the checks play it: a /login URL is followed to the app's loopback (confirming the
    desktop sign-in on its page, browse()); a checkout is paid and its webhook sent."""
    while not stop.is_set():
        for url in [l for l in opened.read_text().splitlines() if l][len(seen):]:
            seen.append(url)
            try:
                if url.startswith(srv.base + "/login"):
                    browse(url, srv.base)
                elif "/pay/cs_test_" in url:
                    s = stand.pay(url.rsplit("/", 1)[1])
                    body, h = signed(event("checkout.session.completed", s))
                    httpx.post(srv.base + "/billing/webhook", content=body, headers=h)
            except Exception as e:  # noqa: BLE001
                seen.append(f"error {e}")
        time.sleep(0.1)


def m8_app():
    """Run ON the Mac (m8 calls it over SSH): the AppKit build signs in through open_url and the loopback, adds an entry,
    upgrades; truth is the report's last view dump (every view's text), the tenant's SQLite and the stand-ins."""
    stand = StandIn()
    srv = Server("m8", stand)
    opened, opener = OUT / "m8-opened.txt", OUT / "m8-opener.sh"
    opened.write_text("")
    opener.write_text(f'#!/bin/sh\necho "$1" >> {opened}\n')
    opener.chmod(0o755)
    stop, seen = threading.Event(), []
    stand.who = ("ada@example.com", "Ada")
    threading.Thread(target=play_browser, args=(srv, stand, opened, seen, stop), daemon=True).start()
    try:
        b = run(["scripts/build.sh", "saas", "mac"], 3600)
        if b.returncode or not MAC_APP.exists():
            return False, "the Mac app didn't build: " + (b.stdout + b.stderr)[-1200:]
        reports = OUT / "m8-report"
        subprocess.run(["rm", "-rf", str(reports)])
        steps = "waitfor:Sign in with Google=10000;tap:Sign in with Google;waitfor:Sign out=20000;type:Note=Coffee;type:Amount=4.50;tap:Add;waitfor:Coffee=10000;tap:Upgrade;waitfor:Manage plan=20000;pause:1500"
        r = run([str(MAC_APP)], 600, {"MOJOUI_TEST": steps, "MOJOUI_OPENER": str(opener), "SAAS_SERVER": srv.base, "MOJOUI_OFFSCREEN": "1",
                                     "MOJOUI_REPORT_DIR": str(reports)})
        runs = sorted(reports.glob("*"))
        if not runs:
            return False, f"the app wrote no report (exit {r.returncode}): {(r.stdout + r.stderr)[-600:]}"
        dumps = sorted(runs[-1].glob("[0-9]*.txt"))
        last = dumps[-1].read_text() if dumps else ""
        (OUT / "m8-views.txt").write_text(last)
        pngs = sorted(runs[-1].glob("[0-9]*.png"))
        if pngs:
            subprocess.run(["cp", str(pngs[-1]), str(OUT / "m8-mac.png")])
        log = (runs[-1] / "log.txt").read_text() if (runs[-1] / "log.txt").exists() else ""
        (OUT / "m8-log.txt").write_text(log)
        for want in ("Signed in as ada@example.com", "Plan: Pro"):
            if want not in last:
                return False, f"the Mac's last screen lacks `{want}` (build/g57/m8-views.txt; browser saw {seen}; log: {log[-400:]})"
        rows = [srv.tenant_rows(p.stem) for p in (srv.data / "tenants").glob("*.db")]
        if rows != [[("Coffee", 450)]]:
            return False, f"the server's tenant files hold {rows}"
        if not any(u.startswith(srv.base + "/login?") and "client=desktop" in u for u in seen):
            return False, f"the Mac app didn't open a desktop sign-in: {seen}"
        if stand.problems:
            return False, f"the stand-ins saw: {stand.problems}"
        return True, "AppKit: signed in through open_url + loopback, an entry in ada's SQLite, upgrade → Pro"
    finally:
        stop.set()
        srv.stop()
        stand.close()


def m8():
    """The owner's Mac over SSH (D-5708, D-5721): sources to ~/omxcode-g57, its own pixi env, then this checker's M2, M3
    and m8_app run there; the app's last picture comes back as build/g57/m8-mac.png. A real run only."""
    ssh = MAC_SSH + [MAC]
    if subprocess.run(ssh + ["true"], capture_output=True, timeout=30).returncode:
        return None, f"the Mac ({MAC}) isn't reachable over SSH: scripts/mac-ci (GitHub's Macs) is the fallback"
    sync = subprocess.run(["rsync", "-az", "--delete", "-e", " ".join(MAC_SSH), "--exclude=/build", "--exclude=/.pixi", "--exclude=/dist",
                           "--exclude=/.git", "--exclude=node_modules", "--exclude=__pycache__", f"{ROOT}/", f"{MAC}:omxcode-g57/"],
                          capture_output=True, text=True, timeout=600)
    if sync.returncode:
        return False, "rsync to the Mac: " + sync.stderr[-300:]
    r = subprocess.run(ssh + ["cd ~/omxcode-g57 && export PATH=$HOME/.pixi/bin:$PATH && pixi install >/dev/null && "
                              "pixi run python docs/goals/57-check.py M2 M3 M8app"], capture_output=True, text=True, timeout=5400)
    out = r.stdout + r.stderr
    (OUT / "m8.out").write_text(out)
    for f in ("m8-mac.png", "m8-views.txt", "m8-log.txt"):
        subprocess.run(["scp", "-q"] + MAC_SSH[1:5] + [f"{MAC}:omxcode-g57/build/g57/{f}", str(OUT / f)], capture_output=True, timeout=120)
    lines = {k: re.search(rf"^{k}: (\w+)  (.*)$", out, re.M) for k in ("M2", "M3", "M8app")}
    bad = [f"{k}: {m.group(1)} {m.group(2)[:300]}" if m else f"{k}: no result" for k, m in lines.items() if not m or m.group(1) != "PASS"]
    if bad:
        return False, "on the Mac: " + "; ".join(bad) + " (build/g57/m8.out)"
    return True, "on the Mac (macOS, arm64): the server passes M2 and M3; the AppKit app signs in and pays; shot build/g57/m8-mac.png"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7, "M8": m8}
EXTRA = {"M8app": m8_app}  # (not a milestone: m8 runs it on the Mac)

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    picked = sys.argv[1:] or list(MILESTONES)
    MILESTONES.update(EXTRA)
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
