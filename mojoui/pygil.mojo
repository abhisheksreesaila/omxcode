# mojoui.pygil: Python from any thread (goal 41 M7, D-1146). Mojo's Python interop starts CPython on the first call and
# leaves its lock (the GIL) with the thread that made it, the UI thread. A job's thread that calls Python then crashes
# (no thread state) or, given one, waits forever: the UI thread never runs Python bytecode, so it never lets go.
#
#   var g = python_enter()        # around every Python call that may run off the UI thread (a job's run())
#   ... Python calls ...
#   python_exit(g)
#
#   python_lend()                 # UI thread, before starting a job that calls Python: hands the lock back to Python
#   python_reclaim()              # UI thread, when that job's result is taken: takes it again (the last lender only)
#
# While lent, the UI thread's own Python calls must sit in python_enter()/python_exit() too (mojoui.pdfsource and
# mojoui.ocrmodel do; code that calls Python bare, e.g. mojoui.visionmodel, must not run on the UI thread while a lent job
# runs). Lending is counted, so two jobs can run at once. python_enter() is safe on a thread that already holds the lock
# (it nests). The C functions come from the loaded libpython (dlsym), so nothing new is linked.

from std.ffi import external_call
from std.memory import Pointer
from std.python import Python
from mojoui.shared import get_shared, put_shared

comptime SLOT_LENT = 94  # mojoui.shared slots: how many lenders (count + 1, 0: never set)
comptime SLOT_SAVED = 95  # the UI thread's saved thread state (address + 1)
comptime SLOT_HOSTED = 96  # 0: not asked yet, 1: Mojo started CPython, 2: a Python program hosts this app (D-1260)


def _sym(name: String) -> Int:
    var n = name
    return external_call["dlsym", Int](0, n.as_c_string_span())  # RTLD_DEFAULT: libpython is loaded globally


def _call0(f: Int) -> Int:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
    var call = Pointer(to=raw).unsafe_bitcast[def() thin abi("C") -> Int]()[]
    return call()


def _call1(f: Int, a: Int) -> Int:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
    var call = Pointer(to=raw).unsafe_bitcast[def(Int) thin abi("C") -> Int]()[]
    return call(a)


def python_start() raises:
    """Starts CPython on this thread (the UI thread) if it isn't running yet."""
    _ = Python.import_module("sys")


def python_enter() raises -> Int:
    """Takes the Python lock on this thread (any thread; nests); hand the result to python_exit()."""
    var f = _sym("PyGILState_Ensure")
    if f == 0:
        raise Error("pygil: libpython isn't loaded (call python_start() on the UI thread first)")
    return _call0(f)


def python_exit(state: Int):
    var f = _sym("PyGILState_Release")
    if f != 0:
        _ = _call1(f, state)


def python_hosted() -> Bool:
    """A Python program hosts this app (it set sys.mojoui_python_host before importing it): Python manages its lock."""
    var known = get_shared(SLOT_HOSTED)
    if known == 0:
        known = 1
        try:
            var sys = Python.import_module("sys")
            if Bool(py=Python.import_module("builtins").hasattr(sys, "mojoui_python_host")):
                known = 2
        except:
            pass
        put_shared(SLOT_HOSTED, known)
    return known == 2


def python_lend() raises:
    """UI thread: lets other threads take the Python lock until the matching python_reclaim() (nothing to do when a
    Python program hosts the app)."""
    python_start()
    if python_hosted():
        return
    var n = max(get_shared(SLOT_LENT) - 1, 0)
    if n == 0:
        put_shared(SLOT_SAVED, _call0(_sym("PyEval_SaveThread")) + 1)
    put_shared(SLOT_LENT, n + 2)


def python_reclaim():
    """UI thread: the end of one python_lend(); the last one takes the lock back."""
    if get_shared(SLOT_HOSTED) == 2:
        return
    var n = max(get_shared(SLOT_LENT) - 1, 0)
    if n == 0:
        return
    if n == 1:
        var saved = get_shared(SLOT_SAVED) - 1
        if saved >= 0:
            _ = _call1(_sym("PyEval_RestoreThread"), saved)
        put_shared(SLOT_SAVED, 0)
    put_shared(SLOT_LENT, n)


def python_lent() -> Int:
    """How many lenders hold the lock out now."""
    return max(get_shared(SLOT_LENT) - 1, 0)
