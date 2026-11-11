# The saas demo's server (goals 57, 60): sign-in, tenants, invites, payments, email and jobs composed from mojoui's
# modules on mojoui.serve's concurrent Handler. Nothing here but routes and wiring: the pieces are the framework's.
# Env and routes: docs/goals/57-check.py's and 60-check.py's docstrings.
#   scripts/saas.sh build && SAAS_SECRET=… GOOGLE_CLIENT_ID=… build/saas/server
from std.os import getenv
from std.sys import exit
from mojoui.serve import Handler, Req, Reply, serve
from mojoui.accounts import Accounts, AuthConfig, Member
from mojoui.billing import Billing, BillingConfig
from mojoui.jobs import Queue, QueuedJob, Runner, start_workers, permanent
from mojoui.clientip import TrustedProxies
from mojoui.mail import SmtpConfig, Mail, send, welcome, invitation
from mojoui.log import Log, Fields
from mojoui.json import Json, json_string
from mojoui.clock import wall_seconds
from mojoui import libc

comptime PRODUCT = "omxcode SaaS"


struct Saas(Handler):
    var acc: Accounts
    var bill: Billing
    var jobs: Queue
    var test_hook: Bool

    def __init__(out self, var acc: Accounts, var bill: Billing, jobs: Queue):
        self.acc = acc^
        self.bill = bill^
        self.jobs = jobs
        # a session without Google, for the live Stripe check only: never with a live key
        self.test_hook = getenv("SAAS_TEST_HOOK") == "1" and self.bill.cfg.is_test_mode()

    def blocking(self, req: Req) -> Bool:
        return self.acc.blocking(req) or self.bill.blocking(req)

    def tick(self):
        """Every minute: expired sign-in states, sessions and desktop codes, and old done/dead jobs, go."""
        try:
            _ = self.acc.sweep()
            _ = self.jobs.sweep()
            _ = self.bill.sweep()
        except e:
            self.acc.log.error("saas: sweep: " + String(e))

    def stop(self):
        pass

    def answer(self, mut req: Req) -> Reply:
        var limit = 1_048_576 if req.path == "/billing/webhook" else 65_536  # (D-5727: before any work)
        if len(req.body.as_bytes()) > limit:
            return secure(Reply.error(413, "the request is too large", "too_large"))
        return secure(self.route(req))

    def route(self, mut req: Req) -> Reply:
        var b = self.bill.handle(req, self.acc)  # (first: its /api/me adds the plan)
        if b.status != 0:
            return b^
        var r = self.acc.handle(req)
        if r.status != 0:
            return r^
        if self.test_hook and req.matches("POST", "/api/test-session"):
            return self.test_session(req.body)
        if req.matches("GET", "/"):
            return Reply.text("omxcode saas demo: sign in at /login")
        var who = self.acc.member(req)
        if not who:
            return Reply.error(401, "sign in first", "unauthorized")
        var m = who.value().copy()
        try:
            if req.matches("GET", "/api/entries"):
                return self.entries(m)
            if req.matches("POST", "/api/entries"):
                if not m.can_write():
                    return Reply.error(403, "viewers can't write", "forbidden")
                return self.add_entry(m, req.body)
            if req.matches("GET", "/api/pro"):
                var wall = self.bill.paywall(m)
                if wall.status != 0:
                    return wall^
                return Reply.json('{"pro": true}')
            if req.matches("GET", "/api/jobs"):
                if not m.is_admin():
                    return Reply.error(403, "only the tenant's admin sees its jobs", "forbidden")
                return Reply.json('{"jobs": ' + self.jobs.list_json(m.tenant) + "}")
        except e:
            self.acc.log.error("saas: " + String(e))
            return Reply.error(500, "the tenant's store failed", "internal")
        return Reply.not_found()

    def test_session(self, body: String) -> Reply:
        try:
            var j = Json.parse(body)
            var email = j.text(j.get(0, "email"))
            if not email.endswith("@example.com"):
                return Reply.error(400, "test sessions are for @example.com", "bad_request")
            return Reply.json('{"cookie": ' + json_string(self.acc.test_session(email)) + "}")
        except:
            return Reply.error(400, "send {email}", "bad_request")

    def entries(self, m: Member) raises -> Reply:
        var q = self.acc.tenant_db(m).prepare("SELECT text, amount_cents, by FROM entries ORDER BY id")
        var out = String('{"entries": [')
        var n = 0
        while q.step():
            out += ("," if n > 0 else "") + '{"text": ' + json_string(q.text(0)) + ', "amount_cents": ' + String(q.int(1)) + ', "by": ' + json_string(q.text(2)) + "}"
            n += 1
        return Reply.json(out + "]}")

    def add_entry(self, m: Member, body: String) raises -> Reply:
        var text: String
        var cents: Int
        try:
            var j = Json.parse(body)
            text = j.text(j.get(0, "text"))
            cents = j.number(j.get(0, "amount_cents"))
        except:
            return Reply.error(400, "send {text, amount_cents}", "bad_request")
        if text == "" or text.byte_length() > 500:
            return Reply.error(400, "an entry needs a short text", "bad_request")
        var db = self.acc.tenant_db(m)
        db.begin()
        try:
            var q = db.prepare("INSERT INTO entries(text, amount_cents, by, at) VALUES (?, ?, ?, ?)")
            q.bind(1, text)
            q.bind(2, cents)
            q.bind(3, m.email)
            q.bind(4, Int(wall_seconds()))
            q.run()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        return Reply.json('{"ok": true}', 201)


