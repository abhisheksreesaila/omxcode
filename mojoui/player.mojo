# mojoui.player: Player, a video you can watch (goal 39 M2). A generic component: omxplorer's video card and the media demo
# are built on it. The picture is a canvas (aspect-fit, rounded); under it one play/pause button, a thin scrubber and the
# time, "0:12 / 0:29". Click the picture or press Space to play and pause; ←/→ step a frame; click or drag the scrubber to seek.
#
#   var player = Player(path, msg_base=100, canvas_base=100)     # raises when the file isn't a video; owns messages 100…104, canvases 100, 101
#   update():  if player.update(event): …                         # True when the event was the player's; player.state.t() is the time then
#   view():    player.view(width)                                 # the picture and its controls on a card; width (points): the picture is exactly the video's shape
#   draw():    if player.draws(canvas): player.draw(canvas, surface, backdrop, palette)    # backdrop: the colour behind the picture (the theme's page)
#   describe(): player.describe()                                 # for an agent: the time, and where on the scrubber a tap seeks to
#
# Time is PlayerState (plain numbers, tested without a video): play(), pause(), seek(t), step(±1) and tick(microseconds), which
# the display frames feed, so playback follows the clock and drops frames rather than drifting. For an agent the controls are
# tools: "play" or "pause" (a button that is whichever applies), "seek" (a tap on the scrubber at x points) and "video"
# (a tap plays or pauses; keys step). Tracing (MOJOUI_TRACE / MOJOUI_TEST) prints `PLAYER: t=12.480 frame=374` on each change.

from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.clock import trace_on
from mojoui.draw import rect, circle
from mojoui.theme import Palette
from mojoui.video import VideoSource
from mojoui.view import View, Button, Canvas, Text, HStack, VStack, Card, CAPTION, ICON_ONLY, NO_MSG, CENTER, PAN, TAP, PRESS, KEY
from mojoui.charts import fixed

# Messages a Player owns, from msg_base
comptime PLAY = 0
comptime PAUSE = 1
comptime SCRUB = 2  # the scrubber's gestures
comptime VIDEO = 3  # the picture's gestures
comptime FRAME = 4  # display frames, while playing
comptime MESSAGES = 5

comptime SCRUB_PAD = 10.0  # points of room at each end of the scrubber's track
comptime FAR_AHEAD = 12  # a frame this far ahead is reached by reading on; further, by seeking
comptime LONGEST_GAP = 250_000  # microseconds: a stalled display catches the clock up by at most this much per frame


