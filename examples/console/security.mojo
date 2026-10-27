# Security (blade-security.js): put the gateway on your LAN over HTTPS (Make it secure: POST /admin/expose, one request
# for a certificate, a key and HTTPS), see its steps, the HTTPS URL, the CA to trust and how, a curl to copy, and turn it
# off again (Stop exposing, on the second tap: POST /admin/expose/stop). Machine-wide. Data: /admin/info's lan_endpoint
# (the app's Store; read again after each change), GET /admin/network (on arrival and after each change).

from mojoui.view import View, Text, VStack, HStack, Spacer, CENTER, START
from mojoui.app import Event
from mojoui.effects import Every
from mojoui.json import Json
from mojoui.timeline import Timeline, Stage, STAGE_PENDING, STAGE_RUNNING, STAGE_DONE
from mojoui.codeblock import CodeBlock
from mojoui.header import PageHeader, IconSquare
from mojoui.panel import Card, CardHead, CardBody, CardFoot, CardStack, FactGrid, FactText, LabeledRow
from mojoui.buttons import SmallButton, ButtonRow, FILL, DANGER
from mojoui.words import QuietText, MonoLine, ErrorLine
from mojoui.marks import StatusMark, GOOD, WARN, QUIET, BAD
from mojoui.copy import CopyRow
from mojoui.feedback import Warning
from api import Api
from data import Store, real_or
from msgs import *

comptime STEP_LABELS: List[String] = ["Issue a local certificate", "Create the gateway key", "Open HTTPS on your LAN"]


def security_curl(url: String, ca: String) -> String:
    """securityView's curl: the LAN URL, the CA to trust, the app key from $MXC_API_KEY."""
    var cacert = ("--cacert " + ca + " ") if ca != "" else String("")
    return ("curl " + cacert + url + "/chat/completions \\\n  -H \"Authorization: Bearer $MXC_API_KEY\" \\\n  -H \"Content-Type: application/json\" \\\n"
            + "  -d '{\"model\":\"<model>\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")


def host_of(url: String) -> String:
    var s = url
    if url.startswith("https://"):
        s = String(url[byte=8:])
    elif url.startswith("http://"):
        s = String(url[byte=7:])
    var out = String("")
    for c in s.codepoint_slices():
        if String(c) == ":" or String(c) == "/":
            break
        out += String(c)
    return out


def file_name(path: String) -> String:
    var parts = path.split("/")
    var last = String(parts[len(parts) - 1]) if len(parts) > 0 else String("")
    return last if last != "" else String("the CA file")


struct SecurityPage(Copyable, Movable):
    var net_loaded: Bool
    var ca_path: String
    var ca_exists: Bool
    var default_host: String
    var caddy_port: Int
    var phase: String  # idle, run, done, fail
    var error: String
    var stop_armed: Bool
    var stop_busy: Bool
    var copies: Int
    var go_to: String  # a place the app should open ("" none)

    def __init__(out self):
        self.net_loaded = False
        self.ca_path = ""
        self.ca_exists = False
        self.default_host = ""
        self.caddy_port = 0
        self.phase = "idle"
        self.error = ""
        self.stop_armed = False
        self.stop_busy = False
        self.copies = 0
        self.go_to = ""

    def enter(mut self, mut api: Api):
        self.stop_armed = False
        api.get(SEC_GOT_NETWORK, "/admin/network")

    def every(self) -> List[Every]:
        var out = List[Every]()
        if self.stop_armed:
            out.append(Every(4000, SEC_DISARM))
        return out^

    def reload(self, mut api: Api):
        """core.js reads /admin/info only every 15 s: the LAN endpoint just changed, so read it (and the network) now."""
        api.get(GOT_INFO, "/admin/info")
        api.get(SEC_GOT_NETWORK, "/admin/network")

    def update(mut self, m: Int, event: Event, mut api: Api, st: Store) -> String:
        """A tap or a reply in Security's range; returns text to put on the clipboard ("" none)."""
        var failed = event.error != "" or event.number >= 400
        var secure = st.lan_endpoint != ""
        if m == SEC_SECURE and self.phase != "run" and not secure:
            self.phase = "run"
            self.error = ""
            api.post(SEC_GOT_EXPOSE, "/admin/expose", "{}")
        elif m == SEC_STOP and not self.stop_busy:
            if not self.stop_armed:  # the second tap confirms
                self.stop_armed = True
            else:
                self.stop_armed = False
                self.stop_busy = True
                api.post(SEC_GOT_STOP, "/admin/expose/stop")
        elif m == SEC_DISARM:
            self.stop_armed = False
        elif m == SEC_KEYS:
            self.go_to = "/keys"
        elif m == SEC_COPY_URL:
            return st.lan_endpoint
        elif m == SEC_COPY_CA:
            return self.ca_path
        elif m == SEC_COPY_CURL:
            self.copies += 1
        elif m == SEC_GOT_EXPOSE:
            if failed:
                self.phase = "fail"
                self.error = message_or(event)
            else:
                self.phase = "done"
            self.reload(api)
        elif m == SEC_GOT_STOP:
            self.phase = "idle"
            self.stop_busy = False
            self.reload(api)
        elif m == SEC_GOT_NETWORK and not failed:
            try:
                var j = Json.parse(event.text)
                self.ca_path = j.text(j.get(0, "ca_path"))
                self.ca_exists = j.flag(j.get(0, "ca_exists"))
                self.default_host = j.text(j.get(0, "default_host"))
                self.caddy_port = Int(real_or(j, j.get(j.get(0, "ports"), "caddy"), 0))
                self.net_loaded = True
            except:
                pass
        return ""


