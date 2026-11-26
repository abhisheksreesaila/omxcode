# mojoui.personalize: a person changes the app's own look a little by asking ("make it darker", "use the mascot instead of
# the orb", "keep the scores bigger", "put it back"). Small, bounded changes only (owner, 2026-11-25): no theme picker, no
# makeover, no arbitrary colour or code. Four settings, each with a fixed set of values:
#
#   scheme     auto (light or dark as the system is: the default, unchanged) | light | dark | night (opt-in: dark from 19:00
#              to 7:00 by the app's clock, else as the system is)
#   accent     default (the theme's own accent) | violet | blue | teal | orange | red | gold: the theme palette's own
#              series colours (Palette.series 0..5), never a colour from outside it
#   presence   orb | mascot (mojoui.mascot.Presence switches between them, with a crossfade)
#   density    compact (up to six tiles on a Stage: today's) | roomy (at most four, so each is bigger)
#
# per person (the Stage's top bar: All, A, S, M), with an undo stack ("put it back"), kept as one small JSON file per person
# under the app's data folder. Every change is meant to be shown with a liquid transition (mojoui.transition.Morph).
#
#   var look = Personalize("omx")                           # $MOJOUI_LOOK, else $XDG_DATA_HOME (~/.local/share)/mojoui/look/omx
#   var look = Personalize("stage", dir="")                 # in memory only (a demo whose pictures checks compare)
#   look.use_profile("a")                                   # the person: their saved look (defaults the first time)
#   var c = look.ask('{"set":{"presence":"mascot","scheme":"dark"}}')   # the agent's call; or look.undo(), look.set(key, value)
#   if c.ok and len(c.changed) > 0: morph.morph(); apply look.prefs   # mojoui.transition: the host blends old into new
#   agent.answer(call.id, c.result())                       # what changed (or why not), in a sentence the model can pass on
#   LlmAgent.add_deferred(PERSONALIZE, PERSONALIZE_ABOUT, PERSONALIZE_PARAMS)   # or personalize_tool() for an AG-UI client
#   look_knobs(look.prefs, KNOBS, look.can_undo())          # the same four knobs and "Put it back" for touch (a Popover's body)
#   var c = look.knob(event, KNOBS)                         # a knob's event (KNOBS + 0 … 4)
#   scheme_dark(look.prefs, system_dark, hour) · is_night(hour) · accent_colour(palette, look.prefs.accent) · stage_most(look.prefs, 6)

from std.os import makedirs
from std.os.path import exists
from mojoui.agui import Tool
from mojoui import libc
from mojoui.json import Json, J_OBJECT, J_STRING, J_BOOL, json_string
from mojoui.shared import environment
from mojoui.theme import Palette
from mojoui.view import View, VStack, HStack, Text, Segmented, Button, CAPTION, START, CENTER, SPACE_S, SPACE_XS, SUBTLE

comptime PERSONALIZE = "personalize"
comptime UNDO_MAX = 12  # the changes "put it back" can undo, per person
comptime KNOB_SCHEME = 0  # look_knobs' messages: base + these
comptime KNOB_ACCENT = 1
comptime KNOB_PRESENCE = 2
comptime KNOB_DENSITY = 3
comptime KNOB_UNDO = 4
comptime KNOB_COUNT = 5
comptime NIGHT_FROM = 19  # scheme auto: night from 19:00 …
comptime NIGHT_UNTIL = 7  # … to 7:00
comptime ROOMY_MOST = 4  # density roomy: at most this many tiles on a Stage (livetiles' preset(4): l l w w)

