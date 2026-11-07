# mojoui.billing: Stripe subscriptions for a mojoui.accounts server (goal 57 M3, goal 60 M6; fh-saas's utils_billing,
# utils_stripe and utils_webhook): a Checkout Session for the tenant (with Stripe's own trial when STRIPE_TRIAL_DAYS),
# Stripe's signed webhooks (checked, at most 5 minutes old, each event applied once, older ones never undoing newer),
# reading a session back on return, the customer portal, a trial of our own for new tenants, cancel at period end,
# past_due with a grace period, and the paywall. Thread-safe (immutable self, per-thread connections to host.db).
#
#   var bill = Billing(data_dir, BillingConfig.from_env(), log)     # its tables in host.db (billing, stripe_events)
#   var r = self.bill.handle(req, self.acc)    # GET /api/me (with plan, status, trial_ends, cancels_at), POST /billing/checkout,
#   if r.status != 0: return r^                # POST /billing/portal, GET /billing/return, POST /billing/webhook
#   var wall = self.bill.paywall(member)       # 402 unless Pro, trialing, or past_due within the grace period
#   def blocking(self, req): return self.bill.blocking(req)        # the routes that call Stripe: off the reactor
#
# Plans: "pro" while the subscription is active or trialing (also while it ends at its period's end: cancels_at says
# when), or past_due for less than SAAS_GRACE_DAYS; "trial" for SAAS_TRIAL_DAYS after a tenant is made, with no
# subscription; else "free" (or "past_due" after the grace). customer.subscription.deleted is final. The tenant rides on
# the session as client_reference_id; a subscription is found by its id afterwards.
# Secrets: the API key goes only into the Authorization header; Stripe's replies are logged by status, never by body.

from std.os import getenv, makedirs
from std.os.path import exists
from mojoui.serve import Req, Reply
from mojoui.http import Request, Response
from mojoui.effects import Backend
from mojoui.json import Json, json_string
from mojoui.sqlite import Database, Pool
from mojoui.crypto import hmac_sha256, same
from mojoui.hash import hex
from mojoui.clock import wall_seconds
from mojoui.log import Log, Fields, Audit
from mojoui.migrate import Migrations, Migration, parse
from mojoui.ratelimit import RateLimit
from mojoui.accounts import Accounts, Member, form, now_s

comptime RETURNS_PER_MINUTE = 30  # /billing/return's Stripe read-backs, for the whole server (anyone may call it; D-5727)
comptime BILLING_002 = (  # round 3 (S-L3): a subscription's events that come before its checkout, kept until it does
    "-- up\n"
    "CREATE TABLE stripe_pending(subscription TEXT PRIMARY KEY, event TEXT NOT NULL, kind TEXT NOT NULL, created INTEGER NOT NULL, body TEXT NOT NULL, at INTEGER NOT NULL);\n"
    "-- down\n"
    "DROP TABLE stripe_pending;\n"
)
comptime TOLERANCE_S = 300  # Stripe's default: a signature older (or newer) than this is refused
comptime BILLING_001 = (
    "-- up\n"
    "CREATE TABLE IF NOT EXISTS billing(tenant TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'none', customer TEXT, subscription TEXT,"
    " period_end INTEGER, cancel_at_period_end INTEGER NOT NULL DEFAULT 0, past_due_since REAL, event_at INTEGER NOT NULL DEFAULT 0, updated REAL);\n"
    "CREATE INDEX IF NOT EXISTS billing_subscription ON billing(subscription);\n"
    "CREATE TABLE IF NOT EXISTS stripe_events(id TEXT PRIMARY KEY, type TEXT, tenant TEXT, at INTEGER);\n"
    "CREATE TABLE IF NOT EXISTS payments(session TEXT PRIMARY KEY, tenant TEXT NOT NULL, amount INTEGER, currency TEXT, at INTEGER);\n"
    "INSERT OR IGNORE INTO billing(tenant, status, customer, subscription) SELECT id, CASE plan WHEN 'pro' THEN 'active' ELSE 'none' END,"
    " customer, subscription FROM tenants WHERE plan = 'pro' OR customer IS NOT NULL;\n"
    "-- down\n"
    "DROP TABLE stripe_events; DROP TABLE billing;\n"
)


