# mojoui.accounts: sign-in with Google (OAuth 2.0 + PKCE), server-side sessions in sealed cookies, users, tenants, roles,
# invites you accept, many tenants per person, and one SQLite file per tenant, for a mojoui.serve Handler (goal 57 M2,
# goal 60 M5 and M7; fh-saas's utils_auth, db_host and db_tenant). Thread-safe: every method takes an immutable self
# and its own thread's SQLite connection (mojoui.sqlite.Pool), so requests run at once.
#
#   var acc = Accounts(data_dir, AuthConfig.from_env(), log, events=queue)   # data_dir/host.db + tenants/<tenant>.db
#   def answer(self, mut req: Req) -> Reply:
#       var r = self.acc.handle(req)          # /login /auth/callback /auth/desktop /api/token /logout (POST; GET: a page)
#                                             # /api/me /api/invites /api/tenants
#       if r.status != 0: return r^           # /api/switch /invites/<token>
#       var m = self.acc.member(req)          # the session's person in their current tenant, or None: answer 401
#       var db = self.acc.tenant_db(m.value())  # their tenant's file, from the session only
#   def blocking(self, req: Req) -> Bool: return self.acc.blocking(req)   # the callback calls Google: off the reactor
#
# Sign-in: /login sends the browser to the provider with a random state and a PKCE S256 challenge, and keeps nothing:
# the pending sign-in (state, next page, a desktop app's loopback, challenge and app_state) is the browser's sealed
# HttpOnly cookie (10 minutes), and the PKCE verifier is an HMAC of the state under the server's key (never sent). So a
# flood of /login writes no row and fills no cap (D-6031). /auth/callback refuses a state its browser's cookie doesn't
# seal (another browser, tampered, older than 10 minutes) or one already used (signin_used: written only once the
# provider has traded the code, so a flood can't write it), trades the code for a token (client secret + verifier),
# reads the verified email and starts a session: a random id kept hashed in
# host.db, sent as a sealed HttpOnly SameSite=Lax cookie (Secure on https). Sessions slide: one idle longer than
# SAAS_SESSION_IDLE ends (use moves it on; written at most every tenth of that), and none outlives 30 days.
# (One pending sign-in per browser: a second /login in another tab replaces the first one's cookie.)
# A new person gets a tenant of their own as its admin, and an event `signed_up` {email, name, tenant} on the jobs queue
# (the app sends the welcome email from it). Nobody joins a tenant without saying so: an admin's invite is a row and an
# event `invite` {invite, email}; its link (/invites/<sealed id>, expiring, single use) shows "Join <tenant>, invited by
# <name>?" to the invited address only, and a same-origin POST accepts it with the invited role. A person in several
# tenants lists them (GET /api/tenants) and switches (POST /api/switch {tenant}); the session carries the current one.
# Per-client limits on /login, /auth/callback and /api/token (SAAS_RATE a minute each; the client is mojoui.serve's
# req.client: X-Forwarded-For only from SAAS_TRUSTED_PROXIES, IPv6 by its /64): 429 with Retry-After.
# A person is their provider's (provider, sub), not their email: the first sign-in with a sub stores it, and a sign-in
# whose sub differs from the stored one is refused (403, an `identity_mismatch` audit row): an address reassigned at
# the provider can't take over its old owner's account. Events go on the queue inside the change's own transaction
# (mojoui.jobs.add_in: an outbox) and carry ids only ({user}, {invite}): the job reads the person when it runs.
# On an https base the cookies are __Host-saas and __Host-saas_state (Secure, Path=/, no Domain: a sibling subdomain
# can't set them); a request carrying two cookies of one of those names is refused (400). Expired used states,
# sessions and desktop codes are swept by tick() (sweep()), a thousand rows a table at a time.
# Desktop apps (RFC 8252): /login?client=desktop&redirect=<http://127.0.0.1:port/…>&challenge=<S256>&app_state=<s>: the
# callback answers "Sign in to <app> on this computer?" (a pending row, 5 minutes; no code yet), and only a same-origin
# POST /auth/desktop from that page (Origin is this site, or Sec-Fetch-Site same-origin) sends the browser to the app's
# loopback with a one-time code (60 s), traded at /api/token for a bearer token. A GET never releases a code, so a
# stranger's link to a desktop sign-in shows a question, not a code in the address bar (RFC 8252 §8.12's phishing risk).

from std.os import getenv, makedirs
from std.os.path import exists
from mojoui.serve import Req, Reply, decode, escape_html
from mojoui.http import Request, Response, uri_component
from mojoui.effects import Backend
from mojoui.json import Json, json_string
from mojoui.sqlite import Database, Pool
from mojoui.crypto import random_token, random_bytes, same, seal, unseal, pkce_challenge, b64url, hmac_sha256
from mojoui.hash import sha256_hex, hex
from mojoui.clock import wall_seconds
from mojoui.log import Log, Fields, Audit
from mojoui.migrate import Migrations, Migration, parse, apply_all
from mojoui.jobs import Queue
from mojoui.ratelimit import RateLimit
from mojoui.clientip import rate_key

comptime COOKIE = "saas"
comptime STATE_COOKIE = "saas_state"  # the web sign-in's state, bound to the browser that started it (D-5726)
comptime SESSION_S = 30 * 24 * 3600  # (no session outlives this, however often it's used)
comptime STATE_S = 600

comptime CODE_S = 60
comptime CONFIRM_S = 300  # (a desktop sign-in's "on this computer?" page waits this long for its answer)
comptime ROLES = ["admin", "editor", "member", "viewer"]  # (editor: fh-saas's name for member)
comptime PROVIDER = "google"
comptime _SWEEP_LIMIT = 1000

