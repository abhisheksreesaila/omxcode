# Settings (blade-settings.js): the theme (Light or Dark; until you pick, the system's), how long an idle model stays
# loaded (per model), the daemon's own info with Stop daemon (the first tap asks, the second sends POST /admin/shutdown),
# and every port and process mxconsole owns. Data: /admin/info (core.js's poll, handed over by app.mojo; uptime keeps
# counting between polls), /admin/system (MXC_HOME, read on arrival; the listeners from system-data.js's 5 s poll), the
# Store's models.

from mojoui.view import View, Text, VStack, HStack, Spacer, CENTER, START
from mojoui.app import Event
from mojoui.effects import Every
from mojoui.json import Json
from mojoui.table import Table
from mojoui.clock import wall_seconds
from mojoui.pagekit import PageHeader, BareCard, CardHead, CardBody, CardFoot, SmallButton, QuietText, MonoLine, Fact, FactText, SegButtons
from mojoui.adminkit import StateMark, ActionButton, CopyFoot, WarnBox, GOOD, WARN, QUIET, DANGER, TEXT
from api import Api
from data import Store, dur, real_or
from msgs import *

comptime DEFAULT_KEEP_ALIVE = 300.0  # models registered without --keep-alive unload after this long
comptime COPIES: List[String] = ["mxc set <model> --keep-alive 10m", "mxc set <model> --pin", "mxc stop --all", "mxc ps"]


@fieldwise_init
struct Listener(Copyable, Movable):
    var name: String
    var address: String
    var reach: String
    var state: String
    var on: Bool
    var talks_to: String


def uptime(seconds: Float64) -> String:
    """core.js uptime: 2m 23s, 3h 4m, 2d 5h."""
    var s = Int(seconds)
    var d = s // 86400
    var hh = (s % 86400) // 3600
    var mm = (s % 3600) // 60
    if d > 0:
        return String(d) + "d " + String(hh) + "h"
    if hh > 0:
        return String(hh) + "h " + String(mm) + "m"
    return String(mm) + "m " + String(s % 60) + "s"


struct SettingsPage(Copyable, Movable):
    var has_info: Bool
    var host: String
    var endpoint: String
    var lan: String
    var max_version: String
    var uptime_seconds: Float64
    var info_at: Float64  # wall seconds when /admin/info answered
    var active_keys: String
    var home: String  # MXC_HOME ("" not yet)
    var listeners: List[Listener]
    var system_at: Bool  # /admin/system answered
    var confirming: Bool
    var stopping: Bool
    var pick: Int  # the theme picked: -1 the system's, 0 light, 1 dark

    def __init__(out self):
        self.has_info = False
        self.host = ""
        self.endpoint = ""
        self.lan = ""
        self.max_version = ""
        self.uptime_seconds = 0
        self.info_at = 0
        self.active_keys = "—"
        self.home = ""
        self.listeners = List[Listener]()
        self.system_at = False
        self.confirming = False
        self.stopping = False
        self.pick = -1

    def enter(mut self, mut api: Api):
        self.confirming = False
        api.get(GOT_SYSTEM, "/admin/system")  # (its mount reads /admin/system for MXC_HOME)

    def every(self) -> List[Every]:
        return List[Every]()

    def read_info(mut self, text: String):
        try:
            var j = Json.parse(text)
            self.host = j.text(j.get(0, "host"))
            self.endpoint = j.text(j.get(0, "endpoint"))
            self.lan = j.text(j.get(0, "lan_endpoint"))
            self.max_version = j.text(j.get(0, "max_version"))
            self.uptime_seconds = real_or(j, j.get(0, "uptime_seconds"), 0)
            var k = j.get(0, "active_keys")
            self.active_keys = String(Int(real_or(j, k, 0))) if real_or(j, k, -1) >= 0 else String("—")
            self.info_at = wall_seconds()
            self.has_info = True
        except:
            pass

    def read_system(mut self, text: String):
        """/admin/system: MXC_HOME and the listeners (portRows)."""
        try:
            var j = Json.parse(text)
            self.home = j.text(j.get(0, "home"))
            var ls = j.get(0, "listeners")
            var out = List[Listener]()
            for k in range(j.size(ls)):
                var l = j.at(ls, k)
                var state = j.text(j.get(l, "state"))
                var port = real_or(j, j.get(l, "port"), -1)
                var words = String("Listening") if state == "listening" else (String("Off") if state == "off" else (
                    String("Starting") if state == "starting" else (String("Crashed") if state == "crashed" else state)))
                out.append(Listener(j.text(j.get(l, "name")), j.text(j.get(l, "host")) + ":" + (String(Int(port)) if port >= 0 else String("—")),
                                    "your LAN" if j.flag(j.get(l, "exposed")) else "this machine", words, state == "listening", j.text(j.get(l, "talks_to"))))
            self.listeners = out^
            self.system_at = True
        except:
            pass

    def update(mut self, m: Int, event: Event, mut api: Api) -> String:
        """A tap or a reply in Settings' range; returns text to put on the clipboard ("" none)."""
        if SET_THEME <= m < SET_THEME + 2:
            self.pick = m - SET_THEME
        elif m == SET_STOP:
            self.confirming = True
        elif m == SET_CANCEL:
            self.confirming = False
        elif m == SET_STOP_SURE and not self.stopping:
            self.stopping = True
            api.post(SET_GOT_STOP, "/admin/shutdown")
        elif SET_COPY <= m < SET_COPY + 4:
            return materialize[COPIES]()[m - SET_COPY]
        elif m == SET_GOT_STOP:
            if event.error != "" or event.number >= 400:
                self.stopping = False
                self.confirming = False
        return ""


