# omxconsole, rebuilt in omxcode (goal 33): the OMX Console's pages over the daemon's /admin/* API, drawn natively on
# GTK and the Mac and as a page on the web, in omxqua. This file is the shell: the route (the URL's hash on the web), the
# top bar, the poll (core.js every 3 s, system-data.js every 5 s, beacon.js every 3 s; the tabs' own), the replies, and
# which page shows. Each page is a file of its own: home.mojo (My models), modelpage.mojo (the model page and its
# Overview), bench.mojo, logs.mojo, notebook.mojo; M6 adds Add, Keys, Gateway, Security and Settings beside them.
#
#   MXC_URL=http://127.0.0.1:11435 MXC_ADMIN_KEY=1 scripts/build.sh console linux      (default: the fixture server)

from mojoui.view import View, Text, Button, VStack, HStack, Scroll, Divider, Spacer, CENTER, START
from mojoui.app import App, Event
from mojoui.http import Request
from mojoui.effects import Every
from mojoui.canvas import Surface
from mojoui.theme import Theme, mix
from mojoui.route import Route, Place, parse_route, route_for
from mojoui.overlays import Clipboard
from mojoui.confirm import TwoStep
from mojoui.sparkline import Sparkline, BarTrack
from mojoui.beacon import Ring
from mojoui.meter import Usage
from mojoui.shell import Shell, PageCard, is_compact
from mojoui.panel import CardNote
from mojoui.json import json_string
from themes.omxqua import omxqua
from api import Api
from data import Store, read_models, read_metrics, read_series, read_info, read_system, read_labels, read_pulls, read_ports, round1
from topbar import top_bar
from home import Library, home_view, visible, label_models, names_json, bulk_state
from modelpage import model_header, overview_view, tab_index, curl_for, fit_of, TAB_KEYS
from bench import Bench, bench_view, bench_bars
from logs import Logs, logs_view
from notebook import Notebook, notebook_view
from add import Add, add_page
from addflow import add_update, add_every, add_enter, now_ms
from keys import KeysPage, keys_view, keys_header
from gateway import GatewayPage, gateway_view, gateway_header
from security import SecurityPage, security_view, security_header
from settings import SettingsPage, settings_view, settings_header
from msgs import *

comptime CONFIRM_REMOVE = 0  # TwoStep keys
comptime CONFIRM_REMOVE_TICKED = 1