comptime PERSONALIZE_ABOUT = (
    "Change this person's look a little, only when they ask (\"make it darker\", \"use the mascot instead of the orb\", "
    "\"keep the scores bigger\", \"make it blue\", \"dark at night\", \"put it back\"). set: one or more of scheme (auto: as the "
    "system is | light | dark | night: dark from 7 pm to 7 am), "
    "accent (default | violet | blue | teal | orange | red | gold: the theme's own colours only), presence (orb | mascot: who "
    "listens in the chat bar), density (compact: up to six tiles | roomy: fewer, bigger tiles). undo: true puts the last change "
    "back. Change only the settings the person named, never others, and all of them in one call. Nothing else can change: no other "
    "colours, sizes or code. The result says what changed, or why not, in a sentence to pass on."
)
comptime PERSONALIZE_PARAMS = (
    '{"type":"object","properties":{'
    '"set":{"type":"object","properties":{'
    '"scheme":{"type":"string","enum":["auto","light","dark","night"]},'
    '"accent":{"type":"string","enum":["default","violet","blue","teal","orange","red","gold"]},'
    '"presence":{"type":"string","enum":["orb","mascot"]},'
    '"density":{"type":"string","enum":["compact","roomy"]}},'
    '"description":"the settings to change (leave out the rest)"},'
    '"undo":{"type":"boolean","description":"true: put the last change back"}}}'
)


def personalize_tool() -> Tool:
    """The `personalize` agent tool for an AG-UI client (LlmAgent: add_deferred(PERSONALIZE, PERSONALIZE_ABOUT, PERSONALIZE_PARAMS))."""
    return Tool(PERSONALIZE, PERSONALIZE_ABOUT, PERSONALIZE_PARAMS)


# ------------------------------------------------------------------------------------------------ the settings


def look_keys() -> List[String]:
    return ["scheme", "accent", "presence", "density"]


def look_values(key: String) -> List[String]:
    """The values `key` may take, its default first ([] for a key that isn't a setting)."""
    if key == "scheme":
        return ["auto", "light", "dark", "night"]
    if key == "accent":
        return ["default", "violet", "blue", "teal", "orange", "red", "gold"]
    if key == "presence":
        return ["orb", "mascot"]
    if key == "density":
        return ["compact", "roomy"]
    return List[String]()


def look_labels(key: String) -> List[String]:
    """The values as a knob shows them."""
    var out = List[String]()
    for v in look_values(key):
        var b = v.as_bytes()
        var first = String(chr(Int(b[0]) - 32)) if b[0] >= 97 and b[0] <= 122 else String(v[byte = 0 : 1])
        out.append(first + String(v[byte = 1 :]))
    return out^


def _say_value(key: String, value: String) -> String:
    """A value as a sentence names it."""
    if key == "scheme":
        if value == "night":
            return "dark at night (7 pm to 7 am)"
        return "the dark look" if value == "dark" else ("the light look" if value == "light" else "light or dark as the system is")
    if key == "accent":
        return "the theme's own accent" if value == "default" else value + " as the accent"
    if key == "presence":
        return "the mascot instead of the orb" if value == "mascot" else "the orb"
    if key == "density":
        return "fewer, bigger tiles" if value == "roomy" else "up to six tiles"
    return value


def _synonym(key: String, value: String) -> String:
    """A few words people use for a value (the model passes them through sometimes): the value they mean, else as given."""
    var v = String(value.strip()).lower()
    if key == "scheme":
        if v == "night" or v == "darker" or v == "black":
            return "dark"
        if v == "day" or v == "lighter" or v == "white" or v == "bright":
            return "light"
        if v == "system" or v == "automatic" or v == "default":
            return "auto"
        if v == "nightly" or v == "at night" or v == "dark at night" or v == "evening" or v == "time" or v == "by the clock":
            return "night"
    elif key == "accent":
        if v == "purple" or v == "indigo":
            return "violet"
        if v == "yellow" or v == "amber":
            return "gold"
        if v == "ink" or v == "none" or v == "normal" or v == "auto":
            return "default"
    elif key == "presence":
        if v == "companion" or v == "character" or v == "pet" or v == "avatar":
            return "mascot"
        if v == "ball" or v == "circle" or v == "sphere":
            return "orb"
    elif key == "density":
        if v == "bigger" or v == "big" or v == "large" or v == "spacious" or v == "fewer" or v == "less":
            return "roomy"
        if v == "dense" or v == "smaller" or v == "small" or v == "more" or v == "default" or v == "normal":
            return "compact"
    return v


def _one_of(values: List[String]) -> String:
    var out = String("")
    for i in range(len(values)):
        out += ("" if i == 0 else (" or " if i == len(values) - 1 else ", ")) + values[i]
    return out


