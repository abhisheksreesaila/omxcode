# mojoui.player: Player, a video you can watch (goal 39 M2). A generic component: omxplorer's video card and the media demo
# are built on it. The picture is a canvas (aspect-fit, rounded); under it one play/pause button, a thin scrubber and the
# time, "0:12 / 0:29". Click the picture or press Space to play and pause; ←/→ step a frame; click or drag the scrubber to seek.
#
#   var player = Player(path, msg_base=100, canvas_base=100)     # returns at once (raises only when the file is missing); owns messages 100…104, canvases 100, 101
#   Player(info, …)                                               # a video already probed (another player's .info): ready at once
#   player.ready(), player.problem()                              # the probe landed / why it can't play ("not a video")
#   update():  if player.update(event): …                         # True when the event was the player's; player.state.t() is the time then
#   view():    player.view(width)                                 # the picture and its controls on a card; width (points): the picture is exactly the video's shape
#   draw():    if player.draws(canvas): player.draw(canvas, surface, backdrop, palette)    # backdrop: the colour behind the picture (the theme's page)
#   describe(): player.describe()                                 # for an agent: the time, and how to seek
#   player.set_marks(marks)                                       # boxes over the picture, per frame (what an analysis found), drawn lightly
#
# Time is PlayerState (plain numbers, tested without a video): play(), pause(), seek(t), step(±1) and tick(microseconds), which
# the display frames feed, so playback follows the clock and drops frames rather than drifting. For an agent the controls are
# tools: "play" and "pause" (one button, whichever applies, with the other as its .alternate(): both are tools), "seek" (set to a time in seconds: the scrubber is .settable(),
# so an agent's {"value": 12.5} arrives as a SET_TO gesture; or a tap at x points) and "video"
# (a tap plays or pauses; keys step). Tracing (MOJOUI_TRACE / MOJOUI_TEST) prints `PLAYER: t=12.480 frame=374` on each change.
#
# Nothing here waits (goal 41 M2): the file is probed and decoded on its own thread (mojoui.framefeed). A seek or a tick
# only says which frame is wanted; the newest wins. The picture shows the newest frame decoded and asks for display
# frames until the one wanted lands (or the app's jobs_message, woken by the feed, calls poll()). settle() waits for it:
# for tests and an agent's render, never in update() or draw().

from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.clock import trace_on
from mojoui.draw import rect, circle
from mojoui.theme import Palette
from mojoui.video import VideoInfo
from mojoui.framefeed import FrameFeed
from std.time import sleep
from mojoui.picture import draw_fitted, fitted_box
from mojoui.draw import with_alpha
from mojoui.view import View, Button, Canvas, Text, HStack, VStack, Card, CAPTION, ICON_ONLY, NO_MSG, CENTER, PAN, TAP, PRESS, KEY, SET_TO
from mojoui.charts import fixed

# Messages a Player owns, from msg_base
comptime PLAY = 0
comptime PAUSE = 1
comptime SCRUB = 2  # the scrubber's gestures
comptime VIDEO = 3  # the picture's gestures
comptime FRAME = 4  # display frames, while playing
comptime MESSAGES = 5

comptime SCRUB_PAD = 10.0  # points of room at each end of the scrubber's track
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


@fieldwise_init
struct Mark(Copyable, Movable, ImplicitlyCopyable):
    """A box over one frame of a video, in the video's pixels; `flagged` draws it in the warning tone (a damaged pallet)."""

    var frame: Int
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var flagged: Bool


def outline(mut s: Surface, x: Float64, y: Float64, w: Float64, h: Float64, width: Float64, color: UInt32, radius: Float64):
    """A rounded rectangle's outline (`width` pixels), anti-aliased: four rounded strips."""
    rect(s, x, y, w, width, color, min(radius, width / 2))
    rect(s, x, y + h - width, w, width, color, min(radius, width / 2))
    rect(s, x, y + width, width, h - 2 * width, color)
    rect(s, x + w - width, y + width, width, h - 2 * width, color)


