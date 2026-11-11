# mojoui.apiclient: a JSON API client for a server talking to other services (goal 66 M2; fh-saas's utils_api and
# utils_graphql). Bearer, basic, or OAuth client-credentials auth whose token is cached and fetched again before it
# expires (and once more on a 401), GraphQL over POST with cursor paging, retries with exponential backoff and jitter on
# 429 and 5xx (and on no reply, for idempotent calls) that honour Retry-After, and a timeout per call. Blocking: run it
# from a job or an offloaded request, never on the reactor.
#
#   var bank = ApiClient("https://bank.example", Auth.client_credentials("https://bank.example/oauth/token", id, secret))
#   var r = bank.get("/v1/accounts")                       # ApiReply: status, body, error, attempts; r.ok()
#   var nodes = bank.graphql_pages("query($after: String) { transactions(after: $after) { nodes {id} pageInfo {hasNextPage endCursor} } }",
#                                  '{"connection": "c1"}', "transactions")    # every page's nodes, as JSON texts
#
# One client per thread: its token cache is the client's own (a job makes one per run, or keeps one per worker).
# Secrets go only into the Authorization header and the token request's body; nothing here logs.

from mojoui.http import Request, Response, utf8_lossy, uri_component
from mojoui.effects import Backend
from mojoui.json import Json, json_string, J_OBJECT, J_ARRAY
from mojoui.crypto import b64, random_bytes
from mojoui.clock import wall_seconds
from mojoui import libc

comptime AUTH_NONE = 0
comptime AUTH_BEARER = 1
comptime AUTH_BASIC = 2
comptime AUTH_CLIENT_CREDENTIALS = 3


@fieldwise_init
struct Auth(Copyable, Movable):
    var kind: Int
    var a: String  # the token, the user, or the client id
    var b: String  # the password or the client secret
    var token_url: String
    var scope: String

    @staticmethod
    def none() -> Auth:
        return Auth(AUTH_NONE, "", "", "", "")

    @staticmethod
    def bearer(token: String) -> Auth:
        return Auth(AUTH_BEARER, token, "", "", "")

    @staticmethod
    def basic(user: String, password: String) -> Auth:
        return Auth(AUTH_BASIC, user, password, "", "")

    @staticmethod
    def client_credentials(token_url: String, client_id: String, client_secret: String, scope: String = "") -> Auth:
        return Auth(AUTH_CLIENT_CREDENTIALS, client_id, client_secret, token_url, scope)


struct ApiReply(Movable):
    var status: Int  # 0: no reply (error says why)
    var body: String
    var error: String  # "" when status is 2xx and (GraphQL) there were no errors
    var attempts: Int
    var retry_after: String

    def __init__(out self, status: Int, body: String, error: String, attempts: Int):
        self.status = status
        self.body = body
        self.error = error
        self.attempts = attempts
        self.retry_after = ""

    def ok(self) -> Bool:
        return self.status >= 200 and self.status < 300 and self.error == ""

    def json(self) raises -> Json:
        return Json.parse(self.body)


def retry_after_ms(value: String, now_s: Float64) -> Int:
    """Retry-After as milliseconds: delta-seconds, or -1 when absent or an HTTP date we don't parse."""
    var v = value.strip()
    if v == "":
        return -1
    try:
        var n = atol(v)
        return max(n, 0) * 1000
    except:
        return -1


def basic_header(user: String, password: String) -> String:
    return "Basic " + b64(user + ":" + password)


