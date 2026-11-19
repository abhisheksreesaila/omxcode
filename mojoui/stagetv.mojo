# mojoui.stagetv: the Stage's TV (goal 77 M7d, D-7810…). When she explains, the chat bar (orb, text box, mic) grows over the
# whole centre column, like gitaway's cover postcard: ONE box reshapes, its height on a soft spring (gitaway's --spring-soft,
# 900 ms, 1.7 % overshoot) while its faces crossfade: the tiles fade out fast (260 ms), the TV's content fades in after 160 ms.
# Inside it: a card on the left (the explanation: a Word, an Iso, a TripMap, a Sight card), the conversation on the right, the
# text box still at the bottom. A follow-up swaps the card in place (the old one fades out, the new one arrives); × or ~12 s of
# quiet after she finishes shrinks it back and the tiles fade back in. With no card (just chatting) the conversation is
# centred with suggestion chips.
#
#   var tv = StageTV(TV_CANVAS, TV_VEIL, on_frame=TV_FRAME, on_close=TV_CLOSE)       # the app owns the state
#   update():  TV_FRAME (and any other frame) → tv.tick(tv_now())                       # steps it; closes after the quiet
#              TV_CLOSE → tv.close(tv_now())
#              she explains → tv.open(tv_now(), "How a heat pump works", "iso-heat")   # a card key the app understands
#              a follow-up → tv.open(tv_now(), "Ephemeral", "word-ephemeral")           # (open already: the card swaps)
#              she starts / stops talking → tv.speaking(tv_now(), True / False)         # the quiet counts from her last word
#   resize():  tv.resize(width)                                                         # (a phone's one column draws it inset)
#   view():    Stage(top, left, tiles, right, chat, w, h, tv=tv, content=TVContent(card_for(tv.card), StageThread(msgs, …), chips))
#   draw():    if tv.draws(canvas): tv.draw(canvas, surface, counter_tv_look(dark))     # the box, its shadow, the veils
#
# How (D-7810): the box is drawn on a see-through Canvas laid over the centre column (Stage puts it there), so its height
# follows the curve on every frame on every host (the web streams a canvas's frames; view patches are paced to 10 a second
# there). The native views sit over it in a band across the column's bottom (Overlay .pin(STRETCH, END)): the chat bar, the
# same TextField all along (typing and IME are never interrupted), and, while open, the TV's body (head, card, thread). The
# tiles fade under a veil of the stage's own ground drawn on the same canvas; the body's content leaves under a second veil
# (a canvas over the body, in the box's colour) and arrives on the host's own spring (View.arrive()). Less motion
# (Surface.still or set_reduced): every change lands at once.
#
#   soft_spring(x) / ease_v2(x)      the curves (CSS linear() and cubic-bezier(.2, .8, .2, 1)), x in 0…1
#   tv.box(area_w, area_h)            the box's rect in the canvas (points) at this moment: TVBox(x, y, w, h, radius)
#   tv.record()                       one line of numbers for a checker's per-frame trace (TV …)

from std.math import sqrt, exp
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.draw import with_alpha
from mojoui.theme import Shadow
from mojoui.table import capitals
from mojoui.pointer import Part
from mojoui.view import View, Node, Text, Button, VStack, HStack, Spacer, Scroll, Overlay, Canvas, ICON_ONLY, PLAIN, NO_MSG, START, CENTER, END

comptime TV_MORPH_MS = 900  # the box's height: --spring-soft over 900 ms
comptime TV_LEAVE_MS = 260  # what leaves fades out (ease-v2)
comptime TV_ARRIVE_DELAY_MS = 160  # what arrives starts after this
comptime TV_ARRIVE_MS = 420  # … and fades in over this (ease-v2)
comptime TV_LIFT_MS = 200  # after a swap, the card's veil lifts over this while the new card arrives
comptime TV_QUIET_MS = 12_000  # quiet this long after she finishes: the TV closes
comptime TV_BAR_H = 64  # the chat bar's pill (mojoui.stage's STAGE_BAR_H)
comptime TV_BOTTOM = 14  # the bar from the column's bottom (STAGE_BOTTOM)
comptime TV_ROW_GAP = 12  # the stage panel to the bar (STAGE_ROW_GAP)
comptime TV_PHONE_STRIP = 8  # a phone's bar strip: 8 above and below the pill
comptime TV_PHONE_PAD = 14  # a phone's sides (STAGE_PHONE_PAD), and the open box's top
comptime TV_TOP = 14  # the room over the open box (desktop: the top bar's gap, which the columns own with a TV): the spring's overshoot pokes into it
comptime TV_RADIUS_BAR = 32.0  # the pill's corners …
comptime TV_RADIUS_OPEN = 30.0  # … become the stage's
comptime TV_PAD_V = 16  # the body's inside (.tv-body: 16px 18px 8px)
comptime TV_PAD_H = 18
comptime TV_PHONE_PAD_H = 6  # a phone's body sides inside its 14 pt inset: the card nearly as wide as the screen (goal 77 M7f)
comptime TV_GAP = 16  # the card to the conversation
comptime TV_THREAD_MIN = 240  # the conversation's least width, else 30 % (.tv-main: minmax(0, 1fr) minmax(240px, 30%))
comptime TV_CARD_MIN = 360  # side by side only when the card keeps this much beside the conversation; else stacked
comptime TV_CHAT_MAX = 720  # with no card, the conversation centred at most this wide