def _env_days(name: String) -> Float64:
    try:
        return atof(getenv(name, "0"))
    except:
        return 0


@fieldwise_init
struct BillingConfig(Copyable, Movable):
    var api: String  # https://api.stripe.com (a stand-in in tests)
    var secret_key: String
    var webhook_secret: String
    var price: String  # the Pro plan's recurring price id
    var base: String  # this server's URL (return pages)
    var price_yearly: String  # the Pro plan's yearly price ("": none)
    var prices_once: List[String]  # one-time prices a tenant may buy (POST /billing/purchase)

    @staticmethod
    def from_env() -> BillingConfig:
        """SAAS_STRIPE_API (default https://api.stripe.com), STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICE_PRO,
        SAAS_BASE."""
        var once = List[String]()
        for p in getenv("STRIPE_PRICES_ONCE").split(","):
            if String(String(p).strip()) != "":
                once.append(String(String(p).strip()))
        return BillingConfig(getenv("SAAS_STRIPE_API", "https://api.stripe.com"), getenv("STRIPE_SECRET_KEY"),
            getenv("STRIPE_WEBHOOK_SECRET"), getenv("STRIPE_PRICE_PRO"), getenv("SAAS_BASE", "http://127.0.0.1:8000"),
            getenv("STRIPE_PRICE_PRO_YEARLY"), once^)

    def is_test_mode(self) -> Bool:
        return self.secret_key.startswith("sk_test_")


@fieldwise_init
struct Plan(Copyable, Movable):
    var name: String  # pro | trial | free | past_due
    var status: String  # Stripe's subscription status ("none" without one)
    var pro: Bool  # the paywall lets it through
    var trial_ends: Int  # 0: none
    var cancels_at: Int  # 0: not cancelling


def paywall(m: Member) -> Reply:
    """402 unless the member's tenant is on Pro; else a Reply with status 0 (go on)."""
    if m.plan != "pro":
        return Reply.error(402, "this needs the Pro plan", "payment_required")
    return Reply(0, "", "")


def signature_ok(header: String, body: String, secret: String, now: Int, tolerance_s: Int = TOLERANCE_S) -> Bool:
    """Stripe-Signature: `t=<unix>,v1=<hex hmac>[,v1=…]`: HMAC-SHA256 of "<t>.<body>" under the endpoint secret, any v1
    matching (compared in constant time), t within `tolerance_s` of now."""
    if secret == "":
        return False
    var t = -1
    var sigs = List[String]()
    for part in header.split(","):
        var p = String(part).strip()
        if p.startswith("t="):
            try:
                t = atol(String(p[byte = 2 :]))
            except:
                return False
        elif p.startswith("v1="):
            sigs.append(String(p[byte = 3 :]))
    if t < 0 or len(sigs) == 0 or abs(now - t) > tolerance_s:
        return False
    var want = hex(hmac_sha256(secret, String(t) + "." + body))
    var ok = False
    for s in sigs:
        ok = same(want, s) or ok
    return ok


def _id_ok(s: String, prefix: String) -> Bool:
    """A Stripe object id: the prefix, then letters, digits and '_' (safe in a URL path)."""
    if not s.startswith(prefix) or s.byte_length() > 255:
        return False
    for b in s.as_bytes():
        var c = Int(b)
        if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95):
            return False
    return True




