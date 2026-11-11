# mojoui.operator: the site's operator (goal 66 M6; fh-saas had an admin panel over its host database). People whose
# signed-in email is in SAAS_OPERATORS (comma-separated) reach an API no tenant role grants, not even a tenant's admin:
# every tenant with its plan and last activity, a tail of the JSON log with filters, and a tenant's SQLite database as a
# consistent download (VACUUM INTO a temporary file). Each operator action, and each refused attempt by a signed-in
# person, is an audit row in host.db.
#
#   var op = Operator(data, getenv("SAAS_OPERATORS"), getenv("SAAS_LOG"))
#   var o = op.handle(req, acc)                 # /operator/api/tenants  /operator/api/log?level=&path=&tenant=&rid=&limit=
#   if o.status != 0: return o^                 # /operator/api/tenants/{id}/snapshot
#   def blocking(self, req): return op.blocking(req)   # (a snapshot copies a whole database: off the reactor)
#
# Identity is mojoui.accounts' session: the email Google verified, bound to the account's `sub` (an address reassigned
# to someone else can't sign in as the operator). Operators are configuration only: changing them is a restart.
from std.os import remove, makedirs
from std.os.path import exists
from mojoui.serve import Req, Reply
from mojoui.accounts import Accounts, Member
from mojoui.sqlite import Database, Pool
from mojoui.log import Audit
from mojoui.json import Json, json_string
from mojoui.crypto import random_token
from mojoui.watch import file_stamp

comptime LOG_TAIL_BYTES = 4 * 1024 * 1024  # the most of the log's end a tail reads
comptime MAX_SNAPSHOT = 512 * 1024 * 1024


def tenant_id_ok(id: String) -> Bool:
    """A tenant id as mojoui.accounts makes them: letters, digits, '-', '_' (it names a file)."""
    if id == "" or id.byte_length() > 64:
        return False
    for b in id.as_bytes():
        var c = Int(b)
        if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95):
            return False
    return True


