# httpcheck: proves mojoui.http and App.every never hold up the screen (goal 33 M1, M2). A strip animates on every display
# frame; Fetch asks for the URL typed above, and the frames counted while the reply is out show nothing waited for it.
# Start ticks runs a 100 ms timer ten times and lists when each tick landed (ms after the tap); the strip is still then,
# so on the web the ticks reach the page through its /wait, not alongside frames.

from mojoui import App, Event, View, HStack, Text, Button, TextField, CAPTION, HEADLINE, PROMINENT
from mojoui.view import Card, SPACE_S, SPACE_M, NO_MSG
from mojoui.canvas import Surface
from mojoui.activity import ActivityStrip, Strip
from mojoui.http import Http, Request
from mojoui.effects import Every
from mojoui.clock import now_ns

comptime URL = 1
comptime FETCH = 2
comptime GOT = 3
comptime FRAME = 4
comptime START_TICKS = 5
comptime TICK = 6
comptime TICKS = 10


struct Main(App):
    comptime HTTP = True
    var http: Http
    var url: String
    var waiting: Bool
    var sent_ns: Int
    var waited_ms: Float64
    var frames: Int  # display frames while the reply was out
    var last_frame_ns: Int
    var gap_ms: Float64  # the longest time between two of them
    var reply: String
    var phase: Int  # every frame: the strip moves
    var ticking: Bool
    var tick_from_ns: Int
    var ticks: List[Int]  # ms after the tap, one per tick

    def __init__(out self):
        self.http = Http()
        self.url = ""
        self.waiting = False
        self.sent_ns = 0
        self.waited_ms = 0
        self.frames = 0
        self.last_frame_ns = 0
        self.gap_ms = 0
        self.reply = "(none yet)"
        self.phase = 0
        self.ticking = False
        self.tick_from_ns = 0
        self.ticks = List[Int]()

    def title(self) -> String:
        return "httpcheck"

    def window_size(self) -> Tuple[Int, Int]:
        return (560, 520)

    def update(mut self, event: Event):
        if event.message == URL:
            self.url = event.text
        elif event.message == FETCH and not self.waiting:
            self.http.send(Request.get(GOT, self.url).timeout(10_000))
            self.waiting = True
            self.sent_ns = now_ns()
            self.frames = 0
            self.gap_ms = 0
            self.last_frame_ns = self.sent_ns
            self.reply = "(waiting)"
        elif event.message == GOT:
            self.waiting = False
            var now = now_ns()
            self.waited_ms = Float64(now - self.sent_ns) / 1e6
            self.gap_ms = max(self.gap_ms, Float64(now - self.last_frame_ns) / 1e6)
            self.reply = ("error " + event.error) if event.error != "" else String(event.number) + " " + event.text
        elif event.message == FRAME:
            self.phase += 1
            if self.waiting:
                var now = now_ns()
                self.frames += 1
                self.gap_ms = max(self.gap_ms, Float64(now - self.last_frame_ns) / 1e6)
                self.last_frame_ns = now
        elif event.message == START_TICKS:
            self.ticking = True
            self.tick_from_ns = now_ns()
            self.ticks = List[Int]()
        elif event.message == TICK and self.ticking:
            self.ticks.append((now_ns() - self.tick_from_ns) // 1_000_000)
            if len(self.ticks) >= TICKS:
                self.ticking = False

    def requests(mut self) -> List[Request]:
        return self.http.take()

    def every(self) -> List[Every]:
        var out = List[Every]()
        if self.ticking:
            out.append(Every(100, TICK))
        return out^

    def draw(mut self, canvas: Int, mut surface: Surface):
        Strip(self.phase, self.theme().palette).draw(surface)

    def view(self) -> View:
        var ticks = String("")
        for t in self.ticks:
            ticks += " " + String(t)
        return Card(
            Text("httpcheck · requests and timers off the main thread", style=HEADLINE),
            TextField(self.url, placeholder="URL", on_change=URL),
            HStack(Button("Fetch", on_tap=FETCH, style=PROMINENT), Button("Start ticks", on_tap=START_TICKS), spacing=SPACE_S),
            ActivityStrip(0, self.phase, on_frame=FRAME if self.waiting else NO_MSG).tag("strip"),
            Text("status: " + ("waiting" if self.waiting else "idle")),
            Text("frames while waiting: " + String(self.frames)),
            Text("waited: " + String(Int(self.waited_ms)) + " ms"),
            Text("longest frame gap: " + String(Int(self.gap_ms)) + " ms"),
            Text("reply: " + (self.reply if self.reply.byte_length() <= 120 else String(self.reply[byte = :120]))),
            Text("ticks:" + ticks),
            Text("Every line of this app is Mojo.", style=CAPTION),
            spacing=SPACE_M,
        ).fill()
