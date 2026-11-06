# The saas demo's server (goal 57): sign-in, tenants and payments composed from mojoui.accounts and mojoui.billing on
# mojoui.serve. Nothing here but routes: the pieces are the framework's. Env and routes: docs/goals/57-check.py's docstring.
#   scripts/saas.sh build && SAAS_SECRET=… GOOGLE_CLIENT_ID=… build/saas/server
from std.os import getenv
from mojoui.serve import Server, Service, Req, Reply
from mojoui.accounts import Accounts, AuthConfig, Member
from mojoui.json import Json, json_string
from mojoui.sqlite import Database
from mojoui.clock import wall_seconds
from mojoui import libc


struct Saas(Service):
    var acc: Accounts

    def __init__(out self) raises:
        self.acc = Accounts(getenv("SAAS_DATA", "data"), AuthConfig.from_env())

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        var r = self.acc.handle(req)
        if r.status != 0:
            return r^
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
                if m.plan != "pro":
                    return Reply.error(402, "this needs the Pro plan", "payment_required")
                return Reply.json('{"pro": true}')
        except e:
            print("saas: " + String(e))
            return Reply.error(500, "the tenant's store failed", "internal")
        return Reply.not_found()

    def open(self, m: Member) raises -> Database:
        var db = self.acc.tenant_db(m)
        db.exec("CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY, text TEXT NOT NULL, amount_cents INTEGER NOT NULL, by TEXT, at INTEGER)")
        return db^

    def entries(self, m: Member) raises -> Reply:
        var db = self.open(m)
        var q = db.prepare("SELECT text, amount_cents, by FROM entries ORDER BY id")
        var out = String("[")
        var n = 0
        while q.step():
            out += ("," if n > 0 else "") + '{"text": ' + json_string(q.text(0)) + ', "amount_cents": ' + String(q.int(1)) + ', "by": ' + json_string(q.text(2)) + "}"
            n += 1
        return Reply.json('{"entries": ' + out + "]}")

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
        var db = self.open(m)
        var q = db.prepare("INSERT INTO entries(text, amount_cents, by, at) VALUES (?, ?, ?, ?)")
        q.bind(1, text)
        q.bind(2, cents)
        q.bind(3, m.email)
        q.bind(4, Int(wall_seconds()))
        q.run()
        return Reply.json('{"ok": true}', 201)


def main() raises:
    var served = Server.start(Saas(), port=atol(getenv("SAAS_PORT", "8000")), host=getenv("SAAS_HOST", "127.0.0.1"))
    print("SAAS: listening " + String(served.port), flush=True)
    while not served.stopped():
        _ = libc.poll(0, 0, 500)
    served.stop()
