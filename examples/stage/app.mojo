# The Stage, shown without a model (goal 77 M7a, D-7781): mojoui.stage's four regions in omxqua's Counter family, light and
# night, at the window's width (a desktop's three columns, a narrow window's two, a phone's one). Nothing here draws: the
# app only composes.
#
# Sides, pins and charms (M7e): mojoui.stagefeed says what stands on the stage (the urgent tile first, then the centre
# tiles, then photos, the birthday and the calendar up to five) and what goes to the sides: the left column has the clock,
# a quiet Today list (passive tiles not on the stage: weather until rain makes it urgent) and Pinned; the right column has
# Live rows that keep ticking (the pasta timer counts down each second). Drag a tile from the stage onto Pinned to pin it
# (the grid fills the gap); the pin-off button on a pinned card puts it back. "Try a day" (in the right column; the left on
# a narrow window) switches the moment of the prototype: each occasion hangs its charm (mojoui.charms) on the tile it is
# about. A phone shows the tiles in two columns of 112 pt rows and the page scrolls.
#
# The TV (M7d, mojoui.stagetv): ask "What does ephemeral mean?" or "How does a heat pump work?" (the top bar's question
# pills, or type it in the chat bar) and the chat bar grows over the whole centre with the real card (genui's WordCard,
# its Iso diagram) on the left and the conversation on the right; ask the other one and the card swaps in place; × (or
# 12 s of quiet, STAGE_TV_QUIET=ms to change it) shrinks it back to the bar. "Chat" opens it with no card: the
# conversation centred, with things to ask. No model: the answers are canned.
#
#   scripts/build.sh stage linux && build/stage/linux/stage          (MOJOUI_WINDOW=390x844 for a phone's width)
#
# STAGE_TRACE=/path: every frame the TV's canvas draws appends its numbers (mojoui.stagetv's record: the box's y and
# height, the tiles' veil, the body's veil, the card) with the wall clock, and each open and close: the M7d proof reads it.
# M7e's lines: EV FEED (the moment, the stage's tiles with their sizes and cells, the holes, Today, Live, Pinned, the grid's
# columns), EV CHARMS (each charm as drawn: tile, charm, box), EV LIVE (the timer's row each second), EV PIN / UNPIN, EV TILES
# (the tiles as drawn once they rest: mojoui.livetiles' record on one line).
# STAGE_SHOT=/path.png@ms: the TV canvas's own pixels saved once, that far into the next open (a mid-morph picture: a
# GTK test step settles for up to a second after a tap, longer than the morph).
# STAGE_CLEAN=1: the stage as it would stand on a counter, for pictures and recordings: no demo controls (the top bar keeps the
# people and Settings; no Try a day). STAGE_CLOCK=7:45: what the clock reads (the demo's clock stands still; default 10:59).
# STAGE_DARK=1: the night look whatever the system says.
# The mascot (a person's presence "mascot", mojoui.mascot): on a desktop it sits full-size on its perch under Pinned (tap to
# poke, hover to lean) while the chat bar keeps the quiet orb; on a phone it sits in the chat bar (D-8421). STAGE_MASCOT=1 (or
# a pack dir) perches it whatever the look says (a demo), STAGE_MASCOT=0 never perches it; STAGE_MASCOT_STATE=rest|listen|
# think|speak|hype|nap; STAGE_MASCOT_CLOUD=1 previews the cloud warning aura.
#
# Personalize (mojoui.personalize, D-8400…): Settings opens the four knobs the agent's `personalize` tool changes in omx (light
# or dark, an accent from the palette's own colours as swatches, the orb or the mascot, compact or roomy tiles) and "Put it
# back", headed by whose look it is; each person in the top bar (All, A, S, M) keeps their own, the active one ringed. An
# accent shows on the mic, the active ring, a hint in the stage's ground and the person's chat bubbles (D-8419). Nothing
# snaps: a new scheme or accent morphs the window
# (mojoui.transition: the window as it was fades over the new one while it settles), the presence crossfades, the tiles reflow
# on their water spring (one that leaves shrinks away, one that joins grows in). In memory only
# (the defaults every run, so the checks' pictures stay); STAGE_LOOK=dir keeps them in that folder.