comptime HOST_001 = (
    "-- up\n"
    "CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, name TEXT, sub TEXT, created INTEGER);\n"
    "CREATE TABLE IF NOT EXISTS tenants(id TEXT PRIMARY KEY, name TEXT, plan TEXT NOT NULL DEFAULT 'free', customer TEXT, subscription TEXT, created INTEGER);\n"
    "CREATE TABLE IF NOT EXISTS members(user_id INTEGER PRIMARY KEY, tenant TEXT NOT NULL, role TEXT NOT NULL);\n"
    "CREATE TABLE IF NOT EXISTS invites(email TEXT NOT NULL, tenant TEXT NOT NULL, role TEXT NOT NULL, by INTEGER, created INTEGER, PRIMARY KEY(email, tenant));\n"
    "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, expires INTEGER NOT NULL);\n"
    "CREATE TABLE IF NOT EXISTS oauth_states(id TEXT PRIMARY KEY, verifier TEXT NOT NULL, next TEXT, redirect TEXT, challenge TEXT, app_state TEXT, expires INTEGER NOT NULL);\n"
    "CREATE TABLE IF NOT EXISTS desktop_codes(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, challenge TEXT NOT NULL, expires INTEGER NOT NULL);\n"
    "-- down\n"
    "DROP TABLE desktop_codes; DROP TABLE oauth_states; DROP TABLE sessions; DROP TABLE invites; DROP TABLE members; DROP TABLE tenants; DROP TABLE users;\n"
)
comptime HOST_002 = (  # goal 60: many tenants per person, sliding sessions, invites you accept, the audit log
    "-- up\n"
    "CREATE TABLE members_new(user_id INTEGER NOT NULL, tenant TEXT NOT NULL, role TEXT NOT NULL, joined INTEGER, PRIMARY KEY(user_id, tenant));\n"
    "INSERT INTO members_new(user_id, tenant, role) SELECT user_id, tenant, role FROM members;\n"
    "DROP TABLE members;\n"
    "ALTER TABLE members_new RENAME TO members;\n"
    "CREATE INDEX members_tenant ON members(tenant);\n"
    "ALTER TABLE users ADD COLUMN last_tenant TEXT;\n"
    "ALTER TABLE sessions ADD COLUMN tenant TEXT;\n"
    "ALTER TABLE sessions ADD COLUMN last_seen INTEGER NOT NULL DEFAULT 0;\n"
    "UPDATE sessions SET tenant = (SELECT tenant FROM members WHERE members.user_id = sessions.user_id LIMIT 1), last_seen = CAST(strftime('%s', 'now') AS INTEGER);\n"
    "DROP TABLE invites;\n"
    "CREATE TABLE invites(id INTEGER PRIMARY KEY, email TEXT NOT NULL, tenant TEXT NOT NULL, role TEXT NOT NULL, by INTEGER, created INTEGER NOT NULL, expires INTEGER NOT NULL, used INTEGER);\n"
    "CREATE INDEX invites_email ON invites(email);\n"
    "CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, tenant TEXT, actor TEXT, action TEXT NOT NULL, detail TEXT);\n"
    "CREATE INDEX IF NOT EXISTS audit_tenant ON audit(tenant, ts);\n"
    "-- down\n"
    "DROP TABLE audit; DROP TABLE invites;\n"
    "CREATE TABLE invites(email TEXT NOT NULL, tenant TEXT NOT NULL, role TEXT NOT NULL, by INTEGER, created INTEGER, PRIMARY KEY(email, tenant));\n"
    "CREATE TABLE members_old(user_id INTEGER PRIMARY KEY, tenant TEXT NOT NULL, role TEXT NOT NULL);\n"
    "INSERT OR IGNORE INTO members_old SELECT user_id, tenant, role FROM members ORDER BY joined;\n"
    "DROP TABLE members; ALTER TABLE members_old RENAME TO members;\n"
    "ALTER TABLE sessions DROP COLUMN last_seen; ALTER TABLE sessions DROP COLUMN tenant; ALTER TABLE users DROP COLUMN last_tenant;\n"
)


comptime HOST_003 = (  # goal 60 round 3: identities by (provider, sub), expiry indexes for the sweep and the cap
    "-- up\n"
    "ALTER TABLE users ADD COLUMN provider TEXT;\n"
    "UPDATE users SET provider = 'google' WHERE sub IS NOT NULL AND sub != '' AND sub != 'test';\n"
    "UPDATE users SET sub = NULL WHERE sub = '' OR sub = 'test';\n"
    "CREATE UNIQUE INDEX users_identity ON users(provider, sub) WHERE sub IS NOT NULL;\n"
    "CREATE INDEX oauth_states_expires ON oauth_states(expires);\n"
    "CREATE INDEX sessions_expires ON sessions(expires);\n"
    "CREATE INDEX desktop_codes_expires ON desktop_codes(expires);\n"
    "-- down\n"
    "DROP INDEX desktop_codes_expires; DROP INDEX sessions_expires; DROP INDEX oauth_states_expires; DROP INDEX users_identity;\n"
    "ALTER TABLE users DROP COLUMN provider;\n"
)


comptime HOST_004 = (  # round 3 review: pending sign-ins counted per client, so a few clients can't fill the cap
    "-- up\n"
    "ALTER TABLE oauth_states ADD COLUMN client TEXT;\n"
    "CREATE INDEX oauth_states_client ON oauth_states(client, expires);\n"
    "-- down\n"
    "DROP INDEX oauth_states_client; ALTER TABLE oauth_states DROP COLUMN client;\n"
)


comptime HOST_005 = (  # hardening (2026-11-11): a desktop sign-in waits for its "on this computer?" confirm
    "-- up\n"
    "CREATE TABLE desktop_pending(id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, challenge TEXT NOT NULL, redirect TEXT NOT NULL, app_state TEXT, expires INTEGER NOT NULL);\n"
    "CREATE INDEX desktop_pending_expires ON desktop_pending(expires);\n"
    "-- down\n"
    "DROP INDEX desktop_pending_expires; DROP TABLE desktop_pending;\n"
)


comptime HOST_006 = (  # hardening (2026-11-11): pending sign-ins live in a sealed cookie; only used states are rows
    "-- up\n"
    "DROP TABLE oauth_states;\n"
    "CREATE TABLE signin_used(id TEXT PRIMARY KEY, expires INTEGER NOT NULL);\n"
    "CREATE INDEX signin_used_expires ON signin_used(expires);\n"
    "-- down\n"
    "DROP INDEX signin_used_expires; DROP TABLE signin_used;\n"
    "CREATE TABLE oauth_states(id TEXT PRIMARY KEY, verifier TEXT NOT NULL, next TEXT, redirect TEXT, challenge TEXT, app_state TEXT, expires INTEGER NOT NULL, client TEXT);\n"
    "CREATE INDEX oauth_states_expires ON oauth_states(expires);\n"
    "CREATE INDEX oauth_states_client ON oauth_states(client, expires);\n"
)


@fieldwise_init
struct SigninState(Copyable, Movable):
    """A pending sign-in, as its browser's sealed cookie holds it (Accounts.open_state)."""
    var state: String
    var next: String
    var redirect: String  # a desktop app's loopback ("" on the web)
    var challenge: String
    var app_state: String
    var verifier: String  # (the server's HMAC of the state: never in the cookie)


def host_migrations() raises -> Migrations:
    """mojoui.accounts' own tables in host.db, versioned in `accounts_migrations`."""
    var l = List[Migration]()
    l.append(parse(1, "001_accounts.sql", HOST_001))
    l.append(parse(2, "002_tenants_invites_audit.sql", HOST_002))
    l.append(parse(3, "003_identity_expiry.sql", HOST_003))
    l.append(parse(4, "004_signin_client.sql", HOST_004))
    l.append(parse(5, "005_desktop_confirm.sql", HOST_005))
    l.append(parse(6, "006_signin_cookie.sql", HOST_006))
    return Migrations(l^, "accounts_migrations")


def now_s() -> Int:
    return Int(wall_seconds())


def _env_int(name: String, default: Int) -> Int:
    try:
        return Int(atof(getenv(name, String(default))))
    except:
        return default