def look_check(key: String, value: String) -> String:
    """"" when `value` is one `key` may take; else why not, as a sentence."""
    var allowed = look_values(key)
    if len(allowed) == 0:
        return "I can only change the scheme, the accent, the presence or the density, not " + key + "."
    for a in allowed:
        if a == value:
            return ""
    if key == "accent":
        return "The accent can only be one of the theme's own colours: " + _one_of(allowed) + " (not " + value + ")."
    return "The " + key + " can only be " + _one_of(allowed) + " (not " + value + ")."


struct LookPrefs(Copyable, Movable):
    """One person's look: the four settings (each one of look_values(key))."""

    var scheme: String
    var accent: String
    var presence: String
    var density: String

    def __init__(out self):
        self.scheme = "auto"
        self.accent = "default"
        self.presence = "orb"
        self.density = "compact"

    def get(self, key: String) -> String:
        if key == "scheme":
            return self.scheme
        if key == "accent":
            return self.accent
        if key == "presence":
            return self.presence
        if key == "density":
            return self.density
        return ""

    def put(mut self, key: String, value: String):
        """Sets `key` (callers check the value first: look_check)."""
        if key == "scheme":
            self.scheme = value
        elif key == "accent":
            self.accent = value
        elif key == "presence":
            self.presence = value
        elif key == "density":
            self.density = value

    def same(self, other: LookPrefs) -> Bool:
        return self.scheme == other.scheme and self.accent == other.accent and self.presence == other.presence and self.density == other.density

    def is_default(self) -> Bool:
        return self.same(LookPrefs())

    def json(self) -> String:
        return ('{"scheme":' + json_string(self.scheme) + ',"accent":' + json_string(self.accent) + ',"presence":' + json_string(self.presence)
                + ',"density":' + json_string(self.density) + "}")

    def index(self, key: String) -> Int:
        """The value's place in look_values(key) (0: the default)."""
        var vs = look_values(key)
        var v = self.get(key)
        for i in range(len(vs)):
            if vs[i] == v:
                return i
        return 0


def _prefs_from(j: Json, node: Int) -> LookPrefs:
    """The settings an object holds (a value off the list keeps its default: a hand-edited file can't smuggle one in)."""
    var p = LookPrefs()
    for key in look_keys():
        var n = j.get(node, key)
        if n >= 0 and j.kind(n) == J_STRING:
            var v = j.text(n)
            if look_check(key, v) == "":
                p.put(key, v)
    return p^


# ------------------------------------------------------------------------------------------------ what a change did


struct LookChange(Copyable, Movable):
    """What one request did: ok (False: refused, nothing changed), the keys that changed, the look before and after, and a
    sentence for the person (the model passes it on)."""

    var ok: Bool
    var undo: Bool
    var changed: List[String]
    var before: LookPrefs
    var after: LookPrefs
    var message: String

    def __init__(out self, ok: Bool, message: String, before: LookPrefs, after: LookPrefs, undo: Bool = False):
        self.ok = ok
        self.undo = undo
        self.message = message
        self.before = before.copy()
        self.after = after.copy()
        self.changed = List[String]()
        for key in look_keys():
            if before.get(key) != after.get(key):
                self.changed.append(key)

    def moved(self) -> Bool:
        """Something on screen changes (a transition is due)."""
        return self.ok and len(self.changed) > 0

    def result(self) -> String:
        """The tool's result (JSON): ok, what changed (from → to), the look now, and the sentence."""
        var ch = String("[")
        for i in range(len(self.changed)):
            var k = self.changed[i]
            ch += ("," if i > 0 else "") + '{"setting":' + json_string(k) + ',"from":' + json_string(self.before.get(k)) + ',"to":' + json_string(self.after.get(k)) + "}"
        ch += "]"
        if not self.ok:
            return '{"ok":false,"refused":' + json_string(self.message) + ',"now":' + self.after.json() + "}"
        return '{"ok":true,"changed":' + ch + ',"now":' + self.after.json() + ',"say":' + json_string(self.message) + "}"


