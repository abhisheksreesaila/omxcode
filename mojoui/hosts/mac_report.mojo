# The Mac report (owner, 2026-10-22): the Mac can't be seen from Linux, so the AppKit host can write down what it
# shows. A folder on the Desktop, omxcode-report-<app>/<launch time>/, gets:
#   log.txt          the Mac, the window, every event and every canvas drawn, as it happens
#   NNN-<cause>.png  the window's content after a change, as AppKit draws it
#   NNN-<cause>.txt  every view of the screen: its kind, its text, and where AppKit put it (points, from the top left)
# It starts from the Debug menu (Record), or at launch when the app asks (App.records(): the Mac check app).
# Popovers and dialogs are windows of their own: the dump says when one is open, the picture doesn't show it.

from mojoui.hosts.objc import cls, msg, ns_string, from_ns
from mojoui.hosts.apple_canvas import CGRect

comptime MAX_SHOTS = 400  # a long session stops taking pictures here (the log goes on)


struct MacReport(Movable):
    var on: Bool
    var dir: String
    var count: Int
    var log: String
    var pending: Bool  # a snapshot is queued for the next quiet moment
    var cause: String  # what changed the screen since the last snapshot

    def __init__(out self):
        self.on = False
        self.dir = ""
        self.count = 0
        self.log = ""
        self.pending = False
        self.cause = "start"

    def start(mut self, app: String, window: Int):
        if self.on:
            return
        var fm = msg(cls("NSFileManager"), "defaultManager")
        var home = from_ns(msg(msg(fm, "homeDirectoryForCurrentUser"), "path"))
        var stamp = msg(msg(cls("NSDateFormatter"), "alloc"), "init")
        _ = msg(stamp, "setDateFormat:", ns_string("yyyy-MM-dd HH.mm.ss"))
        var launch = from_ns(msg(stamp, "stringFromDate:", msg(cls("NSDate"), "date")))
        _ = msg(stamp, "release")
        # one folder per launch inside the app's folder: reopening the app overwrote the last run (Mac, 2026-10-23)
        self.dir = home + "/Desktop/omxcode-report-" + app + "/" + launch
        _ = msg(fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", ns_string(self.dir), 1, 0, 0)
        self.on = True
        var info = msg(cls("NSProcessInfo"), "processInfo")
        self.note("omxcode Mac report: " + app)
        self.note("macOS: " + from_ns(msg(info, "operatingSystemVersionString")))
        self.note("cores: " + String(msg(info, "activeProcessorCount")) + " · memory: " + String(msg(info, "physicalMemory") // (1 << 30)) + " GB")
        if window != 0:
            var screen = msg(window, "screen")
            if screen != 0:
                var s = msg[CGRect](screen, "frame")
                self.note("screen: " + pts(s.width) + " x " + pts(s.height) + " pt · scale " + String(msg[Float64](screen, "backingScaleFactor")))
            var f = msg[CGRect](window, "frame")
            self.note("window: " + pts(f.width) + " x " + pts(f.height) + " pt")
            var appearance = msg(msg(window, "effectiveAppearance"), "name")
            self.note("appearance: " + from_ns(appearance))
        self.note("folder: " + self.dir)

    def note(mut self, line: String):
        """One line in log.txt, written at once (if the app crashes, the log so far is on disk)."""
        if not self.on:
            return
        self.log += line + "\n"
        self.write("log.txt", self.log)

    def write(self, name: String, text: String):
        _ = msg(ns_string(text), "writeToFile:atomically:encoding:error:", ns_string(self.dir + "/" + name), 1, 4, 0)  # NSUTF8StringEncoding

    def next_name(mut self) -> String:
        self.count += 1
        var n = String(self.count)
        while n.byte_length() < 3:
            n = "0" + n
        var cause = String("")
        for ch in self.cause.codepoint_slices():  # a file name: letters, digits and dashes
            var c = String(ch)
            if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"):
                cause += c
            elif cause.byte_length() > 0 and not cause.endswith("-"):
                cause += "-"
            if cause.byte_length() >= 40:
                break
        return n + "-" + (cause if cause.byte_length() > 0 else "change")

    def save_png(self, view: Int, name: String) -> Bool:
        """The view as AppKit draws it, into NNN.png (cacheDisplayInRect: draws it again, off screen)."""
        var b = msg[CGRect](view, "bounds")
        if b.width < 1 or b.height < 1:
            return False
        var rep = msg(view, "bitmapImageRepForCachingDisplayInRect:", b.x, b.y, b.width, b.height)
        if rep == 0:
            return False
        _ = msg(view, "cacheDisplayInRect:toBitmapImageRep:", b.x, b.y, b.width, b.height, rep)
        var png = msg(rep, "representationUsingType:properties:", 4, msg(cls("NSDictionary"), "dictionary"))  # NSBitmapImageFileTypePNG
        if png == 0:
            return False
        return msg(png, "writeToFile:atomically:", ns_string(self.dir + "/" + name), 1) != 0


def pts(v: Float64) -> String:
    """A size in points, rounded (frames are whole points almost always)."""
    var r = Int(v + 0.5) if v >= 0 else -Int(-v + 0.5)
    return String(r)
