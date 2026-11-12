# mojoui.webhooks: signed events from any third party (goal 66 M1; fh-saas's utils_webhook, beyond Stripe). A Source
# names how its sender signs (HMAC-SHA256 in one of four shapes), the receiver checks the signature in constant time and
# the timestamp inside a window, logs the event in host.db once (source + id unique), and hands its processing to
# mojoui.jobs in the same transaction (an outbox: retried with backoff, then dead). Thread-safe (immutable self, the
# pool's per-thread connections).
#
#   var hooks = Webhooks(data + "/host.db", queue)
#   var bank = Source.standard("bank", getenv("BANK_WEBHOOK_SECRET"))     # Svix / Standard Webhooks: webhook-id, -timestamp, -signature
#   Source.stripe("stripe", secret)                  # Stripe-Signature: t=<unix>,v1=<hex>
#   Source.hmac_hex("gh", secret, "X-Hub-Signature-256")   # hex HMAC of the body ("sha256=" prefix allowed)
#   Source.hmac_b64("shop", secret, "X-Shopify-Hmac-Sha256")  # base64 HMAC of the body
#   if req.matches("POST", "/webhooks/bank"): return hooks.receive(req, bank)
#   # a Runner gets kind "webhook", payload {"source", "event"}: hooks.event(source, id) → (type, body)
#
# Answers: 200 accepted (or a duplicate: no effect), 401 a missing or wrong signature, 400 a timestamp outside the window
# (or no event id), 413 a body over the source's cap (1 MB). The plain hex/base64 shapes carry no timestamp: a replay of
# one is stopped by its id, which is read from the signed body only (the log keeps ids for `keep_days`; after that a
# captured event would be taken as new).
# Limits: the signature is checked over the body as text (mojoui.serve's Req.body): a body that isn't UTF-8 is refused
# rather than checked byte for byte.

from mojoui.serve import Req, Reply
from mojoui.jobs import Queue
from mojoui.json import Json, json_string
from mojoui.sqlite import Database, Pool
from mojoui.crypto import hmac_sha256, same, b64, b64url_decode, hmac_hex_ok
from mojoui.hash import hex
from mojoui.clock import wall_seconds

comptime STRIPE = 1
comptime HMAC_HEX = 2
comptime HMAC_B64 = 3
comptime STANDARD = 4  # Standard Webhooks (Svix): "<id>.<timestamp>.<body>", base64, secret "whsec_<base64>"
comptime MAX_BYTES = 1024 * 1024
comptime WINDOW_S = 300
comptime JOB_KIND = "webhook"
comptime SCHEMA = (
    "CREATE TABLE IF NOT EXISTS webhook_events(source TEXT NOT NULL, id TEXT NOT NULL, type TEXT, received REAL NOT NULL,"
    " body TEXT NOT NULL, PRIMARY KEY(source, id));"
    "CREATE INDEX IF NOT EXISTS webhook_events_old ON webhook_events(received)"
)


@fieldwise_init
struct Source(Copyable, Movable):
    var name: String  # the log's source column and the job's payload
    var scheme: Int
    var secret: String
    var header: String  # the signature's header (HMAC_HEX / HMAC_B64)
    var id_header: String  # where the event id is: "" the signed JSON body's "id"; STANDARD: webhook-id (signed too)
    var window_s: Int
    var max_bytes: Int

    @staticmethod
    def stripe(name: String, secret: String) -> Source:
        return Source(name, STRIPE, secret, "stripe-signature", "", WINDOW_S, MAX_BYTES)

    @staticmethod
    def hmac_hex(name: String, secret: String, header: String = "X-Signature") -> Source:
        """The id is the body's "id": these shapes sign only the body, so an id from a header could be changed to
        replay a captured event as new."""
        return Source(name, HMAC_HEX, secret, header.lower(), "", WINDOW_S, MAX_BYTES)

    @staticmethod
    def hmac_b64(name: String, secret: String, header: String = "X-Signature") -> Source:
        return Source(name, HMAC_B64, secret, header.lower(), "", WINDOW_S, MAX_BYTES)

    @staticmethod
    def standard(name: String, secret: String) -> Source:
        return Source(name, STANDARD, secret, "webhook-signature", "webhook-id", WINDOW_S, MAX_BYTES)


def b64_std_decode(s: String) -> Optional[List[UInt8]]:
    """Standard base64 (RFC 4648 §4, `+/`, padding optional)."""
    var t = s.replace("+", "-").replace("/", "_")
    var n = t.byte_length()
    while n > 0 and t.as_bytes()[n - 1] == UInt8(ord("=")):
        n -= 1
    return b64url_decode(String(t[byte = :n]))


def stripe_signature_ok(header: String, body: String, secret: String, now: Int, window_s: Int = WINDOW_S) -> Bool:
    """Stripe-Signature `t=<unix>,v1=<hex>[,v1=…]`: HMAC-SHA256 of "<t>.<body>", any v1 matching, t within the window."""
    return stripe_check(header, body, secret, now, window_s) == 0


def stripe_check(header: String, body: String, secret: String, now: Int, window_s: Int) -> Int:
    """0 good, 401 no or wrong signature, 400 outside the window."""
    if secret == "":
        return 401
    var t = -1
    var sigs = List[String]()
    for part in header.split(","):
        var p = String(part).strip()
        if p.startswith("t="):
            try:
                t = atol(String(p[byte = 2 :]))
            except:
                return 401
        elif p.startswith("v1="):
            sigs.append(String(p[byte = 3 :]))
    if t < 0 or len(sigs) == 0:
        return 401
    var want = hex(hmac_sha256(secret, String(t) + "." + body))
    var ok = False
    for s in sigs:
        ok = same(want, s) or ok
    if not ok:
        return 401
    return 400 if abs(now - t) > window_s else 0