struct Billing(Copyable, Movable):
    var cfg: BillingConfig
    var host: String
    var pool: Pool
    var log: Log
    var returns: RateLimit  # (the read-back budget, for the whole server)
    var trial_s: Float64
    var stripe_trial_days: Int
    var grace_s: Float64

    def __init__(out self, data_dir: String, var cfg: BillingConfig, log: Log = Log(addr=0)) raises:
        """Its tables in data_dir/host.db (next to mojoui.accounts', versioned in billing_migrations). SAAS_TRIAL_DAYS,
        STRIPE_TRIAL_DAYS and SAAS_GRACE_DAYS (days, fractions allowed) from the environment."""
        if not exists(data_dir):
            makedirs(data_dir)
        self.host = data_dir + "/host.db"
        self.pool = Pool.shared()
        self.log = log
        self.returns = RateLimit(RETURNS_PER_MINUTE, 60)
        self.trial_s = _env_days("SAAS_TRIAL_DAYS") * 86400
        self.stripe_trial_days = Int(_env_days("STRIPE_TRIAL_DAYS"))
        self.grace_s = _env_days("SAAS_GRACE_DAYS") * 86400
        _ = log.secret(cfg.secret_key)
        _ = log.secret(cfg.webhook_secret)
        self.cfg = cfg^
        var db = Database(self.host)
        var l = List[Migration]()
        l.append(parse(1, "001_billing.sql", BILLING_001))
        l.append(parse(2, "002_pending_events.sql", BILLING_002))
        _ = Migrations(l^, "billing_migrations").apply(db)

    def db(self) raises -> Database:
        return self.pool.open(self.host)

    def blocking(self, req: Req) -> Bool:
        """The routes that call Stripe."""
        return req.path == "/billing/checkout" or req.path == "/billing/portal" or req.path == "/billing/return" or req.path == "/billing/purchase"

    def plan(self, tenant: String) raises -> Plan:
        var q = self.db().prepare(
            "SELECT COALESCE(b.status, 'none'), b.period_end, COALESCE(b.cancel_at_period_end, 0), b.past_due_since, t.created"
            " FROM tenants t LEFT JOIN billing b ON b.tenant = t.id WHERE t.id = ?")
        q.bind(1, tenant)
        if not q.step():
            return Plan("free", "none", False, 0, 0)
        var status = q.text(0)
        var period_end = 0 if q.is_null(1) else q.int(1)
        var cancels = period_end if q.int(2) != 0 else 0
        var now = wall_seconds()
        if status == "active" or status == "trialing":
            return Plan("pro", status, True, 0, cancels)
        if status == "past_due" and not q.is_null(3):
            var within = now < q.float(3) + self.grace_s
            return Plan("pro" if within else "past_due", status, within, 0, cancels)
        if self.trial_s > 0 and not q.is_null(4):
            var ends = Float64(q.int(4)) + self.trial_s
            if now < ends:
                return Plan("trial", status, True, Int(ends), 0)
        return Plan("free", status, False, 0, 0)

    def paywall(self, m: Member) -> Reply:
        """402 unless the member's tenant is on Pro (or a trial, or within past_due's grace); else status 0 (go on)."""
        try:
            if self.plan(m.tenant).pro:
                return Reply(0, "", "")
        except e:
            self.log.error("billing: " + String(e))
            return Reply.error(500, "billing failed", "internal")
        return Reply.error(402, "this needs the Pro plan", "payment_required")

    def handle(self, mut req: Req, acc: Accounts) -> Reply:
        """Answers /api/me and /billing/*; any other request: a Reply with status 0."""
        try:
            if req.matches("GET", "/api/me"):
                var m = acc.member(req)
                if not m:
                    return Reply.error(401, "sign in first", "unauthorized")
                var p = self.plan(m.value().tenant)
                return Reply.json("{" + acc.me_fields(m.value(), p.name) + ', "status": ' + json_string(p.status)
                    + ', "trial_ends": ' + (String(p.trial_ends) if p.trial_ends > 0 else "null")
                    + ', "cancels_at": ' + (String(p.cancels_at) if p.cancels_at > 0 else "null") + "}")
            if req.matches("POST", "/billing/webhook"):
                return self._webhook(req, acc)
            if req.matches("GET", "/billing/return"):
                return self._return(req, acc)
            if req.matches("POST", "/billing/checkout") or req.matches("POST", "/billing/portal") or req.matches("POST", "/billing/purchase"):
                var m = acc.member(req)
                if not m:
                    return Reply.error(401, "sign in first", "unauthorized")
                if not m.value().is_admin():
                    return Reply.error(403, "only the tenant's admin changes the plan", "forbidden")
                var o = req.header("origin")
                if o != "" and o != self.cfg.base:
                    return Reply.error(403, "billing starts from this site", "forbidden")
                if req.path == "/billing/portal":
                    return self._portal(m.value())
                var j = Json.parse(req.body if String(req.body.strip()) != "" else String("{}"))
                if req.path == "/billing/purchase":
                    return self._purchase(m.value(), j.text(j.get(0, "price")))
                return self._checkout(m.value(), j.text(j.get(0, "interval"), "month"))
        except e:
            self.log.error("billing: " + String(e))
            return Reply.error(500, "billing failed", "internal")
        return Reply(0, "", "")

    def _stripe(self, method: String, path: String, body: String = "") -> Response:
        var r = Request(0, method, self.cfg.api + path, body).header("Authorization", "Bearer " + self.cfg.secret_key).timeout(30_000)
        if body != "":
            r = r^.header("Content-Type", "application/x-www-form-urlencoded")
        var res = Backend.send(r)
        if res.status != 200:
            self.log.warn("Stripe refused", Fields().int("status", res.status).str("call", method + " " + path).str("error", res.error))
        return res^

    def _purchase(self, m: Member, price: String) raises -> Reply:
        """A one-time Checkout Session for a price in STRIPE_PRICES_ONCE (recorded in `payments` once paid)."""
        var known = False
        for p in self.cfg.prices_once:
            known = known or p == price
        if self.cfg.secret_key == "" or not known:
            return Reply.error(400, "not a price this server sells", "bad_price")
        var names: List[String] = ["mode", "line_items[0][price]", "line_items[0][quantity]", "success_url", "cancel_url", "client_reference_id", "metadata[tenant]"]
        var values: List[String] = ["payment", price, "1", self.cfg.base + "/billing/return?session_id={CHECKOUT_SESSION_ID}",
            self.cfg.base + "/billing/return?cancelled=1", m.tenant, m.tenant]
        var r = self._stripe("POST", "/v1/checkout/sessions", form(names, values))
        if r.status != 200:
            return Reply.error(502, "Stripe refused the checkout", "stripe_failed")
        var j = Json.parse(r.text())
        return Reply.json('{"url": ' + json_string(j.text(j.get(0, "url"))) + ', "id": ' + json_string(j.text(j.get(0, "id"))) + "}")

    def _checkout(self, m: Member, interval: String = "month") raises -> Reply:
        var price = self.cfg.price_yearly if interval == "year" else self.cfg.price
        if self.cfg.secret_key == "" or price == "":
            return Reply.error(503, "billing isn't set up (STRIPE_SECRET_KEY, STRIPE_PRICE_PRO, STRIPE_PRICE_PRO_YEARLY)", "not_configured")
        var p = self.plan(m.tenant)
        if p.name == "pro":
            return Reply.error(409, "already on Pro", "already_pro")
        var names: List[String] = ["mode", "line_items[0][price]", "line_items[0][quantity]", "success_url", "cancel_url",
            "client_reference_id", "metadata[tenant]", "subscription_data[metadata][tenant]", "customer_email"]
        var values: List[String] = ["subscription", price, "1", self.cfg.base + "/billing/return?session_id={CHECKOUT_SESSION_ID}",
            self.cfg.base + "/billing/return?cancelled=1", m.tenant, m.tenant, m.tenant, m.email]
        if self.stripe_trial_days > 0:
            names.append("subscription_data[trial_period_days]")
            values.append(String(self.stripe_trial_days))
        var r = self._stripe("POST", "/v1/checkout/sessions", form(names, values))
        if r.status != 200:
            return Reply.error(502, "Stripe refused the checkout", "stripe_failed")
        var j = Json.parse(r.text())
        var url = j.text(j.get(0, "url"))
        if url == "":
            return Reply.error(502, "Stripe sent no checkout URL", "stripe_failed")
        return Reply.json('{"url": ' + json_string(url) + ', "id": ' + json_string(j.text(j.get(0, "id"))) + "}")

    def _portal(self, m: Member) raises -> Reply:
        """A Stripe customer-portal session (cards, invoices, cancel) for the tenant's customer; its URL."""
        if self.cfg.secret_key == "":
            return Reply.error(503, "billing isn't set up (STRIPE_SECRET_KEY)", "not_configured")
        var q = self.db().prepare("SELECT COALESCE(customer, '') FROM billing WHERE tenant = ?")
        q.bind(1, m.tenant)
        var customer = q.text(0) if q.step() else String("")
        q.reset()
        if not _id_ok(customer, "cus_"):
            return Reply.error(409, "no billing account yet: upgrade first", "no_customer")
        var names: List[String] = ["customer", "return_url"]
        var values: List[String] = [customer, self.cfg.base + "/"]
        var r = self._stripe("POST", "/v1/billing_portal/sessions", form(names, values))
        if r.status != 200:
            return Reply.error(502, "Stripe refused the portal", "stripe_failed")
        var j = Json.parse(r.text())
        var url = j.text(j.get(0, "url"))
        if not url.startswith("https://") and not url.startswith(self.cfg.api):
            return Reply.error(502, "Stripe sent no portal URL", "stripe_failed")
        return Reply.json('{"url": ' + json_string(url) + "}")

    def _seen(self, db: Database, id: String) raises -> Bool:
        var q = db.prepare("SELECT 1 FROM stripe_events WHERE id = ?")
        q.bind(1, id)
        var hit = q.step()
        q.reset()
        return hit

    def _once(self, db: Database, id: String, kind: String, tenant: String) raises:
        var q = db.prepare("INSERT OR IGNORE INTO stripe_events(id, type, tenant, at) VALUES (?, ?, ?, ?)")
        q.bind(1, id)
        q.bind(2, kind)
        q.bind(3, tenant)
        q.bind(4, now_s())
        q.run()

    def _session_paid(self, db: Database, id: String, j: Json, s: Int, acc: Accounts) raises -> Bool:
        """A completed, paid Checkout Session (`s`, a node of `j`) makes its tenant Pro, once per session whichever way it
        arrives (its webhook event `id`, or the return page). Inside the caller's transaction."""
        var tenant = j.text(j.get(s, "client_reference_id"))
        var paid = j.text(j.get(s, "payment_status"))
        var key = "session:" + j.text(j.get(s, "id"))
        # (a subscription this server sold: not a Payment Link's one-off payment that carries someone's tenant id)
        if j.text(j.get(s, "mode")) == "payment" and j.text(j.get(s, "status")) == "complete" and paid == "paid" and tenant != "":
            var pay = db.prepare("INSERT OR IGNORE INTO payments(session, tenant, amount, currency, at) VALUES (?, ?, ?, ?, ?)")
            pay.bind(1, j.text(j.get(s, "id")))
            pay.bind(2, tenant)
            pay.bind(3, j.number(j.get(s, "amount_total")))
            pay.bind(4, j.text(j.get(s, "currency")))
            pay.bind(5, now_s())
            pay.run()
            if db.changes() > 0:
                Audit.record(db, tenant, "stripe", "payment", j.text(j.get(s, "id")))
            self._once(db, id, "checkout.session.completed", tenant)
            return False  # (a purchase, never a plan)
        var sold = j.text(j.get(s, "mode")) == "subscription" and j.text(j.get(s, "subscription")) != "" and j.text(j.get(s, "status")) == "complete"
        if tenant == "" or not sold or (paid != "paid" and paid != "no_payment_required") or self._seen(db, id) or self._seen(db, key):
            return False
        var t = db.prepare("SELECT 1 FROM tenants WHERE id = ?")
        t.bind(1, tenant)
        if not t.step():
            return False
        t.reset()
        var u = db.prepare(
            "INSERT INTO billing(tenant, status, customer, subscription, updated) VALUES (?, 'active', ?, ?, ?)"
            " ON CONFLICT(tenant) DO UPDATE SET status = 'active', customer = excluded.customer, subscription = excluded.subscription,"
            " past_due_since = NULL, cancel_at_period_end = 0, updated = excluded.updated")
        u.bind(1, tenant)
        u.bind(2, j.text(j.get(s, "customer")))
        u.bind(3, j.text(j.get(s, "subscription")))
        u.bind(4, wall_seconds())
        u.run()
        var label = db.prepare("UPDATE tenants SET plan = 'pro', customer = ?, subscription = ? WHERE id = ?")
        label.bind(1, j.text(j.get(s, "customer")))
        label.bind(2, j.text(j.get(s, "subscription")))
        label.bind(3, tenant)
        label.run()
        self._once(db, id, "checkout.session.completed", tenant)
        self._once(db, key, "checkout.session.completed", tenant)
        Audit.record(db, tenant, "stripe", "plan_change", "pro")
        self.log.info(id + " applied: " + tenant + " is pro")
        self._apply_held(db, j.text(j.get(s, "subscription")))  # (an update that came first: applied now)
        return True

    def _webhook(self, req: Req, acc: Accounts) raises -> Reply:
        if not signature_ok(req.header("stripe-signature"), req.body, self.cfg.webhook_secret, now_s()):
            return Reply.error(400, "bad or old signature", "bad_signature")
        var j = Json.parse(req.body)
        var id = j.text(j.get(0, "id"))
        var kind = j.text(j.get(0, "type"))
        var created = j.number(j.get(0, "created"))
        var obj = j.get(j.get(0, "data"), "object")
        if id == "" or obj < 0:
            return Reply.error(400, "not an event", "bad_event")
        var db = self.db()
        db.begin()
        try:
            if self._seen(db, id):
                db.commit()
                return Reply.json('{"received": true, "duplicate": true}')
            if kind == "checkout.session.completed":
                _ = self._session_paid(db, id, j, obj, acc)
            elif kind == "customer.subscription.updated" or kind == "customer.subscription.deleted":
                if not self._subscription(db, id, kind, created, j, obj):
                    self._hold(db, id, kind, created, j.text(j.get(obj, "id")), req.body)
            else:
                self._once(db, id, kind, "")  # (not ours to act on: recorded so a retry is a duplicate)
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        return Reply.json('{"received": true}')

    def _hold(self, db: Database, id: String, kind: String, created: Int, subscription: String, body: String) raises:
        """A subscription event for a subscription no tenant has yet (Stripe doesn't order events: its checkout's
        completion may come later): the newest per subscription is kept, applied when the checkout lands."""
        if not _id_ok(subscription, "sub_"):
            self._once(db, id, kind, "")
            return
        var q = db.prepare(
            "INSERT INTO stripe_pending(subscription, event, kind, created, body, at) VALUES (?, ?, ?, ?, ?, ?)"
            " ON CONFLICT(subscription) DO UPDATE SET event = excluded.event, kind = excluded.kind, created = excluded.created,"
            " body = excluded.body, at = excluded.at WHERE excluded.created >= stripe_pending.created AND stripe_pending.kind != 'customer.subscription.deleted'")
        q.bind(1, subscription)
        q.bind(2, id)
        q.bind(3, kind)
        q.bind(4, created)
        q.bind(5, body)
        q.bind(6, now_s())
        q.run()
        self._once(db, id, kind, "")  # (a retry is a duplicate; the row above is applied with the checkout)
        self.log.info(id + " held: its subscription has no tenant yet")

    def _apply_held(self, db: Database, subscription: String) raises:
        """The held newest event of a subscription a checkout just sold, applied now (inside the caller's transaction)."""
        var q = db.prepare("DELETE FROM stripe_pending WHERE subscription = ? RETURNING event, kind, created, body")
        q.bind(1, subscription)
        if not q.step():
            return
        var id = q.text(0)
        var kind = q.text(1)
        var created = q.int(2)
        var body = q.text(3)
        q.reset()
        var j = Json.parse(body)
        _ = self._subscription(db, id, kind, created, j, j.get(j.get(0, "data"), "object"))

    def sweep(self) raises -> Int:
        """Held events older than 30 days (their checkout never came) deleted: for a server's tick."""
        var db = self.db()
        db.begin()
        try:
            var q = db.prepare("DELETE FROM stripe_pending WHERE at < ?")
            q.bind(1, now_s() - 30 * 86400)
            q.run()
            var n = db.changes()
            db.commit()
            return n
        except e:
            _ = db.rollback_quiet()
            raise e^

    def _subscription(self, db: Database, id: String, kind: String, created: Int, j: Json, obj: Int) raises -> Bool:
        """Applies a subscription event to the tenant that bought it: False when no tenant has that subscription."""
        var q = db.prepare("SELECT tenant, status, event_at, past_due_since FROM billing WHERE subscription = ?")
        q.bind(1, j.text(j.get(obj, "id")))
        if not q.step():
            return False  # (not sold yet: held; or already deleted: final, since the row's subscription is gone)
        var tenant = q.text(0)
        var was = q.text(1)
        var event_at = q.int(2)
        var due_since = Float64(-1) if q.is_null(3) else q.float(3)
        q.reset()
        if created > 0 and created < event_at:
            self._once(db, id, kind, tenant)  # (older than what we know: Stripe doesn't order events)
            return True
        var status = "canceled" if kind == "customer.subscription.deleted" else j.text(j.get(obj, "status"))
        var period_end = j.number(j.get(obj, "current_period_end"))
        if period_end == 0:  # (newer API versions keep it on the items)
            var items = j.get(j.get(obj, "items"), "data")
            if items >= 0 and j.size(items) > 0:
                period_end = j.number(j.get(j.at(items, 0), "current_period_end"))
        var cancel_end = 1 if j.flag(j.get(obj, "cancel_at_period_end")) else 0
        var cancel_at = j.number(j.get(obj, "cancel_at"))
        if cancel_at > 0 and period_end == 0:
            period_end = cancel_at
        if cancel_at > 0:
            cancel_end = 1
        var since: Float64 = due_since if (status == "past_due" and due_since >= 0) else (wall_seconds() if status == "past_due" else -1)
        var u = db.prepare(
            "UPDATE billing SET status = ?, period_end = NULLIF(?, 0), cancel_at_period_end = ?, past_due_since = CASE WHEN ? < 0 THEN NULL ELSE ? END,"
            " subscription = CASE WHEN ? = 'canceled' THEN NULL ELSE subscription END, event_at = MAX(event_at, ?), updated = ? WHERE tenant = ?")
        u.bind(1, status)
        u.bind(2, period_end)
        u.bind(3, cancel_end)
        u.bind(4, since)
        u.bind(5, since)
        u.bind(6, status)
        u.bind(7, created)
        u.bind(8, wall_seconds())
        u.bind(9, tenant)
        u.run()
        var label = db.prepare("UPDATE tenants SET plan = ? WHERE id = ?")
        label.bind(1, "pro" if status == "active" or status == "trialing" or status == "past_due" else "free")
        label.bind(2, tenant)
        label.run()
        self._once(db, id, kind, tenant)
        if status != was or cancel_end != 0:
            Audit.record(db, tenant, "stripe", "plan_change", status + (" (cancels at period end)" if cancel_end != 0 else ""))
        self.log.info(id + " applied: " + tenant + " is " + status)
        return True

    def _return(self, req: Req, acc: Accounts) raises -> Reply:
        """Stripe sends the payer back here: the session is read from Stripe itself (never trusted from the URL)."""
        var sid = req.arg("session_id")
        if req.arg("cancelled") == "1":
            return Reply.text("Checkout cancelled: nothing was charged.")
        if not _id_ok(sid, "cs_"):
            return Reply.error(400, "no checkout session", "bad_session")
        if self._seen(self.db(), "session:" + sid):
            return Reply.text("Thanks: your plan is Pro. You can close this page.")
        var wait = self.returns.hit("global")
        if wait > 0:
            return Reply.error(429, "too many checks: try again in a minute", "rate_limited").header("Retry-After", String(wait))
        var r = self._stripe("GET", "/v1/checkout/sessions/" + sid)
        if r.status != 200:
            return Reply.error(502, "Stripe didn't confirm the session", "stripe_failed")
        var j = Json.parse(r.text())
        var db = self.db()
        db.begin()
        var done: Bool
        try:
            done = self._session_paid(db, "return:" + sid, j, 0, acc) or self._seen(db, "session:" + sid)
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        if not done and j.text(j.get(0, "payment_status")) != "paid":
            return Reply.text("Payment isn't complete yet.", 202)
        return Reply.text("Thanks: your plan is Pro. You can close this page.")
