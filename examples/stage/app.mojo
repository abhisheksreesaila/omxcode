# The Stage, shown without a model (goal 77 M7a, D-7781): mojoui.stage's four regions in omxqua's Counter family, light and
# night, at the window's width (a desktop's three columns, a narrow window's two, a phone's one). Placeholder content: a
# clock, a quiet Today list, a pinned card, Live rows, the chat bar with the real orb; the stage holds mojoui.livetiles'
# tiles (M7b) on the stage's own ground. Nothing here draws: the app only composes.
#
#   scripts/build.sh stage linux && build/stage/linux/stage          (MOJOUI_WINDOW=390x844 for a phone's width)

from mojoui.app import App, Event
from mojoui.view import View, VStack, HStack, Canvas, Spacer, CENTER, START, SPACE_S, SPACE_M
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.theme import Theme, Palette
from mojoui.orb import Orb, OrbView, ORB_LISTEN
from mojoui.livetiles import LiveTiles, Tile, Face, TileLook
from mojoui.stage import Stage, StageClock, StageLabel, StageCard, StageRow, StageList, StageAvatar, StagePill, StageChat
from mojoui.stage import stage_compact
from themes.omxqua import omxqua_counter, counter_ground

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


def morning(p: Palette) -> List[Tile]:
    """A school morning, most urgent first (the prototype's 7:45 school run); each kind in one of the family's data colours."""
    var traffic = Tile("traffic", p.series[2], "Traffic", "Leave by 8:05", "Bridge is slow · +18 min to school", icon="car")
    traffic.faces.append(Face("26 min to school", "via the river road · 2 incidents"))
    traffic.why = "you leave in 20 minutes"
    traffic.actions = ["Directions to the car", "Tell school"]
    var todo = Tile("todo", p.series[3], "To do", "3 to do", "Call mum · Pick up Maya · Water bill", icon="todo")
    todo.faces.append(Face("Next: call mum", "it's her birthday Saturday"))
    var cal = Tile("cal", p.series[4], "Calendar", "Pickup 3:15", "Maya · the side gate", icon="cal")
    var counter = Tile("counter", p.ink2, "Counter", "Banana nearly ripe", "seen 7:12", icon="cam")
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

    def title(self) -> String:
        return "Stage"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 820)

    def resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height

    def appearance(mut self, dark: Bool):
        self.dark = dark
        self.tiles.set_tiles(morning(omxqua_counter(dark).palette))  # (the same tiles in the night's data colours: nothing moves)

    def theme(self) -> Theme:
        return omxqua_counter(self.dark)

    def update(mut self, event: Event):
        if event.message == TYPE:
            self.text = event.text
        elif event.message == SEND:
            self.text = ""
        elif event.message == MIC:
            self.orb.mode(ORB_LISTEN)
        elif event.message == GESTURE:
            self.tiles.gesture(event.number, event.x, event.y)
            _ = self.tiles.take_results()
        elif event.message == FRAME:
            _ = self.tiles.frame(event.number)
        elif PERSON <= event.message < PERSON + 4:
            self.person = event.message - PERSON

    def view(self) -> View:
        var compact = stage_compact(self.width)
        var top = HStack(StageAvatar("All", 0, PERSON), StageAvatar("A", 2, PERSON + 1), StageAvatar("S", 3, PERSON + 2),
                         StageAvatar("M", 5, PERSON + 3), StagePill("settings", "Settings", SETTINGS, compact),
                         StagePill("sparkles", "Charms", CHARMS, compact), Spacer(), spacing=SPACE_S).align(CENTER)
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
        return Stage(top, left, stage, right, chat, self.width, self.height)

    def draw(mut self, canvas: Int, mut surface: Surface):
        var p = omxqua_counter(self.dark).palette.copy()
        if canvas == ORB_CANVAS:
            self.orb.draw(surface, p.with_accent(p.series[1]))  # (the Counter's accent is ink: the orb in the family's blue)
            return
        # the tiles on the stage's own ground (TileLook.of would take the room's colour, the page)
        self.tiles.draw(surface, TileLook(p.dark, counter_ground(p.dark), p.card, p.ink, p.ink2, p.line), self.font)
