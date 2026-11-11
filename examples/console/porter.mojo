# The porting assistant (goal 64): who writes a port for a model MAX can't run yet — Claude Code's own login, or an
# API key Claude Code signs in with (Anthropic's, or a gateway's that answers the Anthropic API). One state, one set
# of rules and one view, used on two screens: inline on the port screen (add.mojo's port card, so "Port it" with
# nothing set up is never a dead end) and as a card in Settings (D-6504). Each screen hands it its own message base
# (msgs.mojo: ADD_PORTER, SET_PORTER) so the taps and replies land in that screen's range. The key typed is sent once
# (POST /admin/porter, which makes one small test call first) and never kept here after; the daemon shows only its
# prefix back.

from mojoui.view import View
from mojoui.app import Event
from mojoui.json import Json, json_string, J_OBJECT
from mojoui.fields import OutlinedField, FieldWithHelp
from mojoui.buttons import SmallButton, ButtonRow, FILL, DANGER, TEXT
from mojoui.chip import Badge, BADGE_WARN
from mojoui.header import IconSquare
from mojoui.panel import Card, CardHead, CardBody, CardFoot, FactText, FactGrid
from mojoui.words import QuietText, WarnLine, Hint
from api import Api

comptime CLAUDE_CODE_URL = "https://docs.anthropic.com/en/docs/claude-code"

# offsets from a screen's base (its range holds P_SPAN messages)
comptime P_CLAUDE = 0  # Use Claude Code's own login
comptime P_OPEN = 1  # Give it an API key: the key fields open
comptime P_KEY = 2  # the key field's text
comptime P_BASE = 3  # the base-URL field's text
comptime P_SAVE = 4  # Check and save the key (one small test call first)
comptime P_REMOVE = 5  # Remove (Settings): DELETE /admin/porter
comptime P_GOT = 10  # GET /admin/porter: what is set up and what was detected
comptime P_GOT_SAVE = 11  # POST /admin/porter
comptime P_GOT_REMOVE = 12  # DELETE /admin/porter
comptime P_SPAN = 20


def said(event: Event) -> String:
    """The daemon's error.message, else what went wrong on the way."""
    if event.error != "":
        return event.error
    try:
        var j = Json.parse(event.text)
        var e = j.get(0, "error")
        var s = j.text(j.get(e, "message")) if j.kind(e) == J_OBJECT else j.text(e)
        if s != "":
            return s
    except:
        pass
    return "HTTP " + String(event.number)


struct Porter(Copyable, Movable):
    var stored: String  # the kind the daemon has ("" none): claude-code, anthropic, openai-compatible
    var prefix: String  # the stored key's prefix ("" none)
    var base_url: String  # the stored gateway ("" Anthropic itself)
    var found: String  # Claude Code on this machine, as the daemon detected it ("" none)
    var asked: Bool  # /admin/porter answered
    var note: String  # what went wrong last ("" nothing)
    var key: String  # what is typed in the key field (sent once, never kept after it is saved)
    var base: String  # what is typed in the base-URL field
    var open: Bool  # the key fields are showing
    var saving: Bool
    var removing: Bool

    def __init__(out self):
        self.stored = ""
        self.prefix = ""
        self.base_url = ""
        self.found = ""
        self.asked = False
        self.note = ""
        self.key = ""
        self.base = ""
        self.open = False
        self.saving = False
        self.removing = False

    def ready(self) -> Bool:
        """Set up and usable: a stored key without Claude Code is no porter (Claude Code does the work; the key only
        signs it in)."""
        return self.stored != "" and self.found != ""

    def ask(self, mut api: Api, at: Int):
        api.get(at + P_GOT, "/admin/porter")

    def forget(mut self, why: String):
        """The daemon refused a port for want of a porter: show the choice again, with why."""
        self.stored = ""
        self.asked = True
        self.note = why

    def read(mut self, text: String):
        try:
            var j = Json.parse(text)
            self.found = j.text(j.get(j.get(0, "detected"), "path"))
            self.stored = j.text(j.get(0, "kind")) if j.flag(j.get(0, "configured")) else String("")
            self.prefix = j.text(j.get(0, "key_prefix"))
            self.base_url = j.text(j.get(0, "base_url"))
        except:
            pass

    def update(mut self, k: Int, event: Event, mut api: Api, at: Int) -> Bool:
        """A tap or a reply at offset `k` of the screen's base `at`; True when a choice was just saved."""
        var failed = event.error != "" or event.number >= 400
        if k == P_CLAUDE and not self.saving:
            self.saving = True
            self.note = ""
            api.post(at + P_GOT_SAVE, "/admin/porter", '{"kind": "claude-code"}')
        elif k == P_OPEN:
            self.open = True
            self.note = ""
        elif k == P_KEY:
            self.key = event.text
        elif k == P_BASE:
            self.base = event.text
        elif k == P_SAVE and not self.saving:
            self.saving = True
            self.note = ""
            var gateway = String(self.base.strip())
            var kind = "openai-compatible" if gateway != "" else String("anthropic")
            api.post(at + P_GOT_SAVE, "/admin/porter", '{"kind": ' + json_string(kind) + ', "key": ' + json_string(String(self.key.strip()))
                     + ', "base_url": ' + json_string(gateway) + "}")
        elif k == P_REMOVE and not self.removing:
            self.removing = True
            self.note = ""
            api.send(at + P_GOT_REMOVE, "DELETE", "/admin/porter")
        elif k == P_GOT:
            self.asked = True
            if not failed:
                self.read(event.text)
        elif k == P_GOT_SAVE:
            self.saving = False
            if failed:
                self.note = said(event)
                return False
            self.asked = True
            self.read(event.text)
            if self.stored == "":
                self.stored = "claude-code"
            self.note = ""
            self.key = ""  # (sent; never kept in the app)
            self.open = False
            return True
        elif k == P_GOT_REMOVE:
            self.removing = False
            if failed:
                self.note = said(event)
            else:
                self.stored, self.prefix, self.base_url = "", "", ""
        return False


