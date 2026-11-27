# mojoui.filewatch: a few files watched for any write, by the system's file events, never by polling (goal 82 M7).
#
#   var w = FileWatch([db, db + "-wal", db + "-journal"], wake=True)   # wake: App.jobs_message() reaches update() at once
#   w.start()                       # returns at once; ready() once the watches are in place
#   if w.changed(): …               # never waits: True once for every run of writes since it was last asked
#   w.count(), w.last_ns()          # writes seen so far, and when the last one was (mojoui.clock.now_ns's clock)
#
# What FolderWatcher (mojoui.watch) doesn't do: a file written in place and never closed counts. SQLite's WAL is such a
# file: another program's connection appends to notes.db-wal and keeps it open, so a watcher that waits for the close
# (IN_CLOSE_WRITE) never hears of it. Here every write counts: IN_MODIFY, a close after writing, a file made, removed or
# renamed onto the name, all for the names asked about only (the folder around them is watched, so a file that doesn't
# exist yet, or is replaced by a rename, is still seen). On Linux nothing is kept open but the inotify descriptor.
#
# Linux: inotify on each file's folder, read on a pthread of its own (poll, 50 ms at most between looks at the stop flag).
# Mac: kqueue (EVFILT_VNODE) on each file, opened O_EVTONLY (it holds nothing), and on its folder (a name made, removed or
# renamed onto: the file opened again when its inode changed), on a pthread of its own; FSEvents reports an open file's
# writes only when it is closed. Folders are compared by their real paths. Either way the count lives in shared words read with
# atomics, and wake=True wakes the host through mojoui.wake.UIWaker (a byte down the job-wake pipe on Linux, jobsEnded: on
# the main queue on a Mac) once per batch of events, not once per write.

from std.atomic import Atomic
from std.ffi import c_int, c_char
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.sys import CompilationTarget
from mojoui.clock import now_ns
from mojoui.wake import UIWaker, wake_write_fd
from mojoui.watch import _c, _sym, _cstr, _from_c, _errno

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]

comptime F_STATE = 0  # 0 starting, 1 watching, 2 stopped, -1 failed
comptime F_STOP = 1
comptime F_REFS = 2  # the handle and the thread; the last one frees
comptime F_SPEC = 3  # a C string: "folder\tname\n" for each file
comptime F_WAKE = 4  # 1: wake the host after each batch
comptime F_TARGET = 5  # Mac: the delegate UIWaker found at start()
comptime F_COUNT = 6  # writes seen
comptime F_LAST = 7  # when the last was seen (now_ns)
comptime F_ERR = 8
comptime F_WORDS = 11

comptime IN_MODIFY = 0x2
comptime IN_CLOSE_WRITE = 0x8
comptime IN_MOVED_FROM = 0x40
comptime IN_MOVED_TO = 0x80
comptime IN_CREATE = 0x100
comptime IN_DELETE = 0x200
comptime IN_Q_OVERFLOW = 0x4000
comptime _MASK = IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE | 0x01000000  # ONLYDIR


def _w(words: Int, k: Int) -> _P:
    return _P(unsafe_from_address=words + 8 * k)


def _folder_and_name(path: String) -> Tuple[String, String]:
    var slash = path.rfind("/")
    if slash < 0:
        return (String("."), path)
    if slash == 0:
        return (String("/"), String(path[byte=1:]))
    return (String(path[byte=:slash]), String(path[byte = slash + 1 :]))


def _spec_pairs(words: Int) -> List[Tuple[String, String]]:
    var out = List[Tuple[String, String]]()
    var spec = _from_c(Int(_A.load(_w(words, F_SPEC))))
    for line in spec.split("\n"):
        var tab = String(line).find("\t")
        if tab > 0:
            out.append((String(String(line)[byte=:tab]), String(String(line)[byte = tab + 1 :])))
    return out^


def _seen(words: Int, n: Int):
    _ = _A.fetch_add(_w(words, F_COUNT), Int64(n))
    _A.store(_w(words, F_LAST), Int64(now_ns()))


def _wake(words: Int):
    UIWaker(wake_write_fd() if CompilationTarget.is_linux() else -1, Int(_A.load(_w(words, F_TARGET)))).wake()


# ---- Linux: inotify on the folders, on a thread

