# Gateway (blade-gateway.js): LiteLLM's status, its routes (model name -> upstream), recent requests to /v1, the
# safeguards the daemon counts today, the LiteLLM log's last lines, Restart, and the CLI twins. Data: GET /admin/network,
# /admin/gateway and /admin/litellm/log?bytes=8000 on arrival and every 4 s; the recent requests are core.js's poll
# (/admin/requests?limit=40, handed over by app.mojo); POST /admin/litellm/restart.

from mojoui.shared import floored
from mojoui.view import View, Text, VStack, HStack, Spacer, CENTER, START
from mojoui.app import Event
from mojoui.effects import Every
from mojoui.json import Json, J_NUMBER, J_BOOL
from mojoui.table import Table
from mojoui.lists import SideScroll
from mojoui.logview import LogView
from mojoui.header import PageHeader
from mojoui.panel import Card, CardHead, CardBody, CardFoot, CopyFoot, CardStack, CardNote, FactText, FactGrid
from mojoui.buttons import SmallButton, ButtonRow, TONAL, FILL
from mojoui.words import Mono, QuietText, Hint
from mojoui.marks import StatusMark, GOOD, QUIET, BAD
from mojoui.feedback import EmptyState
from api import Api
from data import Store, real_or
from msgs import *
from mojoui.numformat import en_number

comptime LOG_LINES = 60
comptime COPIES: List[String] = ["mxc status", "mxc requests --limit 200", "mxc console api", "mxc expose", "mxc expose --stop"]


@fieldwise_init
struct RouteRow(Copyable, Movable):
    var name: String
    var state: String
    var port: Int  # 0: none
    var recent: Int


@fieldwise_init
struct RequestRow(Copyable, Movable):
    var ts: Float64
    var app: String
    var model: String
    var route: String
    var status: Int
    var tokens: String
    var ttft: String
    var duration: String


def clock(ts: Float64) -> String:
    """core.js clock: the time of day, 21:36:33 (UTC, as the shots read it)."""
    var s = Int(floored(ts)) % 86400
    var h = s // 3600
    var m = (s % 3600) // 60
    var sec = s % 60
    return ("0" if h < 10 else "") + String(h) + ":" + ("0" if m < 10 else "") + String(m) + ":" + ("0" if sec < 10 else "") + String(sec)


def app_label(name: String) -> String:
    """core.js appLabel's words: no key, benchmark, console, notebook, or the app's name."""
    if name == "":
        return "no key"
    if name == "_bench":
        return "benchmark"
    if name == "_notebook":
        return "notebook"
    return name


def counted(v: Int, one: String, many: String) -> String:
    return en_number(Float64(v)) + " " + (one if v == 1 else many)


