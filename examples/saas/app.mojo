# saas: a tiny native client of the saas server (goal 57): sign in with Google in the system browser (mojoui.signin,
# RFC 8252), keep entries in your tenant's own SQLite on the server, upgrade to Pro through Stripe Checkout
# (mojoui.billing on the server). Everything here is framework pieces: Browser (open_url), DesktopSignIn, Http.
#   scripts/saas.sh run &                     # the server (keys from ~/.config/omxcode/saas.env)
#   scripts/build.sh saas linux && SAAS_SERVER=http://127.0.0.1:8000 build/saas/linux/saas

from mojoui import App, Event, View, VStack, HStack, Text, Button, TextField, TITLE, CAPTION, PROMINENT, BETWEEN
from mojoui.http import Http, Request
from mojoui.effects import Every
from mojoui.browser import Browser
from mojoui.signin import DesktopSignIn
from mojoui.json import Json, json_string
from mojoui.shared import environment
from mojoui.clock import wall_seconds
from mojoui.theme import Theme
from themes.liquid import liquid

comptime SIGN_IN = 1
comptime WAIT_BROWSER = 2  # a timer while the browser is out: has the loopback got its code?
comptime GOT_TOKEN = 3
comptime GOT_ME = 4
comptime NOTE = 5
comptime AMOUNT = 6
comptime ADD = 7
comptime ADDED = 8
comptime GOT_ENTRIES = 9
comptime UPGRADE = 10
comptime GOT_CHECKOUT = 11
comptime SIGN_OUT = 12
comptime SIGNED_OUT = 13
comptime WAIT_PLAN = 14  # a timer while checkout is out: has the plan changed?
comptime MANAGE = 15
comptime GOT_PORTAL = 16
comptime UPGRADE_WAIT_MS = 600_000  # stop asking for the plan this long after checkout opened (an abandoned checkout)


@fieldwise_init
struct Entry(Copyable, Movable):
    var text: String
    var cents: Int


def cents_of(text: String) -> Int:
    """"4.50" → 450, "12" → 1200, "0.5" → 50; -1 when it isn't an amount."""
    var s = String(text.strip())
    var whole = 0
    var frac = 0
    var frac_digits = 0
    var digits = 0
    var dot = False
    if s.byte_length() == 0:
        return -1
    for b in s.as_bytes():
        if b == 46 and not dot:
            dot = True
        elif b >= 48 and b <= 57:
            digits += 1
            if dot:
                if frac_digits == 2:
                    return -1
                frac = frac * 10 + Int(b - 48)
                frac_digits += 1
            else:
                whole = whole * 10 + Int(b - 48)
                if whole > 10_000_000:
                    return -1
        else:
            return -1
    if digits == 0:  # (".")
        return -1
    if frac_digits == 1:
        frac *= 10
    return whole * 100 + frac


def safe_server(url: String) -> Bool:
    """https://, or http:// on this machine only (the bearer token goes to it)."""
    return url.startswith("https://") or url.startswith("http://127.0.0.1:") or url.startswith("http://[::1]:") or url.startswith("http://localhost:")


