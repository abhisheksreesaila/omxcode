# API keys (blade-keys.js): every app key by its prefix, New key (the secret shown once, with Copy), Rotate (shown once;
# it says when it brings a revoked app back) and Revoke, each acting on the second tap. Each action shows its mxc twin.
# Data: GET /admin/keys (on arrival, after each action, and every 12 s while you look: "last used" moves); POST
# /admin/keys {"app"}, POST /admin/keys/<app>/rotate, DELETE /admin/keys/<app>, all with the admin key.

from mojoui.view import View, Text, Button, TextField, VStack, HStack, Spacer, ICON_ONLY, CENTER, START
from mojoui.app import Event
from mojoui.effects import Every
from mojoui.json import Json, json_string
from mojoui.http import uri_component
from mojoui.table import Table
from mojoui.lists import SideScroll
from mojoui.clock import wall_seconds
from mojoui.header import PageHeader, IconSquare, ActionGroup
from mojoui.panel import Card, CardHead, CardBody, CardFoot, CardStack, CardNote
from mojoui.buttons import SmallButton, ButtonRow, TONAL, FILL, TEXT, DANGER
from mojoui.words import QuietText, MonoLine, MonoStrong, ErrorLine, CellText
from mojoui.marks import StatusMark, GOOD, QUIET
from mojoui.copy import SecretField
from mojoui.fields import ShortField
from mojoui.feedback import EmptyState
from api import Api
from data import date_time, real_or
from msgs import *

comptime ROTATE = 0  # the armed action
comptime REVOKE = 1


@fieldwise_init
struct KeyRow(Copyable, Movable):
    var app: String
    var prefix: String
    var created_at: Float64  # 0: unknown
    var last_used_at: Float64  # 0: never
    var revoked: Bool


def ago(ts: Float64, now: Float64) -> String:
    """core.js ago: just now, 84 s ago, 2 min ago, 3 h ago, 2 d ago; never for none."""
    if ts <= 0:
        return "never"
    var sec = max(0.0, now - ts)
    if sec < 5:
        return "just now"
    if sec < 90:
        return String(Int(sec + 0.5)) + " s ago"
    if sec < 5400:
        return String(Int(sec / 60 + 0.5)) + " min ago"
    if sec < 172800:
        return String(Int(sec / 3600 + 0.5)) + " h ago"
    return String(Int(sec / 86400 + 0.5)) + " d ago"


def valid_app_name(name: String) -> Bool:
    """Letters, digits, '.', '_' and '-', starting with a letter or digit ("_" is mxconsole's own)."""
    if name.byte_length() == 0:
        return False
    var first = True
    for c in name.codepoint_slices():
        var o = ord(c)
        var alnum = (48 <= o <= 57) or (65 <= o <= 90) or (97 <= o <= 122)
        if first and not alnum:
            return False
        if not alnum and o != 46 and o != 95 and o != 45:
            return False
        first = False
    return True