def _watch_linux(words: Int) raises:
    var fd = Int(_c[c_int]("inotify_init1", c_int(0x800 | 0x80000)))  # IN_NONBLOCK | IN_CLOEXEC
    if fd < 0:
        _A.store(_w(words, F_ERR), Int64(_errno()))
        raise Error("inotify_init1 failed")
    var mask = unsafe_alloc[UInt64](16)  # SIGPIPE blocked on this thread (the wake pipe's write is then EPIPE, not death)
    _ = _c[c_int]("sigemptyset", Int(mask))
    _ = _c[c_int]("sigaddset", Int(mask), c_int(13))
    _ = _c[c_int]("pthread_sigmask", c_int(0), Int(mask), Int(0))
    mask.unsafe_free()
    var pairs = _spec_pairs(words)
    var wds = List[Int]()  # each pair's folder's watch
    for ref p in pairs:
        var dir = p[0]
        var wd = Int(_c[c_int]("inotify_add_watch", c_int(fd), Int(dir.as_c_string_span().unsafe_ptr()), UInt32(_MASK)))
        _ = dir.byte_length()
        if wd < 0:
            _A.store(_w(words, F_ERR), Int64(_errno()))
            _ = _c[c_int]("close", c_int(fd))
            raise Error("can't watch " + p[0])
        wds.append(wd)
    _A.store(_w(words, F_STATE), 1)
    var buf = unsafe_alloc[UInt8](65536)
    var pfd = unsafe_alloc[Int32](2)
    var wake = _A.load(_w(words, F_WAKE)) != 0
    while _A.load(_w(words, F_STOP)) == 0:
        pfd[0] = Int32(fd)
        pfd[1] = Int32(1)  # POLLIN
        _ = _c[c_int]("poll", Int(pfd), Int(1), c_int(50))
        var hits = 0
        while True:
            var n = _c[Int]("read", c_int(fd), Int(buf), 65536)
            if n <= 0:
                break
            var off = 0
            while off + 16 <= n:
                var at = Int(buf) + off
                var wd = Int(Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=at)[])
                var m = Int(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=at + 4)[])
                var len_ = Int(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=at + 12)[])
                if m & IN_Q_OVERFLOW:  # (the kernel dropped events: one of them may be ours)
                    hits += 1
                elif len_ > 0:
                    var name = _from_c(at + 16)
                    for k in range(len(pairs)):
                        if wds[k] == wd and pairs[k][1] == name:
                            hits += 1
                            break
                off += 16 + len_
        if hits > 0:
            _seen(words, hits)
            if wake:
                _wake(words)
    buf.unsafe_free()
    pfd.unsafe_free()
    _ = _c[c_int]("close", c_int(fd))


def _release(words: Int):
    if _A.fetch_add(_w(words, F_REFS), -1) == 1:
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_w(words, F_SPEC)))).unsafe_free()
        _P(unsafe_from_address=words).unsafe_free()


def _entry(arg: Int) abi("C") -> Int:
    try:
        comptime if CompilationTarget.is_macos():
            _watch_mac(arg)
        else:
            _watch_linux(arg)
        _A.store(_w(arg, F_STATE), 2)
    except:
        _A.store(_w(arg, F_STATE), -1)
    _release(arg)
    return 0


# ---- Mac: kqueue on each file and its folder, on a thread
# (FSEvents was tried first: macOS reports a file's content change when its writer closes it, so a WAL kept open by
# another program's connection went unseen; kqueue's EVFILT_VNODE fires on each write.)

comptime _EVFILT_VNODE = -4
comptime _EV_ADD_CLEAR = 0x1 | 0x4 | 0x20  # EV_ADD | EV_ENABLE | EV_CLEAR
comptime _NOTE_DELETE = 0x1
comptime _NOTE_WRITE = 0x2
comptime _NOTE_EXTEND = 0x4
comptime _NOTE_ATTRIB = 0x8
comptime _NOTE_RENAME = 0x20
comptime _NOTE_REVOKE = 0x40
comptime _O_EVTONLY = 0x8000
comptime _KEV = 32  # sizeof(struct kevent) on arm64 and x86_64: ident 8, filter 2, flags 2, fflags 4, data 8, udata 8


def _identity(path: String) -> Int:
    """The file's inode (-1: not there): what tells a file put in its place from the one that was."""
    var st = List[Int](length=24, fill=0)  # struct stat (64-bit inodes): st_ino at byte 8
    var p = path
    var rc = Int(_c[c_int]("stat", Int(p.as_c_string_span().unsafe_ptr()), Int(st.unsafe_ptr())))
    _ = p.byte_length()
    var ino = st[1] if rc == 0 else -1
    _ = len(st)
    return ino