def _done_sentence(c: LookChange) -> String:
    if len(c.changed) == 0:
        return "That's how it already is."
    var parts = List[String]()
    for k in c.changed:
        parts.append(_say_value(k, c.after.get(k)))
    var head = String("Put back: ") if c.undo else String("Done: ")
    var out = String("")
    for i in range(len(parts)):
        out += ("" if i == 0 else (" and " if i == len(parts) - 1 else ", ")) + parts[i]
    return head + out + "."


# ------------------------------------------------------------------------------------------------ the store


def look_dir(app: String) -> String:
    """Where an app keeps its people's looks: $MOJOUI_LOOK (a folder), else $XDG_DATA_HOME (or ~/.local/share)/mojoui/look/<app>."""
    var own = environment("MOJOUI_LOOK")
    if own != "":
        return own
    var data = environment("XDG_DATA_HOME")
    if data == "":
        data = environment("HOME") + "/.local/share"
    return data + "/mojoui/look/" + app


def is_profile_name(name: String) -> Bool:
    """A person's name as a file name: one word of a-z, 0-9, _ or - (1 to 24 bytes): never a path."""
    var n = name.byte_length()
    if n < 1 or n > 24:
        return False
    for b in name.as_bytes():
        var c = Int(b)
        if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45):
            return False
    return True


