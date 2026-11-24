# mojoui.doubletap (goal 79, 79-gaps 54): a modifier key tapped twice (Control; the Command key on a Mac): down and up alone,
# briefly, twice close together, with nothing else between (Personal Note's double-tap.js). A canvas with keys gets a modifier's
# press as its name ("Control_L", "Meta_L") and its release as KEY_UP + that name, on GTK and AppKit. Times in ms.
#
#   if self.tap.key(name, now_ms()): …    # every key of the canvas; True: a double tap just ended
#   self.tap.interrupt()                  # a press, a wheel, words from an input method
from std.sys import CompilationTarget

comptime KEY_UP = "KeyUp:"
comptime TAP_GAP = 300
comptime TAP_HOLD = 250


def tap_key(name: String) -> Bool:
    """The key that is tapped: Command on a Mac, Control elsewhere (either side's)."""
    comptime if CompilationTarget.is_macos():
        return name.startswith("Meta")
    else:
        return name.startswith("Control")


struct DoubleTap(Copyable, Movable):
    var down_at: Int  # when it went down, while it is down (-1: it isn't)
    var dirty: Bool  # something else happened during this press
    var last_end: Int  # when the clean tap before this one came up (-1: none)

    def __init__(out self):
        self.down_at = -1
        self.dirty = False
        self.last_end = -1

    def key(mut self, name: String, now: Int) -> Bool:
        if name.startswith(KEY_UP):
            if not tap_key(String(name[byte=KEY_UP.byte_length():name.byte_length()])) or self.down_at < 0:
                return False
            var clean = not self.dirty and now - self.down_at <= TAP_HOLD
            self.down_at = -1
            self.dirty = False
            if not clean:
                self.last_end = -1
                return False
            if self.last_end >= 0:
                self.last_end = -1
                return True
            self.last_end = now
            return False
        if not tap_key(name):
            self.interrupt()
            return False
        if self.down_at >= 0:  # (held down: not a tap)
            self.dirty = True
            return False
        self.down_at = now
        self.dirty = False
        if self.last_end >= 0 and now - self.last_end > TAP_GAP:
            self.last_end = -1
        return False

    def interrupt(mut self):
        """Anything else that makes the modifier mean something: the tap in progress and the one before it are void."""
        self.dirty = True
        self.last_end = -1
