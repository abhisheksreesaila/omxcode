# Screens ready before they're shown (goal 79, D-8011): the first frame of a panel or a document shapes its text and
# rasters its glyphs, and that is most of what it costs. An app that has a moment paints the screen it may show next
# into a Scene nobody shows, and gives it to a SceneWarm, which readies its text runs a slice at a time, as drawn: the
# shaped runs, the glyph images and (by painting) the measured widths are then in the font engine's caches.
#
#   var s = Scene(w, h, k); s.begin_layer("x"); s.layer_transform(0, 0, k); panel.draw(s, …)     # idle: no input lately
#   warm.take(s^)
#   while warm.more(): _ = warm.step(4000)                       # ≤ 4 ms at a time (one run at least), on a timer
#
# Nothing is drawn and nothing of the app's state changes: a screen shown before its warming finishes just pays for what
# is not ready yet, and looks the same.
from mojoui.clock import now_ns
from mojoui.fonttext import engine, shape
from mojoui.scene import Scene, OP_RUN


struct SceneWarm(Movable):
    var scene: Scene
    var layer: Int
    var op: Int
    var have: Bool
    var runs: Int  # text runs readied so far
    var ms: Float64

    def __init__(out self):
        self.scene = Scene(0, 0, 1.0)
        self.layer = 0
        self.op = 0
        self.have = False
        self.runs = 0
        self.ms = 0

    def take(mut self, var scene: Scene):
        """The screen to ready (the one before it, if unfinished, is dropped)."""
        self.scene = scene^
        self.layer = 0
        self.op = 0
        self.have = self.scene.layers() > 0

    def more(self) -> Bool:
        return self.have

    def step(mut self, budget_us: Int) -> Bool:
        """The screen's text readied for at most budget_us (a run at least); True while there is more of it."""
        if not self.have:
            return False
        var t0 = Int(now_ns())
        var e = engine()
        while self.layer < self.scene.layers():
            var span = self.scene.layer_range(self.layer)
            var k = self.scene.layer_tk[self.layer]
            while span[0] + self.op < span[1]:
                var at = span[0] + self.op
                self.op += 1
                if Int(self.scene.kinds[at]) != OP_RUN:
                    continue
                var st = self.scene.run_style(at)
                var r = shape(st, self.scene.run_text(at))
                for ref g in r.glyphs:
                    _ = e[].image(g.inst, g.gid, st.size * k, 0)
                self.runs += 1
                if Int(now_ns()) - t0 >= budget_us * 1000:
                    self.ms += Float64(Int(now_ns()) - t0) / 1e6
                    return True
            self.layer += 1
            self.op = 0
        self.ms += Float64(Int(now_ns()) - t0) / 1e6
        self.have = False
        self.scene = Scene(0, 0, 1.0)
        return False