comptime TV_YOU = 0  # StageMsg.who
comptime TV_OMX = 1


def tv_now() -> Int:
    """The wall clock in microseconds (the TV's timeline: what the eye sees, whichever canvas sent the frame)."""
    return now_ns() // 1000


# ---------- the curves ----------

def soft_spring(x: Float64) -> Float64:
    """gitaway's --spring-soft (cover.css): linear(0, 0.006, 0.025 2.8%, 0.101 6.1%, 0.539 18.9%, 0.721 25.3%, 0.849 31.5%,
    0.937 38.1%, 0.968 41.8%, 0.991 45.7%, 1.006 50.1%, 1.015 55%, 1.017 63.9%, 1.001 85.9%, 1): the same points CSS
    interpolates (0.006 takes the even place between its neighbours, 1.4 %). Peaks at 1.017 (63.9 %), 1 at the end."""
    var xs: List[Float64] = [0.0, 0.014, 0.028, 0.061, 0.189, 0.253, 0.315, 0.381, 0.418, 0.457, 0.501, 0.55, 0.639, 0.859, 1.0]
    var ys: List[Float64] = [0.0, 0.006, 0.025, 0.101, 0.539, 0.721, 0.849, 0.937, 0.968, 0.991, 1.006, 1.015, 1.017, 1.001, 1.0]
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    for i in range(1, len(xs)):
        if x <= xs[i]:
            var t = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
            return ys[i - 1] + (ys[i] - ys[i - 1]) * t
    return 1.0


def _bez(t: Float64, a: Float64, b: Float64) -> Float64:
    """One axis of a CSS cubic-bezier(·) at parameter t (end points 0 and 1)."""
    var u = 1.0 - t
    return 3.0 * u * u * t * a + 3.0 * u * t * t * b + t * t * t


def ease_v2(x: Float64) -> Float64:
    """gitaway's --ease-v2: cubic-bezier(.2, .8, .2, 1) (fades), x in 0…1."""
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    var lo = 0.0
    var hi = 1.0
    for _ in range(40):  # (x(t) rises monotonically: halve until it is found)
        var mid = (lo + hi) / 2.0
        if _bez(mid, 0.2, 0.2) < x:
            lo = mid
        else:
            hi = mid
    return _bez((lo + hi) / 2.0, 0.8, 1.0)


def _clamp01(x: Float64) -> Float64:
    return min(max(x, 0.0), 1.0)


# ---------- the look ----------

struct TVLook(Copyable, Movable):
    """The TV's colours from the theme (themes.omxqua.counter_tv_look): the box (the chat bar's card colour), the stage's
    ground the tiles fade into, the room (a phone's page), the open box's shadows (light: sh3; night: sh2)."""

    var card: UInt32
    var ground: UInt32
    var room: UInt32
    var shadows: List[Shadow]

    def __init__(out self, card: UInt32, ground: UInt32, room: UInt32, var shadows: List[Shadow]):
        self.card = card
        self.ground = ground
        self.room = room
        self.shadows = shadows^


@fieldwise_init
struct TVBox(Copyable, Movable, ImplicitlyCopyable):
    """The box's rect (points, in the TV canvas) and its corners."""

    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64
    var radius: Float64


@fieldwise_init
struct TVLayout(Copyable, Movable, ImplicitlyCopyable):
    """Where the open TV's parts go (points): the body's height (above the chat bar), the card's width (0: none; a phone:
    the card's height, stacked over the thread), the conversation's width, the body's sides (a phone's inset)."""

    var body_h: Int
    var card_w: Int
    var card_h: Int
    var thread_w: Int
    var inset: Int
    var compact: Bool
    var stacked: Bool  # the card over the conversation (a phone; a column too narrow for both side by side: a portrait tablet)