def message_or(event: Event) -> String:
    try:
        var j = Json.parse(event.text)
        var said = j.text(j.get(j.get(0, "error"), "message"))
        if said != "":
            return said
    except:
        pass
    return event.error if event.error != "" else "HTTP " + String(event.number)


def security_header() -> View:
    return PageHeader("lock", "Security", "", "certificate, key and HTTPS on your LAN", List[View](), hue=4)


def security_view(sp: SecurityPage, st: Store, phone: Bool) -> View:
    var url = st.lan_endpoint
    var secure = url != ""
    var running = sp.phase == "run" or sp.phase == "done"
    var host = host_of(url) if secure else sp.default_host
    var title = String("Making it secure…") if sp.phase == "run" else (String("Secure on your network") if secure else String("Localhost only"))
    var text = String("adding a certificate, a key and HTTPS") if sp.phase == "run" else (
        String("HTTPS with a key. Other devices on your Wi-Fi can call it.") if secure else String("Only this machine can call it. One click adds a certificate, a key and HTTPS."))
    var word = String("working") if sp.phase == "run" else (String("secure") if secure else String("localhost only"))
    var head = CardHead(title, sub=text, lead=[IconSquare("lock" if secure else "unlock", tone=GOOD if secure else WARN)],
                        tail=[StatusMark(word, WARN if sp.phase == "run" else (GOOD if secure else QUIET))])
    var body: List[View] = []
    if running:
        var metas: List[String] = [("for " + host) if host != "" else String(""), "mxc gateway key", ("port " + String(sp.caddy_port)) if sp.caddy_port > 0 else String("")]
        var stages: List[Stage] = []
        for k in range(3):
            stages.append(Stage(materialize[STEP_LABELS]()[k], STAGE_DONE if sp.phase == "done" else STAGE_RUNNING, -1, metas[k]))
        body.append(Timeline(stages^).fill())
    if sp.phase == "fail":
        body.append(Warning([ErrorLine("Could not make it secure: " + sp.error)]))
    if secure:
        body.append(ButtonRow([SmallButton("Manage API keys", SEC_KEYS, "key-round"),
                               SmallButton("Click again to stop exposing" if sp.stop_armed else "Stop exposing", SEC_STOP, "unlock", DANGER, armed=sp.stop_armed, off=sp.stop_busy)]))
    else:
        body.append(ButtonRow([SmallButton("Try again" if sp.phase == "fail" else "Make it secure", SEC_SECURE, "lock", FILL)]))
    var cards: List[View] = [Card([head^, CardBody(body^), CardFoot("mxc expose --stop" if secure else "mxc expose")])]
    cards.append(Card([CardHead("What “Make it secure” does"), CardBody([FactGrid(["Certificate", "API key", "HTTPS"], [
        FactText("a local CA, “mxconsole local”, signs a certificate for this machine's name", plain=True),
        FactText("the gateway has its own key; requests without a valid app key get 401", plain=True),
        FactText("Caddy and LiteLLM listen on your LAN; localhost keeps working over HTTP", plain=True)])]),
        CardFoot("all three happen in one request", note=True)]))
    if secure:
        cards.append(Card([CardHead("Endpoint"), CardBody([CopyRow("https · lan", url, SEC_COPY_URL, "Copy")]), CardFoot("mxc status")]))
        var file = file_name(sp.ca_path)
        var trust: List[View] = [QuietText("Other devices need to trust the mxconsole CA once, or HTTPS calls fail with a certificate error. This machine already knows it."
                                           if sp.ca_exists else "The CA file is created the first time Caddy starts; it is not there yet."),
                                 CopyRow("ca", sp.ca_path if sp.ca_path != "" else String("—"), SEC_COPY_CA, "Copy" if sp.ca_path != "" else "")]
        var oses: List[String] = ["Linux", "macOS", "Windows", "iPhone, Android"]
        var hows: List[String] = ["sudo cp " + file + " /usr/local/share/ca-certificates/mxconsole.crt && sudo update-ca-certificates",
                                  "Open " + file + " in Keychain Access, then set it to Always Trust",
                                  "Double-click " + file + ", install it into Trusted Root Certification Authorities",
                                  "Send " + file + " to the phone, install it as a profile or CA certificate, then trust it in settings"]
        for k in range(4):
            trust.append(LabeledRow(oses[k], MonoLine(hows[k]), compact=phone))
        cards.append(Card([CardHead("Trust the certificate"), CardBody(trust^), CardFoot("trust it once on each device", note=True)]))
        cards.append(Card([CardHead("From another device on your Wi-Fi"), CardBody([CodeBlock(security_curl(url, sp.ca_path), on_copy=SEC_COPY_CURL, copies=sp.copies,
                                                                                              title="copy").fill()]),
                           CardFoot("replace <model> with a model name", note=True)]))
    return CardStack(cards^)
