# mojoui.billing: Stripe subscriptions for a mojoui.accounts server (goal 57 M3; fh-saas's utils_billing and utils_webhook):
# a Checkout Session for the tenant, Stripe's signed webhooks (checked, at most 5 minutes old, each event applied once),
# reading a session back on return (no webhook needed: a local run can't receive one), and a paywall.
#
#   var bill = Billing(data_dir, BillingConfig.from_env())     # data_dir/billing.db keeps the events it has applied
#   var r = self.bill.handle(req, self.acc)                    # POST /billing/checkout, GET /billing/return, POST /billing/webhook
#   if r.status != 0: return r^
#   var wall = paywall(member)                                 # 402 unless the tenant is on Pro
#
# Plans: checkout.session.completed (paid) → "pro" with its customer and subscription; customer.subscription.updated →
# "pro" while active or trialing, else "free"; customer.subscription.deleted → "free". The tenant rides on the session as
# client_reference_id (and metadata[tenant]); a subscription is found by its id afterwards.
# Secrets: the API key goes only into the Authorization header; replies from Stripe are logged by status, never by body.

from std.os import getenv, makedirs
from std.os.path import exists
from mojoui.serve import Req, Reply
from mojoui.http import Request, Response
from mojoui.effects import Backend
from mojoui.json import Json, json_string
from mojoui.sqlite import Database
from mojoui.crypto import hmac_sha256, same
from mojoui.hash import hex
from mojoui.accounts import Accounts, Member, form, now_s

comptime TOLERANCE_S = 300  # Stripe's default: a signature older (or newer) than this is refused


@fieldwise_init
struct BillingConfig(Copyable, Movable):
    var api: String  # https://api.stripe.com (a stand-in in tests)
    var secret_key: String
    var webhook_secret: String
    var price: String  # the Pro plan's recurring price id
    var base: String  # this server's URL (return pages)

    @staticmethod
    def from_env() -> BillingConfig:
        """SAAS_STRIPE_API (default https://api.stripe.com), STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICE_PRO,
        SAAS_BASE."""
        return BillingConfig(getenv("SAAS_STRIPE_API", "https://api.stripe.com"), getenv("STRIPE_SECRET_KEY"),
            getenv("STRIPE_WEBHOOK_SECRET"), getenv("STRIPE_PRICE_PRO"), getenv("SAAS_BASE", "http://127.0.0.1:8000"))

    def is_test_mode(self) -> Bool:
        return self.secret_key.startswith("sk_test_")


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


