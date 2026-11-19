# Free canvas sample (goal 78 M1/M2): mojoui.freeboard on its own, in Liquid. Four cards placed anywhere at any size;
# drag a title band to move one, any edge or corner to resize it (live, soft snap with guides, Alt: no snap); the page
# grows right and down and scrolls both ways; Ctrl+wheel or Ctrl+- / Ctrl+0 zooms; Super (or Alt) + arrows focus, move
# and resize the focused card, Super+F fills the window, Super+T tidies. The same file on GTK, the web and the Mac.

from mojoui import App, Event, View, VStack, HStack, Card, Text, Spacer, Button, TITLE, CAPTION, HEADLINE, CENTER, STRETCH
from mojoui.menus import MenuBar, Menu, Item
from mojoui.freeboard import FreeBoard, FreeCanvas, ACTS, arrange_menu, HANDLE_MOVE, NO_SNAP, zoom_by
from mojoui.tiling import Rect
from mojoui.theme import Theme
from themes.liquid import liquid

comptime MOVE = 1
comptime RESIZE = 2
comptime ADD = 3
comptime TIDY = 4
comptime ARRANGE = 100  # + mojoui.freeboard's ACT_…
comptime BAR_H = 52


struct Main(App):
    var rects: List[Rect]
    var tags: List[String]
    var fb: FreeBoard
    var width: Int
    var height: Int
    var dark: Bool
    var said: String

    def __init__(out self):
        self.rects = [Rect(0, 0, 560, 360)]
        self.tags = ["notes"]
        self.fb = FreeBoard(200, 120)
        self.width = 1280
        self.height = 800
        self.dark = False
        self.said = ""
        self.place()
        for t in ["chart", "table", "video"]:
            self.add(t)

    def title(self) -> String:
        return "Canvas"

    def theme(self) -> Theme:
        return liquid(self.dark)

    def appearance(mut self, dark: Bool):
        self.dark = dark

    def room_w(self) -> Int:
        return self.width - 32

    def room_h(self) -> Int:
        return self.height - BAR_H - 32

    def resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height

    def place(mut self):
        var sizes = List[Rect]()
        for t in self.tags:
            sizes.append(Rect(0, 0, 640 if t == "table" else 420, 360 if t == "table" else 280))
        self.rects = self.fb.sync(self.tags, self.rects, self.room_w(), self.room_h(), sizes)

    def add(mut self, tag: String):
        self.tags.append(tag)
        self.rects.append(Rect(0, 0, 0, 0))
        self.place()

    def update(mut self, event: Event):
        var m = event.message
        if m == MOVE or m == RESIZE:
            if event.text == "zoom":
                self.fb.zoom = zoom_by(self.fb.zoom, event.zoom)
            elif event.text == "view":
                self.fb.view = Rect(Int(event.x), Int(event.y), Int(event.dx), Int(event.dy))
            else:
                var handle = HANDLE_MOVE if m == MOVE else Int(event.y) % 100
                var k = event.number
                if 0 <= k < len(self.rects):
                    self.rects[k] = self.fb.drag(k, handle, Int(event.dx), Int(event.dy), self.rects, Int(event.y) < NO_SNAP)
                    if event.text != "live":
                        self.fb.end()
                        self.said = self.tags[k] + " " + String(self.rects[k])
                        print("CANVAS: " + self.said, flush=True)
        elif m == ADD:
            self.add("card" + String(len(self.tags)))
        elif m == TIDY:
            self.rects = self.fb.act(17, self.rects, self.room_w(), self.room_h())
        elif m >= ARRANGE and m < ARRANGE + ACTS:
            self.rects = self.fb.act(m - ARRANGE, self.rects, self.room_w(), self.room_h())
            self.said = "act " + String(m - ARRANGE) + (" " + self.tags[self.fb.focus] + " " + String(self.rects[self.fb.focus]) if 0 <= self.fb.focus < len(self.rects) else "")
            print("CANVAS: act " + String(m - ARRANGE) + " focus " + String(self.fb.focus) + " zoom " + String(self.fb.zoom)
                  + (" " + String(self.rects[self.fb.focus]) if 0 <= self.fb.focus < len(self.rects) else ""), flush=True)

    def card(self, k: Int) -> View:
        ref r = self.rects[k]
        var body = Text(String(r.w) + " × " + String(r.h) + " at " + String(r.x) + ", " + String(r.y), CAPTION)
        return (Card(HStack(Text(self.tags[k], HEADLINE), Spacer(), spacing=8).fill().align(CENTER).height(28), body^, spacing=8)
                .at(r.x, r.y).width(r.w).height(r.h).tag(self.tags[k]))

    def view(self) -> View:
        var items = List[View]()
        for k in range(len(self.rects)):
            items.append(self.card(k))
        var canvas = FreeCanvas(items^, self.rects, self.room_w(), self.room_h(), self.fb, MOVE, RESIZE).fill().grow()
        var menus = MenuBar([Menu("Canvas", [Item("Add a card", ADD, shortcut="Ctrl+N"), Item("Tidy", TIDY)]), arrange_menu(ARRANGE).hidden()])
        var bar = HStack(Text("Canvas", HEADLINE), menus^, Button("Add a card", ADD), Button("Tidy", TIDY), Spacer(),
                         Text("zoom " + String(self.fb.zoom) + " % · " + self.said, CAPTION).tag("said"), spacing=12).align(CENTER).padding(8, 16).height(BAR_H)
        return VStack(bar^, canvas^.padding(16), spacing=0).fill().grow()
