# Goal 66 M2: mojoui.apiclient against a local stand-in API (a mojoui.serve Service in this process): bearer and basic
# auth, a client-credentials token cached and fetched again before it expires and once on a 401, GraphQL paged by cursor
# over 3 pages, a 429 with Retry-After honoured, 503s backed off, a GraphQL error reported, and a per-call timeout.
from mojoui.serve import Server, Service, Req, Reply
from mojoui.apiclient import ApiClient, Auth, basic_header
from mojoui.json import Json, json_string
from mojoui.clock import now_ns, wall_seconds
from mojoui import libc


struct StandIn(Service):
    var tokens: List[String]
    var issued: List[Float64]
    var token_calls: Int
    var flaky: Int
    var fails: Int
    var revoked: Bool

    def __init__(out self):
        self.tokens = List[String]()
        self.issued = List[Float64]()
        self.token_calls = 0
        self.flaky = 0
        self.fails = 0
        self.revoked = False

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def valid(self, req: Req) -> Bool:
        var h = req.header("authorization")
        if self.revoked or not h.startswith("Bearer "):
            return False
        var t = String(h[byte = 7:])
        for i in range(len(self.tokens)):
            if self.tokens[i] == t and wall_seconds() < self.issued[i] + 2.0:
                return True
        return False

    def answer(mut self, mut req: Req) -> Reply:
        if req.matches("POST", "/oauth/token"):
            if req.header("authorization") != basic_header("cid", "csecret") or req.body.find("grant_type=client_credentials") < 0:
                return Reply.json('{"error": "invalid_client"}', 401)
            self.token_calls += 1
            self.revoked = False
            var t = "tok" + String(self.token_calls)
            self.tokens.append(t)
            self.issued.append(wall_seconds())
            return Reply.json('{"access_token": ' + json_string(t) + ', "token_type": "Bearer", "expires_in": 2}')
        if req.matches("GET", "/static"):
            return Reply.json('{"ok": true}') if req.header("authorization") == "Bearer s3cret" else Reply.json("{}", 401)
        if req.matches("GET", "/basic"):
            return Reply.json('{"ok": true}') if req.header("authorization") == basic_header("ada", "pw:1") else Reply.json("{}", 401)
        if req.matches("GET", "/token-calls"):
            return Reply.json('{"n": ' + String(self.token_calls) + "}")
        if req.matches("POST", "/revoke"):
            self.revoked = True
            return Reply.empty()
        if req.matches("GET", "/flaky"):
            self.flaky += 1
            if self.flaky == 1:
                return Reply.json('{"error": "slow down"}', 429).header("Retry-After", "1")
            return Reply.json('{"ok": true}')
        if req.matches("GET", "/fails"):
            self.fails += 1
            if self.fails <= 2:
                return Reply.json("{}", 503)
            return Reply.json('{"ok": true}')
        if req.matches("GET", "/slow"):
            _ = libc.poll(0, 0, 1500)
            return Reply.json('{"ok": true}')
        if req.matches("POST", "/graphql"):
            if not self.valid(req):
                return Reply.json('{"errors": [{"message": "unauthenticated"}]}', 401)
            try:
                var j = Json.parse(req.body)
                if j.text(j.get(0, "query")).find("broken") >= 0:
                    return Reply.json('{"data": null, "errors": [{"message": "Cannot query field broken"}]}')
                var v = j.get(0, "variables")
                var after = j.text(j.get(v, "after"))
                var start = 0 if after == "" else atol(after)
                var nodes = String("")
                for i in range(start, min(start + 3, 7)):
                    nodes += ("," if i > start else "") + '{"id": "t' + String(i) + '", "amount": -' + String(i) + '.5, "who": ' + json_string(j.text(j.get(v, "connection"))) + "}"
                var more = "true" if start + 3 < 7 else "false"
                return Reply.json('{"data": {"bank": {"transactions": {"nodes": [' + nodes + '], "pageInfo": {"hasNextPage": ' + more + ', "endCursor": "' + String(start + 3) + '"}}}}}')
            except:
                return Reply.json("{}", 400)
        return Reply.not_found()