@fieldwise_init
struct AuthConfig(Copyable, Movable):
    var client_id: String
    var client_secret: String
    var authorize_url: String
    var token_url: String
    var userinfo_url: String
    var base: String  # this server's own URL (the callback is base + "/auth/callback")
    var secret: String  # the seal key (≥ 32 characters)
    var invite_ttl_s: Int
    var idle_s: Int
    var rate: Int  # requests a minute per IP on each sign-in route (0: no limit)
    var migrations: String  # a folder with tenant/NNN_name.sql ("" or missing: none)
    var app_name: String  # what a desktop sign-in's confirm page calls the app ("Sign in to <app> on this computer?")

    @staticmethod
    def from_env() -> AuthConfig:
        """GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, SAAS_BASE, SAAS_SECRET; SAAS_OAUTH_AUTHORIZE/TOKEN/USERINFO (default
        Google's endpoints); SAAS_INVITE_TTL (s, 7 days), SAAS_SESSION_IDLE (s, 7 days), SAAS_RATE (60; 0: off, for
        limits kept at a proxy), SAAS_MIGRATIONS, SAAS_APP_NAME ("omxcode SaaS"). (SAAS_MAX_SIGNINS and
        SAAS_SIGNINS_PER_CLIENT are gone: a pending sign-in is a cookie, D-6031.)"""
        return AuthConfig(
            getenv("GOOGLE_CLIENT_ID"),
            getenv("GOOGLE_CLIENT_SECRET"),
            getenv("SAAS_OAUTH_AUTHORIZE", "https://accounts.google.com/o/oauth2/v2/auth"),
            getenv("SAAS_OAUTH_TOKEN", "https://oauth2.googleapis.com/token"),
            getenv("SAAS_OAUTH_USERINFO", "https://openidconnect.googleapis.com/v1/userinfo"),
            getenv("SAAS_BASE", "http://127.0.0.1:8000"),
            getenv("SAAS_SECRET"),
            _env_int("SAAS_INVITE_TTL", 7 * 86400),
            _env_int("SAAS_SESSION_IDLE", 7 * 86400),
            _env_int("SAAS_RATE", 60),
            getenv("SAAS_MIGRATIONS", ""),
            getenv("SAAS_APP_NAME", "omxcode SaaS"),
        )

    def callback(self) -> String:
        return self.base + "/auth/callback"


@fieldwise_init
struct Member(Copyable, Movable):
    """The person a request comes from: their user, their current tenant and role in it, the tenant's plan label."""

    var user_id: Int
    var email: String
    var name: String
    var tenant: String
    var role: String
    var plan: String
    var session: String  # the session id's hash (sign-out deletes it)
    var tenant_name: String

    def can_write(self) -> Bool:
        return self.role == "admin" or self.role == "member" or self.role == "editor"

    def at_least(self, role: String) -> Bool:
        """fh-saas's ROLE_HIERARCHY: admin 3 > editor (= member) 2 > viewer 1."""
        return role_rank(self.role) >= role_rank(role) and role_rank(role) > 0

    def is_admin(self) -> Bool:
        return self.role == "admin"


@fieldwise_init
struct Invite(Copyable, Movable):
    """What an invitation email says (Accounts.invite_details)."""
    var email: String
    var link: String
    var inviter: String
    var tenant_name: String
    var role: String
    var days: Int


def role_rank(role: String) -> Int:
    if role == "admin":
        return 3
    if role == "editor" or role == "member":
        return 2
    if role == "viewer":
        return 1
    return 0


def form(names: List[String], values: List[String]) -> String:
    """application/x-www-form-urlencoded."""
    var out = String("")
    for i in range(len(names)):
        out += ("&" if i > 0 else "") + uri_component(names[i]) + "=" + uri_component(values[i])
    return out


def cookie_count(req: Req, name: String) -> Int:
    """How many cookies named `name` the request carries (every Cookie line: HTTP/2 may split them)."""
    var n = 0
    for part in req.header_all("cookie", "; ").split(";"):
        var p = String(part).strip()
        var eq = p.find("=")
        if eq > 0 and String(p[byte = : eq]) == name:
            n += 1
    return n


def cookie(req: Req, name: String) -> String:
    """A request cookie's value ("" when absent, and when two carry the name: a cookie tossed in by a sibling site or
    an http page can't shadow the real one, D-6021)."""
    var out = String("")
    var n = 0
    for part in req.header_all("cookie", "; ").split(";"):
        var p = String(part).strip()
        var eq = p.find("=")
        if eq > 0 and String(p[byte = : eq]) == name:
            out = String(p[byte = eq + 1 :])
            n += 1
    return out if n == 1 else String("")


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


def _same_origin_post(req: Req, base: String) -> Bool:
    """A form POST provably from this site's own page: Origin is this site, or (no Origin) Sec-Fetch-Site says
    same-origin. Neither header (a script, an old browser): refused, unlike _origin_ok."""
    var o = req.header("origin")
    if o != "":
        return o == base
    return req.header("sec-fetch-site") == "same-origin"


def form_arg(body: String, name: String) -> String:
    """A field of an application/x-www-form-urlencoded body ("" when absent)."""
    for part in body.split("&"):
        var p = String(part)
        var eq = p.find("=")
        if eq > 0 and decode(String(p[byte = : eq])) == name:
            return decode(String(p[byte = eq + 1 :]))
    return String("")


def _origin_of(url: String) -> String:
    """http://host:port of a URL (a loopback redirect is checked before this sees it)."""
    var rest = url.find("/", 7) if url.startswith("http://") else -1
    return String(url[byte = : rest]) if rest > 0 else url


