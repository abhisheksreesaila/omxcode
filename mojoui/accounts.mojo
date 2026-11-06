# mojoui.accounts: sign-in with Google (OAuth 2.0 + PKCE), server-side sessions in sealed cookies, users, tenants, roles
# and one SQLite file per tenant, for a mojoui.serve program (goal 57 M2; fh-saas's utils_auth, db_host and db_tenant).
#
#   var acc = Accounts(data_dir, AuthConfig.from_env())        # data_dir/host.db + data_dir/tenants/<tenant>.db
#   def answer(mut self, mut req: Req) -> Reply:
#       var r = self.acc.handle(req)                            # /login /auth/callback /api/token /logout /api/me /api/invites
#       if r.status != 0: return r^
#       var m = self.acc.member(req)                            # the session's person, or None: answer 401
#       if not m: return Reply.error(401, "sign in first", "unauthorized")
#       if not m.value().can_write(): return Reply.error(403, …)
#       var db = self.acc.tenant_db(m.value())                  # their tenant's file, from the session only
#
# Sign-in: /login sends the browser to the provider with a random state and a PKCE S256 challenge (both kept here, hashed);
# /auth/callback refuses a state it didn't issue (or one used before, or older than 10 minutes), trades the code for a
# token (client secret + verifier), reads the verified email, makes the user (and their tenant, admin, or joins the tenant
# that invited them) and starts a session: a random id kept hashed in host.db, sent as a sealed HttpOnly SameSite=Lax
# cookie (Secure on https). /logout deletes the session's row, so an old cookie stops working at once.
# Desktop apps (RFC 8252): /login?client=desktop&redirect=<http://127.0.0.1:port/…>&challenge=<S256>&app_state=<s>: the
# callback then sends the browser to the app's loopback with a one-time code (60 s), which the app trades at /api/token
# for a bearer token with its own PKCE verifier. Only loopback IP redirects are taken: no open redirect.
# `next` (the web's page after sign-in) must be a path on this site.

from std.os import getenv, makedirs
from std.os.path import exists
from mojoui.serve import Req, Reply, decode
from mojoui.http import Request, Response, uri_component
from mojoui.effects import Backend
from mojoui.json import Json, json_string
from mojoui.sqlite import Database
from mojoui.crypto import random_token, random_bytes, same, seal, unseal, pkce_challenge, b64url
from mojoui.hash import sha256_hex, hex
from mojoui.clock import wall_seconds

comptime COOKIE = "saas"
comptime SESSION_S = 7 * 24 * 3600
comptime STATE_S = 600
comptime CODE_S = 60
comptime ROLES = ["admin", "member", "viewer"]


def now_s() -> Int:
    return Int(wall_seconds())


@fieldwise_init
struct AuthConfig(Copyable, Movable):
    var client_id: String
    var client_secret: String
    var authorize_url: String
    var token_url: String
    var userinfo_url: String
    var base: String  # this server's own URL (the callback is base + "/auth/callback")
    var secret: String  # the seal key (≥ 32 characters)

    @staticmethod
    def from_env() -> AuthConfig:
        """GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, SAAS_BASE, SAAS_SECRET; SAAS_OAUTH_AUTHORIZE/TOKEN/USERINFO (default
        Google's endpoints)."""
        return AuthConfig(
            getenv("GOOGLE_CLIENT_ID"),
            getenv("GOOGLE_CLIENT_SECRET"),
            getenv("SAAS_OAUTH_AUTHORIZE", "https://accounts.google.com/o/oauth2/v2/auth"),
            getenv("SAAS_OAUTH_TOKEN", "https://oauth2.googleapis.com/token"),
            getenv("SAAS_OAUTH_USERINFO", "https://openidconnect.googleapis.com/v1/userinfo"),
            getenv("SAAS_BASE", "http://127.0.0.1:8000"),
            getenv("SAAS_SECRET"),
        )

    def callback(self) -> String:
        return self.base + "/auth/callback"


