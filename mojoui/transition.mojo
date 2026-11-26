# mojoui.transition: a view transition (the web's View Transitions API, for every host). The app says the next change should
# morph; the host takes a picture of the screen as it is, makes the change underneath, and blends the picture away while the
# new screen settles from a little smaller on omxqua's soft spring. Nothing snaps: a theme switched (light to dark, another
# accent), a canvas swapped, tiles reflowed, all arrive through the blend (owner, 2026-11-25: "liquid… no snap").
#
#   var morph: Morph                                   # in the app (an outbox, as mojoui.http.Http is)
#   self.morph.morph()                                 # in update(), with the change: the host blends old into new
#   def transition(mut self) -> Int: return self.morph.take()     # App.transition: asked after every update()
#
# The motion (the owner's approved TV motion, scaled to a whole screen): the old picture fades from 1 to 0 over MORPH_FADE_MS
# on the standard ease; the new screen, at full opacity under it, settles from MORPH_FROM_SCALE to 1 over MORPH_SETTLE_MS on the
# soft spring (--oq-spring, k170 c26). The new screen is there from the first frame, so no frame shows an empty window.
#
# Hosts: GTK snapshots the window's last frame (GtkWidgetPaintable's current image: its render node, no copy), lays it over the
# content in an overlay and fades it on the frame clock, the content's settle a CSS transform transition (MORPH_SETTLE_GTK, the
# spring as a cubic-bezier: GTK's CSS has no linear()); the web wraps the swap in document.startViewTransition (MORPH_SETTLE_WEB);
# AppKit / UIKit a fade CATransition on the content's layer.

comptime MORPH_FADE_MS = 420  # the old picture's fade
comptime MORPH_SETTLE_MS = 710  # the new screen's settle (--oq-spring-dur)
comptime MORPH_FROM_SCALE = 0.985
comptime MORPH_FADE_EASE = "cubic-bezier(0.4, 0, 0.2, 1)"  # the standard ease: a true blend at the middle
comptime MORPH_SETTLE_GTK = "cubic-bezier(0.3, 0.53, 0.05, 1)"  # --oq-spring fitted (within 2.4 % at every sample)
comptime MORPH_SETTLE_WEB = "linear(0, 0.023, 0.079, 0.154, 0.237, 0.322, 0.405, 0.482, 0.553, 0.617, 0.674, 0.723, 0.766, 0.803, 0.835, 0.862, 0.885, 0.905, 0.921, 0.935, 0.946, 0.955, 0.963, 0.97, 0.975, 0.98, 0.983, 0.986, 0.989, 0.991, 0.993, 0.994, 0.995, 0.996, 0.997, 0.997, 0.998, 0.998, 0.999, 0.999, 1)"  # --oq-spring


struct Morph(Copyable, Movable):
    """The app's outbox for a view transition: morph() asks for one with the change it is making; take() hands it to the
    runtime once (App.transition)."""

    var asked: Int  # ms; 0: none

    def __init__(out self):
        self.asked = 0

    def morph(mut self, ms: Int = MORPH_FADE_MS):
        self.asked = max(self.asked, max(ms, 1))

    def take(mut self) -> Int:
        var ms = self.asked
        self.asked = 0
        return ms


def fade_ease(t: Float64) -> Float64:
    """MORPH_FADE_EASE at t (0..1): cubic-bezier(0.4, 0, 0.2, 1), solved for x by bisection (hosts that fade by hand)."""
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0
    var lo = 0.0
    var hi = 1.0
    var s = t
    for _ in range(24):
        s = (lo + hi) * 0.5
        var x = 3.0 * (1.0 - s) * (1.0 - s) * s * 0.4 + 3.0 * (1.0 - s) * s * s * 0.2 + s * s * s
        if x < t:
            lo = s
        else:
            hi = s
    return 3.0 * (1.0 - s) * s * s * 1.0 + s * s * s