struct KeysPage(Copyable, Movable):
    var rows: List[KeyRow]
    var loaded: Bool
    var error: String
    var form: Bool
    var name: String
    var form_error: String
    var busy: Bool  # Create key waits for its answer
    var secret: String  # shown once ("" hidden)
    var secret_title: String
    var secret_note: String
    var secret_twin: String
    var armed_app: String  # the button waiting for its second tap ("" none)
    var armed_act: Int

    def __init__(out self):
        self.rows = List[KeyRow]()
        self.loaded = False
        self.error = ""
        self.form = False
        self.name = ""
        self.form_error = ""
        self.busy = False
        self.secret = ""
        self.secret_title = ""
        self.secret_note = ""
        self.secret_twin = ""
        self.armed_app = ""
        self.armed_act = -1

    def enter(mut self, mut api: Api):
        self.armed_app = ""
        self.secret = ""
        api.get(KEYS_GOT_LIST, "/admin/keys")

    def every(self) -> List[Every]:
        var out: List[Every] = [Every(12000, KEYS_POLL)]
        if self.armed_app != "":
            out.append(Every(4000, KEYS_DISARM))
        return out^

    def is_armed(self, app: String, act: Int) -> Bool:
        return self.armed_app == app and self.armed_act == act

    def tap_twice(mut self, app: String, act: Int) -> Bool:
        """The second tap on the same button acts (True); the first only arms it."""
        if self.is_armed(app, act):
            self.armed_app = ""
            return True
        self.armed_app = app
        self.armed_act = act
        return False

    def show(mut self, key: String, title: String, note: String, twin: String):
        self.form_error = ""
        self.secret, self.secret_title, self.secret_note, self.secret_twin = key, title, note, twin

    def update(mut self, m: Int, event: Event, mut api: Api) -> String:
        """A tap or a reply in Keys' range; returns text to put on the clipboard ("" none)."""
        var failed = event.error != "" or event.number >= 400
        var why = event.error if event.error != "" else "HTTP " + String(event.number)
        if m == KEYS_NEW:
            self.form = not self.form
            self.form_error = ""
            if self.form:
                self.name = ""
        elif m == KEYS_CANCEL:
            self.form = False
            self.form_error = ""
        elif m == KEYS_NAME:
            self.name = event.text
        elif m == KEYS_CREATE and not self.busy:
            var app = String(self.name.strip())
            self.form_error = ""
            if not valid_app_name(app):
                self.form_error = "Use letters, digits, '.', '_' or '-', starting with a letter or digit."
            else:
                self.busy = True
                api.post(KEYS_GOT_NEW, "/admin/keys", "{\"app\": " + json_string(app) + "}")
        elif m == KEYS_DONE:
            self.secret = ""
        elif m == KEYS_COPY:
            return self.secret
        elif m == KEYS_POLL:
            api.get(KEYS_GOT_LIST, "/admin/keys")
        elif m == KEYS_DISARM:
            self.armed_app = ""
        elif KEYS_ROTATE <= m < KEYS_REVOKE:
            var k = m - KEYS_ROTATE
            if k < len(self.rows):
                var app = self.rows[k].app.copy()
                if self.tap_twice(app, ROTATE):
                    api.post(KEYS_GOT_ROTATE, "/admin/keys/" + uri_component(app) + "/rotate")
        elif KEYS_REVOKE <= m < KEYS_GOT_LIST:
            var k = m - KEYS_REVOKE
            if k < len(self.rows) and not self.rows[k].revoked:
                var app = self.rows[k].app.copy()
                if self.tap_twice(app, REVOKE):
                    api.send(KEYS_GOT_REVOKE, "DELETE", "/admin/keys/" + uri_component(app))
        elif m == KEYS_GOT_LIST:
            if failed:
                self.error = why
                return ""
            try:
                self.read(event.text)
                self.error = ""
            except e:
                self.error = String(e)
        elif m == KEYS_GOT_NEW:
            self.busy = False
            var app = String(self.name.strip())
            if failed:
                self.form_error = ("There is already a key for " + app + ". Rotate it instead.") if event.number == 409 else message_of(event.text, why)
            else:
                try:
                    var j = Json.parse(event.text)
                    self.form = False
                    self.show(j.text(j.get(0, "key")), "Key for " + app, "Copy it now. It is shown once and cannot be recovered; rotate it if you lose it.",
                              "mxc keys new " + app)
                except:
                    self.form_error = "the daemon's answer wasn't JSON"
            api.get(KEYS_GOT_LIST, "/admin/keys")
        elif m == KEYS_GOT_ROTATE:
            if not failed:
                try:
                    var j = Json.parse(event.text)
                    var app = j.text(j.get(0, "app"))
                    var note = String("Shown once. The old secret stopped working, and this brings the revoked app back to life.") if j.flag(j.get(0, "revived")) else String(
                        "Shown once. The old secret has stopped working: update the app that uses it.")
                    self.show(j.text(j.get(0, "key")), "New key for " + app, note, "mxc keys rotate " + app)
                except:
                    pass
            api.get(KEYS_GOT_LIST, "/admin/keys")
        elif m == KEYS_GOT_REVOKE:
            api.get(KEYS_GOT_LIST, "/admin/keys")
        return ""

    def read(mut self, text: String) raises:
        var j = Json.parse(text)
        var out = List[KeyRow]()
        for i in range(j.size(0)):
            var k = j.at(0, i)
            out.append(KeyRow(j.text(j.get(k, "app")), j.text(j.get(k, "prefix")), real_or(j, j.get(k, "created_at"), 0),
                              real_or(j, j.get(k, "last_used_at"), 0), real_or(j, j.get(k, "revoked_at"), 0) > 0))
        self.rows = out^
        self.loaded = True


