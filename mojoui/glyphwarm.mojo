# Glyphs ready before they're asked for (goal 79, D-8002): the first frame that shows new text pays for its glyphs, on the
# Mac ~50 µs each in CoreText plus a millisecond for a font's first use, so the first time a panel opens is its slowest.
# An app that keeps a GlyphWarm remembers, in a small file, which glyph images and text styles it drew (glyph ids, sizes
# and font names: never text) and, the next time it runs, rasters them again in idle frames, a slice at a time.
#
#   var warm = GlyphWarm(config_dir("app") + "/glyphs.txt")
#   warm.add_ascii(style, k)                      # the first run of all: the app's own styles, printable ASCII, at scale k
#   every():  if warm.more(): Every(WARM_TICK_MS, WARM)          # a timer, not frames: nothing is drawn for it
#   on WARM:  _ = warm.idle_step(4000)            # ≤ 4 ms of it, and none within 300 ms of input (warm.touch())
#   on input: warm.touch()
#   on close: warm.save()                         # writes only when there is something new
#
# The images go into the font engine's cache (mojoui.fonttext), as if drawn; a font that is gone or changed is skipped.
from std.os import getenv
from mojoui.clock import now_ns
from mojoui.fonttext import engine, TextStyle
from mojoui.files import private_write

comptime WARM_TICK_MS = 30
comptime WARM_QUIET_NS = 300_000_000
comptime WARM_MOST = 6000  # glyph images kept in the file (a few per character, size and weight an app shows)


struct GlyphWarm(Movable):
    var path: String  # ("": off)
    var queue: List[String]
    var at: Int
    var loaded: Bool
    var kept: Int  # how many images the file held or the last save wrote (nothing new: nothing written)
    var warmed: Int  # images and styles made ready by step()
    var ms: Float64  # the time that took
    var log: Bool
    var touched: Int  # when input last came (ns)
    var ascii: List[String]  # styles to ready first (add_ascii)

    def __init__(out self, path: String):
        self.path = path if getenv("MOJOUI_GLYPHWARM") != "0" else ""
        self.queue = List[String]()
        self.at = 0
        self.loaded = False
        self.kept = 0
        self.warmed = 0
        self.ms = 0
        self.log = getenv("MOJOUI_GLYPHWARM_LOG") == "1"
        self.touched = 0
        self.ascii = List[String]()

    def add_ascii(mut self, st: TextStyle, k: Float64):
        """Printable ASCII in this style at device scale k, readied after what the file names."""
        if self.path == "":
            return
        for c in range(33, 127, 8):  # (a few characters a line: a slice stays short)
            self.ascii.append("A\t" + String(st.weight) + "\t" + ("1" if st.italic else "0") + "\t" + String(st.size) + "\t" + st.family + "\t" + String(k) + "\t" + String(c))
        if self.loaded:
            self.queue += self.ascii^
            self.ascii = List[String]()

    def touch(mut self):
        """Input came: nothing is warmed for the next 300 ms."""
        self.touched = Int(now_ns())

    def more(self) -> Bool:
        return self.path != "" and (not self.loaded or self.at < len(self.queue) or len(self.ascii) > 0)

    def quiet(self) -> Bool:
        """No input for 300 ms."""
        return Int(now_ns()) - self.touched >= WARM_QUIET_NS

    def idle_step(mut self, budget_us: Int) -> Bool:
        """step(budget_us), unless input came within the last 300 ms."""
        if not self.quiet():
            return self.more()
        return self.step(budget_us)

    def _load(mut self):
        self.loaded = True
        if self.path == "":
            return
        try:
            with open(self.path, "r") as f:
                var t = f.read()
                var glyphs = List[String]()
                for l in t.split("\n"):
                    var line = String(l)
                    if line.startswith("S\t"):
                        self.queue.append(line)  # (styles first: their faces are then open)
                    elif line.startswith("G\t") and len(glyphs) < WARM_MOST:
                        glyphs.append(line)
                self.kept = len(glyphs)
                self.queue += glyphs^
        except:
            pass  # (no file yet)
        self.queue += self.ascii^
        self.ascii = List[String]()

    def step(mut self, budget_us: Int) -> Bool:
        """Glyphs made ready for at most budget_us (one item at least); True while there is more."""
        if not self.loaded:
            self._load()
        if self.at >= len(self.queue):
            return False
        var t0 = Int(now_ns())
        var e = engine()
        while self.at < len(self.queue):
            if e[].warm_line(self.queue[self.at]):
                self.warmed += 1
            self.at += 1
            if Int(now_ns()) - t0 >= budget_us * 1000:
                break
        self.ms += Float64(Int(now_ns()) - t0) / 1e6
        if self.at >= len(self.queue):
            self.queue = List[String]()
            self.at = 0
            if self.log:  # (how much was ready, of the file's and the app's own styles)
                print("GLYPHWARM: " + String(self.warmed) + " ready in " + String(self.ms) + " ms", flush=True)
            return False
        return True

    def save(mut self) -> Bool:
        """The glyph images and styles drawn so far written to the file, when there are more than it holds (through a
        second file renamed over it: a crash leaves the old one). True when written."""
        if self.path == "" or (self.loaded and self.at < len(self.queue)):
            return False
        var e = engine()
        if len(e[].image_of) <= self.kept or self.kept >= WARM_MOST:
            return False
        var lines = e[].glyph_lines(WARM_MOST)
        var t = String("")
        for s in e[].styles_seen.keys():
            t += "S\t" + s + "\n"
        for l in lines:
            t += l + "\n"
        if not private_write(self.path, t):
            return False
        self.kept = len(e[].image_of)
        return True