struct ApiClient(Movable):
    var base: String
    var auth: Auth
    var timeout_ms: Int  # each call (connect, send, wait, read)
    var retries: Int  # tries after the first
    var backoff_ms: Int  # the first wait; doubled each time, with up to half again of jitter
    var max_wait_ms: Int  # no wait (Retry-After included) longer than this; longer: give up with the 429/503
    var refresh_early_s: Float64  # fetch a new token this long before the old one expires
    var graphql_path: String
    var token: String
    var token_expires: Float64
    var token_fetches: Int  # how many tokens this client has asked for (a test reads it)
    var headers_n: List[String]
    var headers_v: List[String]

    def __init__(out self, base: String, var auth: Auth, timeout_ms: Int = 15_000, retries: Int = 3, backoff_ms: Int = 500,
                 max_wait_ms: Int = 30_000, refresh_early_s: Float64 = 30, graphql_path: String = "/graphql"):
        self.base = String(base[byte = : base.byte_length() - 1]) if base.endswith("/") else base
        self.auth = auth^
        self.timeout_ms = timeout_ms
        self.retries = max(retries, 0)
        self.backoff_ms = max(backoff_ms, 1)
        self.max_wait_ms = max_wait_ms
        self.refresh_early_s = refresh_early_s
        self.graphql_path = graphql_path
        self.token = ""
        self.token_expires = 0
        self.token_fetches = 0
        self.headers_n = List[String]()
        self.headers_v = List[String]()

    def header(mut self, name: String, value: String):
        """A header on every call (an API version, a user agent)."""
        self.headers_n.append(name)
        self.headers_v.append(value)

    # ---- auth ----

    def _fetch_token(mut self) -> String:
        """A client-credentials token (RFC 6749 §4.4): the client's id and secret as Basic auth. "" or why it failed."""
        var body = String("grant_type=client_credentials")
        if self.auth.scope != "":
            body += "&scope=" + uri_component(self.auth.scope)
        var req = Request(0, "POST", self.auth.token_url, body).header("Content-Type", "application/x-www-form-urlencoded").header(
            "Accept", "application/json").header("Authorization", basic_header(self.auth.a, self.auth.b)).timeout(self.timeout_ms)
        var res = Backend.send(req^)
        self.token_fetches += 1
        if res.status != 200:
            return "the token endpoint answered " + String(res.status) + (" (" + res.error + ")" if res.error != "" else "")
        try:
            var j = Json.parse(utf8_lossy(res.body))
            var tok = j.text(j.get(0, "access_token"))
            if tok == "":
                return "the token endpoint sent no access_token"
            var life = j.real(j.get(0, "expires_in"), 3600)
            self.token = tok
            self.token_expires = wall_seconds() + life
            return ""
        except e:
            return "the token endpoint's reply isn't JSON"

    def _authorization(mut self) -> Tuple[String, String]:
        """(the Authorization header's value, an error)."""
        if self.auth.kind == AUTH_BEARER:
            return ("Bearer " + self.auth.a, "")
        if self.auth.kind == AUTH_BASIC:
            return (basic_header(self.auth.a, self.auth.b), "")
        if self.auth.kind == AUTH_CLIENT_CREDENTIALS:
            var early = min(self.refresh_early_s, (self.token_expires - wall_seconds()) / 2 if self.token != "" else 0)
            if self.token == "" or wall_seconds() + max(early, 0.5) >= self.token_expires:
                var why = self._fetch_token()
                if why != "":
                    return ("", why)
            return ("Bearer " + self.token, "")
        return ("", "")

    # ---- calls ----

    def get(mut self, path: String) -> ApiReply:
        return self.send("GET", path, "", True)

    def post_json(mut self, path: String, body: String, idempotent: Bool = False) -> ApiReply:
        return self.send("POST", path, body, idempotent)

    def send(mut self, method: String, path: String, body: String, idempotent: Bool) -> ApiReply:
        """One call with retries: 429 and 503 always (the server did nothing), other 5xx and no reply only when
        `idempotent`. A 401 with a client-credentials token fetches a new token and tries once more."""
        var url = path if path.startswith("http://") or path.startswith("https://") else self.base + path
        var attempt = 0
        var refreshed = False
        while True:
            attempt += 1
            var auth = self._authorization()
            if auth[1] != "":
                return ApiReply(0, "", auth[1], attempt)
            var req = Request(0, method, url, body).header("Accept", "application/json").timeout(self.timeout_ms)
            if body != "":
                req = req^.header("Content-Type", "application/json")
            if auth[0] != "":
                req = req^.header("Authorization", auth[0])
            for i in range(len(self.headers_n)):
                req = req^.header(self.headers_n[i], self.headers_v[i])
            var res = Backend.send(req^)
            var text = utf8_lossy(res.body)
            if res.status == 401 and self.auth.kind == AUTH_CLIENT_CREDENTIALS and not refreshed:
                refreshed = True
                self.token = ""  # (revoked or expired early: one new token, one more try)
                attempt -= 1
                continue
            var again = res.status == 429 or res.status == 503 or (idempotent and (res.status == 0 or res.status >= 500))
            if not again or attempt > self.retries:
                var err = String("")
                if res.status == 0:
                    err = res.error if res.error != "" else "no reply"
                elif res.status < 200 or res.status >= 300:
                    err = "HTTP " + String(res.status)
                var out = ApiReply(res.status, text, err, attempt)
                out.retry_after = res.header("retry-after")
                return out^
            var wait = retry_after_ms(res.header("retry-after"), wall_seconds())
            if wait < 0:
                wait = self.backoff_ms * (1 << (attempt - 1))
                try:
                    wait += Int(random_bytes(1)[0]) * wait // 512  # (jitter: up to half again)
                except:
                    pass
            if wait > self.max_wait_ms:
                var out = ApiReply(res.status, text, "HTTP " + String(res.status) + ": asked to wait " + String(wait // 1000) + " s", attempt)
                out.retry_after = res.header("retry-after")
                return out^
            _ = libc.usleep(wait * 1000)

    # ---- GraphQL ----

    def graphql(mut self, query: String, variables: String = "{}") -> ApiReply:
        """POST {query, variables}; a reply with "errors" is an error (its first message)."""
        var gpath = self.graphql_path
        var r = self.send("POST", gpath, '{"query": ' + json_string(query) + ', "variables": ' + variables + "}", True)
        if r.status == 200:
            try:
                var j = Json.parse(r.body)
                var errs = j.get(0, "errors")
                if errs >= 0 and j.size(errs) > 0:
                    r.error = "GraphQL: " + j.text(j.get(j.at(errs, 0), "message"), "an error")
            except:
                r.error = "the reply isn't JSON"
        return r^

    def graphql_pages(mut self, query: String, variables: String, connection: String, max_pages: Int = 1000) raises -> List[String]:
        """Every node of a Relay-style connection at data.<connection> (dots for nested fields): `nodes` or
        `edges[].node`, following pageInfo.endCursor while hasNextPage. `query` takes `$after`; `variables` is a JSON
        object (without "after"). Raises on the first failing page."""
        var out = List[String]()
        var after = String("null")
        var vars = variables.strip()
        if not vars.startswith("{") or not vars.endswith("}"):
            raise Error("graphql_pages: variables must be a JSON object")
        var inner = String(String(vars[byte = 1 : vars.byte_length() - 1]).strip())
        for _ in range(max_pages):
            var v = "{" + inner + (", " if inner != "" else "") + '"after": ' + after + "}"
            var r = self.graphql(query, v)
            if not r.ok():
                raise Error("graphql page " + String(len(out)) + ": " + r.error)
            var j = r.json()
            var node = j.get(0, "data")
            for part in connection.split("."):
                node = j.get(node, String(part))
            if node < 0:
                raise Error("graphql: no data." + connection + " in the reply")
            var nodes = j.get(node, "nodes")
            if nodes >= 0:
                for i in range(j.size(nodes)):
                    out.append(j.dump(j.at(nodes, i)))
            else:
                var edges = j.get(node, "edges")
                for i in range(j.size(edges)):
                    out.append(j.dump(j.get(j.at(edges, i), "node")))
            var info = j.get(node, "pageInfo")
            if not j.flag(j.get(info, "hasNextPage")):
                return out^
            var cursor = j.text(j.get(info, "endCursor"))
            if cursor == "":
                raise Error("graphql: hasNextPage without an endCursor")
            after = json_string(cursor)
        raise Error("graphql: more than " + String(max_pages) + " pages")