def message_of(text: String, default: String) -> String:
    """The daemon's error message ({"error": {"message"}}), or `default`."""
    try:
        var j = Json.parse(text)
        var said = j.text(j.get(j.get(0, "error"), "message"))
        return said if said != "" else default
    except:
        return default


def keys_header(phone: Bool) -> View:
    return PageHeader("key-round", "API keys", "", "shared by every model · requests without a valid key get 401",
                      [SmallButton("New key", KEYS_NEW, "plus", FILL)], hue=4)


def keys_view(kp: KeysPage, phone: Bool) -> View:
    var now = wall_seconds()
    var cards: List[View] = []
    if kp.form:
        var body: List[View] = [ShortField(kp.name, "App name, e.g. my-app", KEYS_NAME, compact=phone)]
        if kp.form_error != "":
            body.append(ErrorLine(kp.form_error))
        body.append(ButtonRow([SmallButton("Create key", KEYS_CREATE, "plus", FILL), SmallButton("Cancel", KEYS_CANCEL, "", TEXT)]))
        cards.append(Card([CardHead("New key"), CardBody(body^), CardFoot("mxc keys new <app>")]))
    if kp.secret != "":
        var head = CardHead(kp.secret_title, lead=[IconSquare("key-round", tone=GOOD)], tail=[Button("Done", KEYS_DONE, ICON_ONLY, icon="x")])
        cards.append(Card([head^, CardBody([QuietText(kp.secret_note), SecretField(kp.secret, "Copy", KEYS_COPY)]), CardFoot(kp.secret_twin)]))
    var table: List[View] = [CardHead("Keys", "prefix only")]
    if kp.loaded and len(kp.rows) == 0 and kp.error == "":
        table.append(EmptyState("key-round", "No keys yet", "Create one for each app that calls your models.", "New key", KEYS_NEW))
    elif not kp.loaded:
        table.append(CardNote("Could not load keys: " + kp.error if kp.error != "" else "Loading…"))
    else:
        var cells: List[View] = []
        for k in range(len(kp.rows)):
            ref r = kp.rows[k]
            var active = not r.revoked
            cells.append(CellText(r.app, mono=True, strong=True))
            cells.append(CellText(r.prefix + "…", mono=True, quiet=True))
            cells.append(CellText(date_time(r.created_at) if r.created_at > 0 else String("—"), quiet=True))
            cells.append(CellText(ago(r.last_used_at, now), quiet=True))
            cells.append(StatusMark("active" if active else "revoked", GOOD if active else QUIET))
            var rot = kp.is_armed(r.app, ROTATE)
            var rev = kp.is_armed(r.app, REVOKE)
            cells.append(HStack(Spacer(), ActionGroup([SmallButton("Click again to rotate: the old key stops working now" if rot else "Rotate", KEYS_ROTATE + k, "rotate-cw", TONAL),
                                                       SmallButton("Click again to revoke" if rev else "Revoke", KEYS_REVOKE + k, "trash-2", DANGER, armed=rev, off=not active)]),
                                spacing=0).align(CENTER).fill())
        table.append(SideScroll(Table(["App", "Key", "Created", "Last used", "Status", ""], cells, align="LLLLLL").fill().tag("keys")))
    table.append(CardFoot("mxc keys ls"))
    cards.append(Card(table^))
    return CardStack(cards^)