def tv_layout(area_w: Float64, area_h: Float64, compact: Bool, has_card: Bool) -> TVLayout:
    """The open TV's parts at the TV canvas's size (the centre column; a phone: the window). Desktop: the body is the
    column above the bar, the card takes what the conversation leaves (1fr | max(240, 30 %)), or, when that would leave the
    card under TV_CARD_MIN (a portrait tablet's narrow column), the card over the conversation as on a phone. A phone: the box
    14 in from the sides and the top, the card over the conversation (1.4fr / 1fr)."""
    var inset = TV_PHONE_PAD if compact else 0
    var body_h = Int(area_h) - (TV_PHONE_STRIP * 2 + TV_BAR_H + TV_PHONE_PAD if compact else TV_BOTTOM + TV_BAR_H + TV_TOP)
    body_h = max(body_h, 0)
    var inner_w = Int(area_w) - 2 * ((TV_PHONE_PAD_H if compact else TV_PAD_H) + inset)
    if not has_card:
        return TVLayout(body_h, 0, 0, min(inner_w, TV_CHAT_MAX), inset, compact, compact)
    var thread_w = max(TV_THREAD_MIN, Int(Float64(inner_w) * 0.30))
    if compact or inner_w - TV_GAP - thread_w < TV_CARD_MIN:
        var room = max(body_h - 2 * TV_PAD_V - 48 - TV_GAP, 0)  # (48: the head and its gap)
        return TVLayout(body_h, inner_w, Int(Float64(room) * 1.4 / 2.4), inner_w, inset, compact, True)
    return TVLayout(body_h, max(inner_w - TV_GAP - thread_w, 0), 0, thread_w, inset, compact, False)


# ---------- the state ----------