struct Main(App):
    comptime HTTP = True
    var api: Api
    var store: Store
    var path: String
    var width: Int
    var height: Int
    var lib: Library
    var bench: Bench
    var logs: Logs
    var nb: Notebook
    var add: Add
    var kp: KeysPage  # Keys, Gateway, Security, Settings (M6 part a)
    var gp: GatewayPage
    var sp: SecurityPage
    var setp: SettingsPage
    var core_ticks: Int  # core polls since /admin/info was last read (it's read every 15 s)
    var clip: String
    var clip_version: Int
    var copies: Int
    var confirm: TwoStep
    var dark: Bool
    var themed: Theme

    def __init__(out self):
        self.api = Api()
        self.store = Store()
        self.path = "/"
        self.width = 1440
        self.height = 900
        self.lib = Library()
        self.bench = Bench()
        self.logs = Logs()
        self.nb = Notebook()
        self.add = Add()
        self.kp = KeysPage()
        self.gp = GatewayPage()
        self.sp = SecurityPage()
        self.setp = SettingsPage()
        self.core_ticks = 0
        self.clip = ""
        self.clip_version = 0
        self.copies = 0
        self.confirm = TwoStep()
        self.dark = False
        self.themed = omxqua(False)
        self.poll_core(True)  # (startPolling, startSystemPolling and the Beacon's loop each poll once at the start)
        self.api.get(GOT_SYSTEM, "/admin/system")
        self.poll_jobs()
        self.api.get(GOT_LABELS, "/admin/labels")

    def title(self) -> String:
        return "omxconsole"

    def window_size(self) -> Tuple[Int, Int]:
        return (1440, 900)

    def resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height

    def appearance(mut self, dark: Bool):
        self.dark = dark
        self.themed = omxqua(dark if self.setp.pick < 0 else self.setp.pick == 1)  # (Settings' Light or Dark, once picked)

    def theme(self) -> Theme:
        return self.themed.copy()

    def requests(mut self) -> List[Request]:
        return self.api.take()

    def place(self) -> Place:
        return parse_route(self.path)

    def phone(self) -> Bool:
        return is_compact(self.width)

    # ---- the poll ----

    def poll_core(mut self, info: Bool = False):
        """core.js refresh: models, metrics, series, requests; info at the start and every 15 s after."""
        self.api.get(GOT_MODELS, "/admin/models")
        self.api.get(GOT_METRICS, "/admin/metrics")
        self.api.get(GOT_SERIES, "/admin/series?range=5m")
        self.api.get(GOT_REQUESTS, "/admin/requests?limit=40")
        self.core_ticks += 1
        if info or self.core_ticks >= 5:
            self.core_ticks = 0
            self.api.get(GOT_INFO, "/admin/info")

    def poll_jobs(mut self):
        self.api.get(GOT_PULLS, "/admin/pulls")
        self.api.get(GOT_PORTS, "/admin/ports")

    def every(self) -> List[Every]:
        var out: List[Every] = [Every(3000, POLL_CORE), Every(5000, POLL_SYSTEM), Every(3000, POLL_JOBS)]
        var p = self.place()
        if p.page == "model" and p.tab == "benchmark":
            out.append(Every(1000 if self.bench.running else 5000, POLL_BENCH))
        if p.page == "model" and p.tab == "logs" and self.logs.follow:
            out.append(Every(2000, POLL_LOG))
        if p.page == "add":
            out += add_every(self.add)
        if p.page == "keys":
            out += self.kp.every()
        if p.page == "gateway":
            out += self.gp.every()
        if p.page == "security":
            out += self.sp.every()
        out += self.confirm.every(DISARM)
        return out^

    def enter(mut self):
        """A new place: what its page reads first (each tab's own data, read once on arrival)."""
        var p = self.place()
        if p.page == "add":
            add_enter(self.add, self.api)
        if p.page == "keys":
            self.kp.enter(self.api)
        if p.page == "gateway":
            self.gp.enter(self.api)
        if p.page == "security":
            self.sp.enter(self.api)
        if p.page == "settings":
            self.setp.enter(self.api)
        if p.page != "model":
            return
        if p.tab == "logs":
            self.logs = Logs()
            self.api.get(GOT_LOG, "/admin/models/" + p.model + "/log")
        elif p.tab == "benchmark":
            self.api.get(GOT_BENCH, "/admin/bench")
        elif p.tab == "notebook":
            if self.nb.model != p.model:
                self.nb = Notebook()
                self.nb.model = p.model
                self.api.get(GOT_LEARN, "/admin/learn/" + p.model)
            self.nb.jupyter = False

    def go(mut self, path: String):
        var before = self.path
        self.path = route_for(parse_route(path))
        if self.path != before:
            self.enter()

    def copy(mut self, text: String):
        self.clip = text
        self.clip_version += 1

    def label_write(mut self, var names: List[String], label: String, add: Bool):
        """Show a label change at once, send it (POST /admin/labels/<label>/add|remove), poll again when it's answered."""
        if len(names) == 0:
            return
        label_models(self.store, names, label, add)
        self.api.post(GOT_WRITE, "/admin/labels/" + label + ("/add" if add else "/remove"), names_json(names))

    # ---- update ----

    def update(mut self, event: Event):
        var m = event.message
        var p = self.place()
        var failed = event.error != "" or event.number >= 400
        if m == ROUTE:
            self.go(event.text)
        elif m == POLL_CORE:
            self.poll_core()
            if p.page == "home":
                self.api.get(GOT_LABELS, "/admin/labels")
        elif m == POLL_SYSTEM:
            self.api.get(GOT_SYSTEM, "/admin/system")
        elif m == POLL_JOBS:
            self.poll_jobs()
        elif m == POLL_BENCH:
            self.api.get(GOT_BENCH, "/admin/bench")
        elif m == POLL_LOG and p.page == "model":
            self.api.get(GOT_LOG, "/admin/models/" + p.model + "/log")
        elif m == DISARM:
            self.confirm.disarm()
        elif ADD_FIRST <= m <= ADD_LAST:
            var o = add_update(self.add, self.api, self.store, m, event)
            if o.clip != "":
                self.copy(o.clip)
            if o.refresh:
                self.poll_core()
            if o.go != "":
                self.go(o.go)
        elif KEYS_FIRST <= m <= SET_LAST:  # Keys, Gateway, Security, Settings: each page's taps and replies
            var clip = String("")
            if m <= KEYS_LAST:
                clip = self.kp.update(m, event, self.api)
            elif m <= GW_LAST:
                clip = self.gp.update(m, event, self.api)
            elif m <= SEC_LAST:
                clip = self.sp.update(m, event, self.api, self.store)
            else:
                clip = self.setp.update(m, event, self.api)
                self.themed = omxqua(self.dark if self.setp.pick < 0 else self.setp.pick == 1)
            if clip != "":
                self.copy(clip)
            if m == GW_ADD or m == SET_ADD:
                self.go("/add")
            if self.sp.go_to != "":
                var to = self.sp.go_to
                self.sp.go_to = ""
                self.go(to)
        elif GOT_MODELS <= m <= GOT_OPEN:
            self.reply(m, event, failed)
        elif m == HOME:
            self.go("/")
        elif CRUMB <= m < CRUMB + 4:
            if m == CRUMB:
                self.go("/")
        elif PLACE <= m < PLACE + 4:
            self.go("/" + ["keys", "gateway", "security", "settings"][m - PLACE])
        elif m == ADD:
            self.go("/add")
        elif m == KEYS:
            self.go("/keys")
        elif m == SEARCH:
            self.lib.q = event.text
        elif VIEW <= m < VIEW + 2:
            self.lib.cards = m == VIEW + 1
        elif GROUP <= m < GROUP + 7:
            var key = "all" if m == GROUP else ("running" if m == GROUP + 1 else "kind:" + ["chat", "coder", "vision", "embeddings", "image"][m - GROUP - 2])
            self.lib.group = "all" if self.lib.group == key and key != "all" else key
        elif LABEL_GROUP <= m < DROP_LABEL:
            var k = m - LABEL_GROUP
            if k < len(self.store.labels):
                var key = "label:" + self.store.labels[k]
                self.lib.group = "all" if self.lib.group == key else key
        elif DROP_LABEL <= m < TICK:
            var k = m - DROP_LABEL
            if k < len(self.store.labels):
                var names = List[String]()
                for n in event.text.split("\n"):
                    if self.store.model(String(n)) >= 0:
                        names.append(String(n))
                var label = self.store.labels[k].copy()
                self.label_write(names^, label, True)
        elif TICK <= m < TICK_ALL:
            var shown = visible(self.store, self.lib)
            var r = m - TICK
            if r < len(shown):
                self.lib.tick(shown[r].name, event.number == 1)
        elif m == TICK_ALL:
            var shown = visible(self.store, self.lib)
            var every = len(shown) > 0
            for s in shown:
                every = every and self.lib.is_ticked(s.name)
            for s in shown:
                self.lib.tick(s.name, not every)
        elif OPEN <= m < TAP_LABEL:
            var shown = visible(self.store, self.lib)
            if m - OPEN < len(shown):
                self.go(route_for(Place("model", shown[m - OPEN].name, "overview")))
        elif TAP_LABEL <= m < CLEAR:
            var k = m - TAP_LABEL
            if k < len(self.store.labels):
                var label = self.store.labels[k].copy()
                var add = bulk_state(self.store, self.lib.ticked, label) != "all"  # (toggleOn: add unless all have it)
                self.label_write(self.lib.ticked.copy(), label, add)
        elif m == CLEAR:
            self.lib.ticked = List[String]()
        elif m == REMOVE_TICKED:
            if self.confirm.tap(CONFIRM_REMOVE_TICKED):
                for n in self.lib.ticked:
                    self.api.send(GOT_WRITE, "DELETE", "/admin/models/" + n)
                self.lib.ticked = List[String]()
        elif TAB <= m < TAB + 4 and p.page == "model":
            self.go(route_for(Place("model", p.model, materialize[TAB_KEYS]()[m - TAB])))
        elif m == CMD_STOP and p.page == "model":
            self.api.post(GOT_WRITE, "/admin/models/" + p.model + "/stop")
        elif m == CMD_START and p.page == "model":
            self.api.post(GOT_WRITE, "/admin/models/" + p.model + "/load")
        elif m == CMD_RESTART and p.page == "model":
            self.api.post(GOT_WRITE, "/admin/models/" + p.model + "/stop", id=1)  # (then load, when the stop is answered)
        elif m == CMD_COPY:
            self.copy(self.store.lan_endpoint if self.store.lan_endpoint != "" else self.store.endpoint_now())
        elif m == CMD_REMOVE and p.page == "model":
            if self.confirm.tap(CONFIRM_REMOVE):
                self.api.send(GOT_WRITE, "DELETE", "/admin/models/" + p.model)
                self.go("/")
        elif m == COPY_CURL and p.page == "model":
            self.copies += 1
            self.copy(curl_for(self.store.endpoint_now(), p.model))
        elif REMOVE_LABEL <= m < REMOVE_LABEL + 20 and p.page == "model":
            var k = self.store.model(p.model)
            if k >= 0 and m - REMOVE_LABEL < len(self.store.models[k].labels):
                var label = self.store.models[k].labels[m - REMOVE_LABEL].copy()
                self.label_write([p.model], label, False)
        elif (m == BENCH_RUN or m == BENCH_ALL) and p.page == "model" and not self.bench.running:
            var body = String("{\"runs\": 5}") if m == BENCH_ALL else "{\"runs\": 5, \"models\": [" + json_string(p.model) + "]}"
            self.api.post(GOT_WRITE, "/admin/bench", body)
            self.bench.running = True
        elif m == LOG_FOLLOW:
            self.logs.follow = not self.logs.follow
            if self.logs.follow and p.page == "model":
                self.api.get(GOT_LOG, "/admin/models/" + p.model + "/log")
        elif m == LOG_COPY:
            self.copy(self.logs.visible_text())
        elif m == LOG_FILTER:
            self.logs.needle = event.text
        elif m == NB_RUN and p.page == "model":
            if self.nb.jupyter:
                self.nb.jupyter = False
            elif self.nb.opened > 0:
                self.nb.jupyter = True
            elif not self.nb.starting:
                self.nb.starting = True
                self.nb.problem = ""
                self.api.post(GOT_OPEN, "/admin/learn/" + p.model + "/open")

    def reply(mut self, m: Int, event: Event, failed: Bool):
        var p = self.place()
        try:
            if m == GOT_MODELS:
                if failed:
                    self.store.error = event.error if event.error != "" else "HTTP " + String(event.number)
                    return
                self.store.error = ""
                read_models(event.text, self.store)
                self.lib.forget_gone(self.store)
            elif failed:
                if m == GOT_LOG:
                    self.logs.loaded = True
                    self.logs.error = (p.model + " is not a registered model.") if event.number == 404 else "Could not read this log: " + (event.error if event.error != "" else "HTTP " + String(event.number))
                elif m == GOT_LEARN:
                    self.nb.error = event.error if event.error != "" else "HTTP " + String(event.number)
                elif m == GOT_OPEN:
                    self.nb.starting = False
                    self.nb.problem = "Could not start Jupyter (" + (event.error if event.error != "" else "HTTP " + String(event.number)) + ")."
                elif m == GOT_BENCH:
                    self.bench.failed = event.error if event.error != "" else "HTTP " + String(event.number)
                elif m == GOT_WRITE:
                    self.poll_core()  # (the daemon said no: the poll puts back what it holds)
                    self.api.get(GOT_LABELS, "/admin/labels")
                return
            elif m == GOT_METRICS:
                read_metrics(event.text, self.store)
            elif m == GOT_SERIES:
                read_series(event.text, self.store)
            elif m == GOT_INFO:
                read_info(event.text, self.store)
                self.setp.read_info(event.text)
            elif m == GOT_SYSTEM:
                read_system(event.text, self.store)
                self.setp.read_system(event.text)
            elif m == GOT_REQUESTS:
                self.gp.read_requests(event.text)
            elif m == GOT_LABELS:
                read_labels(event.text, self.store)
            elif m == GOT_PULLS:
                read_pulls(event.text, self.store)
            elif m == GOT_PORTS:
                read_ports(event.text, self.store)
            elif m == GOT_WRITE:
                if event.id == 1 and p.page == "model":  # Restart: the stop is done, now the load
                    self.api.post(GOT_WRITE, "/admin/models/" + p.model + "/load")
                self.poll_core()
                self.api.get(GOT_LABELS, "/admin/labels")
            elif m == GOT_BENCH:
                if self.bench.read(event.text):
                    self.api.get(GOT_HISTORY, "/admin/bench/history?limit=10")
            elif m == GOT_HISTORY:
                self.bench.read_history(event.text)
            elif m == GOT_LOG:
                self.logs.text = event.text
                self.logs.loaded = True
                self.logs.error = ""
            elif m == GOT_LEARN:
                self.nb.read(event.text)
            elif m == GOT_OPEN:
                self.nb.starting = False
                self.nb.read_open(event.text)
        except e:
            if m == GOT_MODELS:
                self.store.error = String(e)

    # ---- canvases ----

    def draw(mut self, canvas: Int, mut surface: Surface):
        var pal = self.themed.palette.copy()
        var p = self.place()
        if canvas == RING:
            Ring.themed(self.store.pull_percent, self.themed.look).draw(surface)
        elif canvas == SPARK:
            surface.fill(pal.raised)
            Sparkline.signal(self.store.points(p.model), self.themed.look, pal, 1).draw(surface)  # (colorOf: the model's own colour)
        elif canvas == FIT:
            var fit = fit_of(self.store, p.model)
            var whole = fit.total_gb if fit.present and fit.total_gb > 0 else 1.0
            Usage.themed(fit.this_gb / whole if fit.present else 0.0, fit.others_gb / whole if fit.present else 0.0, self.themed.look, pal).draw(surface)
        elif canvas >= BAR:
            surface.fill(pal.card)
            var k = canvas - BAR
            var bars = bench_bars(self.bench, p.model)
            var fr = bars[0].copy()
            var mine = bars[1].copy()
            if k < len(fr):
                BarTrack.themed(fr[k], pal, mine[k]).draw(surface)

    # ---- the screen ----

    def page(self, p: Place) -> View:
        var phone = self.phone()
        if p.page == "home":
            return PageCard([home_view(self.store, self.lib, phone)])
        if p.page == "add":
            return add_page(self.add, now_ms(), phone)
        if p.page == "keys" or p.page == "gateway" or p.page == "security" or p.page == "settings":
            var header = settings_header()
            var body: View
            if p.page == "keys":
                header = keys_header(phone)
                body = keys_view(self.kp, phone)
            elif p.page == "gateway":
                header = gateway_header(self.gp)
                body = gateway_view(self.gp, self.store, phone)
            elif p.page == "security":
                header = security_header()
                body = security_view(self.sp, self.store, phone)
            else:
                body = settings_view(self.setp, self.store, self.dark, phone)
            return PageCard([header^, Divider().fill(), Scroll(body^, height=0).grow().fill()])
        if p.page == "model":
            var k = self.store.model(p.model)
            if k < 0:
                var msg = "Loading…" if not self.store.loaded else "This model is not registered any more."
                return PageCard([CardNote(msg)])
            var model = self.store.models[k].copy()
            var body: View
            if p.tab == "benchmark":
                body = bench_view(self.bench, p.model, phone)
            elif p.tab == "logs":
                body = logs_view(self.logs, p.model, phone)
            elif p.tab == "notebook":
                body = notebook_view(self.nb, self.store, p.model, phone)
            else:
                body = overview_view(self.store, model, phone, self.copies)
            var scrolls = p.tab != "logs" and not (p.tab == "notebook" and not phone)
            return PageCard([model_header(model, p.tab, phone), Divider().fill(), Scroll(body^, height=0).grow().fill() if scrolls else body^.grow()])
        return PageCard([CardNote("Nothing here.")])

    def view(self) -> View:
        var p = self.place()
        var phone = self.phone()
        return VStack(Shell(top_bar(p, self.store, phone), self.page(p), compact=phone), Route(self.path, ROUTE), Clipboard(self.clip, self.clip_version),
                      spacing=0).align(START).fill().tag("console")