def _kev(kq: Int, fd: Int, fflags: Int, udata: Int) -> Bool:
    var ev = List[UInt8](length=_KEV, fill=0)
    var at = Int(ev.unsafe_ptr())
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=at)[] = fd
    Pointer[Int16, MutUntrackedOrigin](unsafe_from_address=at + 8)[] = Int16(_EVFILT_VNODE)
    Pointer[UInt16, MutUntrackedOrigin](unsafe_from_address=at + 10)[] = UInt16(_EV_ADD_CLEAR)
    Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=at + 12)[] = UInt32(fflags)
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=at + 24)[] = udata
    var rc = Int(_c[c_int]("kevent", c_int(kq), at, c_int(1), Int(0), c_int(0), Int(0)))
    _ = len(ev)
    return rc == 0


def _open_evt(path: String) -> Int:
    var p = path
    var fd = Int(_c[c_int]("open", Int(p.as_c_string_span().unsafe_ptr()), c_int(_O_EVTONLY)))
    _ = p.byte_length()
    return fd


def _watch_mac(words: Int) raises:
    var kq = Int(_c[c_int]("kqueue"))
    if kq < 0:
        _A.store(_w(words, F_ERR), Int64(_errno()))
        raise Error("kqueue failed")
    var pairs = _spec_pairs(words)
    var dirs = List[String]()
    for ref p in pairs:
        if p[0] not in dirs:
            dirs.append(p[0])
    var dir_fds = List[Int]()
    for k in range(len(dirs)):  # udata: -(k + 1) for folder k
        var fd = _open_evt(dirs[k])
        if fd < 0 or not _kev(kq, fd, _NOTE_WRITE | _NOTE_DELETE | _NOTE_RENAME, -(k + 1)):
            _A.store(_w(words, F_ERR), Int64(_errno()))
            _ = _c[c_int]("close", c_int(kq))
            raise Error("can't watch " + dirs[k])
        dir_fds.append(fd)
    var fds = List[Int]()  # udata: k + 1 for file k (-1: not there)
    var ids = List[Int]()
    for k in range(len(pairs)):
        var path = pairs[k][0] + "/" + pairs[k][1]
        var fd = _open_evt(path)
        if fd >= 0 and not _kev(kq, fd, _NOTE_WRITE | _NOTE_EXTEND | _NOTE_DELETE | _NOTE_RENAME | _NOTE_REVOKE, k + 1):
            _ = _c[c_int]("close", c_int(fd))
            fd = -1
        fds.append(fd)
        ids.append(_identity(path))
    _A.store(_w(words, F_STATE), 1)
    var evs = List[UInt8](length=_KEV * 64, fill=0)
    var ts = List[Int](length=2, fill=0)
    ts[1] = 50_000_000  # 50 ms
    var wake = _A.load(_w(words, F_WAKE)) != 0
    while _A.load(_w(words, F_STOP)) == 0:
        var n = Int(_c[c_int]("kevent", c_int(kq), Int(0), c_int(0), Int(evs.unsafe_ptr()), c_int(64), Int(ts.unsafe_ptr())))
        if n <= 0:
            continue
        var hits = 0
        var look = List[Bool](length=len(pairs), fill=False)  # files to open again (gone, replaced)
        for e in range(n):
            var at = Int(evs.unsafe_ptr()) + e * _KEV
            var ff = Int(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=at + 12)[])
            var who = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=at + 24)[]
            if who > 0:
                hits += 1
                if ff & (_NOTE_DELETE | _NOTE_RENAME | _NOTE_REVOKE):
                    look[who - 1] = True
            elif who < 0:  # (a name in folder -who - 1 came, went or moved: one of ours, if its file isn't the one it was)
                for k in range(len(pairs)):
                    if pairs[k][0] == dirs[-who - 1]:
                        look[k] = True
        for k in range(len(pairs)):
            if not look[k]:
                continue
            var path = pairs[k][0] + "/" + pairs[k][1]
            var now = _identity(path)
            if now == ids[k] and fds[k] >= 0:
                continue
            if now != ids[k]:
                hits += 1
            ids[k] = now
            if fds[k] >= 0:
                _ = _c[c_int]("close", c_int(fds[k]))
            fds[k] = _open_evt(path)
            if fds[k] >= 0 and not _kev(kq, fds[k], _NOTE_WRITE | _NOTE_EXTEND | _NOTE_DELETE | _NOTE_RENAME | _NOTE_REVOKE, k + 1):
                _ = _c[c_int]("close", c_int(fds[k]))
                fds[k] = -1
        if hits > 0:
            _seen(words, hits)
            if wake:
                _wake(words)
    _ = len(evs)
    _ = len(ts)
    for fd in fds:
        if fd >= 0:
            _ = _c[c_int]("close", c_int(fd))
    for fd in dir_fds:
        _ = _c[c_int]("close", c_int(fd))
    _ = _c[c_int]("close", c_int(kq))