@fieldwise_init
struct Member(Copyable, Movable):
    """The person a request comes from: their user, their tenant and role in it, the tenant's plan."""

    var user_id: Int
    var email: String
    var name: String
    var tenant: String
    var role: String
    var plan: String
    var session: String  # the session id's hash (sign-out deletes it)

    def can_write(self) -> Bool:
        return self.role == "admin" or self.role == "member"

    def is_admin(self) -> Bool:
        return self.role == "admin"


def form(names: List[String], values: List[String]) -> String:
    """application/x-www-form-urlencoded."""
    var out = String("")
    for i in range(len(names)):
        out += ("&" if i > 0 else "") + uri_component(names[i]) + "=" + uri_component(values[i])
    return out


def cookie(req: Req, name: String) -> String:
    """A request cookie's value ("" when absent)."""
    for part in req.header("cookie").split(";"):
        var p = String(part).strip()
        var eq = p.find("=")
        if eq > 0 and String(p[byte = : eq]) == name:
            return String(p[byte = eq + 1 :])
    return ""


def _safe_path_char(c: Int) -> Bool:
    """Letters, digits and -._~/%?=&+ (no '@', '\\', '#', quotes, spaces or controls)."""
    if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
        return True
    return chr(c) in "-._~/%?=&+"


def is_local_path(p: String) -> Bool:
    """A path on this site: "/…", never "//host" or "/\\host" (a browser reads both as another site)."""
    if not p.startswith("/") or p.startswith("//") or p.byte_length() > 512:
        return False
    for b in p.as_bytes():
        if not _safe_path_char(Int(b)):
            return False
    return True


def is_loopback_redirect(url: String) -> Bool:
    """RFC 8252 §7.3: http://127.0.0.1:<port>/<path> or http://[::1]:<port>/<path>, nothing else (no "localhost",
    which DNS or a hosts file can point elsewhere, no user info, no fragment)."""
    var rest: String
    if url.startswith("http://127.0.0.1:"):
        rest = String(url[byte = 17 :])
    elif url.startswith("http://[::1]:"):
        rest = String(url[byte = 13 :])
    else:
        return False
    var slash = rest.find("/")
    var port_text = String(rest) if slash < 0 else String(rest[byte = : slash])
    if port_text.byte_length() == 0 or port_text.byte_length() > 5:
        return False
    for b in port_text.as_bytes():
        if b < 48 or b > 57:
            return False
    try:
        var port = atol(port_text)
        if port < 1 or port > 65535:
            return False
    except:
        return False
    if slash >= 0 and not is_local_path(String(rest[byte = slash :])):
        return False
    return True


def _origin_ok(req: Req, base: String) -> Bool:
    """A browser's cross-site write carries another Origin: refused. (No Origin: a native client or an old browser,
    SameSite=Lax covers the cookie.)"""
    var o = req.header("origin")
    return o == "" or o == base


