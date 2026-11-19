# The Stage, shown without a model (goal 77 M7a, D-7781): mojoui.stage's four regions in omxqua's Counter family, light and
# night, at the window's width (a desktop's three columns, a narrow window's two, a phone's one). Placeholder content: a
# clock, a quiet Today list, a pinned card, Live rows, the chat bar with the real orb; the stage holds mojoui.livetiles'
# tiles (M7b) on the stage's own ground. Nothing here draws: the app only composes.
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
# STAGE_SHOT=/path.png@ms: the TV canvas's own pixels saved once, that far into the next open (a mid-morph picture: a
# GTK test step settles for up to a second after a tap, longer than the morph).

from mojoui.app import App, Event
from mojoui.view import View, Node, VStack, HStack, Canvas, Spacer, CENTER, START, SPACE_S, SPACE_M
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.theme import Theme, Palette
from mojoui.orb import Orb, OrbView, ORB_LISTEN
from mojoui.livetiles import LiveTiles, Tile, Face, TileLook
from mojoui.stage import Stage, StageClock, StageLabel, StageCard, StageRow, StageList, StageAvatar, StagePill, StageChat
from mojoui.stage import stage_compact
from mojoui.stagetv import StageTV, TVContent, StageThread, StageChips, StageMsg, TV_YOU, TV_OMX, TV_QUIET_MS, tv_now
from mojoui.genui import GenUi, sample
from mojoui.jsonpatch import JDoc
from mojoui.clock import now_ns
from mojoui.png import encode_png
from mojoui.shared import environment
from themes.omxqua import omxqua_counter, counter_ground, counter_tv_look

comptime TILES_CANVAS = 1
comptime ORB_CANVAS = 2
comptime TYPE = 1
comptime SEND = 2
comptime MIC = 3
comptime GESTURE = 4
comptime FRAME = 5
comptime PERSON = 10  # PERSON + 0 … 3: the avatars
comptime SETTINGS = 20
comptime CHARMS = 21
comptime TV_CANVAS = 3  # the TV's box (over the centre column)
comptime TV_VEIL = 4  # the TV body's veil
comptime TV_FRAME = 30
comptime TV_CLOSE = 31
comptime ASK_WORD = 32
comptime ASK_ISO = 33
comptime CHAT = 34
comptime CHIP = 40  # CHIP + k: the TV's chips (ASKS[k])
comptime WORD_BASE = 1000  # the cards' own messages and canvases (mojoui.genui)
comptime ISO_BASE = 2000
comptime WORD_CANVAS = 100
comptime ISO_CANVAS = 200

comptime Q_WORD = "What does ephemeral mean?"
comptime Q_ISO = "How does a heat pump work?"
comptime ASK_WORD_LABEL = "Ephemeral?"  # the top bar's pills that ask them
comptime ASK_ISO_LABEL = "Heat pump?"


def morning(p: Palette) -> List[Tile]:
    """A school morning, most urgent first (the prototype's 7:45 school run); each kind in one of the family's data colours."""
    var traffic = Tile("traffic", p.series[2], "Traffic", "Leave by 8:05", "Bridge is slow · +18 min to school", icon="car")
    traffic.faces.append(Face("26 min to school", "via the river road · 2 incidents"))
    traffic.why = "you leave in 20 minutes"
    traffic.actions = ["Directions to the car", "Tell school"]
    var todo = Tile("todo", p.series[3], "To do", "3 to do", "Call mum · Pick up Maya · Water bill", icon="list-todo")
    todo.faces.append(Face("Next: call mum", "it's her birthday Saturday"))
    var cal = Tile("cal", p.series[4], "Calendar", "Pickup 3:15", "Maya · the side gate", icon="calendar")
    var counter = Tile("counter", p.ink2, "Counter", "Banana nearly ripe", "seen 7:12", icon="camera")
    var bday = Tile("bday", p.series[0], "Birthday", "Mum · Saturday", "turns 64", icon="gift")
    var weather = Tile("weather", p.series[1], "Weather", "9° · clear", "rain after 4", icon="cloud")
    var out = List[Tile]()
    out.append(traffic^)
    out.append(todo^)
    out.append(cal^)
    out.append(counter^)
    out.append(bday^)
    out.append(weather^)
    return out^


