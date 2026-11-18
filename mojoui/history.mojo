# mojoui.history: undo and redo for any editor (goal 74 M1, D-7406). The editor decides what a step is; the history keeps
# them in order, merges a run of small ones into one (typing a word is one undo, not five), drops the redo branch when a
# new edit comes, and forgets the oldest past a cap.
#
#   struct Typed(Undoable): ...          # an edit: what changed, enough to put it back and to do it again
#       def merge(mut self, later: Self) -> Bool   # fold a later edit into this one (True), or refuse (False)
#   var h = History[Typed](cap=500)
#   h.push(edit, now_ms, coalesce=True)  # coalesce: may merge with the last step if it came within h.window_ms
#   h.seal()                             # the next push starts a new step (the caret moved, a new tool, a pause)
#   var e = h.undo()                     # Optional: the step to revert; the editor applies its inverse
#   var e = h.redo()                     # Optional: the step to apply again
#
# Snapshot[T] is the simple kind of step: the whole value before and after (an object list, a tree), merged by keeping
# the first before and the last after. Big values (a long text) should push small edits instead.


trait Undoable(Copyable, Movable, Deinitable):
    def merge(mut self, later: Self) -> Bool:
        """Fold `later` (which happened right after self) into self; False leaves both as they were."""
        ...


@fieldwise_init
struct Snapshot[T: Copyable & Movable & Deinitable](Undoable):
    """A step as the whole value before and after it; `kind` tells merging steps apart (merging needs equal kinds)."""

    var kind: Int
    var before: Self.T
    var after: Self.T

    def merge(mut self, later: Self) -> Bool:
        if later.kind != self.kind:
            return False
        self.after = later.after.copy()
        return True


struct History[T: Undoable](Movable):
    var done: List[Self.T]
    var undone: List[Self.T]
    var at_ms: Int  # when the last step was pushed or merged
    var sealed: Bool  # the next push starts a new step
    var cap: Int  # the most steps kept (the oldest go first)
    var window_ms: Int  # pushes closer than this may merge
    var version: Int  # changes on every push, undo, redo and clear (a cheap "did anything change")

    def __init__(out self, cap: Int = 1000, window_ms: Int = 1000):
        self.done = List[Self.T]()
        self.undone = List[Self.T]()
        self.at_ms = -1_000_000_000
        self.sealed = True
        self.cap = max(cap, 1)
        self.window_ms = window_ms
        self.version = 0

    def push(mut self, var step: Self.T, now_ms: Int, coalesce: Bool = False):
        """A new edit: merged into the last step when coalesce is on, the history isn't sealed, the last step came within
        window_ms, and the step agrees to merge; otherwise a step of its own. Either way the redo branch is gone."""
        self.undone.clear()
        self.version += 1
        if coalesce and not self.sealed and len(self.done) > 0 and now_ms - self.at_ms <= self.window_ms:
            if self.done[len(self.done) - 1].merge(step):
                self.at_ms = now_ms
                return
        self.done.append(step^)
        self.at_ms = now_ms
        self.sealed = not coalesce
        if len(self.done) > self.cap:
            var keep = List[Self.T](capacity=self.cap)
            for i in range(len(self.done) - self.cap, len(self.done)):
                keep.append(self.done[i].copy())
            self.done = keep^

    def seal(mut self):
        self.sealed = True

    def undo(mut self) -> Optional[Self.T]:
        if len(self.done) == 0:
            return None
        var s = self.done.pop()
        self.undone.append(s.copy())
        self.sealed = True
        self.version += 1
        return s^

    def redo(mut self) -> Optional[Self.T]:
        if len(self.undone) == 0:
            return None
        var s = self.undone.pop()
        self.done.append(s.copy())
        self.sealed = True
        self.version += 1
        return s^

    def can_undo(self) -> Bool:
        return len(self.done) > 0

    def can_redo(self) -> Bool:
        return len(self.undone) > 0

    def clear(mut self):
        self.done.clear()
        self.undone.clear()
        self.sealed = True
        self.version += 1
