# mojoui.framebudget: how much of a frame a piece of background work (a progressive open's slice, a prefetch) may take,
# from what the rest of the app's frame cost the last time (goal 79, D-7957).
#
#   var fb = FrameBudget(4000)          # µs of the app's own work a frame may hold (the renderer, GPU and compositor
#                                       # take the rest of an 8.3 ms frame)
#   fb.begin()                          # the frame's work starts
#   var us = fb.slice_us(250, 1500)     # what's left for the slice: target − the last frame's other work, clamped
#   fb.spent(slice_took)                # the slice's own time (not counted as "other" work)
#   fb.end()                            # the frame's work ends: its other work is remembered for the next slice_us()
#
# Why: a fixed slice (1.5 ms) on top of a frame whose own walk costs 2–5 ms (a big board's paint, its damage tracking)
# pushes those frames past the silky budget; with nothing else in a frame the slice can take more.

from mojoui.docstore import clock_us
from std.os import getenv


comptime ANSWER_FRAMES = 2  # the one that shows an input, and the next


struct FrameBudget(Copyable, Movable):
    var target_us: Int
    var t0: Int
    var slice: Int  # this frame's slice time so far
    var other_us: Int  # the last frame's work besides its slices (-1: none measured yet)
    var trace: Bool
    var answering: Int  # frames left that answer an input
    var max_override: Int  # MOJOUI_SLICE_MAX_US (an A/B of the cap)

    def __init__(out self, target_us: Int):
        self.target_us = target_us
        try:
            if getenv("MOJOUI_FRAME_WORK_US") != "":  # (an A/B of the target)
                self.target_us = Int(getenv("MOJOUI_FRAME_WORK_US"))
        except:
            pass
        self.t0 = 0
        self.slice = 0
        self.other_us = -1
        self.trace = getenv("MOJOUI_FRAME_TRACE") == "1"
        self.max_override = 0
        self.answering = 0
        try:
            if getenv("MOJOUI_SLICE_MAX_US") != "":
                self.max_override = Int(getenv("MOJOUI_SLICE_MAX_US"))
        except:
            pass

    def begin(mut self):
        self.t0 = clock_us()
        self.slice = 0

    def input(mut self):
        """A person did something: the next frames are its answer, and take as little background work as they may."""
        self.answering = ANSWER_FRAMES

    def slice_us(self, min_us: Int, max_us: Int) -> Int:
        """The budget for this frame's background work: the target less the last frame's other work, within
        [min_us, max_us] (max_us before anything was measured; min_us in the frames that answer an input)."""
        if self.answering > 0:
            return min_us
        var most = max_us if self.max_override <= 0 else self.max_override
        if self.other_us < 0:
            return most
        return max(min_us, min(most, self.target_us - self.other_us))

    def spent(mut self, us: Int):
        self.slice += us

    def end(mut self):
        if self.t0 > 0:
            self.other_us = max(0, clock_us() - self.t0 - self.slice)
            self.answering = max(0, self.answering - 1)
            if self.trace:
                print("FRAMEBUDGET: other " + String(self.other_us) + " us, slice " + String(self.slice) + " us", flush=True)
        self.t0 = 0