struct Accounts(Movable):
    var db: Database
    var cfg: AuthConfig
    var key: List[UInt8]
    var data: String

    def __init__(out self, data_dir: String, var cfg: AuthConfig) raises:
        if cfg.secret.byte_length() < 32:
            raise Error("SAAS_SECRET must be at least 32 characters (e.g. 64 hex digits)")
        self.data = data_dir
        if not exists(data_dir + "/tenants"):
            makedirs(data_dir + "/tenants")
        self.db = Database(data_dir + "/host.db")
        self.key = List[UInt8]()
        for b in cfg.secret.as_bytes():
            self.key.append(b)
        self.cfg = cfg^
        self.db.exec("PRAGMA journal_mode=WAL")
        self.db.exec(
            "CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, name TEXT, sub TEXT,"
            " created INTEGER);"
            "CREATE TABLE IF NOT EXISTS tenants(id TEXT PRIMARY KEY, name TEXT, plan TEXT NOT NULL DEFAULT 'free',"
            " customer TEXT, subscription TEXT, created INTEGER);"
            "CREATE TABLE IF NOT EXISTS members(user_id INTEGER PRIMARY KEY, tenant TEXT NOT NULL, role TEXT NOT NULL);"
            "CREATE TABLE IF NOT EXISTS invites(email TEXT PRIMARY KEY, tenant TEXT NOT NULL, role TEXT NOT NULL,"
            " by INTEGER, created INTEGER);"
            "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, expires INTEGER NOT NULL);"
            "CREATE TABLE IF NOT EXISTS oauth_states(id TEXT PRIMARY KEY, verifier TEXT NOT NULL, next TEXT,"
            " redirect TEXT, challenge TEXT, app_state TEXT, expires INTEGER NOT NULL);"
            "CREATE TABLE IF NOT EXISTS desktop_codes(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, challenge TEXT NOT NULL,"
            " expires INTEGER NOT NULL)"
        )

    # requests -------------------------------------------------------------------------------------------------------

    def handle(mut self, mut req: Req) -> Reply:
        """Answers the sign-in routes; any other request: a Reply with status 0 (not mine)."""
        try:
            if req.matches("GET", "/login"):
                return self._login(req)
            if req.matches("GET", "/auth/callback"):
                return self._callback(req)
            if req.matches("POST", "/api/token"):
                return self._token(req)
            if req.matches("GET", "/logout") or req.matches("POST", "/logout"):
                return self._logout(req)
            if req.matches("GET", "/api/me"):
                var m = self.member(req)
                if not m:
                    return Reply.error(401, "sign in first", "unauthorized")
                var v = m.value().copy()
                return Reply.json('{"email": ' + json_string(v.email) + ', "name": ' + json_string(v.name) + ', "tenant": '
                    + json_string(v.tenant) + ', "role": ' + json_string(v.role) + ', "plan": ' + json_string(v.plan) + "}")
            if req.matches("POST", "/api/invites"):
                return self._invite(req)
        except e:
            print("accounts: " + String(e))
            return Reply.error(500, "the sign-in store failed", "internal")
        return Reply(0, "", "")

    def member(self, req: Req) -> Optional[Member]:
        """The signed-in person: from `Authorization: Bearer <token>` or the session cookie; None when neither is a live
        session (missing, tampered, expired, signed out)."""
        var token = String("")
        var auth = req.header("authorization")
        if auth.startswith("Bearer "):
            token = String(auth[byte = 7 :])
        else:
            token = cookie(req, COOKIE)
        if token == "":
            return None
        var sid = unseal(self.key, token, now_s())
        if not sid:
            return None
        try:
            var h = sha256_hex(sid.value())
            var q = self.db.prepare(
                "SELECT u.id, u.email, u.name, m.tenant, m.role, t.plan FROM sessions s JOIN users u ON u.id = s.user_id"
                " JOIN members m ON m.user_id = u.id JOIN tenants t ON t.id = m.tenant WHERE s.id = ? AND s.expires > ?"
            )
            q.bind(1, h)
            q.bind(2, now_s())
            if q.step():
                return Member(q.int(0), q.text(1), q.text(2), q.text(3), q.text(4), q.text(5), h)
        except e:
            print("accounts: " + String(e))
        return None

    def tenant_db(self, m: Member) raises -> Database:
        """The member's tenant's own SQLite file (tenant ids are hex this module makes: never a path from a request)."""
        for b in m.tenant.as_bytes():
            if not ((b >= 48 and b <= 57) or (b >= 97 and b <= 102)):
                raise Error("not a tenant id")
        return Database(self.data + "/tenants/" + m.tenant + ".db")

    def set_plan(self, tenant: String, plan: String, customer: String = "", subscription: String = "") raises -> Bool:
        """Billing's hook: the tenant's plan (and its Stripe customer/subscription when given). False: no such tenant."""
        var q = self.db.prepare(
            "UPDATE tenants SET plan = ?, customer = COALESCE(NULLIF(?, ''), customer),"
            " subscription = COALESCE(NULLIF(?, ''), subscription) WHERE id = ?"
        )
        q.bind(1, plan)
        q.bind(2, customer)
        q.bind(3, subscription)
        q.bind(4, tenant)
        q.run()
        return self.db.changes() > 0

    def tenant_of_subscription(self, subscription: String) raises -> String:
        var q = self.db.prepare("SELECT id FROM tenants WHERE subscription = ?")
        q.bind(1, subscription)
        return q.text(0) if q.step() else String("")

    def start_session(self, user_id: Int) raises -> String:
        """A new session for the user: its sealed token (the cookie's value, or a desktop app's bearer token)."""
        var sid = random_token(32)
        var q = self.db.prepare("INSERT INTO sessions(id, user_id, expires) VALUES (?, ?, ?)")
        q.bind(1, sha256_hex(sid))
        q.bind(2, user_id)
        q.bind(3, now_s() + SESSION_S)
        q.run()
        return seal(self.key, sid, SESSION_S, now_s())

    def session_cookie(self, token: String) -> String:
        var c = COOKIE + "=" + token + "; Path=/; HttpOnly; SameSite=Lax; Max-Age=" + String(SESSION_S)
        return c + ("; Secure" if self.cfg.base.startswith("https://") else "")

    def user_for(mut self, email: String, name: String, sub: String) raises -> Int:
        """The user with this (verified) email, made on first sign-in: they join the tenant that invited them, with the
        invited role, or get a tenant of their own as its admin."""
        var q = self.db.prepare("SELECT id FROM users WHERE email = ?")
        q.bind(1, email)
        if q.step():
            return q.int(0)
        self.db.begin()
        try:
            var ins = self.db.prepare("INSERT INTO users(email, name, sub, created) VALUES (?, ?, ?, ?)")
            ins.bind(1, email)
            ins.bind(2, name)
            ins.bind(3, sub)
            ins.bind(4, now_s())
            ins.run()
            var uid = self.db.last_id()
            var inv = self.db.prepare("SELECT tenant, role FROM invites WHERE email = ?")
            inv.bind(1, email)
            var tenant: String
            var role: String
            if inv.step():
                tenant = inv.text(0)
                role = inv.text(1)
                var gone = self.db.prepare("DELETE FROM invites WHERE email = ?")
                gone.bind(1, email)
                gone.run()
            else:
                tenant = hex(random_bytes(12))
                role = "admin"
                var t = self.db.prepare("INSERT INTO tenants(id, name, created) VALUES (?, ?, ?)")
                t.bind(1, tenant)
                t.bind(2, name if name != "" else email)
                t.bind(3, now_s())
                t.run()
            var mem = self.db.prepare("INSERT INTO members(user_id, tenant, role) VALUES (?, ?, ?)")
            mem.bind(1, uid)
            mem.bind(2, tenant)
            mem.bind(3, role)
            mem.run()
            self.db.commit()
            _ = Database(self.data + "/tenants/" + tenant + ".db")  # (the tenant's file exists from its first sign-in)
            return uid
        except e:
            self.db.rollback()
            raise e^

    # the routes -----------------------------------------------------------------------------------------------------

    def _login(mut self, req: Req) raises -> Reply:
        if self.cfg.client_id == "":
            return Reply.error(503, "sign-in isn't set up (GOOGLE_CLIENT_ID)", "not_configured")
        var nxt = req.arg("next", "/")
        var redirect = String("")
        var challenge = String("")
        var app_state = String("")
        if req.arg("client") == "desktop":
            redirect = req.arg("redirect")
            challenge = req.arg("challenge")
            app_state = req.arg("app_state")
            if not is_loopback_redirect(redirect):
                return Reply.error(400, "a desktop sign-in returns to a loopback address only", "bad_redirect")
            if challenge.byte_length() != 43 or not b64url_ok(challenge) or app_state.byte_length() > 256 or not b64url_ok(app_state):
                return Reply.error(400, "a desktop sign-in needs an S256 challenge and a plain state", "bad_request")
            nxt = ""
        elif not is_local_path(nxt):
            nxt = "/"
        var state = random_token(32)
        var verifier = random_token(32)
        var old = self.db.prepare("DELETE FROM oauth_states WHERE expires < ?")
        old.bind(1, now_s())
        old.run()
        var q = self.db.prepare("INSERT INTO oauth_states(id, verifier, next, redirect, challenge, app_state, expires) VALUES (?, ?, ?, ?, ?, ?, ?)")
        q.bind(1, sha256_hex(state))
        q.bind(2, verifier)
        q.bind(3, nxt)
        q.bind(4, redirect)
        q.bind(5, challenge)
        q.bind(6, app_state)
        q.bind(7, now_s() + STATE_S)
        q.run()
        var names: List[String] = ["response_type", "client_id", "redirect_uri", "scope", "state", "code_challenge", "code_challenge_method", "prompt"]
        var values: List[String] = ["code", self.cfg.client_id, self.cfg.callback(), "openid email profile", state, pkce_challenge(verifier), "S256", "select_account"]
        var sep = "&" if "?" in self.cfg.authorize_url else "?"
        return Reply.empty(303).header("Location", self.cfg.authorize_url + sep + form(names, values)).header("Cache-Control", "no-store")

    def _callback(mut self, req: Req) raises -> Reply:
        var state = req.arg("state")
        var code = req.arg("code")
        if state == "" or code == "":
            return Reply.error(400, "sign-in was cancelled or refused: " + req.arg("error"), "bad_callback")
        var q = self.db.prepare("SELECT verifier, next, redirect, challenge, app_state FROM oauth_states WHERE id = ? AND expires > ?")
        q.bind(1, sha256_hex(state))
        q.bind(2, now_s())
        if not q.step():
            return Reply.error(400, "this sign-in wasn't started here, or it expired: start again", "bad_state")
        var verifier = q.text(0)
        var nxt = q.text(1)
        var redirect = q.text(2)
        var challenge = q.text(3)
        var app_state = q.text(4)
        var gone = self.db.prepare("DELETE FROM oauth_states WHERE id = ?")  # (one use)
        gone.bind(1, sha256_hex(state))
        gone.run()
        # the code → a token (client secret + PKCE verifier) → who it is
        var tn: List[String] = ["grant_type", "code", "redirect_uri", "client_id", "client_secret", "code_verifier"]
        var tv: List[String] = ["authorization_code", code, self.cfg.callback(), self.cfg.client_id, self.cfg.client_secret, verifier]
        var tr = Backend.send(Request(0, "POST", self.cfg.token_url, form(tn, tv)).header("Content-Type", "application/x-www-form-urlencoded").header("Accept", "application/json").timeout(20_000))
        if tr.status != 200:
            print("accounts: the token endpoint answered " + String(tr.status) + " " + tr.error)
            return Reply.error(502, "the sign-in provider refused the code", "token_failed")
        var tj = Json.parse(tr.text())
        var access = tj.text(tj.get(0, "access_token"))
        if access == "":
            return Reply.error(502, "the sign-in provider sent no token", "token_failed")
        var ur = Backend.send(Request(0, "GET", self.cfg.userinfo_url).header("Authorization", "Bearer " + access).header("Accept", "application/json").timeout(20_000))
        if ur.status != 200:
            return Reply.error(502, "the sign-in provider didn't say who you are", "userinfo_failed")
        var uj = Json.parse(ur.text())
        var email = uj.text(uj.get(0, "email")).lower()
        if email == "" or not uj.flag(uj.get(0, "email_verified")):
            return Reply.error(403, "this account has no verified email", "unverified")
        var uid = self.user_for(email, uj.text(uj.get(0, "name")), uj.text(uj.get(0, "sub")))
        if redirect != "":
            var once = random_token(32)
            var c = self.db.prepare("INSERT INTO desktop_codes(id, user_id, challenge, expires) VALUES (?, ?, ?, ?)")
            c.bind(1, sha256_hex(once))
            c.bind(2, uid)
            c.bind(3, challenge)
            c.bind(4, now_s() + CODE_S)
            c.run()
            var sep = "&" if "?" in redirect else "?"
            var names: List[String] = ["code", "state"]
            var values: List[String] = [once, app_state]
            return Reply.text("Signed in: you can go back to the app.", 303).header("Location", redirect + sep + form(names, values)).header("Cache-Control", "no-store")
        var token = self.start_session(uid)
        return Reply.empty(303).header("Location", nxt if is_local_path(nxt) else "/").header("Set-Cookie", self.session_cookie(token)).header("Cache-Control", "no-store")

    def _token(mut self, req: Req) raises -> Reply:
        """A desktop app trades its one-time code and PKCE verifier for a bearer token."""
        var code: String
        var verifier: String
        try:
            var j = Json.parse(req.body)
            code = j.text(j.get(0, "code"))
            verifier = j.text(j.get(0, "verifier"))
        except:
            return Reply.error(400, "send {code, verifier}", "bad_request")
        var q = self.db.prepare("SELECT user_id, challenge FROM desktop_codes WHERE id = ? AND expires > ?")
        q.bind(1, sha256_hex(code))
        q.bind(2, now_s())
        var found = q.step()
        var uid = q.int(0) if found else 0
        var challenge = q.text(1) if found else String("")
        var gone = self.db.prepare("DELETE FROM desktop_codes WHERE id = ?")  # (one try, right or wrong)
        gone.bind(1, sha256_hex(code))
        gone.run()
        if not found or verifier.byte_length() < 43 or not same(pkce_challenge(verifier), challenge):
            return Reply.error(400, "that code isn't good (used, expired, or the verifier doesn't match)", "invalid_grant")
        return Reply.json('{"token": ' + json_string(self.start_session(uid)) + "}").header("Cache-Control", "no-store")

    def _logout(mut self, req: Req) raises -> Reply:
        var m = self.member(req)
        if m:
            var q = self.db.prepare("DELETE FROM sessions WHERE id = ?")
            q.bind(1, m.value().session)
            q.run()
        var clear = COOKIE + "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
        if req.header("authorization") != "":
            return Reply.json('{"ok": true}')
        return Reply.empty(303).header("Location", "/").header("Set-Cookie", clear)

    def _invite(mut self, req: Req) raises -> Reply:
        var m = self.member(req)
        if not m:
            return Reply.error(401, "sign in first", "unauthorized")
        if not m.value().is_admin() or not _origin_ok(req, self.cfg.base):
            return Reply.error(403, "only the tenant's admin invites", "forbidden")
        var email: String
        var role: String
        try:
            var j = Json.parse(req.body)
            email = j.text(j.get(0, "email")).lower()
            role = j.text(j.get(0, "role"), "member")
        except:
            return Reply.error(400, "send {email, role}", "bad_request")
        var known = False
        for r in materialize[ROLES]():
            known = known or r == role
        if not known or "@" not in email or email.byte_length() > 254:
            return Reply.error(400, "an email and a role (admin, member, viewer)", "bad_request")
        var q = self.db.prepare("INSERT OR REPLACE INTO invites(email, tenant, role, by, created) VALUES (?, ?, ?, ?, ?)")
        q.bind(1, email)
        q.bind(2, m.value().tenant)
        q.bind(3, role)
        q.bind(4, m.value().user_id)
        q.bind(5, now_s())
        q.run()
        return Reply.json('{"invited": ' + json_string(email) + ', "role": ' + json_string(role) + "}", 201)

    def test_session(mut self, email: String) raises -> String:
        """A session for `email` without a provider: for test runs only; the caller gates it (SAAS_TEST_HOOK=1 and a test
        key) and never builds it into a route otherwise."""
        return self.start_session(self.user_for(email.lower(), "", "test"))


def b64url_ok(s: String) -> Bool:
    for b in s.as_bytes():
        var c = Int(b)
        if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 45 or c == 95):
            return False
    return True
