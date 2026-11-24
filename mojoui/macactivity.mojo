# Work a person is waiting for, told to macOS (goal 79, D-8023, a probe: off unless MOJOUI_ACTIVITY is set): NSProcessInfo's
# activity (user-initiated, latency-critical) held for a few seconds after input, never while nothing happens (it holds
# off App Nap and timer coalescing, so it costs battery while held). Whether it brings a thread's first frame after a pause
# back to speed (D-8017: 7× slower on the M4 after 8 ms) is for the Mac to say: scripts/mac-firstframes.
#   MOJOUI_ACTIVITY=0 (or unset): off · 1: held for ACTIVITY_NS after each input · 2: held from the first input on (probe)
#
# A host calls touch() at each input and due() when its timer asks (due_in() says when); nothing is scheduled per event.
from std.os import getenv
from mojoui.clock import now_ns
from mojoui.hosts.objc import msg, cls, ns_string

comptime ACTIVITY_NS = 3_000_000_000
comptime ACTIVITY_OPTIONS = 0x00FFFFFF | 0xFF00000000  # NSActivityUserInitiated | NSActivityLatencyCritical


struct InputActivity(Movable):
    var mode: Int
    var token: Int  # the activity held now (0: none)
    var last: Int  # when input last came (ns)
    var begun: Int  # activities begun so far (tests, the report)

    def __init__(out self):
        var m = getenv("MOJOUI_ACTIVITY")
        self.mode = 1 if m == "1" else (2 if m == "2" else 0)
        self.token = 0
        self.last = 0
        self.begun = 0

    def touch(mut self) -> Bool:
        """Input came. True when an activity began now (the host then calls due() in due_in())."""
        if self.mode == 0:
            return False
        self.last = Int(now_ns())
        if self.token != 0:
            return False
        self.token = msg(msg(cls("NSProcessInfo"), "processInfo"), "beginActivityWithOptions:reason:", ACTIVITY_OPTIONS, ns_string("input"))
        _ = msg(self.token, "retain")
        self.begun += 1
        return True

    def due_in(self) -> Float64:
        """Seconds until due() is worth calling."""
        return max(0.05, Float64(self.last + ACTIVITY_NS - Int(now_ns())) / 1e9)

    def due(mut self) -> Bool:
        """The time may be up: the activity ends when no input came meanwhile. True: call again in due_in()."""
        if self.token == 0:
            return False
        if self.mode == 2 or Int(now_ns()) - self.last < ACTIVITY_NS:
            return True
        self.end()
        return False

    def end(mut self):
        if self.token != 0:
            _ = msg(msg(cls("NSProcessInfo"), "processInfo"), "endActivity:", self.token)
            _ = msg(self.token, "release")
            self.token = 0