def _standard_check(req: Req, secret: String, now: Int, window_s: Int) -> Int:
    var key_text = String(secret[byte = 6 :]) if secret.startswith("whsec_") else secret
    var key = b64_std_decode(key_text)
    if not key or secret == "":
        return 401
    var id = req.header("webhook-id")
    var ts = req.header("webhook-timestamp")
    var sigs = req.header("webhook-signature")
    if id == "" or ts == "" or sigs == "":
        return 401
    var t: Int
    try:
        t = atol(ts)
    except:
        return 401
    var msg = id + "." + ts + "." + req.body
    var mb = List[UInt8](capacity=msg.byte_length())
    for b in msg.as_bytes():
        mb.append(b)
    var want = b64(hmac_sha256(key.value(), mb))
    var ok = False
    for part in sigs.split(" "):
        var p = String(part).strip()
        if p.startswith("v1,"):
            ok = same(want, String(p[byte = 3 :])) or ok
    if not ok:
        return 401
    return 400 if abs(now - t) > window_s else 0


def check(src: Source, req: Req, now: Int) -> Int:
    """0 when the request is signed by `src`'s sender and fresh; else the status to answer (401, 400)."""
    if src.secret == "":
        return 401
    if src.scheme == STRIPE:
        return stripe_check(req.header("stripe-signature"), req.body, src.secret, now, src.window_s)
    if src.scheme == STANDARD:
        return _standard_check(req, src.secret, now, src.window_s)
    var got = req.header(src.header)
    if got == "":
        return 401
    if src.scheme == HMAC_HEX:
        return 0 if hmac_hex_ok(got, req.body, src.secret) else 401
    var mac = hmac_sha256(src.secret, req.body)
    var sig = String(got[byte = 7 :]) if got.startswith("sha256=") else got
    return 0 if same(b64(mac), sig) else 401


struct Webhooks(ImplicitlyCopyable, Movable):
    var path: String  # host.db
    var pool: Pool
    var queue: Queue

    def __init__(out self, path: String, queue: Queue) raises:
        self.path = path
        self.pool = Pool.shared()
        self.queue = queue
        self.db().exec(SCHEMA)

    def db(self) raises -> Database:
        return self.pool.open(self.path)

    def receive(self, req: Req, src: Source, tenant: String = "") -> Reply:
        """Check, log once, queue its processing. `tenant`: the job's tenant when the route already knows it."""
        if req.body.byte_length() > src.max_bytes:
            return Reply.error(413, "the event is too large", "too_large")
        var bad = check(src, req, Int(wall_seconds()))
        if bad == 401:
            return Reply.error(401, "bad signature", "bad_signature")
        if bad != 0:
            return Reply.error(400, "the signature's timestamp is outside the window", "stale")
        var id = String("")
        var kind = String("")
        try:
            var j = Json.parse(req.body)
            kind = j.text(j.get(0, "type"))
            id = req.header(src.id_header) if src.id_header != "" else j.text(j.get(0, "id"))
        except:
            if src.id_header == "":
                return Reply.error(400, "the event isn't JSON", "bad_event")
            id = req.header(src.id_header)
        if id == "" or id.byte_length() > 255:
            return Reply.error(400, "the event has no id", "bad_event")
        try:
            var db = self.db()
            db.begin()
            try:
                var q = db.prepare("INSERT OR IGNORE INTO webhook_events(source, id, type, received, body) VALUES (?, ?, ?, ?, ?)")
                q.bind(1, src.name)
                q.bind(2, id)
                q.bind(3, kind)
                q.bind(4, wall_seconds())
                q.bind(5, req.body)
                q.run()
                if db.changes() == 0:
                    db.commit()
                    return Reply.json('{"received": true, "duplicate": true}')
                _ = self.queue.add_in(db, JOB_KIND, '{"source": ' + json_string(src.name) + ', "event": ' + json_string(id) + "}", tenant)
                db.commit()
            except e:
                _ = db.rollback_quiet()
                raise e^
            self.queue.wake()
            return Reply.json('{"received": true}')
        except:
            return Reply.error(503, "can't record the event: try again", "busy")  # (the sender retries)

    def event(self, source: String, id: String) raises -> Tuple[String, String]:
        """(type, body) of a logged event; raises if there is none."""
        var db = self.db()
        var q = db.prepare("SELECT type, body FROM webhook_events WHERE source = ? AND id = ?")
        q.bind(1, source)
        q.bind(2, id)
        if not q.step():
            raise Error("no such event: " + source + "/" + id)
        return (q.text(0), q.text(1))

    def job_event(self, payload: String) raises -> Tuple[String, String, String, String]:
        """A "webhook" job's payload → (source, id, type, body)."""
        var j = Json.parse(payload)
        var source = j.text(j.get(0, "source"))
        var id = j.text(j.get(0, "event"))
        var ev = self.event(source, id)
        return (source, id, ev[0], ev[1])

    def sweep(self, keep_days: Int = 30) raises -> Int:
        """(tick) events older than `keep_days` deleted: after that a replay of one would be taken as new."""
        var db = self.db()
        var q = db.prepare("DELETE FROM webhook_events WHERE received < ?")
        q.bind(1, wall_seconds() - Float64(keep_days * 86400))
        q.run()
        return db.changes()