def settings_header() -> View:
    return PageHeader("sliders-horizontal", "Settings", "", "this browser and this daemon", List[View]())


def settings_view(sp: SettingsPage, st: Store, dark: Bool, phone: Bool) -> View:
    var cards: List[View] = []
    var chosen = sp.pick if sp.pick >= 0 else (1 if dark else 0)
    cards.append(BareCard([CardHead("Appearance", "kept in this browser"), CardBody([HStack(SegButtons(["Light", "Dark"], ["sun", "moon"], chosen, SET_THEME), spacing=0),
                                                                                    QuietText("Until you pick one, the console follows your system.")], spacing=10),
                           CardFoot("kept in this browser", note=True)]).fill())
    # Idle unload
    var idle: List[View] = [QuietText("A model unloads after " + dur(DEFAULT_KEEP_ALIVE) + " without a request unless you say otherwise. There is no single setting for all of them yet: it is kept per model.").width(520)]
    if len(st.models) == 0:
        idle.append(VStack(Text("No models yet").tag("strong"), QuietText("Add one and its idle time shows here."), SmallButton("Add a model", SET_ADD, "plus", filled=True),
                           spacing=8).align(CENTER).padding(26, 16).fill())
    else:
        var rows: List[View] = []
        for m in st.models:
            rows.append(Fact(m.name, FactText("pinned: never unloads" if m.pinned else "after " + dur(m.keep_alive) + " idle"), key_width=109))
        idle.append(VStack(rows^, spacing=9).align(START).fill())
    cards.append(BareCard([CardHead("Idle unload", "per model"), CardBody(idle^, spacing=4), CopyFoot(materialize[COPIES]()[0], SET_COPY), CopyFoot(materialize[COPIES]()[1], SET_COPY + 1)]).fill())
    # Daemon
    var daemon: List[View] = []
    if sp.has_info:
        var kw = 88
        var elapsed = max(0.0, wall_seconds() - sp.info_at)
        var facts: List[View] = [Fact("Host", FactText(sp.host), key_width=kw), Fact("Endpoint", FactText(sp.endpoint), key_width=kw),
                                 Fact("LAN endpoint", FactText(sp.lan if sp.lan != "" else String("off: this machine only")), key_width=kw),
                                 Fact("MAX version", FactText(sp.max_version if sp.max_version != "" else String("—")), key_width=kw),
                                 Fact("Uptime", FactText(uptime(sp.uptime_seconds + elapsed)), key_width=kw), Fact("Active keys", FactText(sp.active_keys), key_width=kw)]
        if sp.home != "":
            facts.append(Fact("MXC_HOME", FactText(sp.home), key_width=kw))
        daemon.append(VStack(facts^, spacing=9).align(START).fill())
    else:
        daemon.append(QuietText("Loading…"))
    if sp.stopping:
        daemon.append(StateMark("Stopping… the console goes offline in a moment.", WARN))
    elif sp.confirming:
        daemon.append(WarnBox([QuietText("Stop the daemon? Every model unloads and this console goes offline until you run mxc daemon (or any command that starts it) again."),
                               HStack(ActionButton("Stop daemon", SET_STOP_SURE, "square", DANGER), ActionButton("Cancel", SET_CANCEL, "", TEXT), spacing=8).align(CENTER)]))
    else:
        daemon.append(HStack(ActionButton("Stop daemon", SET_STOP, "square", DANGER), spacing=0))
    cards.append(BareCard([CardHead("Daemon"), CardBody(daemon^, spacing=16), CopyFoot(materialize[COPIES]()[2], SET_COPY + 2)]).fill())
    # Ports & processes
    var ports: List[View] = [CardHead("Ports & processes", "most listen on this machine only")]
    if len(sp.listeners) > 0:
        var cells: List[View] = []
        for l in sp.listeners:
            cells.append(FactText(l.name))
            cells.append(FactText(l.address))
            cells.append(Text(l.reach))
            cells.append(StateMark(l.state, GOOD if l.on else QUIET))
            cells.append(QuietText(l.talks_to))
        ports.append(Table(["Listener", "Address", "Reachable from", "State", "What talks to it"], cells, align="LLLLL").fill().tag("ports"))
    else:
        ports.append(QuietText("No listeners reported." if sp.system_at else "Loading…").padding(0, 16))
    ports.append(QuietText("Apps talk to the daemon, which starts one max serve per model on a loopback port. Only Caddy listens beyond this machine, and only after you make a model secure.").padding(12, 16))
    ports.append(CopyFoot(materialize[COPIES]()[3], SET_COPY + 3))
    cards.append(BareCard(ports^).fill())
    return VStack(cards^, spacing=14).align(START).padding(16, 16).fill()