from mojoui.app import App, Event
from mojoui.view import View, Node, VStack, HStack, Canvas, Spacer, Text, CENTER, START, SPACE_S, SPACE_M, PRESS, TAP, HOVER, NO_MSG
from mojoui.canvas import Surface
from mojoui.effects import Every
from mojoui.geometry import rect_of
from mojoui.text import Font
from mojoui.theme import Theme, Palette, ThemePair
from mojoui.orb import Orb, OrbView, ORB_IDLE, ORB_LISTEN, ORB_THINK, ORB_SPEAK
from mojoui.mascot import (
    MascotPerch, Presence, PRESENCE_MASCOT, PRESENCE_ORB, PERCH_SIDE,
    MASCOT_REST, MASCOT_LISTEN, MASCOT_THINK, MASCOT_SPEAK, MASCOT_HYPE,
    mascot_state_id, mascot_pack_dir,
)
from mojoui.livetiles import LiveTiles, Tile, Face, TileLook, Box, DROPPED, size_name, tile_icon
from mojoui.stage import Stage, StageClock, StageLabel, StageCard, StageRow, StageList, StageAvatar, StagePill, StageChat, StageNote
from mojoui.stage import stage_compact, stage_layout
from mojoui.stagefeed import StageFeed, stage_feed, stage_tiles, tile_by_id, wear_occasion, tint_hue
from mojoui.stagetv import StageTV, TVContent, StageThread, StageChips, StageMsg, TV_YOU, TV_OMX, TV_QUIET_MS, tv_now
from mojoui.genui import GenUi, sample
from mojoui.jsonpatch import JDoc
from mojoui.clock import now_ns
from mojoui.png import encode_png
from mojoui.shared import environment
from mojoui.overlays import Popover
from mojoui.personalize import Personalize, LookPrefs, LookChange, look_knobs, look_title, scheme_dark, accent_colour, stage_most, KNOB_COUNT
from mojoui.transition import Morph
from mojoui.theme import ThemeCache
from themes.omxqua import omxqua_counter, counter_palette, counter_ground, counter_tv_look
from std.os.path import exists
from days import Moment, moments, ranked, day_tiles, clock_text, TIMER_START

comptime TILES_CANVAS = 1
comptime ORB_CANVAS = 2
comptime MASCOT_CANVAS = 5
comptime TYPE = 1
comptime SEND = 2
comptime MIC = 3
comptime GESTURE = 4
comptime FRAME = 5
comptime TICK = 6  # each second: the Live rows tick
comptime PERSON = 10  # PERSON + 0 … 3: the avatars
comptime SETTINGS = 20
comptime CHARMS = 21
comptime MASCOT_GESTURE = 22
comptime TV_CANVAS = 3  # the TV's box (over the centre column)
comptime TV_VEIL = 4  # the TV body's veil
comptime TV_FRAME = 30
comptime TV_CLOSE = 31
comptime ASK_WORD = 32
comptime ASK_ISO = 33
comptime CHAT = 34
comptime CHIP = 40  # CHIP + k: the TV's chips (ASKS[k])
comptime DAY = 50  # DAY + k: try moment k of the day
comptime UNPIN = 70  # UNPIN + k: pinned card k back on the stage
comptime SETTINGS_CLOSE = 95
comptime KNOBS = 120  # KNOBS + 0 … KNOB_COUNT - 1 (12): the look's knobs and swatches (mojoui.personalize.look_knobs)
comptime WORD_BASE = 1000  # the cards' own messages and canvases (mojoui.genui)
comptime ISO_BASE = 2000
comptime WORD_CANVAS = 100
comptime ISO_CANVAS = 200

comptime Q_WORD = "What does ephemeral mean?"
comptime Q_ISO = "How does a heat pump work?"
comptime ASK_WORD_LABEL = "Ephemeral?"  # the top bar's pills that ask them
comptime ASK_ISO_LABEL = "Heat pump?"


