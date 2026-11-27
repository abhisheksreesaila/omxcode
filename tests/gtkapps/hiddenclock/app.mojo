# Goal 82 integration, D-8905 (a Mac): an animating window hidden and restored starts its frames again, with no timer of
# the app's own to wake it (pnote has none while it animates). It animates, hides itself after 120 frames, and AppKit
# unhides it 3 s later (performSelector on NSApp: nothing of the app runs meanwhile). Run with MOJOUI_FRAME_CLOCK=early:
# every occlusion notice reads the window as not shown yet, as macOS's notice of a return sometimes does, so only the
# host's half-second look (watch_hidden) can bring the frames back. It prints FACT lines and ends itself 120 frames after
# the return; a frozen window never prints them (the script ends it after 25 s).
from mojoui import App, Event, View, VStack, Text, Canvas
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.hosts.objc import msg, cls, sel


struct Main(App):
    var frames: Int
    var hid_at: Int  # the frame count when it hid (-1: not yet)
    var hid_ns: Int
    var back_ns: Int  # the first frame after the return (0: none yet)

    def __init__(out self):
        self.frames = 0
        self.hid_at = -1
        self.hid_ns = 0
        self.back_ns = 0

    def title(self) -> String:
        return "Hidden clock"

    def window_size(self) -> Tuple[Int, Int]:
        return (400, 240)

    def draw(mut self, id: Int, mut s: Surface):
        s.fill(0xFF202020 + UInt32(self.frames % 200))

    def update(mut self, event: Event):
        if event.message != 3:
            return
        self.frames += 1
        var app = msg(cls("NSApplication"), "sharedApplication")
        if self.frames == 120 and self.hid_at < 0:
            self.hid_at = self.frames
            self.hid_ns = Int(now_ns())
            print("HIDE at", self.frames, flush=True)
            _ = msg(app, "hide:", 0)
            _ = msg(app, "performSelector:withObject:afterDelay:", sel("unhideWithoutActivation"), 0, Float64(3.0))
        elif self.hid_at >= 0 and self.back_ns == 0 and Int(now_ns()) - self.hid_ns > 2_900_000_000:
            self.back_ns = Int(now_ns())
            print("FACT hidden_frames", self.frames - self.hid_at - 1, flush=True)
            print("FACT back_after_ms", (self.back_ns - self.hid_ns) // 1_000_000, flush=True)
            self.hid_at = self.frames
        elif self.back_ns != 0 and self.frames - self.hid_at >= 120:
            print("FACT restored_frames", self.frames - self.hid_at, flush=True)
            print("FACT restored_per_s", Float64(self.frames - self.hid_at) / (Float64(Int(now_ns()) - self.back_ns) / 1e9), flush=True)
            print("mac_hidden_restore: ok", flush=True)
            _ = msg(app, "terminate:", 0)

    def view(self) -> View:
        return VStack(Text("hidden clock"), Canvas(1, self.frames, on_frame=3).width(300).height(150))