def ok(c: Bool, what: String) raises:
    if not c:
        raise Error("FAILED: " + what)


def ms_since(t0: Int) -> Int:
    return (now_ns() - t0) // 1_000_000


def main() raises:
    var served = Server.start(StandIn(), port=0)
    var base = "http://127.0.0.1:" + String(served.port)

    var s = ApiClient(base, Auth.bearer("s3cret"))
    ok(s.get("/static").ok(), "bearer")
    var w = ApiClient(base, Auth.bearer("wrong"))
    ok(w.get("/static").status == 401, "a wrong bearer is 401, no retry")
    print("bearer: ok")
    var ba = ApiClient(base, Auth.basic("ada", "pw:1"))
    ok(ba.get("/basic").ok(), "basic")
    print("basic: ok")

    var c = ApiClient(base, Auth.client_credentials(base + "/oauth/token", "cid", "csecret"), refresh_early_s=0.5)
    var q = String("query($connection: String, $after: String) { bank { transactions(connection: $connection, after: $after) { nodes { id amount } pageInfo { hasNextPage endCursor } } } }")
    var nodes = c.graphql_pages(q, '{"connection": "c-1"}', "bank.transactions")
    ok(len(nodes) == 7, "7 nodes, got " + String(len(nodes)))
    var last = Json.parse(nodes[6])
    ok(last.text(last.get(0, "id")) == "t6" and last.text(last.get(0, "who")) == "c-1" and last.real(last.get(0, "amount")) == -6.5, "the last node: " + nodes[6])
    ok(c.token_fetches == 1, "one token for three pages, got " + String(c.token_fetches))
    print("pages: ok 3 pages, 7 nodes, one token")

    _ = libc.poll(0, 0, 1700)  # (the 2 s token is now inside its last half second: fetched again before use)
    ok(c.graphql(q, '{"connection": "c-1", "after": null}').ok() and c.token_fetches == 2, "refreshed before expiry: " + String(c.token_fetches))
    var plain = ApiClient(base, Auth.none())
    _ = plain.post_json("/revoke", "{}")
    var again = c.graphql(q, '{"connection": "c-1", "after": null}')
    ok(again.ok() and c.token_fetches == 3 and again.attempts == 1, "a 401 fetched one new token and tried once more: " + String(c.token_fetches))
    var bad = ApiClient(base, Auth.client_credentials(base + "/oauth/token", "cid", "nope"))
    var refused = bad.graphql(q, "{}")
    ok(not refused.ok() and refused.error.find("401") >= 0 and bad.token_fetches == 1, "a refused client stops: " + refused.error)
    print("refresh: ok before expiry, and once on a 401")

    var t0 = now_ns()
    var f = plain.get("/flaky")
    var waited = ms_since(t0)
    ok(f.ok() and f.attempts == 2 and waited >= 950, "429 then 200 after Retry-After: " + String(waited) + " ms")
    print("retry_after: ok waited " + String(waited) + " ms")

    t0 = now_ns()
    var quick = ApiClient(base, Auth.none(), backoff_ms=100)
    var b = quick.get("/fails")
    waited = ms_since(t0)
    ok(b.ok() and b.attempts == 3 and waited >= 300, "503, 503, 200 with backoff: " + String(waited) + " ms")
    var once = ApiClient(base, Auth.none(), retries=0)
    var gave_up = once.get("/fails")
    ok(gave_up.ok(), "the stand-in recovered")
    print("backoff: ok 3 attempts in " + String(waited) + " ms")

    var g = c.graphql("query { broken }")
    ok(not g.ok() and g.error.find("Cannot query field broken") >= 0, "a GraphQL error: " + g.error)
    print("graphql_error: ok")

    t0 = now_ns()
    var hurried = ApiClient(base, Auth.none(), timeout_ms=300, retries=0)
    var slow = hurried.get("/slow")
    waited = ms_since(t0)
    ok(slow.status == 0 and slow.error != "" and waited < 1200, "a 300 ms timeout: " + String(slow.status) + " " + slow.error + " after " + String(waited))
    print("timeout: ok gave up after " + String(waited) + " ms (" + slow.error + ")")
    served.stop()