struct StageTV(Copyable, Movable):
    """The TV's state: open or closed, where its box is on the curve, what it shows. Times are microseconds on one clock
    (tv_now() in an app; anything steady in a test). `canvas` 0: the Stage has no TV (M7a's chat bar alone)."""

    var canvas: Int  # the box's canvas (over the centre column)
    var veil: Int  # the body's veil canvas (over the TV's content)
    var on_frame: Int  # the frame message both canvases send while anything moves (and while open: the quiet's clock)
    var on_close: Int  # the × button's message
    var quiet_ms: Int
    var is_open: Bool  # where it is going
    var t0: Int  # when the last open or close began
    var p_from: Float64  # the box's progress (0 the bar, 1 the whole column) when it began …
    var p_to: Float64  # … and where it goes
    var hide_from: Float64  # the tiles' veil when it began
    var body: Bool  # the TV's body (head, card, thread) is on screen
    var leave_t0: Int  # a leaving veil began (-1: none): the whole body (closing) or the card (a swap)
    var leave_whole: Bool
    var lift_t0: Int  # after a swap: the card's veil lifts (-1: none)
    var card: String  # the card on screen ("" none)
    var next_card: String  # the card asked for (a swap's target)
    var title: String
    var next_title: String
    var heard_at: Int  # her last word, or the last thing done in the TV: the quiet counts from here
    var talking: Bool
    var now: Int
    var version: Int  # moves on whenever the canvases' pictures change
    var reduced: Bool
    var compact: Bool  # a phone's one column (resize)
    var area_w: Float64  # the TV canvas's size in points, from its last draw (0: not drawn yet)
    var area_h: Float64
    var closed_by: String  # why it last closed: "x", "quiet", "app"
    var frames: Int  # frames ticked (a checker's count)
    var drawn: Bool  # the TV canvas has told its size (area_w/area_h); until then they are guessed from the window (resize)

    def __init__(out self, canvas: Int = 0, veil: Int = 0, on_frame: Int = NO_MSG, on_close: Int = NO_MSG, quiet_ms: Int = TV_QUIET_MS):
        self.canvas = canvas
        self.veil = veil
        self.on_frame = on_frame
        self.on_close = on_close
        self.quiet_ms = quiet_ms
        self.is_open = False
        self.t0 = 0
        self.p_from = 0.0
        self.p_to = 0.0
        self.hide_from = 0.0
        self.body = False
        self.leave_t0 = -1
        self.leave_whole = False
        self.lift_t0 = -1
        self.card = ""
        self.next_card = ""
        self.title = ""
        self.next_title = ""
        self.heard_at = 0
        self.talking = False
        self.now = 0
        self.version = 0
        self.reduced = False
        self.compact = False
        self.area_w = 0
        self.area_h = 0
        self.closed_by = ""
        self.frames = 0
        self.drawn = False

    def on(self) -> Bool:
        """The Stage has a TV (a canvas to draw its box on)."""
        return self.canvas != 0

    def draws(self, canvas: Int) -> Bool:
        return self.canvas != 0 and (canvas == self.canvas or canvas == self.veil)

    def resize(mut self, width: Int, height: Int = 0):
        """The window's size (App.resize): a phone's one column (≤ 760) draws the box inset, its body stacked. With the height,
        and until the TV canvas has drawn once, its size is guessed from the window (the centre column as mojoui.stage lays it
        out, under the top bar), so the body can arrive in a window that hasn't painted yet (a test window that is never shown)."""
        self.compact = width <= 760
        if height > 0 and not self.drawn:
            var w = Float64(width)
            if not self.compact:  # (the centre column: minmax(0, 2.75fr) of three, or 2.6fr of two under 1000)
                w = (w - 54.0) * 2.75 / 4.75 if width >= 1000 else (w - 45.0) * 2.6 / 3.6
            self.area_w = w
            self.area_h = Float64(height) - (0.0 if self.compact else 52.0)
        self.version += 1

    def set_reduced(mut self, reduced: Bool):
        """Less motion: every change lands at once."""
        self.reduced = reduced

    # --- where things are at self.now ---

    def progress(self) -> Float64:
        """The box: 0 the chat bar, 1 the whole column (past 1 on the spring's overshoot)."""
        if self.reduced:
            return self.p_to
        var x = Float64(self.now - self.t0) / (Float64(TV_MORPH_MS) * 1000.0)
        return self.p_from + (self.p_to - self.p_from) * soft_spring(x)

    def tiles_hidden(self) -> Float64:
        """The veil over the tiles, 0…1: opening, it rises at once over 260 ms; closing, it holds 160 ms, then lifts over 420."""
        if self.reduced:
            return 1.0 if self.is_open else 0.0
        var ms = Float64(self.now - self.t0) / 1000.0
        if self.is_open:
            return self.hide_from + (1.0 - self.hide_from) * ease_v2(ms / Float64(TV_LEAVE_MS))
        return self.hide_from * (1.0 - ease_v2((ms - Float64(TV_ARRIVE_DELAY_MS)) / Float64(TV_ARRIVE_MS)))

    def leaving(self) -> Float64:
        """The veil over what is leaving the body (0 none … 1 gone): the whole body closing, or the card in a swap; after a
        swap it lifts again over 200 ms while the new card arrives."""
        if self.leave_t0 >= 0:
            return 1.0 if self.reduced else ease_v2(Float64(self.now - self.leave_t0) / (Float64(TV_LEAVE_MS) * 1000.0))
        if self.lift_t0 >= 0:
            return 0.0 if self.reduced else 1.0 - ease_v2(Float64(self.now - self.lift_t0) / (Float64(TV_LIFT_MS) * 1000.0))
        return 0.0

    def veils_card_only(self) -> Bool:
        """The body's veil covers only the card column (a swap) rather than the whole body (closing)."""
        return not (self.leave_t0 >= 0 and self.leave_whole)

    def moving(self) -> Bool:
        """Anything still on its way (the canvases redraw every frame)."""
        if self.reduced:
            return False
        var ms = (self.now - self.t0) // 1000
        var box = self.p_from != self.p_to and ms < TV_MORPH_MS
        var fade = (self.is_open and self.hide_from < 1.0 and ms < TV_LEAVE_MS) or (not self.is_open and self.hide_from > 0.0 and ms < TV_ARRIVE_DELAY_MS + TV_ARRIVE_MS)
        return box or fade or self.leave_t0 >= 0 or self.lift_t0 >= 0 or (self.is_open and not self.body)

    def ticking(self) -> Bool:
        """The canvases ask for frames: while anything moves, and while open (the quiet's clock)."""
        return self.canvas != 0 and (self.is_open or self.moving())

    def visible(self) -> Bool:
        """Anything of the TV to draw beyond M7a's chat bar."""
        return self.is_open or self.moving() or self.progress() > 0.0005

    def box(self, area_w: Float64, area_h: Float64) -> TVBox:
        """The box at this moment in a TV canvas `area_w` × `area_h` points: from the chat bar's pill (64 high, 14 above the
        column's bottom) to the whole column (a phone: the window, 14 in, the strip's 8 under it)."""
        var p = self.progress()
        var inset = Float64(TV_PHONE_PAD) if self.compact else 0.0
        var bottom = area_h - (Float64(TV_PHONE_STRIP) if self.compact else Float64(TV_BOTTOM))
        var top = Float64(TV_PHONE_PAD) if self.compact else Float64(TV_TOP)
        var full = max(bottom - top, Float64(TV_BAR_H))
        var h = Float64(TV_BAR_H) + (full - Float64(TV_BAR_H)) * p
        var r = TV_RADIUS_BAR + (TV_RADIUS_OPEN - TV_RADIUS_BAR) * _clamp01(p)
        return TVBox(inset, bottom - h, area_w - 2 * inset, h, r)

    def hides_tiles(self) -> Bool:
        """The TV covers the stage's tiles (open, or still on its way there or back with the tiles' veil up): what an app
        tells mojoui.pointer is on screen must leave the tiles out (pointed_parts), so she never points at a hidden tile."""
        return self.is_open or self.tiles_hidden() > 0.5

    def layout(self) -> TVLayout:
        return tv_layout(self.area_w, self.area_h, self.compact, self.card != "")

    # --- what the app does ---

    def open(mut self, now: Int, title: String = "", card: String = ""):
        """She explains (or the orb is tapped): the bar grows into the TV. Open already: a new card swaps in (a follow-up)."""
        self.now = now
        self.heard_at = now
        if self.is_open:
            self.show(now, card, title)
            return
        var p = self.progress()
        var hide = self.tiles_hidden()
        self.is_open = True
        self.t0 = now
        self.p_from = p
        self.p_to = 1.0
        self.hide_from = hide
        self.leave_t0 = -1
        self.lift_t0 = -1
        if not self.body:  # (closing and opened again before the body went: it stays, as it was)
            self.card = card
            self.title = title
        elif card != self.card:
            self.next_card = card
            self.next_title = title
            self.leave_t0 = now
            self.leave_whole = False
        self.version += 1
        self.tick(now)

    def show(mut self, now: Int, card: String, title: String = ""):
        """A follow-up: the card in the TV changes in place (the old one fades out, the new one arrives)."""
        self.now = now
        self.heard_at = now
        if not self.is_open:
            self.open(now, title, card)
            return
        if not self.body:  # (not on screen yet: it arrives as this one)
            self.card = card
            self.title = title if title != "" else self.title
            return
        if card == self.card and self.leave_t0 < 0:
            if title != "":
                self.title = title
            return
        self.next_card = card
        self.next_title = title if title != "" else self.title
        if self.leave_t0 < 0:
            self.leave_t0 = now
            self.leave_whole = False
            self.lift_t0 = -1
        self.version += 1

    def close(mut self, now: Int, why: String = "x"):
        """× (or the quiet): it shrinks back into the chat bar; its body fades out, the tiles fade back in."""
        self.now = now
        if not self.is_open:
            return
        var p = self.progress()
        var hide = self.tiles_hidden()
        self.is_open = False
        self.t0 = now
        self.p_from = p
        self.p_to = 0.0
        self.hide_from = hide
        self.closed_by = why
        self.lift_t0 = -1
        if self.body:
            self.leave_t0 = now
            self.leave_whole = True
        self.version += 1
        self.tick(now)

    def speaking(mut self, now: Int, talking: Bool):
        """She started (True) or finished (False) a reply: the quiet counts from when she finishes."""
        self.talking = talking
        self.heard_at = now

    def touch(mut self, now: Int):
        """Something happened in the TV (typing, a tap on the card): the quiet starts again."""
        self.heard_at = now

    def tick(mut self, now: Int) -> Bool:
        """One frame at `now`: the body arrives 160 ms into opening, what is leaving goes when its veil is up, the quiet
        closes it. True when the screen changed shape (the app's view moved on)."""
        self.now = max(now, self.now)
        self.frames += 1
        var changed = False
        if self.moving() or self.leave_t0 >= 0 or self.lift_t0 >= 0:
            self.version += 1
        var ms = (self.now - self.t0) // 1000
        if self.is_open and not self.body and (self.reduced or ms >= TV_ARRIVE_DELAY_MS) and self.area_h > 0:
            self.body = True
            changed = True
        if self.leave_t0 >= 0 and (self.reduced or (self.now - self.leave_t0) // 1000 >= TV_LEAVE_MS):
            self.leave_t0 = -1
            if self.leave_whole:  # closed: the body goes, the next open starts empty
                self.body = False
                self.card = ""
                self.title = ""
            else:  # a swap: the new card is on screen under the veil, which lifts
                self.card = self.next_card
                self.title = self.next_title
                self.lift_t0 = -1 if self.reduced else self.now
            changed = True
        if self.lift_t0 >= 0 and (self.now - self.lift_t0) // 1000 >= TV_LIFT_MS:
            self.lift_t0 = -1
        if self.is_open and self.body and not self.talking and (self.now - self.heard_at) // 1000 >= self.quiet_ms:
            self.close(self.now, "quiet")
            changed = True
        return changed

    # --- drawing ---

    def draw(mut self, canvas: Int, mut s: Surface, look: TVLook):
        """The box's canvas: the veil over the tiles, the box's shadow and the box (under the native chat bar and body);
        the body's veil canvas: the box's colour over what is leaving. Both see-through elsewhere. Records the canvas's
        size (the body's height comes from it)."""
        if s.still and not self.reduced:
            self.reduced = True
        var k = s.scale
        s.fill(0)
        if canvas == self.canvas:
            var w = s.points_width()
            var h = s.points_height()
            if w < 2 * Float64(TV_BAR_H) or h < 2 * Float64(TV_BAR_H):  # (a canvas not laid out yet, the web's 1x1 first frame: not the column)
                return
            self.drawn = True
            if w != self.area_w or h != self.area_h:
                self.area_w = w
                self.area_h = h
            if not self.visible():
                return
            var hide = self.tiles_hidden()
            if hide > 0.001:
                if self.compact:  # (a phone: the page above the strip fades into the room)
                    _paint(s, 0, 0, w * k, (h - Float64(TV_PHONE_STRIP * 2 + TV_BAR_H)) * k, 0, with_alpha(look.room, hide))
                else:  # the stage panel (under the top's gap, above the bar and its gap) fades into its own ground
                    _paint(s, 0, Float64(TV_TOP) * k, w * k, (h - Float64(TV_TOP + TV_BOTTOM + TV_BAR_H + TV_ROW_GAP)) * k, 30 * k, with_alpha(look.ground, hide))
            var b = self.box(w, h)
            var lift = _clamp01(self.progress() * 3.0)  # (the open box's own shadow grows in as it lifts off the bar)
            for sh in look.shadows:
                if not sh.inset:
                    _shadow(s, b.x * k, b.y * k, b.w * k, b.h * k, b.radius * k, sh, k, lift)
            _paint(s, b.x * k, b.y * k, b.w * k, b.h * k, b.radius * k, look.card)
        elif canvas == self.veil:
            var a = self.leaving()
            if a <= 0.001:
                return
            if self.veils_card_only():  # the card's column (and the title over it, which changes with it)
                var lay = self.layout()
                var right = Float64(lay.inset + TV_PAD_H + lay.card_w) + Float64(TV_GAP) / 2
                if lay.stacked:
                    _paint(s, 0, 0, s.points_width() * k, Float64(TV_PAD_V + 48 + lay.card_h + TV_GAP // 2) * k, 0, with_alpha(look.card, a))
                else:
                    _paint(s, 0, 0, right * k, s.points_height() * k, 0, with_alpha(look.card, a))
            else:
                _paint(s, 0, 0, s.points_width() * k, s.points_height() * k, 0, with_alpha(look.card, a))

    def record(self) -> String:
        """One line for a checker (all in points, at self.now): the box's y and height, the tiles' veil, the body's veil,
        whether the body is on screen, the card, the canvas's size, open or closed."""
        var b = self.box(self.area_w, self.area_h)
        return ("TV y=" + _f(b.y) + " h=" + _f(b.h) + " r=" + _f(b.radius) + " p=" + _f(self.progress()) + " hide=" + _f(self.tiles_hidden())
                + " leave=" + _f(self.leaving()) + " body=" + ("1" if self.body else "0") + " card=" + (self.card if self.card != "" else "-")
                + " area=" + _f(self.area_w) + "x" + _f(self.area_h) + " open=" + ("1" if self.is_open else "0"))


def _f(x: Float64) -> String:
    var v = Int(x * 1000.0 + (0.5 if x >= 0 else -0.5))
    var neg = v < 0
    if neg:
        v = -v
    var frac = String(v % 1000)
    while frac.byte_length() < 3:
        frac = "0" + frac
    return ("-" if neg else "") + String(v // 1000) + "." + frac


def _sdf(px: Float64, py: Float64, x: Float64, y: Float64, w: Float64, h: Float64, r: Float64) -> Float64:
    """Signed distance to a rounded rectangle's edge (negative inside), pixels."""
    var hw = w / 2
    var hh = h / 2
    var rr = min(max(r, 0.0), min(hw, hh))
    var qx = abs(px - (x + hw)) - (hw - rr)
    var qy = abs(py - (y + hh)) - (hh - rr)
    var ox = max(qx, 0.0)
    var oy = max(qy, 0.0)
    return sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0.0) - rr


def _over(d: UInt32, c: UInt32, cov: Float64) -> UInt32:
    """`c` over `d`, straight alpha (a see-through canvas keeps what it leaves clear)."""
    var a = cov * Float64(Int((c >> 24) & 0xFF)) / 255.0
    if a <= 0.0:
        return d
    var da = Float64(Int((d >> 24) & 0xFF)) / 255.0
    var oa = a + da * (1 - a)
    if oa <= 0.0:
        return 0
    var r = (Float64(Int(c & 0xFF)) * a + Float64(Int(d & 0xFF)) * da * (1 - a)) / oa
    var g = (Float64(Int((c >> 8) & 0xFF)) * a + Float64(Int((d >> 8) & 0xFF)) * da * (1 - a)) / oa
    var b = (Float64(Int((c >> 16) & 0xFF)) * a + Float64(Int((d >> 16) & 0xFF)) * da * (1 - a)) / oa
    return UInt32(Int(r + 0.5)) | (UInt32(Int(g + 0.5)) << 8) | (UInt32(Int(b + 0.5)) << 16) | (UInt32(Int(oa * 255.0 + 0.5)) << 24)


def _paint(mut s: Surface, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, color: UInt32):
    """A rounded rectangle (pixels) composited over a see-through canvas: rows inside the corners written straight, the
    edges and corners anti-aliased."""
    if w <= 0 or h <= 0:
        return
    var r = min(max(radius, 0.0), min(w, h) / 2)
    var y0 = max(Int(y), 0)
    var y1 = min(Int(y + h) + 1, s.height)
    var x0 = max(Int(x), 0)
    var x1 = min(Int(x + w) + 1, s.width)
    var px = s.pixels()
    for py in range(y0, y1):
        var cy = Float64(py) + 0.5
        var row = py * s.width
        var corner_row = cy < y + r or cy > y + h - r
        var edge_row = cy < y + 1 or cy > y + h - 1
        for qx in range(x0, x1):
            var cx = Float64(qx) + 0.5
            var p = px.unsafe_offset(row + qx)
            if not corner_row and not edge_row and cx > x + 1 and cx < x + w - 1:
                p[] = _over(p[], color, 1.0)
                continue
            var cov = min(max(0.5 - _sdf(cx, cy, x, y, w, h, r), 0.0), 1.0)
            if cov > 0:
                p[] = _over(p[], color, cov)


def _shadow(mut s: Surface, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, sh: Shadow, k: Float64, strength: Float64):
    """A CSS box-shadow (outer) for the box, composited over a see-through canvas, at `strength` of its alpha; pixels the
    box will cover are skipped."""
    var a0 = Float64(Int((sh.color >> 24) & 0xFF)) / 255.0 * strength
    if a0 <= 0.0 or w <= 0 or h <= 0:
        return
    var color = with_alpha(sh.color, a0)
    var sigma = Float64(sh.blur) * k / 2.0
    var spread = Float64(sh.spread) * k
    var sx = x - spread
    var sy = y + Float64(sh.y) * k - spread
    var sw = w + 2 * spread
    var shh = h + 2 * spread
    if sw <= 0 or shh <= 0:
        return
    var sr = max(radius + spread, 0.0)
    var reach = 3.0 * sigma + 1.0
    var px = s.pixels()
    for py in range(max(Int(sy - reach), 0), min(Int(sy + shh + reach) + 1, s.height)):
        var cy = Float64(py) + 0.5
        var inside_rows = cy > y + radius + 1 and cy < y + h - radius - 1
        for qx in range(max(Int(sx - reach), 0), min(Int(sx + sw + reach) + 1, s.width)):
            var cx = Float64(qx) + 0.5
            if inside_rows and cx > x + 1 and cx < x + w - 1:
                continue  # (under the box)
            if _sdf(cx, cy, x, y, w, h, radius) < -1.0:
                continue
            var d = _sdf(cx, cy, sx, sy, sw, shh, sr)
            var cov: Float64
            if sigma <= 0.25:
                cov = min(max(0.5 - d, 0.0), 1.0)
            else:
                cov = 1.0 / (1.0 + exp(1.702 * d / sigma))
            if cov > 0.002:
                var p = px.unsafe_offset(py * s.width + qx)
                p[] = _over(p[], color, cov)


# ---------- the views ----------

@fieldwise_init
struct StageMsg(Copyable, Movable):
    """One line of the conversation: who said it (TV_YOU, TV_OMX), what, and when ("7:38")."""

    var who: Int
    var text: String
    var at: String


def StageThread(msgs: List[StageMsg], width: Int = 0) -> View:
    """The conversation as bubbles, newest at the bottom, following the newest (a pinned Scroll): you on the right in the
    ink (stage-msg-you), omx on the left on the stage's ground (stage-msg-omx), each with a small "You · 7:38" over it
    (stage-msg-meta, stage-msg-text). `width`: the column's width, so a bubble is at most 78 % of it (0: 78 % of 320)."""
    var most = Int(Float64(width if width > 0 else 320) * 0.78)
    var items = List[View]()
    for m in msgs:
        var you = m.who == TV_YOU
        var meta = ("You" if you else "omx") + ((" · " + m.at) if m.at != "" else "")
        var bubble = VStack(Text(meta).tag("stage-msg-meta"), Text(m.text).tag("stage-msg-text"), spacing=2).align(START).max_width(most).tag("stage-msg-you" if you else "stage-msg-omx")
        if you:
            items.append(HStack(Spacer(), bubble^, spacing=0).fill().arrive())
        else:
            items.append(HStack(bubble^, Spacer(), spacing=0).fill().arrive())
    return Scroll(VStack(items^, spacing=8).fill(), height=0, pinned=True).grow().fill().tag("stage-tv-thread")


def StageChips(phrases: List[String], first_msg: Int) -> View:
    """Things to ask when the TV has no card (the orb tapped, just chatting): one button each, message first_msg + k
    (stage-tv-chip), wrapped under the conversation."""
    var items = List[View]()
    for k in range(len(phrases)):
        items.append(Button(phrases[k], first_msg + k, PLAIN, "sparkles").tag("stage-tv-chip"))
    return VStack(items^, spacing=8).align(START).fill().tag("stage-tv-chips")


struct TVContent(Copyable, Movable):
    """What the TV shows, built by the app each view(): the card for StageTV.card (an empty View when there is none), the
    conversation (StageThread) and the chips shown when there is no card (StageChips, or an empty View)."""

    var card: View
    var thread: View
    var chips: View

    def __init__(out self):
        self.card = View(List[Node]())
        self.thread = View(List[Node]())
        self.chips = View(List[Node]())

    def __init__(out self, card: View, thread: View, chips: View):
        self.card = card.copy()
        self.thread = thread.copy()
        self.chips = chips.copy()



def tv_body(tv: StageTV, content: TVContent) -> View:
    """The open TV's body (above the chat bar, over the box): the head (omx, the title, ×), then the card on the left and the
    conversation on the right (a phone: the card over it), or the conversation centred with its chips; and the veil
    canvas over it all (what is leaving fades under it). Its height is the column's less the bar (from the canvas)."""
    var lay = tv.layout()
    var head = HStack(Text(capitals("omx")).tag("stage-tv-kicker"), Text(tv.title if tv.title != "" else "Today's conversation").grow().tag("stage-tv-title"),
                      Button("Back to the tiles", tv.on_close, ICON_ONLY, "x").width(36).height(36).tag("stage-tv-close"),
                      spacing=10).align(CENTER).fill().tag("stage-tv-head")
    var main: View
    var has_card = tv.card != "" and len(content.card.nodes) > 0
    if has_card:
        var card = VStack(Scroll(content.card.copy(), height=0).grow().fill(), spacing=0).fill().arrive().tag(
            "stage-tv-card-compact" if lay.stacked else "stage-tv-card")  # (a phone: the card's own frame is enough, no second one round it)
        if lay.stacked:
            main = VStack(card^.height(lay.card_h), content.thread.copy(), spacing=TV_GAP).grow().fill()
        else:
            main = HStack(card^.width(lay.card_w), VStack(content.thread.copy(), spacing=0).width(lay.thread_w).fill(), spacing=TV_GAP).grow().fill()
    else:
        var col = List[View]()
        col.append(content.thread.copy())
        if len(content.chips.nodes) > 0:
            col.append(content.chips.copy())
        main = HStack(VStack(col^, spacing=12).width(lay.thread_w).fill(), spacing=0).justify(CENTER).grow().fill()
    var body = VStack(head, main, spacing=12).padding(TV_PAD_V, (TV_PHONE_PAD_H if lay.compact else TV_PAD_H) + lay.inset).grow().fill().tag("stage-tv")
    var veil_frames = tv.on_frame if tv.leave_t0 >= 0 or tv.lift_t0 >= 0 else NO_MSG
    return Overlay(body, Canvas(tv.veil, tv.version, on_frame=veil_frames).passthrough().grow().fill().tag("stage-tv-veil")).height(lay.body_h).fill()


def pointed_parts(tv: StageTV, parts: List[Part], tiles: String) -> List[Part]:
    """`parts` less the tiles' while the TV hides them: those drawn inside the canvas tagged `tiles` (mojoui.livetiles'
    parts(card, inside)) or of the card `tiles` (a genui LiveTiles card). Pass the result to Pointer.know(); the ring's own
    layer stays over the whole page, so it still reaches the TV's card."""
    var out = List[Part]()
    var hide = tv.hides_tiles()
    for p in parts:
        if hide and (p.inside == tiles or p.card == tiles):
            continue
        out.append(p.copy())
    return out^