struct Player(Movable):
    var state: PlayerState
    var info: VideoInfo  # the video's size, rate and length (zeros until the probe lands: ready())
    var feed: FrameFeed  # the decoder, on its own thread
    var buf: List[UInt32]  # the frame `have`, decoded (taken from the feed: the newest that landed)
    var have: Int  # which frame buf holds (-1: none yet)
    var version: Int  # the picture's version: moves when a frame or the probe lands, or the marks change
    var base: Int  # message numbers base … base + MESSAGES - 1
    var canvas: Int  # the picture's canvas id; the scrubber's is canvas + 1
    var scrub_w: Float64  # the scrubber's width in points, from its last draw
    var marks: List[List[Mark]]  # per frame: the boxes drawn over it (set_marks), empty: none
    var marked: Int  # how many times the marks were set

    def __init__(out self, path: String, msg_base: Int = 100, canvas_base: Int = 100) raises:
        """Opens `path` without waiting: the probe runs on the feed's thread. Raises only when the file is missing."""
        self.feed = FrameFeed(path)
        self.info = VideoInfo.unknown(path)
        self.state = PlayerState(30.0, 1, 0.0)
        self.buf = List[UInt32]()
        self.have = -1
        self.version = 0
        self.base = msg_base
        self.canvas = canvas_base
        self.scrub_w = 0.0
        self.marks = List[List[Mark]]()
        self.marked = 0

    def __init__(out self, info: VideoInfo, msg_base: Int = 100, canvas_base: Int = 100):
        """A video already probed (another player's or a feed's info): ready at once, its first frame on its way."""
        self.feed = FrameFeed(info)
        self.info = info
        self.state = PlayerState(info.fps, info.frames, info.duration)
        self.buf = List[UInt32]()
        self.have = -1
        self.version = 0
        self.base = msg_base
        self.canvas = canvas_base
        self.scrub_w = 0.0
        self.marks = List[List[Mark]]()
        self.marked = 0
        self.feed.want(0)

    def ready(self) -> Bool:
        """The probe has landed: info, state.frames and state.duration are the video's."""
        return self.info.known()

    def problem(self) -> String:
        """Why it can't play ("": opening or fine): the feed's reason, e.g. "not a video"."""
        return self.feed.problem()

    def path(self) -> String:
        return self.info.path

    def pending(self) -> Bool:
        """Still opening, or the frame on show hasn't landed: the picture keeps asking for display frames."""
        return self.feed.pending()

    def poll(mut self) -> Bool:
        """Takes what landed on the feed's thread (the probe, the newest frame) and asks for the frame on show. True when
        the picture changed (its version moved). Cheap: call it on any event (update() does)."""
        var changed = False
        if not self.info.known() and self.feed.ready():
            self.info = self.feed.info()
            var playing = self.state.playing
            self.state = PlayerState(self.info.fps, self.info.frames, self.info.duration)
            self.state.playing = playing
            changed = True
        if self.info.known():
            self.feed.want(self.state.frame)
        if self.feed.take(self.buf):
            self.have = self.feed.frame_of_take
            changed = True
        if changed:
            self.version += 1
        return changed

    def settle(mut self, seconds: Float64 = 10.0) -> Bool:
        """Waits until the frame on show is in buf (tests, an agent's render, a still for the editor: never update() or
        draw()). False when it timed out or the file can't be read."""
        var waited = 0.0
        _ = self.poll()
        while waited < seconds and self.problem() == "":
            if self.info.known() and self.have == self.state.frame and not self.feed.decoding():
                return True
            sleep(0.001)
            waited += 0.001
            _ = self.poll()
        return self.info.known() and self.have == self.state.frame

    def owns(self, message: Int) -> Bool:
        return self.base <= message < self.base + MESSAGES

    def set_marks(mut self, marks: List[Mark]):
        """Boxes to draw over the picture, each on its own frame (an empty list: none). Kept by frame, so drawing reads
        only the frame on show."""
        self.marks = List[List[Mark]]()
        var last = self.state.frames
        for m in marks:
            last = max(last, m.frame)
        for _ in range(last + 1):
            self.marks.append(List[Mark]())
        for m in marks:
            if 0 <= m.frame < len(self.marks):
                self.marks[m.frame].append(m)
        self.marked += 1
        self.version += 1  # (the picture is drawn again with them)

    def seek(mut self, seconds: Float64):
        """Shows the frame at `seconds` (paused or playing on from there): what a row of an analysis seeks to."""
        var before = self.state.frame
        self.state.seek(seconds)
        if self.info.known():
            self.feed.want(self.state.frame)  # (returns at once: the frame lands later)
        if self.state.frame != before:
            self._trace()

    def marks_on(self, frame: Int) -> Int:
        """How many boxes frame `frame` has."""
        return len(self.marks[frame]) if 0 <= frame < len(self.marks) else 0

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
            elif event.number == SET_TO:  # an agent set the time straight (event.text: seconds), the scrubber's .settable()
                try:
                    self.state.seek(Float64(event.text))
                except:
                    pass
        elif which == VIDEO:
            if event.number == TAP:
                self.state.toggle()
            elif event.number == KEY:
                self._key(event.text)
        if self.state.frame != before or self.state.playing != was_playing:
            self._trace()
        _ = self.poll()  # (asks for the frame now on show; takes what landed)
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
        var w = self.info.width if self.info.known() else 16  # (until the probe lands: 16:9)
        var h = self.info.height if self.info.known() else 9
        return max(width * h // max(w, 1), 1)

    def view(self, width: Int = 0) -> View:
        """The picture and its controls. `width`: the points the player is wide, when the app knows them: the picture is then
        exactly the video's shape (no bands above and below); 0: it takes the room it is given and fits the video inside."""
        var playing = self.state.playing
        var button = (Button("pause", on_tap=self.base + PAUSE, style=ICON_ONLY, icon="pause").alternate("play", self.base + PLAY) if playing
                      else Button("play", on_tap=self.base + PLAY, style=ICON_ONLY, icon="play").alternate("pause", self.base + PAUSE))  # (an agent gets both: D-855)
        var ticks = playing or self.pending()  # (display frames while it plays, and until the frame wanted lands)
        var picture = Canvas(self.canvas, self.version, on_gesture=self.base + VIDEO, on_frame=self.base + FRAME if ticks else NO_MSG, keys=True)
        picture = picture^.fill().tag("video").label(self._words())
        if width > 0:
            picture = picture^.height(self.height_for(width))
        else:
            picture = picture^.grow()
        var scrubber = Canvas(self.canvas + 1, self.state.frame, on_gesture=self.base + SCRUB, keys=True).height(28).grow().fill().tag("seek")
        scrubber = scrubber^.settable("seconds", 0.0, self.state.duration).tooltip("Seek: drag, or set a time in seconds")
        var controls = HStack(button^.tag("pause" if playing else "play"), scrubber^, Text(self.state.time_text(), style=CAPTION).tag("time").min_width(92),
                              spacing=10).align(CENTER).fill()
        # the controls sit on a card (a quiet bar under the picture): the scrubber paints its track on the card's colour
        var bar = Card(controls^, spacing=0).padding(6, 12).fill().tag("player-controls")  # (themes keep these always shown, D-856)
        if width > 0:
            return VStack(picture^, bar^, spacing=10).width(width)
        return VStack(picture^, bar^, spacing=10).grow().fill()

    def describe(self) -> String:
        """For an agent: where the video is, and how to seek (tap the "seek" canvas at x points from its left)."""
        ref s = self.state
        var head = ("t=" + fixed(s.t(), 3) + " s of " + fixed(s.duration, 3) + " s, frame " + String(s.frame) + " of " + String(s.frames)
                    + (", playing" if s.playing else ", paused") + ". Seek: set the seek view to a time in seconds (its value)")
        if self.scrub_w <= 2 * SCRUB_PAD:  # (not drawn yet: no track to tap on)
            return head + "."
        return (head + ", or tap it at x points from its left; its track runs from x=" + fixed(SCRUB_PAD, 0) + " (0 s) to x="
                + fixed(self.scrub_w - SCRUB_PAD, 0) + " (the end).")

    # ---------- drawing ----------

    def _words(self) -> String:
        """The picture's name for a screen reader: the file and where it is."""
        var slash = self.info.path.rfind("/")
        var name = String(self.info.path[byte=slash + 1:]) if slash >= 0 else self.info.path
        if self.problem() != "":
            return "Video " + name + ": can't be played"
        if not self.ready():
            return "Video " + name + ", opening"
        return "Video " + name + ", " + self.state.time_text() + (", playing" if self.state.playing else ", paused")

    def draw(mut self, canvas: Int, mut s: Surface, backdrop: UInt32, pal: Palette):
        if canvas == self.canvas + 1:
            self._draw_scrubber(s, pal)
        elif canvas == self.canvas:
            self._draw_picture(s, backdrop)
            self._draw_marks(s, pal)

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
        # never waits: asks for the frame on show and paints the newest one that landed (its version is moved by poll())
        if self.info.known():
            self.feed.want(self.state.frame)
        if self.feed.take(self.buf):
            self.have = self.feed.frame_of_take
        if self.have < 0 or len(self.buf) != self.info.width * self.info.height:
            s.fill(backdrop)
            return
        draw_fitted(s, self.buf, self.info.width, self.info.height, backdrop)

    def _draw_marks(self, mut s: Surface, pal: Palette):
        """The frame's boxes, light: a thin rounded outline (the accent; flagged ones in the warning tone, a little
        heavier), so the picture stays the subject."""
        var f = self.have  # (the boxes of the frame painted, which may trail the one wanted)
        if self.have < 0 or self.marks_on(f) == 0:
            return
        var fit = fitted_box(s, self.info.width, self.info.height)
        var k = s.scale
        for m in self.marks[f]:
            var x = fit[0] + Float64(m.x) * fit[2]
            var y = fit[1] + Float64(m.y) * fit[2]
            var w = Float64(m.w) * fit[2]
            var h = Float64(m.h) * fit[2]
            if w < 4 or h < 4:
                continue
            var colour = with_alpha(pal.warn, 0.95) if m.flagged else with_alpha(pal.accent, 0.8)
            outline(s, x - 2 * k, y - 2 * k, w + 4 * k, h + 4 * k, (2.5 if m.flagged else 1.5) * k, colour, 6 * k)