def money(cents: Int) -> String:
    var c = cents % 100
    return "$" + String(cents // 100) + "." + ("0" if c < 10 else "") + String(c)


struct Main(App):
    comptime HTTP = True
    var http: Http
    var browser: Browser
    var server: String
    var signing: Optional[DesktopSignIn]
    var token: String  # the bearer token: in memory only, never in a view
    var email: String
    var plan: String
    var trial_ends: Int
    var role: String
    var note: String
    var amount: String
    var entries: List[Entry]
    var upgrading: Bool
    var upgrade_ticks: Int  # WAIT_PLAN ticks since checkout opened
    var status: String

    def __init__(out self):
        self.http = Http()
        self.browser = Browser()
        self.server = environment("SAAS_SERVER", "http://127.0.0.1:8000")
        self.signing = None
        self.token = ""
        self.email = ""
        self.plan = ""
        self.trial_ends = 0
        self.role = ""
        self.note = ""
        self.amount = ""
        self.entries = List[Entry]()
        self.upgrading = False
        self.upgrade_ticks = 0
        self.status = ""
        if not safe_server(self.server):
            self.status = "SAAS_SERVER must be https:// (or http:// on 127.0.0.1): the sign-in token would travel in the clear."
            self.server = ""

    def title(self) -> String:
        return "omxcode SaaS"

    def theme(self) -> Theme:
        return liquid()

    def window_size(self) -> Tuple[Int, Int]:
        return (440, 600)

    def requests(mut self) -> List[Request]:
        return self.http.take()

    def opens(mut self) -> List[String]:
        return self.browser.take()

    def every(self) -> List[Every]:
        var out = List[Every]()
        if self.signing:
            out.append(Every(100, WAIT_BROWSER))
        if self.upgrading:
            out.append(Every(1000, WAIT_PLAN))
        return out^

    def authed(self, var r: Request) -> Request:
        return r^.header("Authorization", "Bearer " + self.token)

    def update(mut self, e: Event):
        var m = e.message
        if m == SIGN_IN:
            if self.server == "":
                return
            try:
                var s = DesktopSignIn(self.server)
                self.browser.open(s.url)
                self.signing = s^
                self.status = "Finish signing in in your browser…"
            except err:
                self.status = "Can't start the sign-in: " + String(err)
        elif m == WAIT_BROWSER and self.signing:
            var code = self.signing.value().code()
            if code != "":
                self.http.send(self.signing.value().token_request(GOT_TOKEN, code))
                self.signing = None
            elif self.signing.value().failed():
                self.signing = None
                self.status = "The sign-in timed out: try again."
        elif m == GOT_TOKEN:
            var t = self.field(e, "token")
            if e.number != 200 or t == "":
                self.status = "The server refused the sign-in (" + String(e.number) + ")."
                return
            self.token = t
            self.http.send(self.authed(Request.get(GOT_ME, self.server + "/api/me")))
        elif m == GOT_ME:
            if e.number == 401:
                self.signed_out("Signed out.")
                return
            if e.number != 200:
                return
            self.email = self.field(e, "email")
            self.role = self.field(e, "role")
            var plan = self.field(e, "plan")
            self.trial_ends = self.number(e, "trial_ends")
            if plan == "pro" and self.upgrading:
                self.upgrading = False
                self.status = "Welcome to Pro."
            elif self.status.startswith("Finish signing in"):
                self.status = ""
            if self.plan == "":
                self.http.send(self.authed(Request.get(GOT_ENTRIES, self.server + "/api/entries")))
            self.plan = plan
        elif m == NOTE:
            self.note = e.text
        elif m == AMOUNT:
            self.amount = e.text
        elif m == ADD:
            var cents = cents_of(self.amount)
            var text = String(self.note.strip())
            if text == "" or cents < 0:
                self.status = "An entry needs a note and an amount like 4.50."
                return
            self.http.send(self.authed(Request.post_json(ADDED, self.server + "/api/entries", '{"text": ' + json_string(text) + ', "amount_cents": ' + String(cents) + "}")))
            self.note = ""
            self.amount = ""
        elif m == ADDED:
            self.status = "" if e.number == 201 else ("Viewers can't add entries." if e.number == 403 else "The server refused it (" + String(e.number) + ").")
            self.http.send(self.authed(Request.get(GOT_ENTRIES, self.server + "/api/entries")))
        elif m == GOT_ENTRIES:
            if e.number != 200:
                return
            try:
                var j = Json.parse(e.text)
                var list = j.get(0, "entries")
                var out = List[Entry]()
                for k in range(j.size(list)):
                    var row = j.at(list, k)
                    out.append(Entry(j.text(j.get(row, "text")), j.number(j.get(row, "amount_cents"))))
                self.entries = out^
            except:
                pass
        elif m == UPGRADE:
            self.http.send(self.authed(Request(GOT_CHECKOUT, "POST", self.server + "/billing/checkout")))
        elif m == GOT_CHECKOUT:
            var url = self.field(e, "url")
            if e.number != 200 or url == "":
                self.status = "Checkout isn't available (" + String(e.number) + ")."
                return
            self.browser.open(url)
            self.upgrading = True
            self.upgrade_ticks = 0
            self.status = "Finish checkout in your browser…"
        elif m == WAIT_PLAN:
            self.upgrade_ticks += 1
            if self.upgrade_ticks * 1000 > UPGRADE_WAIT_MS:
                self.upgrading = False
                self.status = "Checkout wasn't finished: Upgrade again when you're ready."
                return
            self.http.send(self.authed(Request.get(GOT_ME, self.server + "/api/me")))
        elif m == MANAGE:  # (Stripe's portal: cards, invoices, cancel; with no card yet, the checkout)
            self.http.send(self.authed(Request(GOT_PORTAL, "POST", self.server + "/billing/portal")))
        elif m == GOT_PORTAL:
            var url = self.field(e, "url")
            if e.number == 409:
                self.http.send(self.authed(Request(GOT_CHECKOUT, "POST", self.server + "/billing/checkout")))
                return
            if e.number != 200 or url == "":
                self.status = "Billing isn't available (" + String(e.number) + ")."
                return
            self.browser.open(url)
            self.status = "Manage billing in your browser…"
        elif m == SIGN_OUT:
            self.http.send(self.authed(Request(SIGNED_OUT, "POST", self.server + "/logout")))
        elif m == SIGNED_OUT:
            self.signed_out("Signed out.")

    def signed_out(mut self, why: String):
        self.token = ""
        self.email = ""
        self.plan = ""
        self.role = ""
        self.entries = List[Entry]()
        self.upgrading = False
        self.status = why

    def number(self, e: Event, name: String) -> Int:
        try:
            var j = Json.parse(e.text)
            return j.number(j.get(0, name))
        except:
            return 0

    def plan_line(self) -> String:
        if self.plan == "pro":
            return "Plan: Pro"
        if self.plan == "trial":
            var days = max((self.trial_ends - Int(wall_seconds()) + 86399) // 86400, 0)
            return "Plan: Trial · " + String(days) + (" day left" if days == 1 else " days left")
        if self.plan == "past_due":
            return "Plan: Pro · payment due"
        return "Plan: Free"

    def field(self, e: Event, name: String) -> String:
        try:
            var j = Json.parse(e.text)
            return j.text(j.get(0, name))
        except:
            return ""

    def view(self) -> View:
        var status = Text(self.status, style=CAPTION).fill()
        if self.email == "":
            return VStack(
                Text("omxcode SaaS", style=TITLE),
                Text("Your entries, in your own tenant. Sign in with your Google account.", style=CAPTION).fill(),
                Button("Sign in with Google", on_tap=SIGN_IN, style=PROMINENT),
                status^,
                spacing=16,
            ).padding(24).width(440)
        var rows = List[View]()
        var total = 0
        for k in range(len(self.entries)):
            ref en = self.entries[k]
            total += en.cents
            rows.append(HStack(Text(en.text), Text(money(en.cents)), spacing=8).fill().justify(BETWEEN))  # (a row: the note left, its amount right)
        if len(rows) == 0:
            rows.append(Text("No entries yet", style=CAPTION))
        var pro = self.plan == "pro"
        var plan_button = Button("Manage plan", on_tap=MANAGE) if pro else (
            Button("Manage billing", on_tap=MANAGE, style=PROMINENT) if self.plan == "trial" or self.plan == "past_due" else Button("Upgrade", on_tap=UPGRADE, style=PROMINENT))
        return VStack(
            HStack(Text("omxcode SaaS", style=TITLE), Button("Sign out", on_tap=SIGN_OUT), spacing=8).fill().justify(BETWEEN),
            Text("Signed in as " + self.email, style=CAPTION).fill(),
            HStack(
                Text(self.plan_line()),
                plan_button^,
                spacing=8,
            ).fill().justify(BETWEEN),
            HStack(
                TextField(self.note, placeholder="Note", on_change=NOTE, on_submit=ADD).grow(),
                TextField(self.amount, placeholder="Amount", on_change=AMOUNT, on_submit=ADD).width(110),
                Button("Add", on_tap=ADD),
                spacing=8,
            ).fill(),
            VStack(rows^, spacing=6).fill(),
            Text(String(len(self.entries)) + (" entry · " if len(self.entries) == 1 else " entries · ") + money(total), style=CAPTION).fill(),
            status^,
            spacing=14,
        ).padding(24).width(440)