struct Main(App):
    var dark: Bool
    var system_dark: Bool  # what the system (or STAGE_DARK) says: the look's "auto" follows it, and the night by the demo's clock
    var themes: ThemeCache  # one theme per scheme and accent, each built once (D-7889)
    var look: Personalize  # each person's look (mojoui.personalize)
    var morph: Morph  # the next change morphs (mojoui.transition)
    var settings_open: Bool
    var perch_mode: String  # STAGE_MASCOT: "pin" (1 or a pack dir: always perched on a desktop), "off" (0: never), "" (the look says)
    var width: Int
    var height: Int
    var text: String
    var presence: Presence  # the chat bar's orb or mascot (mojoui.mascot), and the perch's mascot
    var mascot_side: Int
    var tiles: LiveTiles
    var font: Font
    var person: Int
    var day: Int  # the moment being tried (moments()[day])
    var pins: List[String]
    var timer_s: Int
    var all: List[Tile]  # every tile of the moment, its charm on
    var feed: StageFeed
    var tv: StageTV
    var msgs: List[StageMsg]
    var word: GenUi[]
    var iso: GenUi[]
    var state: JDoc
    var trace: String
    var t0: Int
    var shot: String  # STAGE_SHOT's path, "" once taken
    var shot_ms: Int
    var mark: Int  # the wall clock (µs) of the last open or close
    var said_charms: String  # what EV CHARMS / EV TILES / EV ZONES last said (each logged when it changes)
    var said_tiles: String
    var said_zones: String
    var clean: Bool  # STAGE_CLEAN: no demo controls
    var clock: String  # STAGE_CLOCK: what the clock reads
    var charms_on: Bool  # the top bar's Charms pill turns the occasions' charms off and on (a prototype's control)

    def __init__(out self):
        self.dark = False
        self.system_dark = False
        self.themes = ThemeCache()
        self.themes.put("light/default", omxqua_counter(False))
        self.themes.put("dark/default", omxqua_counter(True))
        self.look = Personalize("stage", dir=environment("STAGE_LOOK", ""))
        self.morph = Morph()
        self.settings_open = False
        var pin = environment("STAGE_MASCOT")
        self.perch_mode = String("off") if pin == "0" else (String("pin") if pin != "" else String(""))
        self.width = 1280
        self.height = 820
        self.text = ""
        self.presence = Presence()
        self.mascot_side = PERCH_SIDE
        if self.perch_mode == "pin":
            var pack_dir = mascot_pack_dir("STAGE_MASCOT")  # (a folder in STAGE_MASCOT, else the omx pack found from the program)
            try:
                self.presence.load_mascot(pack_dir)  # (the perch draws the mascot; the chat bar keeps the person's choice)
                _ = self.presence.mascot.clips[MASCOT_REST].ensure_loaded()
                var init_state = environment("STAGE_MASCOT_STATE")
                if init_state != "":
                    var sid = mascot_state_id(init_state)
                    if sid >= 0:
                        self.presence.mascot.mode(sid)
                if environment("STAGE_MASCOT_CLOUD") == "1":
                    self.presence.mascot.lane(True)
            except e:
                print("stage mascot load failed:", e)
        self.tiles = LiveTiles()
        self.font = Font()
        self.person = 0
        self.day = 0
        self.pins = ["lisbon"]
        self.timer_s = TIMER_START
        self.all = List[Tile]()
        self.feed = StageFeed()
        var quiet = TV_QUIET_MS
        try:
            var q = environment("STAGE_TV_QUIET")
            if q != "":
                quiet = Int(q)
        except:
            pass
        self.tv = StageTV(TV_CANVAS, TV_VEIL, on_frame=TV_FRAME, on_close=TV_CLOSE, quiet_ms=quiet)
        self.tv.resize(1280)
        self.msgs = List[StageMsg]()
        self.word = GenUi(sample("WordCard"), WORD_BASE, WORD_CANVAS)
        self.iso = GenUi(sample("Iso"), ISO_BASE, ISO_CANVAS)
        self.state = JDoc()
        self.trace = environment("STAGE_TRACE")
        self.t0 = now_ns()
        var want = environment("STAGE_SHOT")
        var at = want.find("@")
        self.shot = String(want[byte = 0 : at]) if at > 0 else ""
        self.shot_ms = 0
        if at > 0:
            try:
                self.shot_ms = Int(String(want[byte = at + 1 :]))
            except:
                self.shot = ""
        self.mark = -1
        self.said_charms = ""
        self.said_tiles = ""
        self.said_zones = ""
        self.clean = environment("STAGE_CLEAN") == "1"
        self.clock = environment("STAGE_CLOCK", "10:59")
        self.charms_on = True
        self.log("START")
        self.refeed()  # (the presence is placed by the first resize, at the real width: a phone never perches for a frame)

    def title(self) -> String:
        return "Stage"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 820)

    def every(self) -> List[Every]:
        return [Every(1000, TICK)]

    def resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height
        self.tv.resize(width)
        var cols = 2 if stage_compact(width) else 4
        if cols != self.tiles.cols:
            self.tiles.set_columns(cols)
            self.log_feed()
        self.place_presence()  # (a phone puts the mascot in the chat bar; a desktop on its perch)

    def wall_ms(self) -> Int:
        return (now_ns() - self.t0) // 1_000_000

    def log(self, line: String):
        if self.trace == "":
            return
        try:
            with open(self.trace, "a") as f:
                f.write("EV " + String(self.wall_ms()) + " " + line + "\n")
        except:
            pass

    # ---------------------------------------------------------------- the feed

    def moment(self) -> Moment:
        return moments()[self.day].copy()

    def refeed(mut self):
        """The moment's tiles (its occasion's charm on), the feed (what stands on the stage, Today, Live, Pinned), the stage's
        tiles in its order, then the sides again from what the grid really shows."""
        var m = self.moment()
        self.all = day_tiles(m, self.timer_s)
        wear_occasion(self.all, m.occasion if self.charms_on else String(""), m.about)
        var r = ranked(m)
        var old = self.feed.copy()
        self.feed = stage_feed(r, m.urgent, self.pins, most=stage_most(self.look.prefs, 3 if m.big else 6))  # (roomy: fewer, bigger tiles)
        self.tiles.set_tiles(stage_tiles(self.all, self.feed))
        self.feed.place(r, self.tiles.layout().ids)
        self.feed.since(old)  # (rows whose tiles just left the stage ease in: D-8425)
        self.log_feed()

    def log_feed(self):
        var lay = self.tiles.layout()
        var stage = String("")
        for i in range(len(lay.ids)):
            var c = lay.cells[i]
            stage += ("," if i > 0 else "") + lay.ids[i] + ":" + size_name(lay.sizes[i]) + "@" + String(c.x) + "." + String(c.y) + "." + String(c.w) + "." + String(c.h)
        self.log("FEED day=" + self.moment().id + " stage=" + stage + " holes=" + String(lay.holes) + " today=" + _ids(self.feed.today)
                 + " live=" + _ids(self.feed.live) + " pinned=" + _ids(self.feed.pinned) + " cols=" + String(self.tiles.cols))

    def pin(mut self, id: String):
        for p in self.pins:
            if p == id:
                return
        self.pins.append(id)
        self.log("PIN " + id)
        self.refeed()

    def unpin(mut self, k: Int):
        if k < 0 or k >= len(self.pins):
            return
        var id = self.pins.pop(k)
        self.log("UNPIN " + id)
        self.refeed()

    def drop_zones(mut self):
        """Pinned, as a place a dragged tile can be let go (in the tiles canvas's points: it lies outside the canvas)."""
        var pins = rect_of("stage.pins")
        var cv = rect_of("stage.tiles")
        if len(pins) == 4 and len(cv) == 4:
            self.tiles.drop_zone("pinned", Box(pins[0] - cv[0], pins[1] - cv[1], pins[2], pins[3]))

    # ---------------------------------------------------------------- the TV

    def ask(mut self, question: String):
        """A question (a pill, a chip or typed): what she would show for it (no model: canned), into the TV."""
        var q = question.lower()
        var now = tv_now()
        self.msgs.append(StageMsg(TV_YOU, question, "7:38"))
        if q.find("ephemeral") >= 0 or q.find("mean") >= 0:
            self.msgs.append(StageMsg(TV_OMX, "Ephemeral means lasting only a very short time, like cherry blossoms.", "7:38"))
            self.tv.open(now, "What “ephemeral” means", "word")
        elif q.find("heat") >= 0 or q.find("work") >= 0:
            self.msgs.append(StageMsg(TV_OMX, "It moves heat instead of making it: the outdoor coil soaks it up, the compressor squeezes it hot, the indoor coil gives it to your room.", "7:39"))
            self.tv.open(now, "How a heat pump works", "iso")
        else:
            self.msgs.append(StageMsg(TV_OMX, "I can show you what a word means or how something works: try one of these.", "7:39"))
            self.tv.open(now, "Today's conversation", "")
        self.tv.speaking(now, False)  # (no voice here: she has finished as soon as she answers)
        self.mark = now
        self.presence.mode(MASCOT_SPEAK)  # (the chat bar's orb, and the mascot)
        self.log("OPEN " + (self.tv.next_card if self.tv.leave_t0 >= 0 else self.tv.card) + " " + question)

    def appearance(mut self, dark: Bool):
        self.system_dark = dark or environment("STAGE_DARK") == "1"
        self.restyle()

    def hour(self) -> Int:
        """The demo's clock's hour (STAGE_CLOCK, 10:59 by default): the look's opt-in "night" is dark at night by it ("auto"
        follows the system only)."""
        try:
            return Int(String(self.clock.split(":")[0]))
        except:
            return 12

    def theme_key(self) -> String:
        return ("dark/" if self.dark else "light/") + self.look.prefs.accent

    def accent(self) -> UInt32:
        """The person's accent as a colour of this scheme's palette (0: the theme's own: nothing tinted)."""
        if self.look.prefs.accent == "default":
            return 0
        return accent_colour(counter_palette(self.dark), self.look.prefs.accent)

    def restyle(mut self):
        """The look's scheme and accent into the theme (each theme built once, here, never in theme()) and the canvases."""
        self.dark = scheme_dark(self.look.prefs, self.system_dark, self.hour())
        var key = self.theme_key()
        if not self.themes.has(key):
            self.themes.put(key, omxqua_counter(self.dark, self.accent()))
        self.tiles.version += 1  # (the same tiles in the night's palette: their tints are names; nothing moves)
        self.tv.version += 1  # (the TV's box in the night's colours)

    def personalized(mut self, c: LookChange):
        """A look change (a knob, a person picked in the top bar): the scheme and accent restyle, the presence crossfades, the
        tiles reflow on their water spring; only a new scheme or accent morphs the window."""
        if not c.moved():
            if c.message != "":
                self.log("LOOK refused " + c.message)
            return
        var was = ("dark/" if self.dark else "light/") + c.before.accent  # (the theme before: the prefs have already changed)
        self.restyle()
        if self.theme_key() != was:  # (only a new scheme or accent morphs the window; the presence crossfades by itself and the
            self.morph.morph()        # tiles reflow on their own water spring: no picture of the old screen over them, D-8413)
        if c.before.presence != c.after.presence:
            self.place_presence()
        if c.before.density != c.after.density:
            self.refeed()
        self.log("LOOK " + self.look.profile + " " + self.look.prefs.json() + " " + c.message)

    def place_presence(mut self):
        """Where the presence shows (D-8421): the person's mascot full-size on its perch on a desktop, the chat bar keeping the
        quiet orb (two mascots never stare at once); in the chat bar on a phone; STAGE_MASCOT pins or stops the perch. Its
        resting strip is decoded first, never during the spring."""
        var want = self.look.prefs.presence == "mascot"
        var perched = not stage_compact(self.width) and self.perch_mode != "off" and (want or self.perch_mode == "pin")
        if want or perched:
            self.mascot_ready()
        var was = self.presence.perched
        self.presence.arrange(want and not perched, perched)
        if self.presence.perched != was:
            self.log("PERCH " + ("on" if self.presence.perched else "off") + " w=" + String(self.width))

    def mascot_ready(mut self):
        """The mascot pack loaded and its resting strip decoded (~85 ms, once), before a switch needs it: never in a transition."""
        var pack = mascot_pack_dir("STAGE_MASCOT")
        if self.presence.has_mascot() or pack == "":
            return
        try:
            self.presence.load_mascot(pack)
            _ = self.presence.mascot.clips[MASCOT_REST].ensure_loaded()
        except e:
            print("stage mascot load failed:", e)

    def transition(mut self) -> Int:
        return self.morph.take()

    def theme(self) -> Theme:
        return self.themes.get(self.theme_key())

    def update(mut self, event: Event):
        if event.message == TYPE:
            self.text = event.text
            if self.presence.has_mascot():  # (the mascot listens while you type; the orb keeps its own state)
                self.presence.mascot.mode(MASCOT_LISTEN if self.text != "" else MASCOT_REST)
        elif event.message == SEND:
            if self.text != "":
                var q = self.text
                self.ask(q)
            self.text = ""
        elif event.message == ASK_WORD:
            self.ask(Q_WORD)
        elif event.message == ASK_ISO:
            self.ask(Q_ISO)
        elif event.message == CHAT:
            self.tv.open(tv_now(), "Today's conversation", "")
            self.mark = tv_now()
            self.log("OPEN chat")
        elif CHIP <= event.message < CHIP + 2:
            self.ask(Q_WORD if event.message == CHIP else Q_ISO)
        elif event.message == TV_CLOSE:
            self.tv.close(tv_now(), "x")
            self.presence.mode(MASCOT_REST)
            self.mark = tv_now()
            self.log("CLOSE x")
        elif event.message == TV_FRAME:
            var was = self.tv.is_open
            _ = self.tv.tick(tv_now())
            if was and not self.tv.is_open:
                self.mark = tv_now()
                self.log("CLOSE " + self.tv.closed_by)
        elif event.message == MIC:
            var next_m = ORB_IDLE if self.presence.orb.current() == ORB_LISTEN else ORB_LISTEN
            self.presence.mode(next_m)
        elif event.message == GESTURE:
            if event.number == PRESS:
                self.drop_zones()
            self.tiles.gesture(event.number, event.x, event.y)
            for r in self.tiles.take_results():
                if r.kind == DROPPED and r.text == "pinned":
                    self.pin(r.id)
        elif event.message == FRAME:
            _ = self.tiles.frame(event.number)
            var was = self.tv.is_open
            _ = self.tv.tick(tv_now())
            if was and not self.tv.is_open:
                self.mark = tv_now()
                self.log("CLOSE " + self.tv.closed_by)
        elif event.message == TICK:
            var prev_timer = self.timer_s
            self.timer_s = max(self.timer_s - 1, 0)
            if prev_timer > 0 and self.timer_s == 0 and self.presence.has_mascot():
                self.presence.mascot.mode(MASCOT_HYPE)
            self.log("LIVE timer=" + clock_text(self.timer_s))
            var m = self.moment()  # (the tiles' words again: the Live row reads them; nothing moves)
            self.all = day_tiles(m, self.timer_s)
            wear_occasion(self.all, m.occasion if self.charms_on else String(""), m.about)
            if self.feed.side_of("timer") == "stage":  # (its face on the stage too)
                self.tiles.set_tiles(stage_tiles(self.all, self.feed))
        elif DAY <= event.message < DAY + len(moments()):
            self.day = event.message - DAY
            self.log("DAY " + self.moment().id)
            self.refeed()
        elif UNPIN <= event.message < UNPIN + 20:
            self.unpin(event.message - UNPIN)
        elif self.word.owns(event.message) or self.iso.owns(event.message):
            self.tv.touch(tv_now())
        elif PERSON <= event.message < PERSON + 4:
            self.person = event.message - PERSON
            if self.presence.has_mascot():
                self.presence.poke()
            var names: List[String] = ["all", "a", "s", "m"]
            var before = self.look.prefs.copy()
            _ = self.look.use_profile(names[self.person])
            if not before.same(self.look.prefs):
                self.personalized(LookChange(True, "", before, self.look.prefs))
        elif event.message == SETTINGS:
            self.settings_open = not self.settings_open
            if self.settings_open:
                self.mascot_ready()  # (before the person can pick it: its first strip decodes now, not mid-transition)
        elif event.message == SETTINGS_CLOSE:
            self.settings_open = False
        elif KNOBS <= event.message < KNOBS + KNOB_COUNT:
            self.personalized(self.look.knob(event.number, event.message - KNOBS))
        elif event.message == MASCOT_GESTURE:
            if event.number == TAP:
                self.presence.poke()
                self.log("MASCOT poke")
            elif event.number == HOVER:
                if event.x < 0 or event.y < 0:
                    self.presence.mascot.look(0.0, 0.0, 0.0)
                else:
                    var half = Float64(self.mascot_side) * 0.5
                    var gx = (event.x - half) / max(half, 1.0)
                    var gy = (event.y - half) / max(half, 1.0)
                    self.presence.mascot.look(gx, gy, 0.75)
        elif event.message == CHARMS:
            self.charms_on = not self.charms_on
            self.log("CHARMS_ON " + ("1" if self.charms_on else "0"))
            self.refeed()

    # ---------------------------------------------------------------- the view

    def row(self, id: String) -> View:
        """A tile as a one-line side row: its icon, its head, its first face's big line (the timer's value ticking)."""
        var t = tile_by_id(self.all, id)
        var value = t.faces[0].big if len(t.faces) > 0 else String("")
        return StageRow(tile_icon(t.icon), t.head, value, tint_hue(t.tint), key=id, arrive=self.feed.arrives(id))

    def days(self) -> View:
        var ms = moments()
        var items = List[View]()
        for k in range(len(ms)):
            items.append(StagePill("sparkles" if k == self.day else "calendar", ms[k].label, DAY + k))
        return VStack(StageLabel("sparkles", "Try a day"), VStack(items, spacing=SPACE_S).align(START), spacing=SPACE_S).align(START)

    def view(self) -> View:
        var compact = stage_compact(self.width)
        var wide = stage_layout(self.width).right
        var settings = HStack(StagePill("settings", "Settings", SETTINGS, compact), spacing=0).tag("stage-settings")  # (the popover's anchor
        # wraps the pill: a role-wearing view is never tagged again, docs/lessons.md)
        var bar: List[View] = [StageAvatar("All", 0, PERSON, self.person == 0), StageAvatar("A", 2, PERSON + 1, self.person == 1),
                               StageAvatar("S", 3, PERSON + 2, self.person == 2), StageAvatar("M", 5, PERSON + 3, self.person == 3), settings^]
        if self.settings_open:
            bar.append(Popover("stage-settings", "Settings", look_knobs(self.look.prefs, KNOBS, self.look.can_undo(), look_title(self.look.profile)),
                               on_close=SETTINGS_CLOSE))
        if not self.clean:
            bar.append(StagePill("sparkles", "Charms", CHARMS, compact))
        var top = HStack(bar^, spacing=SPACE_S).align(CENTER)
        if not compact and not self.clean:  # (the TV's sample questions, short so the bar fits 900 wide; a phone types them in the chat bar)
            top = HStack(top^, StagePill("book-open", ASK_WORD_LABEL, ASK_WORD), StagePill("box", ASK_ISO_LABEL, ASK_ISO),
                         StagePill("comment", "Chat", CHAT), Spacer(), spacing=SPACE_S).align(CENTER)
        else:
            top = HStack(top^, Spacer(), spacing=SPACE_S).align(CENTER)
        # left: the clock (its weather line), Today (passive tiles not on the stage), Pinned (a drop place for a tile)
        var wx = tile_by_id(self.all, "weather")
        var wline = (wx.faces[0].big + " · " + wx.faces[0].sub) if len(wx.faces) > 0 else String("")
        var today = List[View]()
        for id in self.feed.today:
            today.append(self.row(id))
        if len(today) == 0:
            today.append(StageNote("Nothing else today"))
        var pins = List[View]()
        for k in range(len(self.feed.pinned)):
            var t = tile_by_id(self.all, self.feed.pinned[k])
            var f = t.faces[0].copy() if len(t.faces) > 0 else Face(t.head, "")
            pins.append(StageCard(tile_icon(t.icon), t.head, f.big, f.sub, tint_hue(t.tint), on_unpin=UNPIN + k))
        if len(pins) == 0:
            pins.append(StageNote("Drag a tile here to keep it at your side"))
        var pinned = VStack(VStack(StageLabel("pin", "Pinned"), StageList(pins), spacing=SPACE_S).align(START).fill().tag(
            "stage-drop" if self.tiles.hover_zone == "pinned" else "stage-pins"), spacing=0).fill().tag("stage.pins")  # (a tile dragged
        # over it: it lights up; the dotted tag is one every host reports a rect for, mojoui.geometry.rect_of: the drop zone)
        var left_items = List[View]()
        left_items.append(StageClock(self.clock, "Wednesday, November 18", wline, compact))
        left_items.append(StageLabel("calendar", "Today"))
        left_items.append(VStack(StageList(today), spacing=0).fill().tag("stage-today"))
        left_items.append(pinned^)
        if self.presence.perch_shown() and not compact:  # (the mascot full-size under Pinned; it stays while it leaves)
            left_items.append(MascotPerch(MASCOT_CANVAS, self.presence.perch_version(), on_gesture=MASCOT_GESTURE if self.presence.perched else NO_MSG))
        if not wide and not compact and not self.clean:
            left_items.append(self.days())
        var left = VStack(left_items^, spacing=SPACE_M).align(START)
        # right: Live (rows that keep ticking), then the sample days
        var live = List[View]()
        for id in self.feed.live:
            live.append(self.row(id))
        if len(live) == 0:
            live.append(StageNote("Nothing live right now"))
        var right_items = List[View]()
        right_items.append(StageLabel("zap", "Live"))
        right_items.append(VStack(StageList(live), spacing=0).fill().tag("stage-live"))
        if (wide or compact) and not self.clean:
            right_items.append(self.days())
        var right = VStack(right_items^, spacing=SPACE_M).align(START)
        var chat = StageChat(OrbView(ORB_CANVAS, self.presence.version(), big=False, side=52), self.text, "Ask omx, or just say “omx”",
                             on_change=TYPE, on_submit=SEND, on_mic=MIC)
        var stage = Canvas(TILES_CANVAS, self.tiles.version, on_gesture=GESTURE, on_frame=FRAME).grow().fill().tag("stage.tiles")
        var card = View(List[Node]())
        if self.tv.card == "word":
            card = self.word.view(self.state, self.tv.version)
        elif self.tv.card == "iso":
            card = self.iso.view(self.state, self.tv.version)
        var lay = self.tv.layout()
        var content = TVContent(card^, StageThread(self.msgs, lay.thread_w), StageChips([Q_WORD, Q_ISO], CHIP))
        return Stage(top, left, stage, right, chat, self.width, compact_panel=self.tiles.compact_height() + 20, tv=self.tv, content=content)

    def draw(mut self, canvas: Int, mut surface: Surface):
        var p = counter_palette(self.dark)  # (the palette only: the whole theme, its CSS included, is not rebuilt every frame, D-7876)
        if canvas == ORB_CANVAS:
            self.presence.draw(surface, p.with_accent(self.presence_colour(p)))  # (the orb, or the mascot, or the crossfade between them)
            return
        if canvas == MASCOT_CANVAS:
            self.presence.draw_perch(surface, p.with_accent(self.presence_colour(p)))  # (full-size; arriving or leaving on its spring)
            return
        if self.tv.draws(canvas):
            self.tv.draw(canvas, surface, counter_tv_look(self.dark, self.accent()))
            if canvas == TV_CANVAS:
                self.record(surface)
            return
        if self.word.draws(canvas):
            self.word.draw(canvas, surface, p, self.state, self.font)
            return
        if self.iso.draws(canvas):
            self.iso.draw(canvas, surface, p, self.state, self.font)
            return
        # the tiles on the stage's own ground (TileLook.of would take the room's colour, the page; a person's accent tints it)
        self.tiles.draw(surface, TileLook.on(p, counter_ground(p.dark, self.accent())), self.font)
        if self.trace != "":
            var pins = rect_of("stage.pins")
            var cv = rect_of("stage.tiles")
            if len(pins) == 4 and len(cv) == 4:
                var z = ("ZONES pinned=" + _r(pins[0] - cv[0]) + "," + _r(pins[1] - cv[1]) + "," + _r(pins[2]) + "," + _r(pins[3])
                         + " canvas=" + _r(cv[0]) + "," + _r(cv[1]) + "," + _r(cv[2]) + "," + _r(cv[3]))
                if z != self.said_zones:
                    self.said_zones = z
                    self.log(z)
        if self.trace != "" and not self.tiles.moving():
            var ch = self.tiles.charms().replace("\n", ";")
            if ch != self.said_charms:
                self.said_charms = ch
                self.log("CHARMS day=" + self.moment().id + " " + ch)
            var rec = self.tiles.record().replace("\n", ";")
            if rec != self.said_tiles:
                self.said_tiles = rec
                self.log("TILES w=" + String(Int(self.tiles.width)) + " h=" + String(Int(self.tiles.height)) + " cols=" + String(self.tiles.cols) + " " + rec)

    def presence_colour(self, p: Palette) -> UInt32:
        """The orb's (and the mascot's aura's) colour: the accent the person picked, else the family's blue (the Counter's own
        accent is ink)."""
        return accent_colour(p, self.look.prefs.accent) if self.look.prefs.accent != "default" else p.series[1]

    def record(mut self, mut surface: Surface):
        """STAGE_TRACE: this frame's numbers; STAGE_SHOT: the canvas's pixels once, that far into the morph."""
        if self.shot != "" and self.mark >= 0 and tv_now() - self.mark >= self.shot_ms * 1000:
            var px = List[UInt32](capacity=surface.width * surface.height)
            for i in range(surface.width * surface.height):
                px.append(surface.pixels().unsafe_offset(i)[])
            try:
                with open(self.shot, "w") as f:
                    f.write_bytes(Span(encode_png(px, surface.width, surface.height)))
                self.log("SHOT " + String((tv_now() - self.mark) // 1000) + " " + self.shot)
            except:
                pass
            self.shot = ""
        if self.trace != "":
            try:
                with open(self.trace, "a") as f:
                    f.write("D " + String(self.wall_ms()) + " " + self.tv.record() + " scale=" + String(surface.scale) + "\n")
            except:
                pass


def _r(v: Float64) -> String:
    return String(Int(v + 0.5)) if v >= 0 else "-" + String(Int(-v + 0.5))


def _ids(ids: List[String]) -> String:
    var out = String("")
    for i in range(len(ids)):
        out += ("," if i > 0 else "") + ids[i]
    return out