struct SaasJobs(Runner):
    """The queue's jobs: accounts' events become emails."""
    var smtp: SmtpConfig
    var acc: Accounts

    def __init__(out self, var smtp: SmtpConfig, var acc: Accounts):
        self.smtp = smtp^
        self.acc = acc^

    def run(self, job: QueuedJob) -> String:
        """(Started only when SMTP is set up: until then the jobs wait, pending, and send after a restart with it.)"""
        var j: Json
        try:
            j = Json.parse(job.payload)
        except e:
            return permanent("a payload that isn't JSON: " + String(e))
        try:
            if job.kind == "signed_up":  # {user}: the person is read now (the payload names nobody)
                var who = self.acc.user_email(j.number(j.get(0, "user")))
                if who:
                    send(self.smtp, welcome(who.value()[0], who.value()[1], PRODUCT, self.acc.cfg.base + "/"))
            elif job.kind == "invite":
                var inv = self.acc.invite_details(j.number(j.get(0, "invite")))
                if inv:  # (used or gone: nothing to send)
                    var i = inv.value().copy()
                    send(self.smtp, invitation(i.email, i.inviter, i.tenant_name, PRODUCT, i.link, i.days))
            elif job.kind == "mail":
                send(self.smtp, Mail.from_json(job.payload))
            return ""
        except e:
            return String(e)


def secure(var r: Reply) -> Reply:
    """Headers every reply carries: no type sniffing, never framed (a page's own policy, which says so too, is kept:
    a second Content-Security-Policy would replace it on Flare's path and be added to it on the offload's)."""
    var has_csp = False
    for n in r.names:
        has_csp = has_csp or n.lower() == "content-security-policy"
    r = r^.header("X-Content-Type-Options", "nosniff")
    if has_csp:
        return r^
    return r^.header("Content-Security-Policy", "frame-ancestors 'none'")


def _int(name: String, default: Int, lo: Int = 0, hi: Int = 1_000_000_000) raises -> Int:
    """A whole-number setting: unset → `default`; anything else that isn't a whole number from lo to hi refuses to
    start, naming it (a typo never turns into a default quietly, D-6036)."""
    var text = getenv(name, "")
    if text == "":
        return default
    var v: Int
    try:
        v = atol(text)
    except:
        raise Error(name + " must be a whole number (it is " + json_string(text) + ")")
    if v < lo or v > hi:
        raise Error(name + " must be from " + String(lo) + " to " + String(hi) + " (it is " + String(v) + ")")
    return v


def main() raises:
    var data = getenv("SAAS_DATA", "data")
    var log = Log.open(getenv("SAAS_LOG"))
    _ = log.secret(getenv("SMTP_PASSWORD"))
    try:
        var jobs = Queue(data + "/host.db", backoff_ms=_int("SAAS_JOB_BACKOFF_MS", 2000, 1), max_attempts=_int("SAAS_JOB_MAX_ATTEMPTS", 5, 1, 100))
        var cfg = AuthConfig.from_env()
        if cfg.migrations == "":
            cfg.migrations = "examples/saas/migrations"  # (the demo's own tenant schema)
        var acc = Accounts(data, cfg^, log, jobs)
        var bill = Billing(data, BillingConfig.from_env(), log)
        var smtp = SmtpConfig.from_env()
        if smtp.ready():
            start_workers(jobs, SaasJobs(smtp^, acc.copy()), threads=2)
        else:
            log.warn("SMTP isn't set up (SMTP_HOST, SMTP_FROM): emails wait in the queue until it is")
        var proxies = TrustedProxies.parse(getenv("SAAS_TRUSTED_PROXIES"))  # (a typo refuses to start)
        var app = Saas(acc^, bill^, jobs)
        if app.test_hook:
            print("SAAS: the test-session hook is on (SAAS_TEST_HOOK=1, a test-mode Stripe key): never in production", flush=True)
        var port = _int("SAAS_PORT", 8000, 0, 65535)
        var threads = _int("SAAS_OFFLOAD_THREADS", 16, 1, 1024)  # (the callback, checkout, portal, return, purchase)
        var queue = _int("SAAS_OFFLOAD_QUEUE", 64, 0, 3072)
        var per_client = _int("SAAS_OFFLOAD_PER_CLIENT", 4, 0, 4096)
        var served = serve(app^, port=port, host=getenv("SAAS_HOST", "127.0.0.1"), tick_ms=60_000, log=log, proxies=proxies^,
                           offload_threads=threads, offload_queue=queue, offload_per_client=per_client)
        print("SAAS: listening " + String(served.port), flush=True)
        while not served.stopped():
            _ = libc.poll(0, 0, 500)
        served.stop()
    except e:
        log.error("SAAS: not starting: " + String(e))
        print("SAAS: not starting: " + String(e), flush=True)
        exit(1)