def clock_text(seconds: Float64) -> String:
    """0:12, or 1:02:03 from an hour on."""
    var s = Int(max(seconds, 0.0))
    var h = s // 3600
    var m = (s // 60) % 60
    var ss = s % 60
    var tail = ("0" if ss < 10 else "") + String(ss)
    if h > 0:
        return String(h) + ":" + ("0" if m < 10 else "") + String(m) + ":" + tail
    return String(m) + ":" + tail


struct PlayerState(Copyable, Movable):
    """Where a recording is and whether it plays: numbers only."""
    var fps: Float64
    var frames: Int
    var duration: Float64
    var clock: Float64  # the media clock, seconds (it runs between frames; t() is the frame it shows)
    var frame: Int  # the frame on show
    var playing: Bool

    def __init__(out self, fps: Float64, frames: Int, duration: Float64):
        self.fps = fps
        self.frames = max(frames, 1)
        self.duration = duration
        self.clock = 0.0
        self.frame = 0
        self.playing = False

    def _frame_of(self, seconds: Float64) -> Int:
        return min(max(Int(seconds * self.fps + 1e-6), 0), self.frames - 1)

    def t(self) -> Float64:
        """The time of the frame on show."""
        return Float64(self.frame) / self.fps

    def seek(mut self, seconds: Float64):
        """Jumps to the frame shown at `seconds` (clamped to the video); playing carries on from there."""
        self.clock = min(max(seconds, 0.0), self.duration)
        self.frame = self._frame_of(self.clock)

    def step(mut self, frames: Int):
        """Pauses and moves by whole frames (negative: back)."""
        self.playing = False
        self.frame = min(max(self.frame + frames, 0), self.frames - 1)
        self.clock = self.t()

    def play(mut self):
        if self.frame >= self.frames - 1 and self.clock >= self.duration - 1.0 / self.fps:  # at the end: again from the start
            self.seek(0.0)
        self.playing = True

    def pause(mut self):
        self.playing = False

    def toggle(mut self):
        if self.playing:
            self.pause()
        else:
            self.play()

    def tick(mut self, microseconds: Int) -> Bool:
        """The display advanced by this long: the clock follows (frames are dropped, never stretched). True when the
        frame on show changed or the video ended."""
        if not self.playing:
            return False
        self.clock += Float64(min(max(microseconds, 0), LONGEST_GAP)) / 1e6
        var before = self.frame
        if self.clock >= self.duration:  # the end: stop on the last frame
            self.clock = self.duration
            self.frame = self.frames - 1
            self.playing = False
            return True
        self.frame = self._frame_of(self.clock)
        return self.frame != before

    def time_text(self) -> String:
        return clock_text(self.t()) + " / " + clock_text(self.duration)


def _channels(p: UInt32) -> SIMD[DType.float32, 4]:
    return SIMD[DType.float32, 4](Float32(p & 255), Float32((p >> 8) & 255), Float32((p >> 16) & 255), Float32((p >> 24) & 255))


def _pack(c: SIMD[DType.float32, 4]) -> UInt32:
    return (UInt32(min(max(c[0], 0.0), 255.0) + 0.5) | (UInt32(min(max(c[1], 0.0), 255.0) + 0.5) << 8)
            | (UInt32(min(max(c[2], 0.0), 255.0) + 0.5) << 16) | (UInt32(255) << 24))


struct Player(Movable):
    var state: PlayerState
    var src: VideoSource
    var buf: List[UInt32]  # the frame `have`, decoded
    var have: Int  # which frame buf holds (-1: none yet)
    var base: Int  # message numbers base … base + MESSAGES - 1
    var canvas: Int  # the picture's canvas id; the scrubber's is canvas + 1
    var scrub_w: Float64  # the scrubber's width in points, from its last draw
    var stuck: Bool  # the last read failed (the picture stays on the frame before)

    def __init__(out self, path: String, msg_base: Int = 100, canvas_base: Int = 100) raises:
        self.src = VideoSource(path)
        self.state = PlayerState(self.src.fps, self.src.frames, self.src.duration)
        self.buf = List[UInt32]()
        self.have = -1
        self.base = msg_base
        self.canvas = canvas_base
        self.scrub_w = 0.0
        self.stuck = False

    def owns(self, message: Int) -> Bool:
        return self.base <= message < self.base + MESSAGES

    def draws(self, canvas: Int) -> Bool:
        return canvas == self.canvas or canvas == self.canvas + 1

    # ---------- events ----------

    def _trace(self):
        if trace_on():
            print("PLAYER: t=" + fixed(self.state.t(), 3) + " frame=" + String(self.state.frame), flush=True)

    def _seek_x(mut self, x: Float64):
        """The scrubber was touched x points from its left: the frame under it."""
        var track = max(self.scrub_w - 2 * SCRUB_PAD, 1.0)
        self.state.seek(min(max((x - SCRUB_PAD) / track, 0.0), 1.0) * self.state.duration)

    def update(mut self, event: Event) -> Bool:
        """True when `event` was the player's (the state may have moved: read player.state)."""
        if not self.owns(event.message):
            return False
        var which = event.message - self.base
        var before = self.state.frame
        var was_playing = self.state.playing
        if which == PLAY:
            self.state.play()
        elif which == PAUSE:
            self.state.pause()
        elif which == FRAME:
            _ = self.state.tick(event.number)
        elif which == SCRUB:
            if event.number == PRESS or event.number == PAN or event.number == TAP:
                self._seek_x(event.x)
            elif event.number == KEY:
                self._key(event.text)
        elif which == VIDEO:
            if event.number == TAP:
                self.state.toggle()
            elif event.number == KEY:
                self._key(event.text)
        if self.state.frame != before or self.state.playing != was_playing:
            self._trace()
        return True

    def _key(mut self, key: String):
        if key == " ":
            self.state.toggle()
        elif key == "ArrowLeft":
            self.state.step(-1)
        elif key == "ArrowRight":
            self.state.step(1)

    # ---------- the screen ----------

    def height_for(self, width: Int) -> Int:
        """How tall the picture is when it is `width` points wide (the video's own proportions)."""
        return max(width * self.src.height // max(self.src.width, 1), 1)

    def view(self, width: Int = 0) -> View:
        """The picture and its controls. `width`: the points the player is wide, when the app knows them: the picture is then
        exactly the video's shape (no bands above and below); 0: it takes the room it is given and fits the video inside."""
        var playing = self.state.playing
        var button = (Button("pause", on_tap=self.base + PAUSE, style=ICON_ONLY, icon="pause") if playing
                      else Button("play", on_tap=self.base + PLAY, style=ICON_ONLY, icon="play"))
        var picture = Canvas(self.canvas, self.state.frame, on_gesture=self.base + VIDEO, on_frame=self.base + FRAME if playing else NO_MSG, keys=True)
        picture = picture^.fill().tag("video")
        if width > 0:
            picture = picture^.height(self.height_for(width))
        else:
            picture = picture^.grow()
        var scrubber = Canvas(self.canvas + 1, self.state.frame, on_gesture=self.base + SCRUB, keys=True).height(28).grow().fill().tag("seek")
        var controls = HStack(button^.tag("pause" if playing else "play"), scrubber^, Text(self.state.time_text(), style=CAPTION).tag("time").min_width(92),
                              spacing=10).align(CENTER).fill()
        # the controls sit on a card (a quiet bar under the picture): the scrubber paints its track on the card's colour
        var bar = Card(controls^, spacing=0).padding(6, 12).fill()
        if width > 0:
            return VStack(picture^, bar^, spacing=10).width(width)
        return VStack(picture^, bar^, spacing=10).grow().fill()

    def describe(self) -> String:
        """For an agent: where the video is, and how to seek (tap the "seek" canvas at x points from its left)."""
        ref s = self.state
        return ("t=" + fixed(s.t(), 3) + " s of " + fixed(s.duration, 3) + " s, frame " + String(s.frame) + " of " + String(s.frames)
                + (", playing" if s.playing else ", paused") + ". Seek: tap the seek view at x points from its left; its track runs from x="
                + fixed(SCRUB_PAD, 0) + " (0 s) to x=" + fixed(max(self.scrub_w - SCRUB_PAD, SCRUB_PAD), 0) + " (the end).")

    # ---------- drawing ----------

    def _show(mut self, frame: Int):
        """Makes buf hold `frame`: reading on when it is just ahead, a seek otherwise."""
        if self.have == frame:
            return
        try:
            var at = self.src.position()
            if not (at <= frame <= at + FAR_AHEAD):
                self.src.seek_frame(frame)
            while self.src.position() < frame:
                if not self.src.next_into(self.buf):
                    break
            self.stuck = not self.src.next_into(self.buf)
            if not self.stuck:
                self.have = frame
        except:
            self.stuck = True

    def draw(mut self, canvas: Int, mut s: Surface, backdrop: UInt32, pal: Palette):
        if canvas == self.canvas + 1:
            self._draw_scrubber(s, pal)
        elif canvas == self.canvas:
            self._draw_picture(s, backdrop)

    def _draw_scrubber(mut self, mut s: Surface, pal: Palette):
        var k = s.scale
        s.fill(pal.card)
        self.scrub_w = s.points_width()
        var left = SCRUB_PAD * k
        var right = Float64(s.width) - SCRUB_PAD * k
        var mid = Float64(s.height) / 2
        var h = 4.0 * k
        var done = left + (right - left) * min(max(self.state.t() / max(self.state.duration, 1e-9), 0.0), 1.0)
        rect(s, left, mid - h / 2, right - left, h, pal.line_strong, h / 2)
        if done > left:
            rect(s, left, mid - h / 2, done - left, h, pal.accent, h / 2)
        circle(s, done, mid, 8 * k, pal.line_strong)  # the handle: white, with a hairline
        circle(s, done, mid, 7 * k, pal.card)

    def _draw_picture(mut self, mut s: Surface, backdrop: UInt32):
        s.fill(backdrop)
        self._show(self.state.frame)
        var vw = self.src.width
        var vh = self.src.height
        if self.have < 0 or vw <= 0 or vh <= 0 or len(self.buf) != vw * vh:
            return
        var scale = min(Float64(s.width) / Float64(vw), Float64(s.height) / Float64(vh))
        var dw = max(Int(Float64(vw) * scale), 1)
        var dh = max(Int(Float64(vh) * scale), 1)
        var x0 = (s.width - dw) // 2
        var y0 = (s.height - dh) // 2
        var radius = min(14.0 * s.scale, Float64(min(dw, dh)) / 2)
        var back = _channels(backdrop)
        var out = s.pixels()
        var src = self.buf.unsafe_ptr()
        var sx_step = Float64(vw) / Float64(dw)
        var sy_step = Float64(vh) / Float64(dh)
        for y in range(dh):
            var fy = min(max((Float64(y) + 0.5) * sy_step - 0.5, 0.0), Float64(vh - 1))
            var iy = Int(fy)
            var iy2 = min(iy + 1, vh - 1)
            var wy = Float32(fy - Float64(iy))
            var dy = min(Float64(y) + 0.5, Float64(dh) - Float64(y) - 0.5)  # distance to the nearest top or bottom edge
            for x in range(dw):
                var fx = min(max((Float64(x) + 0.5) * sx_step - 0.5, 0.0), Float64(vw - 1))
                var ix = Int(fx)
                var ix2 = min(ix + 1, vw - 1)
                var wx = Float32(fx - Float64(ix))
                var top = _channels(src.unsafe_offset(iy * vw + ix)[]) * (1 - wx) + _channels(src.unsafe_offset(iy * vw + ix2)[]) * wx
                var bottom = _channels(src.unsafe_offset(iy2 * vw + ix)[]) * (1 - wx) + _channels(src.unsafe_offset(iy2 * vw + ix2)[]) * wx
                var c = top * (1 - wy) + bottom * wy
                var dx = min(Float64(x) + 0.5, Float64(dw) - Float64(x) - 0.5)
                if dx < radius and dy < radius:  # inside a corner's square: how much of the pixel the rounded corner covers
                    var ex = radius - dx
                    var ey = radius - dy
                    var cover = min(max(radius - (ex * ex + ey * ey) ** 0.5 + 0.5, 0.0), 1.0)
                    c = back + (c - back) * Float32(cover)
                out.unsafe_offset((y0 + y) * s.width + x0 + x)[] = _pack(c)