struct Main(App):
    var dark: Bool
    var width: Int
    var height: Int
    var text: String
    var orb: Orb
    var tiles: LiveTiles
    var font: Font
    var person: Int
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

    def __init__(out self):
        self.dark = False
        self.width = 1280
        self.height = 820
        self.text = ""
        self.orb = Orb()
        self.tiles = LiveTiles()
        self.tiles.set_tiles(morning(omxqua_counter(False).palette))
        self.font = Font()
        self.person = 0
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
        self.log("START")

    def title(self) -> String:
        return "Stage"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 820)

    def resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height
        self.tv.resize(width)

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
        self.log("OPEN " + (self.tv.next_card if self.tv.leave_t0 >= 0 else self.tv.card) + " " + question)

    def appearance(mut self, dark: Bool):
        self.dark = dark
        self.tiles.set_tiles(morning(omxqua_counter(dark).palette))  # (the same tiles in the night's data colours: nothing moves)
        self.tv.version += 1  # (the TV's box in the night's colours)

    def theme(self) -> Theme:
        return omxqua_counter(self.dark)

    def update(mut self, event: Event):
        if event.message == TYPE:
            self.text = event.text
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
            self.mark = tv_now()
            self.log("CLOSE x")
        elif event.message == TV_FRAME:
            var was = self.tv.is_open
            _ = self.tv.tick(tv_now())
            if was and not self.tv.is_open:
                self.mark = tv_now()
                self.log("CLOSE " + self.tv.closed_by)
        elif event.message == MIC:
            self.orb.mode(ORB_LISTEN)
        elif event.message == GESTURE:
            self.tiles.gesture(event.number, event.x, event.y)
            _ = self.tiles.take_results()
        elif event.message == FRAME:
            _ = self.tiles.frame(event.number)
            var was = self.tv.is_open
            _ = self.tv.tick(tv_now())
            if was and not self.tv.is_open:
                self.mark = tv_now()
                self.log("CLOSE " + self.tv.closed_by)
        elif self.word.owns(event.message) or self.iso.owns(event.message):
            self.tv.touch(tv_now())
        elif PERSON <= event.message < PERSON + 4:
            self.person = event.message - PERSON

    def view(self) -> View:
        var compact = stage_compact(self.width)
        var top = HStack(StageAvatar("All", 0, PERSON), StageAvatar("A", 2, PERSON + 1), StageAvatar("S", 3, PERSON + 2),
                         StageAvatar("M", 5, PERSON + 3), StagePill("settings", "Settings", SETTINGS, compact),
                         StagePill("sparkles", "Charms", CHARMS, compact), spacing=SPACE_S).align(CENTER)
        if not compact:  # (the TV's sample questions, short so the bar fits 900 wide; a phone types them in the chat bar)
            top = HStack(top^, StagePill("book-open", ASK_WORD_LABEL, ASK_WORD), StagePill("box", ASK_ISO_LABEL, ASK_ISO),
                         StagePill("comment", "Chat", CHAT), Spacer(), spacing=SPACE_S).align(CENTER)
        else:
            top = HStack(top^, Spacer(), spacing=SPACE_S).align(CENTER)
        var today: List[View] = [StageCard("cloud-sun", "Weather", "9° · clear", "rain after 4", 2),
                                 StageCard("calendar", "Calendar", "Pickup 3:15", "Maya · the side gate", 5)]
        var pins: List[View] = [StageCard("map-pin", "Pinned", "A day in Lisbon", "3 stops", 3)]
        var left = VStack(StageClock("10:59", "Wednesday, November 18", "9° · clear · rain after 4", compact),
                          StageLabel("calendar", "Today"), StageList(today, compact),
                          StageLabel("pin", "Pinned"), StageList(pins, compact), spacing=SPACE_M).align(START)
        var live: List[View] = [StageRow("timer", "Pasta", "7:20", 4), StageRow("trophy", "Lisbon v Porto", "2–1", 1),
                                StageRow("car", "To school", "12 min", 3), StageRow("home", "Door locked", "21°", 2)]
        var right = VStack(StageLabel("zap", "Live · also today"), StageList(live), spacing=SPACE_M).align(START)
        var chat = StageChat(OrbView(ORB_CANVAS, self.orb.version(), big=False, side=52), self.text, "Ask omx, or just say “omx”",
                             on_change=TYPE, on_submit=SEND, on_mic=MIC)
        var stage = Canvas(TILES_CANVAS, self.tiles.version, on_gesture=GESTURE, on_frame=FRAME).grow().fill().tag("stage-tiles")
        var card = View(List[Node]())
        if self.tv.card == "word":
            card = self.word.view(self.state, self.tv.version)
        elif self.tv.card == "iso":
            card = self.iso.view(self.state, self.tv.version)
        var lay = self.tv.layout()
        var content = TVContent(card^, StageThread(self.msgs, lay.thread_w), StageChips([Q_WORD, Q_ISO], CHIP))
        return Stage(top, left, stage, right, chat, self.width, tv=self.tv, content=content)

    def draw(mut self, canvas: Int, mut surface: Surface):
        var p = omxqua_counter(self.dark).palette.copy()
        if canvas == ORB_CANVAS:
            self.orb.draw(surface, p.with_accent(p.series[1]))  # (the Counter's accent is ink: the orb in the family's blue)
            return
        if self.tv.draws(canvas):
            self.tv.draw(canvas, surface, counter_tv_look(self.dark))
            if canvas == TV_CANVAS:
                self.record(surface)
            return
        if self.word.draws(canvas):
            self.word.draw(canvas, surface, p, self.state, self.font)
            return
        if self.iso.draws(canvas):
            self.iso.draw(canvas, surface, p, self.state, self.font)
            return
        # the tiles on the stage's own ground (TileLook.of would take the room's colour, the page)
        self.tiles.draw(surface, TileLook.on(p, counter_ground(p.dark)), self.font)

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