struct Personalize(Movable):
    """The people's looks: the current person's settings (prefs), their undo stack, and a JSON file per person (dir; "" keeps
    them in memory only). serial goes up with every change (an app redraws what depends on it)."""

    var app: String
    var dir: String
    var profile: String
    var prefs: LookPrefs
    var undos: List[LookPrefs]  # the current person's, oldest first
    var serial: Int
    var error: String  # why the last save failed ("" when it didn't)
    var _grouping: Bool  # begin_group(): the changes until end_group() are one undo step
    var _grouped: Bool  # (that step is on the stack already)
    var _names: List[String]  # every person met this run, with their look and undo stack
    var _prefs: List[LookPrefs]
    var _undos: List[List[LookPrefs]]

    def __init__(out self, app: String, dir: String = "-"):
        """`dir`: "-" (the default) is look_dir(app); "" keeps the looks in memory only."""
        self.app = app
        self.dir = look_dir(app) if dir == "-" else dir
        self.profile = ""
        self.prefs = LookPrefs()
        self.undos = List[LookPrefs]()
        self.serial = 0
        self.error = ""
        self._grouping = False
        self._grouped = False
        self._names = List[String]()
        self._prefs = List[LookPrefs]()
        self._undos = List[List[LookPrefs]]()
        self.use_profile("all")

    def path(self, profile: String) -> String:
        return self.dir + "/" + profile + ".json" if self.dir != "" else String("")

    def use_profile(mut self, name: String) -> Bool:
        """The look of person `name` ("all", "a", …) from now on: kept from earlier this run, else their file, else the
        defaults. False (nothing changes) for a name that isn't one word."""
        var who = name.lower()
        if not is_profile_name(who):
            return False
        if who == self.profile:
            return True
        self._keep()
        self.profile = who
        for i in range(len(self._names)):
            if self._names[i] == who:
                self.prefs = self._prefs[i].copy()
                self.undos = self._undos[i].copy()
                self.serial += 1
                return True
        self.prefs = LookPrefs()
        self.undos = List[LookPrefs]()
        self._load()
        self._keep()
        self.serial += 1
        return True

    def _keep(mut self):
        """The current person's look into the run's memory."""
        if self.profile == "":
            return
        for i in range(len(self._names)):
            if self._names[i] == self.profile:
                self._prefs[i] = self.prefs.copy()
                self._undos[i] = self.undos.copy()
                return
        self._names.append(self.profile)
        self._prefs.append(self.prefs.copy())
        self._undos.append(self.undos.copy())

    def _load(mut self):
        var p = self.path(self.profile)
        if p == "" or not exists(p):
            return
        try:
            var text: String
            with open(p, "r") as f:
                text = f.read()
            var j = Json.parse(text)
            if j.kind(0) != J_OBJECT:
                return
            self.prefs = _prefs_from(j, 0)
            var u = j.get(0, "undo")
            for i in range(j.size(u)):
                var n = j.at(u, i)
                if j.kind(n) == J_OBJECT:
                    self.undos.append(_prefs_from(j, n))
            while len(self.undos) > UNDO_MAX:
                _ = self.undos.pop(0)
        except:
            pass  # (a damaged file: the defaults; the next change writes a good one)

    def save(mut self) -> Bool:
        """The current person's look and undo stack to their file (nothing to do in memory-only mode)."""
        self._keep()
        var p = self.path(self.profile)
        if p == "":
            return True
        var undo = String("[")
        for i in range(len(self.undos)):
            undo += ("," if i > 0 else "") + self.undos[i].json()
        undo += "]"
        var body = self.prefs.json()
        var text = String(body[byte = 0 : body.byte_length() - 1]) + ',"undo":' + undo + "}\n"
        var tmp = p + ".tmp"
        try:
            makedirs(self.dir, exist_ok=True)
            with open(tmp, "w") as f:
                f.write(text)
            if libc.rename(tmp, p) != 0:  # (whole or not at all)
                _ = libc.unlink(tmp)
                self.error = "couldn't replace " + p
                return False
            self.error = ""
            return True
        except e:
            if exists(tmp):
                _ = libc.unlink(tmp)  # (no half-written file left behind)
            self.error = String(e)
            return False

    def begin_group(mut self):
        """The changes from now until end_group() are one undo step: an agent's turn ("use the mascot and make it dark" may come
        as two calls), so "put it back" undoes the whole request. A Settings knob tapped while that turn is still running joins
        its group too: rare, and "put it back" then undoes a little more than the knob."""
        self._grouping = True
        self._grouped = False

    def end_group(mut self):
        self._grouping = False
        self._grouped = False

    def can_undo(self) -> Bool:
        return len(self.undos) > 0

    def _apply(mut self, next: LookPrefs) -> LookChange:
        var before = self.prefs.copy()
        var c = LookChange(True, "", before, next)
        if len(c.changed) > 0:
            if not (self._grouping and self._grouped):  # (inside a group, only its first change is an undo step)
                self.undos.append(before.copy())
                while len(self.undos) > UNDO_MAX:
                    _ = self.undos.pop(0)
            self._grouped = self._grouping
            self.prefs = next.copy()
            self.serial += 1
            _ = self.save()
        c.message = _done_sentence(c)
        return c^

    def set(mut self, key: String, value: String) -> LookChange:
        """One setting (a knob, or a caller's own request): checked, applied, saved, undoable."""
        var v = _synonym(key, value)
        var why = look_check(key, v)
        if why != "":
            return LookChange(False, why, self.prefs, self.prefs)
        var next = self.prefs.copy()
        next.put(key, v)
        return self._apply(next)

    def undo(mut self) -> LookChange:
        """"Put it back": the look before the last change."""
        if len(self.undos) == 0:
            return LookChange(False, "There's nothing to put back.", self.prefs, self.prefs, undo=True)
        var before = self.prefs.copy()
        var back = self.undos.pop()
        self._grouped = False  # (a change after it in the same turn is a step of its own)
        self.prefs = back.copy()
        self.serial += 1
        _ = self.save()
        var c = LookChange(True, "", before, back, undo=True)
        c.message = _done_sentence(c)
        return c^

    def ask(mut self, request: String) -> LookChange:
        """The agent's request (JSON): {"set": {setting: value, …}} or {"undo": true} (a flat {setting: value} is read as a
        set). All or nothing: one value off the list refuses the whole request, with the reason."""
        var j: Json
        try:
            j = Json.parse(request)
        except:
            return LookChange(False, "I couldn't read that request.", self.prefs, self.prefs)
        if j.kind(0) != J_OBJECT:
            return LookChange(False, "I couldn't read that request.", self.prefs, self.prefs)
        var u = j.get(0, "undo")
        if u >= 0 and j.kind(u) == J_BOOL and j.flag(u):
            return self.undo()
        var s = j.get(0, "set")
        var obj = s if s >= 0 else 0
        if j.kind(obj) != J_OBJECT:
            return LookChange(False, "set needs the settings to change, like {\"scheme\": \"dark\"}.", self.prefs, self.prefs)
        var next = self.prefs.copy()
        var any = False
        for i in range(j.size(obj)):
            var key = j.key(obj, i)
            if s < 0 and key == "undo":
                continue
            var n = j.at(obj, i)
            if j.kind(n) != J_STRING:
                return LookChange(False, look_check(key, "that") if len(look_values(key)) == 0 else "The " + key + " needs a word, one of " + _one_of(look_values(key)) + ".", self.prefs, self.prefs)
            var v = _synonym(key, j.text(n))
            var why = look_check(key, v)
            if why != "":
                return LookChange(False, why, self.prefs, self.prefs)
            next.put(key, v)
            any = True
        if not any:
            return LookChange(False, "Say what to change: the scheme, the accent, the presence or the density.", self.prefs, self.prefs)
        return self._apply(next)

    def knob(mut self, value: Int, which: Int) -> LookChange:
        """A look_knobs event: `which` = event.message - base (KNOB_*), `value` = event.number (the segment's index)."""
        if which == KNOB_UNDO:
            return self.undo()
        var keys = look_keys()
        if which < 0 or which >= len(keys):
            return LookChange(False, "", self.prefs, self.prefs)
        var vs = look_values(keys[which])
        if value < 0 or value >= len(vs):
            return LookChange(False, "", self.prefs, self.prefs)
        return self.set(keys[which], vs[value])