struct Billing(Movable):
    var db: Database
    var cfg: BillingConfig

    def __init__(out self, data_dir: String, var cfg: BillingConfig) raises:
        if not exists(data_dir):
            makedirs(data_dir)
        self.db = Database(data_dir + "/billing.db")
        self.db.exec("PRAGMA journal_mode=WAL")
        self.db.exec("CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, type TEXT, tenant TEXT, at INTEGER)")
        self.cfg = cfg^

    def handle(mut self, mut req: Req, mut acc: Accounts) -> Reply:
        """Answers /billing/*; any other request: a Reply with status 0."""
        try:
            if req.matches("POST", "/billing/webhook"):
                return self._webhook(req, acc)
            if req.matches("GET", "/billing/return"):
                return self._return(req, acc)
            if req.matches("POST", "/billing/checkout"):
                var m = acc.member(req)
                if not m:
                    return Reply.error(401, "sign in first", "unauthorized")
                if not m.value().is_admin():
                    return Reply.error(403, "only the tenant's admin changes the plan", "forbidden")
                var o = req.header("origin")
                if o != "" and o != self.cfg.base:
                    return Reply.error(403, "a checkout starts from this site", "forbidden")
                return self._checkout(m.value())
        except e:
            print("billing: " + String(e))
            return Reply.error(500, "billing failed", "internal")
        return Reply(0, "", "")

    def _stripe(self, method: String, path: String, body: String = "") -> Response:
        var r = Request(0, method, self.cfg.api + path, body).header("Authorization", "Bearer " + self.cfg.secret_key).timeout(30_000)
        if body != "":
            r = r^.header("Content-Type", "application/x-www-form-urlencoded")
        var res = Backend.send(r)
        if res.status != 200:
            print("billing: Stripe answered " + String(res.status) + " to " + method + " " + path + (" (" + res.error + ")" if res.error != "" else ""))
        return res^

    def _checkout(mut self, m: Member) raises -> Reply:
        if self.cfg.secret_key == "" or self.cfg.price == "":
            return Reply.error(503, "billing isn't set up (STRIPE_SECRET_KEY, STRIPE_PRICE_PRO)", "not_configured")
        if m.plan == "pro":
            return Reply.error(409, "already on Pro", "already_pro")
        var names: List[String] = ["mode", "line_items[0][price]", "line_items[0][quantity]", "success_url", "cancel_url",
            "client_reference_id", "metadata[tenant]", "subscription_data[metadata][tenant]", "customer_email"]
        var values: List[String] = ["subscription", self.cfg.price, "1", self.cfg.base + "/billing/return?session_id={CHECKOUT_SESSION_ID}",
            self.cfg.base + "/billing/return?cancelled=1", m.tenant, m.tenant, m.tenant, m.email]
        var r = self._stripe("POST", "/v1/checkout/sessions", form(names, values))
        if r.status != 200:
            return Reply.error(502, "Stripe refused the checkout", "stripe_failed")
        var j = Json.parse(r.text())
        var url = j.text(j.get(0, "url"))
        if url == "":
            return Reply.error(502, "Stripe sent no checkout URL", "stripe_failed")
        return Reply.json('{"url": ' + json_string(url) + ', "id": ' + json_string(j.text(j.get(0, "id"))) + "}")

    def _once(mut self, id: String, kind: String, tenant: String) raises -> Bool:
        """Records an event as applied; False when it already was."""
        var q = self.db.prepare("INSERT OR IGNORE INTO events(id, type, tenant, at) VALUES (?, ?, ?, ?)")
        q.bind(1, id)
        q.bind(2, kind)
        q.bind(3, tenant)
        q.bind(4, now_s())
        q.run()
        return self.db.changes() > 0

    def _seen(self, id: String) raises -> Bool:
        var q = self.db.prepare("SELECT 1 FROM events WHERE id = ?")
        q.bind(1, id)
        return q.step()

    def _session_paid(mut self, id: String, j: Json, s: Int, mut acc: Accounts) raises -> Bool:
        """A completed, paid Checkout Session (`s`, a node of `j`) makes its tenant Pro, once per session whichever way it
        arrives (its webhook event `id`, or the return page)."""
        var tenant = j.text(j.get(s, "client_reference_id"))
        var paid = j.text(j.get(s, "payment_status"))
        var key = "session:" + j.text(j.get(s, "id"))
        if tenant == "" or (paid != "paid" and paid != "no_payment_required") or self._seen(id) or self._seen(key):
            return False
        if not acc.set_plan(tenant, "pro", j.text(j.get(s, "customer")), j.text(j.get(s, "subscription"))):
            return False
        _ = self._once(id, "checkout.session.completed", tenant)
        _ = self._once(key, "checkout.session.completed", tenant)
        print(id + " applied: " + tenant + " is pro", flush=True)
        return True

    def _webhook(mut self, req: Req, mut acc: Accounts) raises -> Reply:
        if not signature_ok(req.header("stripe-signature"), req.body, self.cfg.webhook_secret, now_s()):
            return Reply.error(400, "bad or old signature", "bad_signature")
        var j = Json.parse(req.body)
        var id = j.text(j.get(0, "id"))
        var kind = j.text(j.get(0, "type"))
        var obj = j.get(j.get(0, "data"), "object")
        if id == "" or obj < 0:
            return Reply.error(400, "not an event", "bad_event")
        if self._seen(id):
            return Reply.json('{"received": true, "duplicate": true}')
        if kind == "checkout.session.completed":
            _ = self._session_paid(id, j, obj, acc)
        elif kind == "customer.subscription.deleted" or kind == "customer.subscription.updated":
            var tenant = acc.tenant_of_subscription(j.text(j.get(obj, "id")))
            var status = j.text(j.get(obj, "status"))
            var plan = "pro" if kind == "customer.subscription.updated" and (status == "active" or status == "trialing") else "free"
            if tenant != "" and acc.set_plan(tenant, plan):
                _ = self._once(id, kind, tenant)
                print(id + " applied: " + tenant + " is " + plan, flush=True)
        return Reply.json('{"received": true}')

    def _return(mut self, req: Req, mut acc: Accounts) raises -> Reply:
        """Stripe sends the payer back here: the session is read from Stripe itself (never trusted from the URL)."""
        var sid = req.arg("session_id")
        if req.arg("cancelled") == "1":
            return Reply.text("Checkout cancelled: nothing was charged.")
        if not _id_ok(sid, "cs_"):
            return Reply.error(400, "no checkout session", "bad_session")
        var r = self._stripe("GET", "/v1/checkout/sessions/" + sid)
        if r.status != 200:
            return Reply.error(502, "Stripe didn't confirm the session", "stripe_failed")
        var j = Json.parse(r.text())
        var done = self._session_paid("return:" + sid, j, 0, acc) or self._seen("session:" + sid)
        if not done and j.text(j.get(0, "payment_status")) != "paid":
            return Reply.text("Payment isn't complete yet.", 202)
        return Reply.text("Thanks: your plan is Pro. You can close this page.")
