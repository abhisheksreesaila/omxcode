# finance_min (goal 66 M9): a small personal-finance SaaS from mojoui's server modules alone. Google sign-in and tenants
# (accounts), plans (billing), a made-up bank aggregator's API (apiclient: OAuth client credentials, GraphQL pages) and
# its signed webhooks (webhooks), the sync as a job (jobs) that bulk-upserts the tenant's transactions keeping the
# categories a person edited (sqlite.bulk_upsert), spending by category, a CSV export (csvstream), a weekly digest email
# on a schedule in the tenant's time zone (schedule + mail), a static JS front end (static), public pages (pages) and the
# operator's API (operator). Environment: examples/saas's (docs/saas.md) plus SAAS_OPERATORS SAAS_CONTACT_TO
# SAAS_CONTACT_RATE SAAS_TIMEZONE SAAS_STATIC BANK_API BANK_CLIENT_ID BANK_CLIENT_SECRET BANK_WEBHOOK_SECRET FIN_DIGEST.
#   scripts/mojo_flare.sh build examples/finance_min/server.mojo -o build/finance_min/server
from std.os import getenv
from std.sys import exit, argv
from mojoui.serve import Handler, Req, Reply, serve, escape_html
from mojoui.accounts import Accounts, AuthConfig, Member, origin_ok
from mojoui.billing import Billing, BillingConfig
from mojoui.jobs import Queue, QueuedJob, Runner, start_workers, permanent
from mojoui.clientip import TrustedProxies
from mojoui.mail import SmtpConfig, Mail, send
from mojoui.log import Log, Fields
from mojoui.json import Json, json_string
from mojoui.clock import wall_seconds
from mojoui.static import Static
from mojoui.webhooks import Webhooks, Source, JOB_KIND
from mojoui.apiclient import ApiClient, Auth
from mojoui.sqlite import Database, Pool, bulk_upsert, set_edited
from mojoui.csvstream import stream_csv
from mojoui.schedule import Scheduler, Schedule, Cron, Zone
from mojoui.pages import render, public_page, sitemap_reply, robots_reply, manifest_json, manifest_reply, service_worker_js, worker_reply, ContactForm
from mojoui.operator import Operator
from mojoui.crypto import random_token
from mojoui.http import Request
from mojoui.effects import Backend
from mojoui import libc

comptime PRODUCT = "finance_min"
comptime HOST_TABLES = (
    "CREATE TABLE IF NOT EXISTS bank_links(connection TEXT PRIMARY KEY, tenant TEXT NOT NULL, at INTEGER);"
    "CREATE TABLE IF NOT EXISTS digests_sent(tenant TEXT NOT NULL, slot TEXT NOT NULL, PRIMARY KEY(tenant, slot))"
)
comptime BANK_QUERY = "query($connection: String!, $after: String) { transactions(connection: $connection, first: 100, after: $after) { nodes { id date amount merchant category } pageInfo { hasNextPage endCursor } } }"
comptime SHELL = (
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
    '<title>{{title}}</title><meta name="description" content="{{description}}"><link rel="manifest" href="/manifest.webmanifest">'
    '<link rel="icon" href="{{icon}}"><link rel="stylesheet" href="{{css}}"></head><body><main>{{{body}}}</main></body></html>'
)
comptime LANDING = (
    '<div class="card"><h1>See where your money goes</h1><p>finance_min links your bank, sorts every transaction into a '
    'category and shows where your money goes each week, with a digest in your inbox on Monday morning.</p>'
    '<p><a class="button" href="/login?next=/app">Sign in</a> <a href="/contact">Contact us</a></p></div>'
    '<div class="card"><h2>What it does</h2><ul><li>Syncs transactions from your bank as they happen.</li>'
    '<li>Keeps the categories you change.</li><li>Exports everything as CSV.</li></ul></div>'
)
comptime APP = (
    '<div class="card"><h1>Your money</h1><p id="who" class="muted"></p><p id="status" class="muted">Loading…</p>'
    '<p><a id="export" class="button" href="/api/transactions.csv" download>Export CSV</a></p></div>'
    '<div class="card"><h2>Spending by category</h2><table><tbody id="spending"></tbody></table></div>'
    '<script src="{{js}}" defer></script>'
)