def real_path(path: String) -> String:
    """The path with its links resolved (realpath); the path itself when it can't be."""
    var buf = List[UInt8](length=4096, fill=0)
    var p = path
    var r = _c[Int]("realpath", Int(p.as_c_string_span().unsafe_ptr()), Int(buf.unsafe_ptr()))
    _ = p.byte_length()
    if r == 0:
        return path
    var out = _from_c(Int(buf.unsafe_ptr()))
    _ = len(buf)
    return out


struct FileWatch(Movable):
    """Watches a few files for any write. Dropping it stops the watching."""

    var paths: List[String]
    var wake: Bool
    var words: Int
    var started: Bool
    var seen: Int  # the count when changed() was last asked
    var reason: String

    def __init__(out self, paths: List[String], wake: Bool = False):
        self.paths = paths.copy()
        self.wake = wake
        self.words = 0
        self.started = False
        self.seen = 0
        self.reason = ""

    def start(mut self):
        """Starts watching and returns at once (ready() once the watches are in place)."""
        if self.started:
            return
        self.started = True
        var spec = String("")
        for p in self.paths:
            var pf = _folder_and_name(p)
            var dir = real_path(pf[0])  # (the folder must exist; the file needn't)
            spec += dir + "\t" + pf[1] + "\n"
        var words = unsafe_alloc[Int64](F_WORDS)
        for k in range(F_WORDS):
            _A.store(_w(Int(words), k), 0)
        _A.store(_w(Int(words), F_REFS), 2)
        _A.store(_w(Int(words), F_SPEC), Int64(_cstr(spec)))
        _A.store(_w(Int(words), F_WAKE), Int64(1 if self.wake else 0))
        if self.wake:  # (looked up on the UI thread: a Mac's delegate)
            _A.store(_w(Int(words), F_TARGET), Int64(UIWaker().target))
        self.words = Int(words)
        var tid = List[Int](length=1, fill=0)
        var entry = _entry  # (pthread_create by address, as mojoui.watch does)
        var rc = _c[c_int]("pthread_create", Int(tid.unsafe_ptr()), Int(0), Pointer(to=entry).unsafe_bitcast[Int]()[], self.words)
        if rc != 0:
            _A.store(_w(self.words, F_STATE), -1)
            _release(self.words)
            self.reason = "no thread for the watcher"
        else:
            _ = _c[c_int]("pthread_detach", tid[0])

    def _state(self) -> Int:
        return Int(_A.load(_w(self.words, F_STATE))) if self.words != 0 else (-1 if self.reason else 0)

    def ready(self) -> Bool:
        return self._state() == 1

    def failed(self) -> Bool:
        return self._state() == -1

    def stopped(self) -> Bool:
        return self._state() == 2 or self._state() == -1

    def why(self) -> String:
        if self.reason:
            return self.reason
        if self.failed():
            return "can't watch (error " + String(Int(_A.load(_w(self.words, F_ERR)))) + ")"
        return ""

    def count(self) -> Int:
        """Writes seen so far (an overflow of the system's queue counts as one)."""
        return Int(_A.load(_w(self.words, F_COUNT))) if self.words != 0 else 0

    def last_ns(self) -> Int:
        """When the last write was seen (now_ns's clock; 0: none yet)."""
        return Int(_A.load(_w(self.words, F_LAST))) if self.words != 0 else 0

    def changed(mut self) -> Bool:
        """Whether anything was written since this was last asked. Never waits."""
        var n = self.count()
        if n == self.seen:
            return False
        self.seen = n
        return True

    def stop(mut self):
        """Asks the watching to stop (within 50 ms). Never waits."""
        if self.words != 0:
            _A.store(_w(self.words, F_STOP), 1)

    def __deinit__(deinit self):
        if self.words == 0:
            return
        _A.store(_w(self.words, F_STOP), 1)
        var until = now_ns() + 2_000_000_000  # (the thread sees the flag within 50 ms; its words are freed by the last owner)
        while now_ns() < until:
            var st = Int(_A.load(_w(self.words, F_STATE)))
            if st == 2 or st == -1:
                break
            _ = _c[c_int]("poll", Int(0), Int(0), c_int(5))
        _release(self.words)
