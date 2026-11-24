# A big value's end on a job thread (goal 79, D-8015). (A module of its own: jobs come from omxcore.)
from omxcore import JobBody, JobCtl, start_job


struct _LetGo[T: Movable & Deinitable](JobBody):
    comptime Out = Int
    var docs: List[Self.T]

    def __init__(out self, var doc: Self.T):
        self.docs = List[Self.T]()
        self.docs.append(doc^)

    def run(mut self, ctl: JobCtl) raises -> Int:
        self.docs.clear()
        return 0


def let_go[T: Movable & Deinitable](var doc: T):
    """A big value freed on a job thread (D-8015: a 1 200-object board's objects and strings took the opening frame 2.7 ms
    on the Mac). Nothing else may still point into it. Where jobs have no threads (the iPhone), freed here."""
    _ = start_job(_LetGo[T](doc^))