def secure(var r: Reply) -> Reply:
    var has_csp = False
    for n in r.names:
        has_csp = has_csp or n.lower() == "content-security-policy"
    r = r^.header("X-Content-Type-Options", "nosniff")
    return r^ if has_csp else r^.header("Content-Security-Policy", "frame-ancestors 'none'")


struct Fin(Handler):
    var acc: Accounts
    var bill: Billing
    var jobs: Queue
    var files: Static
    var hooks: Webhooks
    var bank: Source
    var contact: ContactForm
    var op: Operator
    var sched: Scheduler
    var digest: Cron
    var zone: Zone

    def __init__(out self, var acc: Accounts, var bill: Billing, jobs: Queue, var files: Static, hooks: Webhooks, var bank: Source,
                 var contact: ContactForm, var op: Operator, sched: Scheduler, var digest: Cron, var zone: Zone):
        self.acc = acc^
        self.bill = bill^
        self.jobs = jobs
        self.files = files^
        self.hooks = hooks
        self.bank = bank^
        self.contact = contact^
        self.op = op^
        self.sched = sched
        self.digest = digest^
        self.zone = zone^

    def blocking(self, req: Req) -> Bool:
        return self.acc.blocking(req) or self.bill.blocking(req) or self.op.blocking(req) or req.path == "/api/bank/connect"  # (waits on the bank)

    def tick(self):
        """Every second: each tenant's digest schedule; every minute: the sweeps."""
        try:
            var q = self.acc.db().prepare("SELECT id FROM tenants")
            var now = Int(wall_seconds())
            while q.step():
                _ = self.sched.due(Schedule("digest", q.text(0), self.digest.copy(), self.zone.copy(), "digest", ""), now)
            if now % 60 <= 1:  # (a 1 s tick can land on either second: the sweeps are idempotent, twice is harmless)
                _ = self.acc.sweep()
                _ = self.jobs.sweep()
                _ = self.bill.sweep()
                _ = self.hooks.sweep()
        except e:
            self.acc.log.error("finance_min: tick: " + String(e))

    def stop(self):
        pass

    def page(self, title: String, description: String, body: String) -> String:
        return render(SHELL, ["title", "description", "icon", "css", "body"],
                      [title, description, self.files.url("icon.svg"), self.files.url("app.css"), body])

    def answer(self, mut req: Req) -> Reply:
        var limit = 1_048_576 if req.path.startswith("/webhooks/") or req.path == "/billing/webhook" else 65_536
        if len(req.body.as_bytes()) > limit:
            return secure(Reply.error(413, "the request is too large", "too_large"))
        return secure(self.route(req))

    def route(self, mut req: Req) -> Reply:
        var f = self.files.handle(req)
        if f.status != 0:
            return f^
        if req.matches("GET", "/"):
            return public_page(self.page("finance_min: see where your money goes", "Link your bank and see where your money goes.", LANDING))
        if req.matches("GET", "/contact"):
            return self.contact.page(self.page("Contact finance_min", "Write to the people behind finance_min.", '<div class="card"><h1>Contact us</h1>{{{form}}}</div>'))
        if req.matches("POST", "/contact"):
            return self.contact.post(req, self.page("Thanks", "", '<div class="card"><h1>Thanks</h1><p>We read every message.</p></div>'))
        if req.matches("GET", "/sitemap.xml"):
            return sitemap_reply(self.acc.cfg.base, ["/", "/contact"])
        if req.matches("GET", "/robots.txt"):
            return robots_reply(self.acc.cfg.base, ["/api/", "/operator/", "/app", "/billing/", "/auth/"])
        if req.matches("GET", "/manifest.webmanifest"):
            return manifest_reply(manifest_json("finance_min", "Money", "/app", "#1f5f4a", "#f6f7f5", "/static/icon.svg"))
        if req.matches("GET", "/sw.js"):
            return worker_reply(service_worker_js("fin-1", ["/", self.files.url("app.css"), self.files.url("app.js"), self.files.url("icon.svg")]))
        if req.matches("GET", "/health"):
            try:
                _ = self.acc.db().count("SELECT 1")
                return Reply.json('{"ok": true}').header("Cache-Control", "no-store")
            except:
                return Reply.json('{"ok": false}', 503)
        if req.matches("POST", "/webhooks/bank"):
            return self.hooks.receive(req, self.bank)
        var o = self.op.handle(req, self.acc)
        if o.status != 0:
            return o^
        var b = self.bill.handle(req, self.acc)
        if b.status != 0:
            return b^
        var r = self.acc.handle(req)
        if r.status != 0:
            return r^
        var who = self.acc.member(req)
        if req.matches("GET", "/app"):
            if not who:
                return Reply(303, "", "").header("Location", "/login?next=/app")
            return public_page(self.page("Your money · finance_min", "", render(APP, ["js"], [self.files.url("app.js")])), cache="no-store")
        if not who:
            return Reply.error(401, "sign in first", "unauthorized")
        var m = who.value().copy()
        if req.method != "GET" and not origin_ok(req, self.acc.cfg.base):
            return Reply.error(403, "another site's request", "forbidden")
        try:
            if req.matches("GET", "/api/transactions"):
                return self.transactions(m)
            if req.matches("POST", "/api/transactions"):
                return self.add(m, req.body)
            if req.matches("PATCH", "/api/transactions/{id}"):
                return self.recategorise(m, req.param("id"), req.body)
            if req.matches("GET", "/api/spending"):
                return self.spending(m)
            if req.matches("GET", "/api/transactions.csv"):
                var header = List[String]()
                for h in ["date", "amount", "merchant", "category"]:
                    header.append(String(h))
                return stream_csv(self.acc.tenant_db(m).path, "SELECT date, amount, merchant, category FROM transactions ORDER BY date, id",
                                  List[String](), header^, "transactions.csv")
            if req.matches("POST", "/api/bank/connect"):
                return self.connect(m, req.body)
            if req.matches("POST", "/api/bank/sync"):
                if not m.can_write():
                    return Reply.error(403, "viewers can't sync", "forbidden")
                _ = self.jobs.add("bank_sync", '{"tenant": ' + json_string(m.tenant) + "}", m.tenant)
                return Reply.json('{"queued": true}', 202)
        except e:
            self.acc.log.error("finance_min: " + String(e))
            return Reply.error(500, "the tenant's store failed", "internal")
        return Reply.not_found()

    def transactions(self, m: Member) raises -> Reply:
        var q = self.acc.tenant_db(m).prepare("SELECT id, date, amount, merchant, category, coalesce(edited, '') FROM transactions ORDER BY date DESC, id LIMIT 1000")
        var out = String('{"transactions": [')
        var n = 0
        while q.step():
            out += (("," if n > 0 else "") + '{"id": ' + json_string(q.text(0)) + ', "date": ' + json_string(q.text(1)) + ', "amount": ' + String(q.float(2))
                    + ', "merchant": ' + json_string(q.text(3)) + ', "category": ' + json_string(q.text(4)) + ', "edited": ' + json_string(q.text(5)) + "}")
            n += 1
        return Reply.json(out + "]}")

    def spending(self, m: Member) raises -> Reply:
        var q = self.acc.tenant_db(m).prepare(
            "SELECT coalesce(category, 'Uncategorised'), sum(amount), count(*) FROM transactions WHERE amount < 0 GROUP BY 1 ORDER BY 2")
        var out = String('{"categories": [')
        var n = 0
        while q.step():
            out += ("," if n > 0 else "") + '{"category": ' + json_string(q.text(0)) + ', "total": ' + String(q.float(1)) + ', "count": ' + String(q.int(2)) + "}"
            n += 1
        return Reply.json(out + "]}")

    def add(self, m: Member, body: String) raises -> Reply:
        if not m.can_write():
            return Reply.error(403, "viewers can't write", "forbidden")
        var j: Json
        try:
            j = Json.parse(body)
        except:
            return Reply.error(400, "send {date, amount, merchant, category}", "bad_request")
        var rows = List[List[String]]()
        var row = List[String]()
        row.append("manual-" + random_token(12))
        row.append(j.text(j.get(0, "date")))
        row.append(String(j.real(j.get(0, "amount"))))
        row.append(j.text(j.get(0, "merchant")))
        row.append(j.text(j.get(0, "category")))
        rows.append(row^)
        _ = bulk_upsert(self.acc.tenant_db(m), "transactions", ["id"], ["id", "date", "amount", "merchant", "category"], rows)
        return Reply.json('{"ok": true}', 201)

    def recategorise(self, m: Member, id: String, body: String) raises -> Reply:
        if not m.can_write():
            return Reply.error(403, "viewers can't write", "forbidden")
        var cat: String
        try:
            var j = Json.parse(body)
            cat = j.text(j.get(0, "category"))
        except:
            return Reply.error(400, "send {category}", "bad_request")
        if cat == "" or cat.byte_length() > 60:
            return Reply.error(400, "a category of 1–60 characters", "bad_request")
        if set_edited(self.acc.tenant_db(m), "transactions", "id", id, "category", cat) == 0:
            return Reply.not_found()
        return Reply.json('{"ok": true}')

    def connect(self, m: Member, body: String) raises -> Reply:
        """Links a bank connection the person just made in the aggregator's own link screen: its one-time public token is
        traded server to server for the connection id (a connection id from the browser is never trusted: anyone could
        send someone else's)."""
        if not m.is_admin():
            return Reply.error(403, "only the tenant's admin links a bank", "forbidden")
        var token: String
        try:
            var j = Json.parse(body)
            token = j.text(j.get(0, "public_token"))
        except:
            return Reply.error(400, "send {public_token}", "bad_request")
        if token == "" or token.byte_length() > 200:
            return Reply.error(400, "send the link screen's public_token", "bad_request")
        var api = getenv("BANK_API")
        if api == "":
            return Reply.error(503, "no bank is set up", "not_configured")
        var client = ApiClient(api, Auth.client_credentials(api + "/oauth/token", getenv("BANK_CLIENT_ID"), getenv("BANK_CLIENT_SECRET")), timeout_ms=10_000)
        var r = client.post_json("/link/exchange", '{"public_token": ' + json_string(token) + "}")
        if r.status == 400 or r.status == 404:
            return Reply.error(400, "the bank didn't recognise that link", "bad_link")
        if not r.ok():
            return Reply.error(502, "the bank didn't answer: try again", "bank_unavailable")
        var conn = String("")
        try:
            var j = r.json()
            conn = j.text(j.get(0, "connection"))
        except:
            pass
        if conn == "" or conn.byte_length() > 100:
            return Reply.error(502, "the bank's answer had no connection", "bank_unavailable")
        var q = self.acc.db().prepare("INSERT INTO bank_links(connection, tenant, at) VALUES (?, ?, ?) ON CONFLICT(connection) DO NOTHING")
        q.bind(1, conn)
        q.bind(2, m.tenant)
        q.bind(3, Int(wall_seconds()))
        q.run()
        var check = self.acc.db().prepare("SELECT tenant FROM bank_links WHERE connection = ?")
        check.bind(1, conn)
        if not check.step() or check.text(0) != m.tenant:
            return Reply.error(409, "that connection belongs to another tenant", "conflict")
        return Reply.json('{"ok": true}')