# ------------------------------------------------------------------------------------------------ reading a look


def is_night(hour: Int) -> Bool:
    """NIGHT_FROM (19:00) to NIGHT_UNTIL (7:00)."""
    return hour >= NIGHT_FROM or hour < NIGHT_UNTIL


def scheme_dark(p: LookPrefs, system_dark: Bool, hour: Int) -> Bool:
    """Whether the look is dark: dark or light as set; auto (the default): as the system is, nothing else; night (opt-in):
    dark from NIGHT_FROM to NIGHT_UNTIL by `hour` (the app's own clock: a demo's clock that stands still keeps its pictures),
    as the system is by day."""
    if p.scheme == "dark":
        return True
    if p.scheme == "light":
        return False
    if p.scheme == "night":
        return system_dark or is_night(hour)
    return system_dark


def accent_index(accent: String) -> Int:
    """The accent's palette series slot (0..5), -1 for the theme's own accent."""
    var vs = look_values("accent")
    for i in range(1, len(vs)):
        if vs[i] == accent:
            return i - 1
    return -1


def accent_colour(p: Palette, accent: String) -> UInt32:
    """The accent as a colour of palette `p` (its series colour; the palette's own accent for "default")."""
    var k = accent_index(accent)
    if k < 0 or len(p.series) == 0:
        return p.accent
    return p.series[k % len(p.series)]


def stage_most(p: LookPrefs, most: Int) -> Int:
    """How many tiles a Stage may show (mojoui.stagefeed.stage_feed's `most`): roomy keeps at most ROOMY_MOST, so each tile is
    bigger (livetiles' presets fill the same grid with fewer tiles)."""
    return min(most, ROOMY_MOST) if p.density == "roomy" else most


def look_knobs(p: LookPrefs, base: Int, can_undo: Bool) -> View:
    """The four settings as segmented controls (messages base + KNOB_SCHEME … KNOB_DENSITY, event.number = the value's index)
    and "Put it back" (base + KNOB_UNDO), for a Settings popover: what the agent can change, by touch."""
    var rows = List[View]()
    var names: List[String] = ["Light or dark", "Accent", "Presence", "Tiles"]
    var keys = look_keys()
    for k in range(len(keys)):
        rows.append(VStack(Text(names[k], CAPTION), Segmented(look_labels(keys[k]), p.index(keys[k]), base + k), spacing=SPACE_XS).align(START))
    if can_undo:
        rows.append(Button("Put it back", base + KNOB_UNDO, SUBTLE, "undo"))
    return VStack(rows^, spacing=SPACE_S).align(START).tag("look-knobs")