struct Operator(Copyable, Movable):
    var data: String
    var emails: List[String]
    var log_path: String
    var pool: Pool

    def __init__(out self, data: String, operators: String, log_path: String) raises:
        self.data = data
        self.emails = List[String]()
        for e in operators.split(","):
            var t = String(String(e).strip()).lower()
            if t != "":
                if t.find("@") < 1:
                    raise Error("SAAS_OPERATORS: not an email: " + t)
                self.emails.append(t)
        self.log_path = log_path
        self.pool = Pool.shared()

    def host(self) raises -> Database:
        return self.pool.open(self.data + "/host.db")

    def is_operator(self, m: Member) -> Bool:
        var e = m.email.lower()
        for o in self.emails:
            if o == e:
                return True
        return False

    def blocking(self, req: Req) -> Bool:
        return req.path.startswith("/operator/api/tenants/") and req.path.endswith("/snapshot")

    def handle(self, mut req: Req, acc: Accounts) -> Reply:
        if not req.path.startswith("/operator/"):
            return Reply.empty(0)
        var who = acc.member(req)
        if not who:
            return Reply.error(401, "sign in first", "unauthorized")
        var m = who.value().copy()
        if not self.is_operator(m):
            try:
                Audit.record(self.host(), m.tenant, m.email, "operator_refused", req.method + " " + req.path)
            except:
                pass
            return Reply.error(403, "operators only", "forbidden")
        try:
            if req.matches("GET", "/operator/api/tenants"):
                Audit.record(self.host(), "", m.email, "operator_tenants", "")
                return Reply.json(self.tenants_json()).header("Cache-Control", "no-store")
            if req.matches("GET", "/operator/api/log"):
                var lim = 200
                try:
                    lim = max(1, min(atol(req.arg("limit", "200")), 2000))
                except:
                    pass
                Audit.record(self.host(), req.arg("tenant"), m.email, "operator_log", req.query)
                return Reply.json(self.log_json(req.arg("level"), req.arg("path"), req.arg("tenant"), req.arg("rid"), lim)).header("Cache-Control", "no-store")
            if req.matches("GET", "/operator/api/tenants/{id}/snapshot"):
                return self.snapshot(req.param("id"), m)
        except e:
            return Reply.error(500, "the operator's request failed", "internal")
        return Reply.not_found()

    def tenants_json(self) raises -> String:
        var db = self.host()
        var billing = db.count("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'billing'") > 0
        var q = db.prepare(
            "SELECT t.id, coalesce(t.name, ''), t.plan, coalesce(t.created, 0), (SELECT count(*) FROM members m WHERE m.tenant = t.id),"
            " coalesce((SELECT max(ts) FROM audit a WHERE a.tenant = t.id), 0), "
            + ("coalesce((SELECT status FROM billing b WHERE b.tenant = t.id), 'none')" if billing else "'none'")
            + " FROM tenants t ORDER BY t.created")
        var out = String('{"tenants": [')
        var n = 0
        while q.step():
            var id = q.text(0)
            var last = max(q.int(3), q.int(5))
            var stamp = file_stamp(self.data + "/tenants/" + id + ".db")
            if stamp[1] >= 0:
                last = max(last, stamp[0] // 1_000_000_000)
            out += (("," if n > 0 else "") + '{"id": ' + json_string(id) + ', "name": ' + json_string(q.text(1)) + ', "plan": ' + json_string(q.text(2))
                    + ', "billing_status": ' + json_string(q.text(6)) + ', "members": ' + String(q.int(4)) + ', "created": ' + String(q.int(3))
                    + ', "last_activity": ' + String(last) + ', "db_bytes": ' + String(max(stamp[1], 0)) + "}")
            n += 1
        return out + "]}"

    def log_json(self, level: String, path: String, tenant: String, rid: String, limit: Int) raises -> String:
        """The newest `limit` JSON lines of the log's last LOG_TAIL_BYTES matching every filter given (exact)."""
        var lines = List[String]()
        if self.log_path != "" and exists(self.log_path):
            var size = file_stamp(self.log_path)[1]
            var start = max(0, size - LOG_TAIL_BYTES)
            var text: String
            with open(self.log_path, "r") as f:
                if start > 0:
                    _ = f.seek(start)
                text = String(from_utf8_lossy=Span(f.read_bytes(size - start)))
            var all = text.split("\n")
            var i = len(all) - 1
            while i >= 0 and len(lines) < limit:
                var line = String(String(all[i]).strip())
                i -= 1
                if line == "" or not line.startswith("{"):
                    continue
                try:
                    var j = Json.parse(line)
                    if level != "" and j.text(j.get(0, "level")) != level:
                        continue
                    if path != "" and j.text(j.get(0, "path")) != path:
                        continue
                    if tenant != "" and j.text(j.get(0, "tenant")) != tenant:
                        continue
                    if rid != "" and j.text(j.get(0, "rid")) != rid:
                        continue
                    lines.append(line)
                except:
                    continue  # (a line cut by the tail's start)
        var out = String('{"lines": [')
        for k in range(len(lines)):  # (oldest first)
            out += ("," if k > 0 else "") + lines[len(lines) - 1 - k]
        return out + "]}"

    def snapshot(self, id: String, m: Member) raises -> Reply:
        if not tenant_id_ok(id):
            return Reply.error(400, "not a tenant id", "bad_request")
        var host = self.host()
        var q = host.prepare("SELECT 1 FROM tenants WHERE id = ?")
        q.bind(1, id)
        if not q.step():
            return Reply.error(404, "no such tenant", "not_found")
        q.reset()
        var src = self.data + "/tenants/" + id + ".db"
        if not exists(src):
            return Reply.error(404, "the tenant has no database yet", "not_found")
        makedirs(self.data + "/snapshots", exist_ok=True)
        var tmp = self.data + "/snapshots/" + id + "-" + random_token(8) + ".db"
        var db = self.pool.open(src)
        var into = db.prepare("VACUUM INTO ?")
        into.bind(1, tmp)
        into.run()
        var bytes: List[UInt8]
        try:
            var size = file_stamp(tmp)[1]
            if size > MAX_SNAPSHOT:
                raise Error("the snapshot is over " + String(MAX_SNAPSHOT // (1024 * 1024)) + " MB")
            with open(tmp, "r") as f:
                bytes = f.read_bytes(size)
        except e:
            remove(tmp)
            raise e^
        remove(tmp)
        Audit.record(host, id, m.email, "operator_snapshot", String(len(bytes)) + " bytes")
        var r = Reply(200, "application/vnd.sqlite3", "")
        r.body = bytes^
        return r^.header("Content-Disposition", 'attachment; filename="tenant-' + id + '.db"').header("Cache-Control", "no-store")