struct FinJobs(Runner):
    var smtp: SmtpConfig
    var acc: Accounts
    var hooks: Webhooks
    var data: String
    var bank_api: String
    var bank_id: String
    var bank_secret: String
    var jobs: Queue

    def __init__(out self, var smtp: SmtpConfig, var acc: Accounts, hooks: Webhooks, data: String, jobs: Queue):
        self.smtp = smtp^
        self.acc = acc^
        self.hooks = hooks
        self.data = data
        self.bank_api = getenv("BANK_API")
        self.bank_id = getenv("BANK_CLIENT_ID")
        self.bank_secret = getenv("BANK_CLIENT_SECRET")
        self.jobs = jobs

    def tenant_db(self, tenant: String) raises -> Database:
        return Pool.shared().open(self.data + "/tenants/" + tenant + ".db")

    def run(self, job: QueuedJob) -> String:
        try:
            if job.kind == "mail":
                if not self.smtp.ready():
                    return "SMTP isn't set up"
                send(self.smtp, Mail.from_json(job.payload))
            elif job.kind == JOB_KIND:
                var ev = self.hooks.job_event(job.payload)
                if ev[2] == "transactions.updated":
                    var j = Json.parse(ev[3])
                    var conn = j.text(j.get(j.get(0, "data"), "connection"))
                    return self.sync_connection(conn)
            elif job.kind == "bank_sync":
                var q = self.acc.db().prepare("SELECT connection FROM bank_links WHERE tenant = ?")
                q.bind(1, job.tenant)
                while q.step():
                    var why = self.sync_connection(q.text(0))
                    if why != "":
                        return why
            elif job.kind == "digest":
                return self.digest(job)
            return ""
        except e:
            return String(e)

    def sync_connection(self, conn: String) raises -> String:
        var q = self.acc.db().prepare("SELECT tenant FROM bank_links WHERE connection = ?")
        q.bind(1, conn)
        if not q.step():
            return permanent("no tenant links connection " + conn)
        var tenant = q.text(0)
        q.reset()
        if self.bank_api == "":
            return permanent("BANK_API isn't set")
        var client = ApiClient(self.bank_api, Auth.client_credentials(self.bank_api + "/oauth/token", self.bank_id, self.bank_secret))
        var nodes = client.graphql_pages(BANK_QUERY, '{"connection": ' + json_string(conn) + "}", "transactions")
        var rows = List[List[String]]()
        for n in nodes:
            var j = Json.parse(n)
            var r = List[String]()
            r.append("bank-" + j.text(j.get(0, "id")))
            r.append(j.text(j.get(0, "date")))
            r.append(String(j.real(j.get(0, "amount"))))
            r.append(j.text(j.get(0, "merchant")))
            r.append(j.text(j.get(0, "category")))
            r.append("bank")
            rows.append(r^)
        _ = bulk_upsert(self.tenant_db(tenant), "transactions", ["id"], ["id", "date", "amount", "merchant", "category", "source"], rows, ["category"])
        self.acc.log.info("bank sync", Fields().str("tenant", tenant).int("rows", len(rows)))
        return ""

    def digest(self, job: QueuedJob) raises -> String:
        var j = Json.parse(job.payload)
        var slot = j.text(j.get(0, "slot"))
        var host = self.acc.db()
        var seen = host.prepare("SELECT 1 FROM digests_sent WHERE tenant = ? AND slot = ?")
        seen.bind(1, job.tenant)
        seen.bind(2, slot)
        if seen.step():
            return ""  # (a rerun after a crash: sent already)
        seen.reset()
        if not self.smtp.ready():
            return "SMTP isn't set up"
        var lines = String("")
        var q = self.tenant_db(job.tenant).prepare("SELECT coalesce(category, 'Uncategorised'), sum(amount) FROM transactions WHERE amount < 0 GROUP BY 1 ORDER BY 2")
        while q.step():
            lines += "- " + q.text(0) + ": " + String(q.float(1)) + "\n"
        if lines == "":
            lines = "No spending yet.\n"
        var who = host.prepare("SELECT u.email, coalesce(u.name, '') FROM members m JOIN users u ON u.id = m.user_id WHERE m.tenant = ? AND m.role IN ('admin', 'member')")
        who.bind(1, job.tenant)
        while who.step():
            send(self.smtp, Mail.from_template(who.text(0), who.text(1), "Your weekly digest from finance_min",
                                                "Hello {{name}},\n\nYour spending by category:\n\n{{lines}}", ["name", "lines"], [who.text(1), lines]))
        var done = host.prepare("INSERT OR IGNORE INTO digests_sent(tenant, slot) VALUES (?, ?)")
        done.bind(1, job.tenant)
        done.bind(2, slot)
        done.run()
        return ""


