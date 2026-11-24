# A kept view read before it is shown (goal 79, D-8015): an app about to open a document whose last view is kept
# (mojoui.viewsnap) asks for it as the open begins; a job thread reads the file while the opening frame is laid out, and
# the renderer's snap_take finds it read, or waits out the rest. UI thread only. (A module of its own: jobs come from
# omxcore, and the renderers that read snapshots don't need it.)
from omxcore import JobBody, JobCtl, start_job
from std.memory import Pointer
from mojoui.clock import now_ns
from mojoui.viewsnap import SnapAhead, snap_ahead_cell, snap_read


struct _ReadJob(JobBody):
    comptime Out = Int
    var path: String
    var cell: Int

    def __init__(out self, path: String, cell: Int):
        self.path = path
        self.cell = cell

    def run(mut self, ctl: JobCtl) raises -> Int:
        var s = snap_read(self.path)
        var a = Pointer[SnapAhead, MutUntrackedOrigin](unsafe_from_address=self.cell)
        swap(a[].snap, s)
        _ = a[].ready.fetch_add(1)  # (last: the UI thread reads `snap` only once this is set)
        return 0


def snap_ahead(path: String):
    """The snapshot at path read on a job thread from now (nothing when another is still being read)."""
    var a = snap_ahead_cell()
    if a[].started and a[].ready.load() == 0:
        return
    a[].path = path
    a[].at = Int(now_ns())
    _ = a[].ready.fetch_sub(a[].ready.load())
    a[].started = True
    _ = start_job(_ReadJob(path, Int(a)))