def _utf8(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    for b in s.as_bytes():
        out.append(b)
    return out^


def _is_tenant_id(t: String) -> Bool:
    if t.byte_length() != 24:
        return False
    for b in t.as_bytes():
        if not ((b >= 48 and b <= 57) or (b >= 97 and b <= 102)):
            return False
    return True


struct Accounts(Copyable, Movable):
    var cfg: AuthConfig
    var key: List[UInt8]
    var data: String
    var host: String
    var pool: Pool
    var log: Log
    var limits: RateLimit
    var invites: RateLimit  # (per admin and tenant: an invite sends an email)
    var events: Optional[Queue]
    var tenant_migrations: Optional[Migrations]

    def __init__(out self, data_dir: String, var cfg: AuthConfig, log: Log = Log(addr=0), events: Optional[Queue] = None) raises:
        """Opens (and migrates) host.db, and every tenant's file to SAAS_MIGRATIONS' newest: raises (refusing to start)
        when a migration is broken or an applied one was edited, with no file changed."""
        if cfg.secret.byte_length() < 32:
            raise Error("SAAS_SECRET must be at least 32 characters (e.g. 64 hex digits)")
        self.data = data_dir
        if not exists(data_dir + "/tenants"):
            makedirs(data_dir + "/tenants")
        self.host = data_dir + "/host.db"
        self.pool = Pool.shared()
        self.key = List[UInt8]()
        for b in cfg.secret.as_bytes():
            self.key.append(b)
        self.limits = RateLimit(cfg.rate, 60)
        self.invites = RateLimit(50, 3600)
        self.log = log
        self.events = events
        self.tenant_migrations = None
        var dir = cfg.migrations + "/tenant"
        if cfg.migrations != "" and exists(dir):
            self.tenant_migrations = Migrations.from_dir(dir)
        self.cfg = cfg^
        _ = log.secret(self.cfg.client_secret)
        _ = log.secret(self.cfg.secret)
        var db = Database(self.host)
        db.exec("PRAGMA journal_mode=WAL")
        _ = host_migrations().apply(db)
        if self.tenant_migrations:
            var paths = List[String]()
            var q = db.prepare("SELECT id FROM tenants ORDER BY created, id")
            while q.step():
                if _is_tenant_id(q.text(0)):
                    paths.append(self.data + "/tenants/" + q.text(0) + ".db")
            var n = apply_all(self.tenant_migrations.value(), paths)
            if n > 0:
                self.log.info("tenant migrations applied", Fields().int("tenants", len(paths)).int("applied", n))

    def db(self) raises -> Database:
        """This thread's connection to host.db."""
        return self.pool.open(self.host)

    # requests -------------------------------------------------------------------------------------------------------

    def blocking(self, req: Req) -> Bool:
        """The routes that wait on the provider (the callback's token and userinfo calls)."""
        return req.path == "/auth/callback"

    def handle(self, mut req: Req) -> Reply:
        """Answers the account routes; any other request: a Reply with status 0 (not mine)."""
        try:
            var twice = self.cookie_name() if cookie_count(req, self.cookie_name()) > 1 else (self.state_cookie_name() if cookie_count(req, self.state_cookie_name()) > 1 else String(""))
            if twice != "":  # (refused, not guessed between; and expired, so the next request works: D-6027)
                return Reply.error(400, "two cookies named " + twice + ": signed out, sign in again", "bad_cookie").header(
                    "Set-Cookie", twice + "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" + ("; Secure" if self.secure() else ""))
            if req.path == "/login" or req.path == "/auth/callback" or req.path == "/api/token":
                var wait = self.limits.hit(rate_key(req.client if req.client != "" else req.peer) + " " + req.path)
                if wait > 0:
                    return Reply.error(429, "too many sign-in attempts from here: try again shortly", "rate_limited").header("Retry-After", String(wait))
            if req.matches("GET", "/login"):
                return self._login(req)
            if req.matches("GET", "/auth/callback"):
                return self._callback(req).header("Referrer-Policy", "no-referrer")  # (its URL holds the code)
            if req.matches("POST", "/api/token"):
                return self._token(req)
            if req.matches("POST", "/auth/desktop"):
                return self._desktop_confirm(req).header("Referrer-Policy", "no-referrer").header("Cache-Control", "no-store")
            if req.matches("GET", "/logout"):  # (a link or an img must sign nobody out: a page with the button, D-6034)
                return self._logout_page()
            if req.matches("POST", "/logout"):
                return self._logout(req)
            if req.matches("GET", "/api/me"):
                var m = self.member(req)
                if not m:
                    return Reply.error(401, "sign in first", "unauthorized")
                return Reply.json("{" + self.me_fields(m.value(), m.value().plan) + "}")
            if req.matches("POST", "/api/invites"):
                return self._invite(req)
            if req.matches("GET", "/api/tenants"):
                return self._tenants(req)
            if req.matches("POST", "/api/switch"):
                return self._switch(req)
            if req.matches("GET", "/invites/{token}") or req.matches("POST", "/invites/{token}"):
                return self._invitation(req).header("Referrer-Policy", "no-referrer")  # (its URL is the invitation)
        except e:
            self.log.error("accounts: " + String(e))
            return Reply.error(500, "the sign-in store failed", "internal")
        return Reply(0, "", "")

    def me_fields(self, v: Member, plan: String) -> String:
        """/api/me's fields (no braces) with `plan` as given, for a module that adds its own (mojoui.billing)."""
        return ('"email": ' + json_string(v.email) + ', "name": ' + json_string(v.name) + ', "tenant": ' + json_string(v.tenant)
            + ', "tenant_name": ' + json_string(v.tenant_name) + ', "role": ' + json_string(v.role) + ', "plan": ' + json_string(plan))

    def member(self, req: Req) -> Optional[Member]:
        """The signed-in person in their current tenant: from `Authorization: Bearer <token>` or the session cookie;
        None when neither is a live session (missing, tampered, expired, idle too long, signed out)."""
        var token = String("")
        var auth = req.header("authorization")
        if auth.startswith("Bearer "):
            token = String(auth[byte = 7 :])
        else:
            token = cookie(req, self.cookie_name())
            if req.method != "GET" and req.method != "HEAD" and not _origin_ok(req, self.cfg.base):
                return None  # (a browser's cross-site write with the cookie: refused on every route, D-5726)
        if token == "":
            return None
        var now = now_s()
        var sid = unseal(self.key, token, now)
        if not sid:
            return None
        try:
            var h = sha256_hex(sid.value())
            var db = self.db()
            var q = db.prepare(
                "SELECT u.id, u.email, u.name, s.tenant, m.role, t.plan, t.name, s.last_seen FROM sessions s JOIN users u ON u.id = s.user_id"
                " JOIN members m ON m.user_id = s.user_id AND m.tenant = s.tenant JOIN tenants t ON t.id = s.tenant"
                " WHERE s.id = ? AND s.expires > ? AND s.last_seen > ?"
            )
            q.bind(1, h)
            q.bind(2, now)
            q.bind(3, now - self.cfg.idle_s)
            if not q.step():
                return None
            var m = Member(q.int(0), q.text(1), q.text(2), q.text(3), q.text(4), q.text(5), h, q.text(6))
            var seen = q.int(7)
            q.reset()
            if now - seen >= max(self.cfg.idle_s // 10, 1):  # (sliding: written at most every tenth of the idle time)
                db.begin()
                try:
                    var u = db.prepare("UPDATE sessions SET last_seen = ? WHERE id = ?")
                    u.bind(1, now)
                    u.bind(2, h)
                    u.run()
                    db.commit()
                except e:
                    _ = db.rollback_quiet()
                    raise e^
            return m^
        except e:
            self.log.error("accounts: " + String(e))
        return None

    def need(self, req: Req, role: String) -> Tuple[Optional[Member], Reply]:
        """fh-saas's @require_role: the member when their role is at least `role`, else None and the 401 or 403 to answer."""
        var m = self.member(req)
        if not m:
            return (Optional[Member](None), Reply.error(401, "sign in first", "unauthorized"))
        if not m.value().at_least(role):
            return (Optional[Member](None), Reply.error(403, "this needs the " + role + " role", "forbidden"))
        return (m^, Reply(0, "", ""))

    def tenant_db(self, m: Member) raises -> Database:
        """The member's tenant's own SQLite file, this thread's connection (tenant ids are hex this module makes:
        never a path from a request)."""
        if not _is_tenant_id(m.tenant):
            raise Error("not a tenant id")
        return self.pool.open(self.data + "/tenants/" + m.tenant + ".db")

    def set_plan(self, tenant: String, plan: String, customer: String = "", subscription: String = "") raises -> Bool:
        """A billing module's hook: the tenant's plan label (and its Stripe customer/subscription when given)."""
        var db = self.db()
        db.begin()
        try:
            var q = db.prepare(
                "UPDATE tenants SET plan = ?, customer = COALESCE(NULLIF(?, ''), customer),"
                " subscription = COALESCE(NULLIF(?, ''), subscription) WHERE id = ?"
            )
            q.bind(1, plan)
            q.bind(2, customer)
            q.bind(3, subscription)
            q.bind(4, tenant)
            q.run()
            var ok = db.changes() > 0
            db.commit()
            return ok
        except e:
            _ = db.rollback_quiet()
            raise e^

    def audit(self, tenant: String, actor: String, action: String, detail: String = ""):
        try:
            var db = self.db()
            db.begin()
            try:
                Audit.record(db, tenant, actor, action, detail)
                db.commit()
            except e:
                _ = db.rollback_quiet()
                raise e^
        except e:
            self.log.error("audit: " + String(e))

    def start_session(self, user_id: Int, tenant: String) raises -> String:
        """A new session for the user in `tenant`: its sealed token (the cookie's value, or a desktop app's bearer token)."""
        var sid = random_token(32)
        var db = self.db()
        db.begin()
        try:
            var q = db.prepare("INSERT INTO sessions(id, user_id, tenant, expires, last_seen) VALUES (?, ?, ?, ?, ?)")
            q.bind(1, sha256_hex(sid))
            q.bind(2, user_id)
            q.bind(3, tenant)
            q.bind(4, now_s() + SESSION_S)
            q.bind(5, now_s())
            q.run()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        return seal(self.key, sid, SESSION_S, now_s())

    def secure(self) -> Bool:
        return self.cfg.base.startswith("https://")

    def cookie_name(self) -> String:
        """The session cookie: __Host-saas on https (Secure, Path=/, no Domain), else saas."""
        return ("__Host-" if self.secure() else "") + COOKIE

    def state_cookie_name(self) -> String:
        return ("__Host-" if self.secure() else "") + STATE_COOKIE

    def session_cookie(self, token: String) -> String:
        var c = self.cookie_name() + "=" + token + "; Path=/; HttpOnly; SameSite=Lax; Max-Age=" + String(SESSION_S)
        return c + ("; Secure" if self.secure() else "")

    def sweep(self) raises -> Int:
        """Expired used sign-in states, sessions and desktop codes deleted (a thousand rows a table a transaction, by their
        expiry indexes): for a server's tick. How many went."""
        var gone = 0
        var db = self.db()
        for table in ["signin_used", "desktop_codes", "desktop_pending", "sessions"]:
            while True:
                db.begin()
                var n: Int
                try:
                    var q = db.prepare("DELETE FROM " + table + " WHERE rowid IN (SELECT rowid FROM " + table + " WHERE expires < ? LIMIT ?)")
                    q.bind(1, now_s())
                    q.bind(2, _SWEEP_LIMIT)
                    q.run()
                    n = db.changes()
                    db.commit()
                except e:
                    _ = db.rollback_quiet()
                    raise e^
                gone += n
                if n < _SWEEP_LIMIT:
                    break
        return gone

    def user_email(self, user_id: Int) raises -> Optional[Tuple[String, String]]:
        """A user's (email, name), for a job that reads its person when it runs (None: gone)."""
        var q = self.db().prepare("SELECT email, COALESCE(name, '') FROM users WHERE id = ?")
        q.bind(1, user_id)
        if not q.step():
            return None
        return (q.text(0), q.text(1))

    def home_tenant(self, user_id: Int) raises -> String:
        """The tenant a sign-in lands in: the last one used, while still a member; else the first joined."""
        var q = self.db().prepare(
            "SELECT m.tenant FROM members m JOIN users u ON u.id = m.user_id WHERE m.user_id = ?"
            " ORDER BY (m.tenant = u.last_tenant) DESC, m.rowid LIMIT 1")
        q.bind(1, user_id)
        return q.text(0) if q.step() else String("")

    def user_for(self, email: String, name: String, sub: String) raises -> Tuple[Int, String]:
        """The user this provider identity (sub) or, the first time, this verified email is, and the tenant to sign in
        to; (-1, "") when the email's account belongs to another sub (refused, an `identity_mismatch` audit row). Made on
        first sign-in with a tenant of their own (admin) and a `signed_up` event {user}, in one transaction. Invites never
        join anyone here: they're accepted (/invites/…). `sub` "" (a test session): the email alone."""
        var db = self.db()
        if sub != "":
            var by_sub = db.prepare("SELECT id, email FROM users WHERE provider = ? AND sub = ?")  # (the common case: no lock)
            by_sub.bind(1, PROVIDER)
            by_sub.bind(2, sub)
            if by_sub.step() and by_sub.text(1) == email:
                var known = by_sub.int(0)
                by_sub.reset()
                return (known, self.home_tenant(known))
            by_sub.reset()
        var tenant = hex(random_bytes(12))
        var uid: Int
        db.begin()
        try:
            if sub != "":  # (under the writer lock: a first sign-in racing another with this sub sees it here)
                var mine = db.prepare("SELECT id, email FROM users WHERE provider = ? AND sub = ?")
                mine.bind(1, PROVIDER)
                mine.bind(2, sub)
                if mine.step():
                    uid = mine.int(0)
                    var had = mine.text(1)
                    mine.reset()
                    if had != email:  # (the provider vouches for another address now: invites must match it, D-6027)
                        var taken = db.prepare("SELECT 1 FROM users WHERE email = ? AND id != ?")
                        taken.bind(1, email)
                        taken.bind(2, uid)
                        var clash = taken.step()
                        taken.reset()
                        if clash:
                            Audit.record(db, self.home_tenant(uid), had, "identity_mismatch", "the " + PROVIDER + " account's address is another account's now")
                            db.commit()
                            return (-1, String(""))
                        var mv = db.prepare("UPDATE users SET email = ? WHERE id = ?")
                        mv.bind(1, email)
                        mv.bind(2, uid)
                        mv.run()
                        Audit.record(db, self.home_tenant(uid), email, "email_changed", had + " → " + email)
                    db.commit()
                    return (uid, self.home_tenant(uid))
                mine.reset()
            var again = db.prepare("SELECT id, COALESCE(sub, '') FROM users WHERE email = ?")  # (under the writer lock: two first sign-ins at once)
            again.bind(1, email)
            if again.step():
                uid = again.int(0)
                var have = again.text(1)
                again.reset()
                if sub != "" and have != "" and have != sub:
                    Audit.record(db, self.home_tenant(uid), email, "identity_mismatch", "a sign-in from another " + PROVIDER + " account with this address")
                    db.commit()
                    return (-1, String(""))
                if sub != "" and have == "":
                    var claim = db.prepare("UPDATE users SET provider = ?, sub = ? WHERE id = ?")  # (the first sign-in with a sub: it's theirs now)
                    claim.bind(1, PROVIDER)
                    claim.bind(2, sub)
                    claim.bind(3, uid)
                    claim.run()
                db.commit()
                return (uid, self.home_tenant(uid))
            again.reset()
            var ins = db.prepare("INSERT INTO users(email, name, sub, provider, created, last_tenant) VALUES (?, ?, ?, ?, ?, ?)")
            ins.bind(1, email)
            ins.bind(2, name)
            if sub != "":
                ins.bind(3, sub)
                ins.bind(4, PROVIDER)
            else:
                ins.bind_null(3)
                ins.bind_null(4)
            ins.bind(5, now_s())
            ins.bind(6, tenant)
            ins.run()
            uid = db.last_id()
            var t = db.prepare("INSERT INTO tenants(id, name, created) VALUES (?, ?, ?)")
            t.bind(1, tenant)
            t.bind(2, name if name != "" else email)
            t.bind(3, now_s())
            t.run()
            var mem = db.prepare("INSERT INTO members(user_id, tenant, role, joined) VALUES (?, ?, 'admin', ?)")
            mem.bind(1, uid)
            mem.bind(2, tenant)
            mem.bind(3, now_s())
            mem.run()
            Audit.record(db, tenant, email, "sign_up")
            if self.events:  # (the outbox: the welcome exists if and only if the account does)
                _ = self.events.value().add_in(db, "signed_up", '{"user": ' + String(uid) + "}", tenant)
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        if self.events:
            self.events.value().wake()
        var tdb = Database(self.data + "/tenants/" + tenant + ".db")  # (the tenant's file exists from its first sign-in, migrated)
        tdb.exec("PRAGMA journal_mode=WAL")
        if self.tenant_migrations:
            _ = self.tenant_migrations.value().apply(tdb)
        return (uid, tenant)

    # the routes -----------------------------------------------------------------------------------------------------

    def _login(self, req: Req) raises -> Reply:
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
        var sealed = seal(self.key, "signin\n" + state + "\n" + nxt + "\n" + redirect + "\n" + challenge + "\n" + app_state, STATE_S, now_s())
        var verifier = self._verifier(state)
        var names: List[String] = ["response_type", "client_id", "redirect_uri", "scope", "state", "code_challenge", "code_challenge_method", "prompt"]
        var values: List[String] = ["code", self.cfg.client_id, self.cfg.callback(), "openid email profile", state, pkce_challenge(verifier), "S256", "select_account"]
        var sep = "&" if "?" in self.cfg.authorize_url else "?"
        var path = "/" if self.secure() else "/auth/callback"  # (__Host- needs Path=/)
        return Reply.empty(303).header("Location", self.cfg.authorize_url + sep + form(names, values)).header("Cache-Control", "no-store").header(
            "Set-Cookie", self.state_cookie_name() + "=" + sealed + "; Path=" + path + "; HttpOnly; SameSite=Lax; Max-Age=" + String(STATE_S)
            + ("; Secure" if self.secure() else ""))

    def _verifier(self, state: String) -> String:
        """The PKCE verifier for a state: an HMAC under the server's key (43 characters), so it needs no row and the
        browser never holds it."""
        return b64url(hmac_sha256(self.key, _utf8("pkce:" + state)))

    def open_state(self, sealed: String, state: String, now: Int) -> Optional[SigninState]:
        """The pending sign-in a browser's state cookie seals, if it's this server's, unexpired, and for `state`."""
        var v = unseal(self.key, sealed, now)
        if not v or not v.value().startswith("signin\n"):
            return None
        var f = v.value().split("\n")
        if len(f) != 6 or not same(String(f[1]), state):
            return None
        return SigninState(String(f[1]), String(f[2]), String(f[3]), String(f[4]), String(f[5]), self._verifier(state))

    def state_used(self, state: String) raises -> Bool:
        var q = self.db().prepare("SELECT 1 FROM signin_used WHERE id = ?")
        q.bind(1, sha256_hex("state:" + state))
        var used = q.step()
        q.reset()
        return used

    def use_state(self, state: String) raises -> Bool:
        """Marks a state used (until its cookie could have expired anyway): False when it already was (a replay)."""
        var db = self.db()
        db.begin()
        try:
            var q = db.prepare("INSERT OR IGNORE INTO signin_used(id, expires) VALUES (?, ?)")
            q.bind(1, sha256_hex("state:" + state))
            q.bind(2, now_s() + STATE_S)
            q.run()
            var fresh = db.changes() == 1
            db.commit()
            return fresh
        except e:
            _ = db.rollback_quiet()
            raise e^

    def _callback(self, req: Req) raises -> Reply:
        var state = req.arg("state")
        var code = req.arg("code")
        if state == "" or code == "":
            return Reply.error(400, "sign-in was cancelled or refused: " + req.arg("error"), "bad_callback")
        var opened = self.open_state(cookie(req, self.state_cookie_name()), state, now_s())
        if not opened:
            return Reply.error(400, "this sign-in wasn't started in this browser, or it expired: start again here", "bad_state")
        if self.state_used(state):  # (a replayed callback: refused before the provider is asked again)
            return Reply.error(400, "this sign-in was already used: start again", "bad_state")
        var st = opened.value().copy()
        var verifier = st.verifier
        var nxt = st.next
        var redirect = st.redirect
        var challenge = st.challenge
        var app_state = st.app_state
        # the code → a token (client secret + PKCE verifier) → who it is
        var tn: List[String] = ["grant_type", "code", "redirect_uri", "client_id", "client_secret", "code_verifier"]
        var tv: List[String] = ["authorization_code", code, self.cfg.callback(), self.cfg.client_id, self.cfg.client_secret, verifier]
        var tr = Backend.send(Request(0, "POST", self.cfg.token_url, form(tn, tv)).header("Content-Type", "application/x-www-form-urlencoded").header("Accept", "application/json").timeout(20_000))
        if tr.status != 200:
            self.log.warn("the token endpoint refused the code", Fields().int("status", tr.status).str("error", tr.error))
            return Reply.error(502, "the sign-in provider refused the code", "token_failed")
        if not self.use_state(state):  # (two callbacks with one state at once: the provider traded the code once; this one too)
            return Reply.error(400, "this sign-in was already used: start again", "bad_state")
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
        var sub = uj.text(uj.get(0, "sub"))
        if sub == "":
            return Reply.error(502, "the sign-in provider didn't say which account this is", "userinfo_failed")
        var who = self.user_for(email, uj.text(uj.get(0, "name")), sub)
        var uid = who[0]
        var tenant = who[1]
        if uid < 0:
            self.log.warn("sign-in refused: the address belongs to another account", Fields().str("provider", PROVIDER))
            return Reply.error(403, "this address is already used by another " + PROVIDER + " account: sign in with that one", "identity_mismatch")
        if redirect != "":  # (no code yet: the person says it's their app first)
            return self._confirm_page(uid, email, challenge, redirect, app_state)
        self.audit(tenant, email, "sign_in", "web")
        var token = self.start_session(uid, tenant)
        # (one Set-Cookie per reply in mojoui.serve: the state cookie is scoped to /auth/callback and expires in 10 minutes)
        return Reply.empty(303).header("Location", nxt if is_local_path(nxt) else "/").header("Set-Cookie", self.session_cookie(token)).header("Cache-Control", "no-store")

    def _confirm_page(self, uid: Int, email: String, challenge: String, redirect: String, app_state: String) raises -> Reply:
        """"Sign in to <app> on this computer?": a pending row under a random id that only this page holds (in its
        body, never a URL), answered by POST /auth/desktop."""
        var ask = random_token(32)
        var db = self.db()
        db.begin()
        try:
            var q = db.prepare("INSERT INTO desktop_pending(id, user_id, challenge, redirect, app_state, expires) VALUES (?, ?, ?, ?, ?, ?)")
            q.bind(1, sha256_hex(ask))
            q.bind(2, uid)
            q.bind(3, challenge)
            q.bind(4, redirect)
            q.bind(5, app_state)
            q.bind(6, now_s() + CONFIRM_S)
            q.run()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        var app = escape_html(self.cfg.app_name)
        var page = ("<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width'>"
            + "<title>Sign in to " + app + " on this computer?</title></head>"
            + "<body style='font-family: system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1rem'>"
            + "<h1>Sign in to " + app + " on this computer?</h1>"
            + "<p>You're signed in as <b>" + escape_html(email) + "</b>. The " + app + " desktop app on this computer asked to sign in"
            + " (it is waiting at <code>" + escape_html(_origin_of(redirect)) + "</code>).</p>"
            + "<p>Continue only if you just pressed Sign in in the app yourself. If a link someone sent you brought you here, cancel:"
            + " they may be trying to get into your account.</p>"
            + "<form method=post action=/auth/desktop><input type=hidden name=confirm value=" + ask + ">"
            + "<button type=submit name=do value=yes>Sign in to " + app + "</button> "
            + "<button type=submit name=do value=no>Cancel</button></form></body></html>")
        # (form-action: this site, and the loopback the confirm's 303 goes on to; never framed, never cached)
        return Reply(200, "text/html; charset=utf-8", page).header("Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' " + _origin_of(redirect) + "; frame-ancestors 'none'").header(
            "X-Frame-Options", "DENY").header("Cache-Control", "no-store")

    def _desktop_confirm(self, req: Req) raises -> Reply:
        """The confirm page's answer: a same-origin POST {confirm, do}; "yes" releases the one-time code to the app's
        loopback (303), anything else cancels. Either way the pending row is used up."""
        if not _same_origin_post(req, self.cfg.base):
            return Reply.error(403, "a desktop sign-in is confirmed on this site's own page only", "forbidden")
        var ask = form_arg(req.body, "confirm")
        if ask == "" or ask.byte_length() > 64:
            return Reply.error(400, "send the confirm page's form", "bad_request")
        var db = self.db()
        var uid: Int
        var challenge: String
        var redirect: String
        var app_state: String
        db.begin()
        try:
            var q = db.prepare("DELETE FROM desktop_pending WHERE id = ? AND expires > ? RETURNING user_id, challenge, redirect, app_state")  # (one answer)
            q.bind(1, sha256_hex(ask))
            q.bind(2, now_s())
            if not q.step():
                q.reset()
                db.commit()
                return Reply.error(400, "this sign-in was answered, cancelled or expired: start again from the app", "bad_state")
            uid = q.int(0)
            challenge = q.text(1)
            redirect = q.text(2)
            app_state = q.text(3)
            q.reset()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        if form_arg(req.body, "do") != "yes":
            return Reply.html("<!doctype html><title>Sign-in cancelled</title><p>Cancelled: nothing was sent to the app.</p>")
        var once = random_token(32)
        db.begin()
        try:
            var c = db.prepare("INSERT INTO desktop_codes(id, user_id, challenge, expires) VALUES (?, ?, ?, ?)")
            c.bind(1, sha256_hex(once))
            c.bind(2, uid)
            c.bind(3, challenge)
            c.bind(4, now_s() + CODE_S)
            c.run()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        var who = self.user_email(uid)
        if who:
            self.audit(self.home_tenant(uid), who.value()[0], "sign_in", "desktop")
        var sep = "&" if "?" in redirect else "?"
        var names: List[String] = ["code", "state"]
        var values: List[String] = [once, app_state]
        return Reply.text("Signed in: you can go back to the app.", 303).header("Location", redirect + sep + form(names, values))

    def _token(self, req: Req) raises -> Reply:
        """A desktop app trades its one-time code and PKCE verifier for a bearer token."""
        var code: String
        var verifier: String
        try:
            var j = Json.parse(req.body)
            code = j.text(j.get(0, "code"))
            verifier = j.text(j.get(0, "verifier"))
        except:
            return Reply.error(400, "send {code, verifier}", "bad_request")
        var db = self.db()
        db.begin()
        var found = False
        var uid = 0
        var challenge = String("")
        try:
            var q = db.prepare("DELETE FROM desktop_codes WHERE id = ? RETURNING user_id, challenge, expires")  # (one try, right or wrong)
            q.bind(1, sha256_hex(code))
            if q.step():
                found = q.int(2) > now_s()
                uid = q.int(0)
                challenge = q.text(1)
            q.reset()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        if not found or verifier.byte_length() < 43 or not same(pkce_challenge(verifier), challenge):
            return Reply.error(400, "that code isn't good (used, expired, or the verifier doesn't match)", "invalid_grant")
        return Reply.json('{"token": ' + json_string(self.start_session(uid, self.home_tenant(uid))) + "}").header("Cache-Control", "no-store")

    def _logout_page(self) -> Reply:
        var app = escape_html(self.cfg.app_name)
        return Reply.html("<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width'>"
            + "<title>Sign out of " + app + "?</title></head>"
            + "<body style='font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem'>"
            + "<h1>Sign out of " + app + "?</h1><form method=post action=/logout><button type=submit>Sign out</button></form>"
            + "</body></html>").header("Cache-Control", "no-store")

    def _logout(self, req: Req) raises -> Reply:
        """POST only (a GET answers _logout_page). A cookie's sign-out from another site is refused (403) and its
        cookie left alone; a bearer token's (a native app) ends that session."""
        if req.header("authorization") == "" and not _origin_ok(req, self.cfg.base):
            return Reply.error(403, "sign out on this site", "forbidden")
        var m = self.member(req)
        if m:
            var db = self.db()
            db.begin()
            try:
                var q = db.prepare("DELETE FROM sessions WHERE id = ?")
                q.bind(1, m.value().session)
                q.run()
                db.commit()
            except e:
                _ = db.rollback_quiet()
                raise e^
        var clear = self.cookie_name() + "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" + ("; Secure" if self.secure() else "")
        if req.header("authorization") != "":
            return Reply.json('{"ok": true}')
        return Reply.empty(303).header("Location", "/").header("Set-Cookie", clear)

    def _invite(self, req: Req) raises -> Reply:
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
        if not known or "@" not in email or email.byte_length() > 254 or "\r" in email or "\n" in email:
            return Reply.error(400, "an email and a role (admin, editor, member, viewer)", "bad_request")
        var v = m.value().copy()
        var wait = self.invites.hit(String(v.user_id) + " " + v.tenant)
        if wait > 0:
            return Reply.error(429, "too many invitations this hour", "rate_limited").header("Retry-After", String(wait))
        var db = self.db()
        var id: Int
        var expires = now_s() + self.cfg.invite_ttl_s
        db.begin()
        try:
            var q = db.prepare("INSERT INTO invites(email, tenant, role, by, created, expires) VALUES (?, ?, ?, ?, ?, ?)")
            q.bind(1, email)
            q.bind(2, v.tenant)
            q.bind(3, role)
            q.bind(4, v.user_id)
            q.bind(5, now_s())
            q.bind(6, expires)
            q.run()
            id = db.last_id()
            Audit.record(db, v.tenant, v.email, "invite", email + " as " + role)
            if self.events:  # (the outbox: the email's job exists if and only if the invite does)
                _ = self.events.value().add_in(db, "invite", '{"invite": ' + String(id) + "}", v.tenant)
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        if self.events:
            self.events.value().wake()
        return Reply.json('{"invited": ' + json_string(email) + ', "role": ' + json_string(role) + ', "expires": ' + String(expires) + "}", 201)

    def invite_token(self, id: Int, expires: Int) -> String:
        """The link's token: the invite's id sealed under the server's key until it expires."""
        return seal(self.key, "invite:" + String(id), expires, 0)

    def invite_details(self, id: Int) raises -> Optional[Invite]:
        """What its email says (None once it's used or gone): for the app's job that sends it."""
        var q = self.db().prepare(
            "SELECT i.email, i.role, i.expires, COALESCE(u.name, u.email, ''), COALESCE(t.name, '') FROM invites i"
            " LEFT JOIN users u ON u.id = i.by LEFT JOIN tenants t ON t.id = i.tenant WHERE i.id = ? AND i.used IS NULL")
        q.bind(1, id)
        if not q.step():
            return None
        var expires = q.int(2)
        var days = max((expires - now_s() + 86399) // 86400, 1)
        return Invite(q.text(0), self.cfg.base + "/invites/" + self.invite_token(id, expires), q.text(3), q.text(4), q.text(1), days)

    def _invitation(self, mut req: Req) raises -> Reply:
        """GET: "Join <tenant>, invited by <name>?" for the invited address; POST (same origin): accept it."""
        var token = req.param("token")
        var opened = unseal(self.key, token, 0)  # (the signature only: an expired link says so, 410)
        if not opened or not opened.value().startswith("invite:"):
            return Reply.error(404, "no such invitation", "not_found")
        var id: Int
        try:
            id = atol(String(opened.value()[byte = 7 :]))
        except:
            return Reply.error(404, "no such invitation", "not_found")
        if req.method == "POST" and req.header("origin") != "" and req.header("origin") != self.cfg.base:
            return Reply.error(403, "an invitation is accepted on this site only", "forbidden")
        var db = self.db()
        var q = db.prepare(
            "SELECT i.email, i.tenant, i.role, i.expires, i.used, COALESCE(u.name, u.email, ''), COALESCE(t.name, '')"
            " FROM invites i LEFT JOIN users u ON u.id = i.by LEFT JOIN tenants t ON t.id = i.tenant WHERE i.id = ?")
        q.bind(1, id)
        if not q.step():
            return Reply.error(404, "no such invitation", "not_found")
        var email = q.text(0)
        var tenant = q.text(1)
        var role = q.text(2)
        var expires = q.int(3)
        var used = not q.is_null(4)
        var inviter = q.text(5)
        var tname = q.text(6)
        q.reset()
        if used:
            return Reply.html("<!doctype html><title>Invitation used</title><p>This invitation has been used.</p>", 410)
        if expires <= now_s():
            return Reply.html("<!doctype html><title>Invitation expired</title><p>This invitation has expired: ask for a new one.</p>", 410)
        var m = self.member(req)
        if not m:
            if req.method == "GET":
                return Reply.empty(303).header("Location", "/login?next=" + uri_component("/invites/" + token)).header("Cache-Control", "no-store")
            return Reply.error(401, "sign in first", "unauthorized")
        var me = m.value().copy()
        if me.email != email:
            return Reply.error(403, "this invitation is for another address", "forbidden")
        if req.method == "GET":
            var page = ("<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                + "<title>Join " + escape_html(tname) + "</title></head>"
                + "<body style='font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem'>"
                + "<h1>Join " + escape_html(tname) + ", invited by " + escape_html(inviter) + "?</h1>"
                + "<p>You'll join as <b>" + escape_html(role) + "</b>, signed in as " + escape_html(email) + ".</p>"
                + "<form method=post><button type=submit>Join " + escape_html(tname) + "</button></form></body></html>")
            return Reply.html(page).header("Cache-Control", "no-store")
        db.begin()
        try:
            var u = db.prepare("UPDATE invites SET used = ? WHERE id = ? AND used IS NULL AND expires > ?")
            u.bind(1, now_s())
            u.bind(2, id)
            u.bind(3, now_s())
            u.run()
            if db.changes() != 1:
                db.commit()
                return Reply.error(410, "this invitation has been used", "gone")
            var j = db.prepare("INSERT OR IGNORE INTO members(user_id, tenant, role, joined) VALUES (?, ?, ?, ?)")
            j.bind(1, me.user_id)
            j.bind(2, tenant)
            j.bind(3, role)
            j.bind(4, now_s())
            j.run()
            self._move(db, me, tenant)
            Audit.record(db, tenant, me.email, "invite_accept", role)
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        return Reply.empty(303).header("Location", "/").header("Cache-Control", "no-store")

    def _move(self, db: Database, m: Member, tenant: String) raises:
        """The session (and the next sign-in) now in `tenant` (inside the caller's transaction)."""
        var s = db.prepare("UPDATE sessions SET tenant = ? WHERE id = ?")
        s.bind(1, tenant)
        s.bind(2, m.session)
        s.run()
        var u = db.prepare("UPDATE users SET last_tenant = ? WHERE id = ?")
        u.bind(1, tenant)
        u.bind(2, m.user_id)
        u.run()

    def _tenants(self, req: Req) raises -> Reply:
        var m = self.member(req)
        if not m:
            return Reply.error(401, "sign in first", "unauthorized")
        var q = self.db().prepare("SELECT m.tenant, COALESCE(t.name, ''), m.role FROM members m JOIN tenants t ON t.id = m.tenant WHERE m.user_id = ? ORDER BY m.rowid")
        q.bind(1, m.value().user_id)
        var out = String("[")
        var n = 0
        while q.step():
            out += ("," if n > 0 else "") + '{"tenant": ' + json_string(q.text(0)) + ', "name": ' + json_string(q.text(1)) + ', "role": ' + json_string(q.text(2))
            out += ', "current": ' + ("true" if q.text(0) == m.value().tenant else "false") + "}"
            n += 1
        return Reply.json('{"tenants": ' + out + "]}")

    def _switch(self, req: Req) raises -> Reply:
        var m = self.member(req)
        if not m:
            return Reply.error(401, "sign in first", "unauthorized")
        var tenant: String
        try:
            var j = Json.parse(req.body)
            tenant = j.text(j.get(0, "tenant"))
        except:
            return Reply.error(400, "send {tenant}", "bad_request")
        var db = self.db()
        db.begin()
        try:
            var q = db.prepare("SELECT role FROM members WHERE user_id = ? AND tenant = ?")
            q.bind(1, m.value().user_id)
            q.bind(2, tenant)
            if not q.step():
                q.reset()
                db.commit()
                return Reply.error(403, "you're not a member of that tenant", "forbidden")
            var role = q.text(0)
            q.reset()
            self._move(db, m.value(), tenant)
            db.commit()
            return Reply.json('{"tenant": ' + json_string(tenant) + ', "role": ' + json_string(role) + "}")
        except e:
            _ = db.rollback_quiet()
            raise e^

    def test_session(self, email: String) raises -> String:
        """A session for `email` without a provider: for test runs only; the caller gates it (SAAS_TEST_HOOK=1 and a test
        key) and never builds it into a route otherwise."""
        var who = self.user_for(email.lower(), "", "")
        return self.start_session(who[0], who[1])


def b64url_ok(s: String) -> Bool:
    for b in s.as_bytes():
        var c = Int(b)
        if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 45 or c == 95):
            return False
    return True