def _int(name: String, default: Int, lo: Int = 0, hi: Int = 1_000_000_000) raises -> Int:
    var v = getenv(name)
    if v == "":
        return default
    var n: Int
    try:
        n = atol(v)
    except:
        raise Error(name + " isn't a whole number: " + v)
    if n < lo or n > hi:
        raise Error(name + " is out of range: " + v)
    return n


def health_probe(url: String) -> Int:
    """`server --health <url>`: the image's health check (no curl in the image)."""
    var r = Backend.send(Request.get(0, url).timeout(3000))
    return 0 if r.status == 200 else 1


def main() raises:
    var args = argv()
    if len(args) >= 3 and String(args[1]) == "--health":
        exit(health_probe(String(args[2])))
    var data = getenv("SAAS_DATA", "data")
    var log = Log.open(getenv("SAAS_LOG"))
    _ = log.secret(getenv("SMTP_PASSWORD"))
    _ = log.secret(getenv("BANK_CLIENT_SECRET"))
    _ = log.secret(getenv("BANK_WEBHOOK_SECRET"))
    try:
        var jobs = Queue(data + "/host.db", backoff_ms=_int("SAAS_JOB_BACKOFF_MS", 2000, 1), max_attempts=_int("SAAS_JOB_MAX_ATTEMPTS", 5, 1, 100))
        var cfg = AuthConfig.from_env()
        if cfg.migrations == "":
            cfg.migrations = getenv("FIN_ROOT", "examples/finance_min") + "/migrations"
        var acc = Accounts(data, cfg^, log, jobs)
        acc.db().exec(HOST_TABLES)
        var bill = Billing(data, BillingConfig.from_env(), log)
        var hooks = Webhooks(data + "/host.db", jobs)
        var files = Static(getenv("SAAS_STATIC", getenv("FIN_ROOT", "examples/finance_min") + "/static"), prefix="/static/")
        var key = List[UInt8]()
        for b in acc.cfg.secret.as_bytes():
            key.append(b)
        var contact = ContactForm(key, acc.cfg.base, getenv("SAAS_CONTACT_TO"), PRODUCT, _int("SAAS_CONTACT_RATE", 5, 0, 10000), jobs)
        var op = Operator(data, getenv("SAAS_OPERATORS"), getenv("SAAS_LOG"))
        var sched = Scheduler(data + "/host.db", jobs)
        var digest = Cron.parse_any(getenv("FIN_DIGEST", "every Monday 08:00"))
        var zone = Zone.load(getenv("SAAS_TIMEZONE", "UTC"))
        start_workers(jobs, FinJobs(SmtpConfig.from_env(), acc.copy(), hooks, data, jobs), threads=2)
        var app = Fin(acc^, bill^, jobs, files^, hooks, Source.standard("bank", getenv("BANK_WEBHOOK_SECRET")), contact^, op^, sched, digest^, zone^)
        var served = serve(app^, port=_int("SAAS_PORT", 8000, 0, 65535), host=getenv("SAAS_HOST", "127.0.0.1"), tick_ms=1000, log=log,
                           proxies=TrustedProxies.parse(getenv("SAAS_TRUSTED_PROXIES")), max_body=2 * 1024 * 1024,
                           offload_threads=_int("SAAS_OFFLOAD_THREADS", 16, 1, 1024), offload_queue=_int("SAAS_OFFLOAD_QUEUE", 64, 0, 3072),
                           offload_per_client=_int("SAAS_OFFLOAD_PER_CLIENT", 4, 0, 4096))
        print("SAAS: listening " + String(served.port), flush=True)
        while not served.stopped():
            _ = libc.poll(0, 0, 500)
        served.stop()
    except e:
        log.error("SAAS: not starting: " + String(e))
        print("SAAS: not starting: " + String(e), flush=True)
        exit(1)
