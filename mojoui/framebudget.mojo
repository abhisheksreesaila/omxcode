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


struct FrameBudget(Copyable, Movable):
    var target_us: Int
    var t0: Int
    var slice: Int  # this frame's slice time so far
    var other_us: Int  # the last frame's work besides its slices (-1: none measured yet)

    def __init__(out self, target_us: Int):
        self.target_us = target_us
        self.t0 = 0
        self.slice = 0
        self.other_us = -1

    def begin(mut self):
        self.t0 = clock_us()
        self.slice = 0

    def slice_us(self, min_us: Int, max_us: Int) -> Int:
        """The budget for this frame's background work: the target less the last frame's other work, within
        [min_us, max_us] (max_us before anything was measured)."""
        if self.other_us < 0:
            return max_us
        return max(min_us, min(max_us, self.target_us - self.other_us))

    def spent(mut self, us: Int):
        self.slice += us

    def end(mut self):
        if self.t0 > 0:
            self.other_us = max(0, clock_us() - self.t0 - self.slice)
        self.t0 = 0
