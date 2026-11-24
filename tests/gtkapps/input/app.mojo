# Goal 81, M4: every event changes the screen's shape (rows come, go and move; every eleventh changes the root, so the
# whole window is built again), and is written to $G81_LOG as it reaches update(). "Set" writes the app's own words and
# values into the controls; "Drop K" takes target K away, "Back" brings all of them back.
from std.os import getenv
from mojoui import *


struct Main(App):
    var n: Int
    var here: List[Bool]
    var text: String
    var long: String
    var on: Bool
    var choice: Int
    var level: Int
    var part: Int
    var dot: Int
    var sets: Int

    def __init__(out self):
        self.n = 0
        self.here = [True, True, True, True]
        self.text = "start"
        self.long = "start"
        self.on = False
        self.choice = 0
        self.level = 10
        self.part = 0
        self.dot = 0
        self.sets = 0

    def title(self) -> String:
        return "Input"

    def window_size(self) -> Tuple[Int, Int]:
        return (1000, 800)

    def row(self, list_id: Int, index: Int) -> String:
        return "row " + String(index)

    def update(mut self, event: Event):
        try:
            var f = open(getenv("G81_LOG"), "a")
            f.write(String(event.message) + "\t" + event.text + "\t" + String(event.number) + "\t" + String(Int(event.dx)) + "\t" + String(Int(event.dy)) + "\n")
            f.close()
        except:
            print("no log")
        var m = event.message
        self.n += 1
        if m == 10:
            self.text = event.text
        elif m == 11:
            self.long = event.text
        elif m == 12:
            self.on = event.number != 0
        elif m == 13:
            self.choice = event.number
        elif m == 14:
            self.level = event.number
        elif m == 15:
            self.part = event.number
        elif m == 16:
            self.dot = event.number
        elif m == 20:
            self.sets += 1
            self.text = "by app " + String(self.sets)
            self.long = "by app " + String(self.sets)
            self.on = not self.on
            self.choice = (self.choice + 1) % 3
            self.level = (self.level + 7) % 100
            self.part = (self.part + 1) % 3
            self.dot = (self.dot + 1) % 3
        elif 30 <= m < 34:
            self.here[m - 30] = False
        elif m == 39:
            self.here = [True, True, True, True]

    def view(self) -> View:
        var parts = List[View]()
        parts.append(HStack(Button("A", 1).tag("a"), Button("B", 2).tag("b"), Button("Set", 20).tag("set"), Button("Back", 39).tag("back")))
        var drops = List[View]()
        var targets = List[View]()
        for k in range(4):
            drops.append(Button("Drop " + String(k), 30 + k).tag("drop" + String(k)))
            if self.here[k]:
                targets.append(Button("Target " + String(k), 40 + k).tag("x" + String(k)))
        parts.append(HStack(drops))
        parts.append(HStack(targets))
        parts.append(TextField(self.text, "words", on_change=10, on_submit=17).tag("field"))
        parts.append(TextArea(self.long, "long", on_change=11).tag("area"))
        parts.append(HStack(Toggle("On", self.on, 12).tag("toggle"), Dropdown(["One", "Two", "Three"], self.choice, 13).tag("drop"), Slider(self.level, 14).tag("slide")))
        parts.append(HStack(Segmented(["L", "M", "R"], self.part, 15).tag("seg"), Radio(["x", "y", "z"], self.dot, 16).tag("radio")))
        parts.append(LazyList(500, 1, on_tap=18, height=100, row_height=30).tag("list"))
        parts.append(Canvas(1, self.n, on_gesture=19, keys=True, scroll_pans=True).width(200).height(80).tag("canvas"))
        parts.append(MenuBar([Menu("Edit", [Item("Find", 21, shortcut="Ctrl+F")])]))
        # the shape: notes between the parts, and the parts turned round
        var out = List[View]()
        for k in range(len(parts)):
            var at = (k + self.n // 2) % len(parts)
            out.append(parts[at].copy())
            if (self.n + k) % 3 == 0:
                out.append(Text("note " + String(self.n)))
        if (self.n // 11) % 2 == 1:
            return HStack(VStack(out), Text("another root"))
        return VStack(out)
