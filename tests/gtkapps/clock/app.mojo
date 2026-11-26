# Goal 81, M7 (a Mac): how often a canvas's frames come: 3 s animating on the fastest screen, 3 s hidden, shown again,
# then idle. It prints its counts as FACT lines and ends itself.
from mojoui import App, Event, View, VStack, Text, Canvas
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.effects import Every
from mojoui.hosts.objc import msg, cls, sel
from mojoui.hosts.apple_canvas import CGRect


struct Main(App):
    var half: Int  # half seconds so far
    var frames: Int
    var marks: List[Int]  # frames at each half second
    var times: List[Int]
    var animates: Bool
    var hz: Int

    def __init__(out self):
        self.half = 0
        self.frames = 0
        self.marks = List[Int]()
        self.times = List[Int]()
        self.animates = True
        self.hz = 0

    def title(self) -> String:
        return "Clock"

    def window_size(self) -> Tuple[Int, Int]:
        return (500, 300)

    def every(self) -> List[Every]:
        return [Every(500, 2)]

    def draw(mut self, id: Int, mut s: Surface):
        s.fill(0xFF202020 + UInt32(self.frames % 200))

    def update(mut self, event: Event):
        if event.message == 3:
            self.frames += 1
            return
        if event.message != 2:
            return
        self.half += 1
        self.marks.append(self.frames)
        self.times.append(now_ns())
        var app = msg(cls("NSApplication"), "sharedApplication")
        var window = msg(msg(app, "windows"), "objectAtIndex:", 0)
        if self.half == 1:  # onto the fastest screen
            var screens = msg(cls("NSScreen"), "screens")
            var best = 0
            for k in range(msg(screens, "count")):
                var s = msg(screens, "objectAtIndex:", k)
                var f = msg(s, "maximumFramesPerSecond")
                print("SCREEN", k, "max", f, flush=True)
                if f > self.hz:
                    self.hz = f
                    best = k
            var f = msg[CGRect](msg(screens, "objectAtIndex:", best), "visibleFrame")
            _ = msg(window, "setFrameOrigin:", f.x + 60, f.y + 60)
        elif self.half == 9:
            self.hz = msg(msg(window, "screen"), "maximumFramesPerSecond")
            print("VISIBLE", msg(window, "occlusionState") & 2, "SCREENMAX", self.hz, flush=True)
            _ = msg(app, "hide:", 0)
        elif self.half == 16:
            _ = msg(app, "unhideWithoutActivation")
        elif self.half == 22:
            self.animates = False
        elif self.half == 29:
            print("FACT ticks_per_s", round(self.rate(4, 8), 2))
            print("FACT screen_hz", self.hz)
            print("FACT hidden_ticks", self.marks[14] - self.marks[10])
            print("FACT again_per_s", round(self.rate(18, 20), 2))
            print("FACT idle_frames", self.marks[27] - self.marks[23], flush=True)
            _ = msg(app, "terminate:", 0)

    def rate(self, a: Int, b: Int) -> Float64:
        return Float64(self.marks[b] - self.marks[a]) / (Float64(self.times[b] - self.times[a]) / 1e9)

    def view(self) -> View:
        return VStack(Text("clock"), Canvas(1, self.frames, on_frame=3 if self.animates else 0).width(300).height(150))