struct GatewayPage(Copyable, Movable):
    var loaded: Bool  # /admin/network answered
    var failed: String
    var litellm: Bool
    var caddy: Bool
    var lan: String
    var litellm_port: Int
    var daemon_port: Int
    var routes: List[RouteRow]
    var has_gw: Bool
    var tls_on: Bool
    var tls_endpoint: String
    var keys_active: Int
    var keys_revoked: Int
    var unauthorized: Int
    var unknown_routes: Int
    var admin_refused: Int
    var log_text: String
    var log_failed: String
    var log_loaded: Bool
    var requests: List[RequestRow]
    var requests_loaded: Bool
    var busy: Bool  # Restart waits for its answer

    def __init__(out self):
        self.loaded = False
        self.failed = ""
        self.litellm = False
        self.caddy = False
        self.lan = ""
        self.litellm_port = 0
        self.daemon_port = 0
        self.routes = List[RouteRow]()
        self.has_gw = False
        self.tls_on = False
        self.tls_endpoint = ""
        self.keys_active = 0
        self.keys_revoked = 0
        self.unauthorized = 0
        self.unknown_routes = 0
        self.admin_refused = 0
        self.log_text = ""
        self.log_failed = ""
        self.log_loaded = False
        self.requests = List[RequestRow]()
        self.requests_loaded = False
        self.busy = False

    def load(self, mut api: Api):
        api.get(GW_GOT_NETWORK, "/admin/network")
        api.get(GW_GOT_GATEWAY, "/admin/gateway")
        api.get(GW_GOT_LOG, "/admin/litellm/log?bytes=8000")

    def enter(mut self, mut api: Api):
        self.load(api)

    def every(self) -> List[Every]:
        return [Every(4000, GW_POLL)]

    def update(mut self, m: Int, event: Event, mut api: Api) -> String:
        """A tap or a reply in Gateway's range; returns text to put on the clipboard ("" none)."""
        var failed = event.error != "" or event.number >= 400
        var why = event.error if event.error != "" else "HTTP " + String(event.number)
        if m == GW_POLL:
            self.load(api)
        elif m == GW_RESTART and not self.busy and self.litellm:
            self.busy = True
            api.post(GW_GOT_RESTART, "/admin/litellm/restart")
        elif GW_COPY <= m < GW_COPY + 5:
            return materialize[COPIES]()[m - GW_COPY]
        elif m == GW_GOT_RESTART:
            self.busy = False
            self.load(api)
        elif m == GW_GOT_NETWORK:
            if failed:
                self.failed = why
                return ""
            try:
                self.read_network(event.text)
                self.failed = ""
            except e:
                self.failed = String(e)
        elif m == GW_GOT_GATEWAY and not failed:
            try:
                self.read_gateway(event.text)
            except:
                pass
        elif m == GW_GOT_LOG:
            self.log_loaded = True
            self.log_failed = why if failed else ""
            self.log_text = "" if failed else event.text
        return ""

    def read_network(mut self, text: String) raises:
        var j = Json.parse(text)
        var ex = j.get(0, "expose")
        self.litellm = j.flag(j.get(ex, "litellm"))
        self.caddy = j.flag(j.get(ex, "caddy"))
        self.lan = j.text(j.get(0, "lan_endpoint"))
        var ports = j.get(0, "ports")
        self.litellm_port = Int(real_or(j, j.get(ports, "litellm"), 0))
        self.daemon_port = Int(real_or(j, j.get(ports, "daemon"), 0))
        var models = j.get(0, "models")
        var out = List[RouteRow]()
        for k in range(j.size(models)):
            var r = j.at(models, k)
            out.append(RouteRow(j.text(j.get(r, "name")), j.text(j.get(r, "state")), Int(real_or(j, j.get(r, "port"), 0)), Int(real_or(j, j.get(r, "recent"), 0))))
        self.routes = out^
        self.loaded = True

    def read_gateway(mut self, text: String) raises:
        var j = Json.parse(text)
        var tls = j.get(0, "tls")
        self.tls_on = j.flag(j.get(tls, "on"))
        self.tls_endpoint = j.text(j.get(tls, "endpoint"))
        var keys = j.get(0, "keys")
        self.keys_active = Int(real_or(j, j.get(keys, "active"), 0))
        self.keys_revoked = Int(real_or(j, j.get(keys, "revoked"), 0))
        self.unauthorized = Int(real_or(j, j.get(0, "unauthorized_today"), 0))
        self.unknown_routes = Int(real_or(j, j.get(0, "unknown_routes_today"), 0))
        self.admin_refused = Int(real_or(j, j.get(0, "admin_refused_today"), 0))
        self.has_gw = True

    def read_requests(mut self, text: String):
        """core.js's /admin/requests?limit=40 (newest first): the first 12 as the table shows them (requestRows)."""
        try:
            var j = Json.parse(text)
            var out = List[RequestRow]()
            for k in range(min(j.size(0), 12)):
                var r = j.at(0, k)
                var comp = j.get(r, "completion_tokens")
                var tokens = String("—")
                if j.kind(comp) == J_NUMBER:
                    tokens = en_number(real_or(j, j.get(r, "prompt_tokens"), 0)) + " → " + ("~" if j.flag(j.get(r, "estimated")) else "") + en_number(j.real(comp))
                var tt = j.get(r, "ttft_ms")
                var model = j.text(j.get(r, "model"))
                out.append(RequestRow(real_or(j, j.get(r, "ts"), 0), j.text(j.get(r, "app")), model if model != "" else String("—"), j.text(j.get(r, "route")),
                                      Int(real_or(j, j.get(r, "status"), 0)), tokens, (en_number(j.real(tt)) + " ms") if j.kind(tt) == J_NUMBER else String("—"),
                                      en_number(real_or(j, j.get(r, "duration_ms"), 0)) + " ms"))
            self.requests = out^
            self.requests_loaded = True
        except:
            pass

    def log_lines(self) -> List[String]:
        """tailLines: the last 60 lines, without the trailing blank."""
        var lines = List[String]()
        for l in String(self.log_text.rstrip()).split("\n"):
            lines.append(String(l))
        if len(lines) == 1 and lines[0] == "":
            return List[String]()
        if len(lines) <= LOG_LINES:
            return lines^
        var out = List[String]()
        for k in range(len(lines) - LOG_LINES, len(lines)):
            out.append(lines[k])
        return out^


def gateway_header(gp: GatewayPage) -> View:
    return PageHeader("route", "Gateway", "", "LiteLLM · one endpoint routes to every model",
                      [SmallButton("Restart", GW_RESTART, "refresh-cw", TONAL, off=gp.busy or not gp.litellm)], hue=6)