def stored_facts(p: Porter) -> Tuple[List[String], List[View]]:
    """What writes ports now, as Settings lists it: the key by its prefix only (the daemon never sends more)."""
    var keys: List[String] = ["Writes ports with"]
    var values: List[View] = []
    if p.stored == "claude-code":
        values.append(FactText("Claude Code's own login"))
    else:
        values.append(FactText("Claude Code, signed in with an API key"))
        keys.append("Key")
        values.append(FactText(p.prefix if p.prefix != "" else String("—")))
        keys.append("Answered by")
        values.append(FactText(p.base_url if p.stored == "openai-compatible" and p.base_url != "" else String("Anthropic")))
    keys.append("Claude Code")
    values.append(FactText(p.found if p.found != "" else String("not found on this machine")))
    return (keys^, values^)


def porter_choice(p: Porter, at: Int) -> List[View]:
    """The choice itself: what was detected, then Claude Code's own login or the key fields (or, with no Claude Code,
    how to get it). The port screen shows this inline in its card; Settings shows it in its own."""
    var body: List[View] = []
    if not p.asked:
        body.append(QuietText("Looking for Claude Code on this machine…"))
        return body^
    body.append(QuietText(("Porting runs Claude Code, and it is on this machine (" + p.found + "). Use its own login, "
                           + "or give it an API key: Anthropic's, or a gateway's that answers the Anthropic API.") if p.found != ""
                          else ("Porting runs Claude Code, which was not found on this machine. Install it first ("
                                + CLAUDE_CODE_URL + "), then sign in with its own login or give it an API key here.")))
    if p.note != "":
        body.append(WarnLine(p.note))
    if p.open:
        body.append(FieldWithHelp(OutlinedField(p.base, "Base URL of a gateway that answers the Anthropic API (optional: empty means Anthropic itself)", at + P_BASE, at + P_SAVE, icon="route"),
                                  "https://…, or http:// only to this machine (localhost, 127.0.0.1); never the key in the URL"))
        body.append(FieldWithHelp(OutlinedField(p.key, "API key Claude Code signs in with", at + P_KEY, at + P_SAVE, icon="key-round", secret=True),
                                  "Kept for omxconsole only, readable by you alone, never shown again and never logged. Removable at any time."))
        var row: List[View] = [SmallButton("Checking the key…" if p.saving else String("Check and save the key"), at + P_SAVE, "key-round", FILL)]
        if p.found != "":  # (a way back to the other choice)
            row.append(SmallButton("Use Claude Code's own login", at + P_CLAUDE, "sparkles", TEXT))
        body.append(ButtonRow(row^))
    elif p.found != "":
        body.append(ButtonRow([SmallButton("Saving…" if p.saving else String("Use Claude Code's own login"), at + P_CLAUDE, "sparkles", FILL),
                               SmallButton("Give it an API key", at + P_OPEN, "key-round")]))
    return body^


def porter_card(p: Porter, at: Int) -> View:
    """Settings' card: what writes ports now, with Remove, or the same choice the port screen offers."""
    var body: List[View] = []
    if p.stored != "":
        var facts = stored_facts(p)
        body.append(FactGrid(facts[0].copy(), facts[1].copy()))
        if p.found == "":
            body.append(WarnLine("Claude Code was not found, so nothing can be ported until it is installed (" + CLAUDE_CODE_URL + ")."))
        if p.note != "":
            body.append(WarnLine(p.note))
        body.append(ButtonRow([SmallButton("Removing…" if p.removing else String("Remove"), at + P_REMOVE, "trash-2", DANGER)]))
    else:
        body = porter_choice(p, at)
    body.append(Hint("Only a frontier model writes ports: your own local model is never offered. Linux only for now (the sandbox is bubblewrap)."))
    return Card([CardHead("Porting assistant", sub="for models MAX can't run yet", lead=[IconSquare("hammer", hue=1)], tail=[Badge("beta", BADGE_WARN)]),
                  CardBody(body^), CardFoot("kept for omxconsole only · the key is never shown again", note=True)])