def gateway_view(gp: GatewayPage, st: Store, phone: Bool) -> View:
    var cards: List[View] = []
    # Status
    var status: List[View] = [CardHead("Status")]
    if not gp.loaded:
        status.append(CardNote(("Could not load the gateway: " + gp.failed) if gp.failed != "" else "Loading…"))
    else:
        var keys: List[String] = ["LiteLLM", "Caddy (HTTPS)", "Local endpoint", "LAN endpoint"]
        var values: List[View] = [StatusMark(("running · :" + String(gp.litellm_port)) if gp.litellm else "off", GOOD if gp.litellm else QUIET, mono=True),
                                  StatusMark("running" if gp.caddy else "off", GOOD if gp.caddy else QUIET, mono=True),
                                  FactText(st.endpoint if st.endpoint != "" else String("—")), FactText(gp.lan if gp.lan != "" else String("off"))]
        var facts: List[View] = [FactGrid(keys, values^)]
        if not gp.litellm:
            facts.append(Hint("LiteLLM is off, so only the daemon's own /v1 answers. The routes below apply once mxc expose starts it."))
        status.append(CardBody(facts^, flow=True))
    status.append(CopyFoot("mxc status", GW_COPY))
    cards.append(Card(status^))
    # Routes
    if gp.loaded:
        var daemon = "http://127.0.0.1:" + String(gp.daemon_port) + "/v1"
        var routes: List[View] = [CardHead("Routes")]
        if len(gp.routes) > 0:
            var cells: List[View] = []
            for r in gp.routes:
                cells.append(Mono(r.name))
                cells.append(Mono("openai/" + r.name))
                cells.append(Mono((":" + String(r.port)) if r.port > 0 else ("starting" if r.state == "starting" else "idle")))
                cells.append(Mono(en_number(Float64(r.recent))))
            routes.append(SideScroll(Table(["Model name", "Upstream model", "max serve", "Req · 1 min"], cells, align="LLLR").fill().tag("routes")))
            routes.append(CardFoot("every route goes to " + daemon, note=True))
        else:
            routes.append(EmptyState("route", "No routes yet", "Add a model and it gets a route.", "Add a model", GW_ADD))
            routes.append(CardFoot("a route appears for each model you add", note=True))
        cards.append(Card(routes^))
    # Recent requests
    var recent: List[View] = [CardHead("Recent requests", "newest first · kept for 7 days")]
    if len(gp.requests) > 0:
        var cells: List[View] = []
        for r in gp.requests:
            cells.append(Mono(clock(r.ts)))
            cells.append(Text(app_label(r.app)))
            cells.append(Mono(r.model))
            cells.append(Mono(r.route))
            cells.append(StatusMark(String(r.status), GOOD if r.status < 400 else BAD, mono=True))
            cells.append(Mono(r.tokens))
            cells.append(Mono(r.ttft))
            cells.append(Mono(r.duration))
        recent.append(SideScroll(Table(["Time", "App", "Model", "Route", "Status", "Tokens in → out", "TTFT", "Duration"], cells, align="LLLLLLLL").fill().tag("requests")))
    elif gp.requests_loaded:
        recent.append(EmptyState("scroll-text", "No requests yet", "They show up here once an app calls /v1."))
    else:
        recent.append(CardNote("Loading…"))
    recent.append(CopyFoot("mxc requests --limit 200", GW_COPY + 1))
    cards.append(Card(recent^))
    # Safeguards
    if gp.has_gw:
        cards.append(Card([CardHead("Safeguards", "counted today"), CardBody([FactGrid(["Encrypted on your LAN", "One key per app", "Only four doors open", "Admin stays home"],
            [FactText(("HTTPS on · " + gp.tls_endpoint) if gp.tls_on else "off: nothing listens beyond this machine"),
             FactText(String(gp.keys_active) + " active · " + String(gp.keys_revoked) + " revoked · " + counted(gp.unauthorized, "request", "requests") + " refused today (401)"),
             FactText(counted(gp.unknown_routes, "request", "requests") + " to other /v1 paths today"),
             FactText(counted(gp.admin_refused, "refusal", "refusals") + " today")])]), CopyFoot("mxc status", GW_COPY)]))
    # The LiteLLM log
    var lines = gp.log_lines()
    var empty = String("Loading…") if not gp.log_loaded else (("Could not read the LiteLLM log: " + gp.log_failed) if gp.log_failed != "" else "No LiteLLM log yet: it appears once `mxc expose` starts LiteLLM.")
    cards.append(Card([CardHead("LiteLLM log", "last lines"), CardBody([LogView(lines.copy() if gp.log_failed == "" else List[String](), empty=empty, short=True).fill()]),
                       CardFoot("refreshed every few seconds", note=True)]))
    # The API reference, the terminal
    cards.append(Card([CardHead("API reference"), CardBody([QuietText("Base URL, auth, every endpoint and a request you can copy."),
                                                            ButtonRow([SmallButton("Open the API reference", GW_DOCS, "book-open", FILL)])]),
                       CopyFoot("mxc console api", GW_COPY + 2)]))
    cards.append(Card([CardHead("From the terminal"), CopyFoot("mxc status", GW_COPY), CopyFoot("mxc expose", GW_COPY + 3), CopyFoot("mxc expose --stop", GW_COPY + 4)]))
    return CardStack(cards^)
