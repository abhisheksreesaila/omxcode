# mojoui.watch: a folder watcher (goal 45 M0). Watches a folder and every folder under it, new ones included, on a
# thread of its own; the caller (the UI thread, a job) takes what happened without ever waiting.
#
#   var w = FolderWatcher(path, wake=True)       # wake: each batch of changes wakes the host (App.jobs_message())
#   w.start()                                    # returns at once; w.ready() once every folder is watched
#   for e in w.take():                           # never waits; e.kind is CREATED, MODIFIED, RENAMED, DELETED, OVERFLOW
#       print(e.kind_name(), e.path, e.at_ns)    # e.old_path for a rename; e.at_ns on mojoui.clock.now_ns()'s clock
#   w.stop()                                     # (dropping it stops it too)
#
# One event per change: a file written once is one CREATED (or MODIFIED) when it's closed, not one per write(); a
# rename inside the folder is one RENAMED; a file moved in is CREATED, moved out DELETED. OVERFLOW means the system
# dropped events (too many at once): rescan. Folders themselves aren't reported, except a folder deleted or moved out
# (DELETED, is_dir), so a consumer can forget what was under it.
#
# Linux: inotify, read on a pthread of its own; each new folder gets a watch the moment it appears, and what was put in
# it before the watch was added is found by listing it (reported when its writer closes it, or within 20 ms if it
# already had). Mac: FSEvents (file-level events on a dispatch queue of its own), built, not run (docs/components.md).
# The thread hands events over through a pipe (a few bytes each), so nothing is shared but the pipe, and a consumer
# can sleep on it (wait()). Also here: walk_files, every file under a folder (what a first scan needs).

from std.atomic import Atomic
from std.ffi import external_call, c_int, c_char
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.sys import CompilationTarget
from std.collections import Dict
from mojoui.clock import now_ns
from mojoui.shared import get_shared

comptime CREATED = 1
comptime MODIFIED = 2
comptime RENAMED = 3
comptime DELETED = 4
comptime OVERFLOW = 5

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime W_STATE = 0  # 0 starting, 1 watching, 2 stopped, -1 failed
comptime W_STOP = 1
comptime W_REFS = 2  # the handle and the thread; the last one frees
comptime W_OUT = 3  # the pipe's write end (the thread's)
comptime W_ROOT = 4  # a NUL-terminated copy of the root
comptime W_WAKE = 5  # 1: wake the host after each batch
comptime W_TID = 6  # the reader thread's id (gettid), once it runs
comptime W_ERR = 7  # errno when it failed
comptime W_STREAM = 8  # Mac: the FSEventStream
comptime W_WORDS = 9

comptime IN_CLOSE_WRITE = 0x8
comptime IN_MOVED_FROM = 0x40
comptime IN_MOVED_TO = 0x80
comptime IN_CREATE = 0x100
comptime IN_DELETE = 0x200
comptime IN_DELETE_SELF = 0x400
comptime IN_MOVE_SELF = 0x800
comptime IN_Q_OVERFLOW = 0x4000
comptime IN_IGNORED = 0x8000
comptime IN_ISDIR = 0x40000000
comptime _MASK = IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF | 0x01000000 | 0x02000000  # ONLYDIR, DONT_FOLLOW
comptime SCANNED_WAIT_NS = 20_000_000  # a file found by listing a new folder: reported at its close, or after this
comptime CREATED_WAIT_NS = 2_000_000_000  # a created file still open this long is reported anyway (then MODIFIED at close)
comptime PAIR_WAIT_NS = 20_000_000  # a move out with no move in after this is a delete


@fieldwise_init
struct WatchEvent(Copyable, Movable):
    var kind: Int
    var path: String  # absolute
    var old_path: String  # a rename's old name ("" otherwise)
    var at_ns: Int  # when the watcher's thread saw it (now_ns()'s clock: CLOCK_MONOTONIC on Linux)
    var is_dir: Bool

    def kind_name(self) -> String:
        if self.kind == CREATED:
            return "create"
        if self.kind == MODIFIED:
            return "modify"
        if self.kind == RENAMED:
            return "rename"
        if self.kind == DELETED:
            return "delete"
        return "overflow"


def _word(words: Int, k: Int) -> _P:
    return _P(unsafe_from_address=words + 8 * k)


def wake_ui():
    """mojoui.jobs.wake_ui without its engine import (mojoui.watch runs under `mojo run` too): one byte down the
    host's job-wake pipe (mojoui.shared slot 90), so App.jobs_message() reaches update() at once. Linux only; the Mac
    host's wake is a message to its delegate (mojoui.jobs.WakeUI): a Mac app polls take() on a timer for now."""
    comptime if CompilationTarget.is_linux():
        var fd = get_shared(90) - 1
        if fd >= 0:
            var b = List[UInt8](length=1, fill=1)
            _ = _c[Int]("write", c_int(fd), Int(b.unsafe_ptr()), 1)
            _ = len(b)


def _sym(name: String) -> Int:
    var n = name
    var anywhere = -2 if CompilationTarget.is_macos() else 0  # RTLD_DEFAULT
    return external_call["dlsym", Int](anywhere, n.as_c_string_span())


def _c[T: RegisterPassable = Int, *A: AnyType](name: String, *args: *A) -> T:
    """A libc function called by address (the standard library and the hosts declare read(), poll() and friends their
    own ways, and a program may declare a C function only once)."""
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=_sym(name))
    var f = Pointer(to=raw).unsafe_bitcast[def(*a: *A) thin abi("C") -> T]()[]
    return f(*args)


def _cstr(s: String) -> Int:
    var n = s.byte_length()
    var p = unsafe_alloc[UInt8](n + 1)
    var src = s.unsafe_ptr()
    for i in range(n):
        p[i] = src[i]
    p[n] = 0
    return Int(p)


def _from_c(addr: Int) -> String:
    if addr == 0:
        return String("")
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


def _errno() -> Int:
    comptime if CompilationTarget.is_macos():
        return Int(Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=_c[Int]("__error"))[])
    return Int(Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=_c[Int]("__errno_location"))[])


# ---- listing folders (opendir/readdir: d_type says file or folder without a stat per entry)

def list_dir(path: String) -> List[Tuple[String, Bool]]:
    """A folder's entries (name, is_dir), without . and ..; symlinks and other kinds left out. Empty if unreadable."""
    var out = List[Tuple[String, Bool]]()
    var p = path
    var d = _c[Int]("opendir", Int(p.as_c_string_span().unsafe_ptr()))
    if d == 0:
        return out^
    comptime name_at = 21 if CompilationTarget.is_macos() else 19
    comptime type_at = 20 if CompilationTarget.is_macos() else 18
    while True:
        var e = _c[Int]("readdir", d)
        if e == 0:
            break
        var t = Int(Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=e + type_at)[])
        var name = _from_c(e + name_at)
        if name == "." or name == "..":
            continue
        if t == 4:  # DT_DIR
            out.append((name, True))
        elif t == 8:  # DT_REG
            out.append((name, False))
        elif t == 0:  # DT_UNKNOWN (some file systems): ask
            var full = path + "/" + name
            var probe = _c[Int]("opendir", Int(full.as_c_string_span().unsafe_ptr()))
            if probe != 0:
                _ = _c[c_int]("closedir", probe)
                out.append((name, True))
            else:
                out.append((name, False))
    _ = _c[c_int]("closedir", d)
    return out^


def file_stamp(path: String) -> Tuple[Int, Int]:
    """A file's (modified time in ns since the epoch, size in bytes); (0, -1) if it can't be read. What a rescan
    compares with what it kept (struct stat: x86-64 Linux st_size at byte 48, st_mtim at 88; the Mac's 64-bit-inode
    stat st_mtimespec at 48, st_size at 96)."""
    var st = List[Int](length=24, fill=0)
    var p = path
    if Int(_c[c_int]("stat", Int(p.as_c_string_span().unsafe_ptr()), Int(st.unsafe_ptr()))) != 0:
        return (0, -1)
    comptime if CompilationTarget.is_macos():
        return (st[6] * 1_000_000_000 + st[7], st[12])
    return (st[11] * 1_000_000_000 + st[12], st[6])


def walk_files(root: String, suffixes: List[String]) -> List[String]:
    """Every file under root (absolute paths) whose name ends with one of suffixes (all files if none), depth first."""
    var out = List[String]()
    var todo = List[String]()
    todo.append(String(root.rstrip("/")))
    while len(todo) > 0:
        var dir = todo.pop()
        for entry in list_dir(dir):
            var full = dir + "/" + entry[0]
            if entry[1]:
                todo.append(full)
            else:
                var keep = len(suffixes) == 0
                for s in suffixes:
                    if entry[0].endswith(s):
                        keep = True
                if keep:
                    out.append(full)
    return out^


# ---- the thread

def _emit(words: Int, kind: Int, path: String, old: String = "", is_dir: Bool = False):
    """One record down the pipe: kind, dir flag, time, path, old path, tab-separated, one line (the pipe blocks when
    full, so nothing is lost while the consumer catches up)."""
    var rec = String(kind) + ("d" if is_dir else "f") + "\t" + String(now_ns()) + "\t" + path + "\t" + old + "\n"
    var fd = Int(_A.load(_word(words, W_OUT)))
    var off = 0
    var n = rec.byte_length()
    while off < n:
        var w = _c[Int]("write", c_int(fd), Int(rec.unsafe_ptr()) + off, n - off)
        if w <= 0:
            if _errno() == 4:  # EINTR
                continue
            return
        off += w
    _ = rec.byte_length()


struct _Linux(Movable):
    """What the reader thread keeps: the watches, files waiting for their close, a move waiting for its pair."""
    var fd: Int
    var words: Int
    var dirs: Dict[Int, String]  # watch descriptor → folder
    var pending: Dict[String, Int]  # a new file → the time to report it anyway
    var moved_cookie: Int  # a move out waiting for its move in (0: none)
    var moved_path: String
    var moved_dir: Bool
    var moved_at: Int
    var emitted: Int

    def __init__(out self, fd: Int, words: Int):
        self.fd = fd
        self.words = words
        self.dirs = Dict[Int, String]()
        self.pending = Dict[String, Int]()
        self.moved_cookie = 0
        self.moved_path = ""
        self.moved_dir = False
        self.moved_at = 0
        self.emitted = 0

    def emit(mut self, kind: Int, path: String, old: String = "", is_dir: Bool = False):
        _emit(self.words, kind, path, old, is_dir)
        self.emitted += 1

    def add_tree(mut self, root: String, report_files: Bool):
        """Watches root and every folder under it; with report_files (a folder that appeared while watching), the
        files already in it wait for their close (or SCANNED_WAIT_NS)."""
        var todo = List[String]()
        todo.append(root)
        while len(todo) > 0:
            var dir = todo.pop()
            var wd = _c[c_int]("inotify_add_watch", c_int(self.fd), Int(dir.as_c_string_span().unsafe_ptr()), UInt32(_MASK))
            if Int(wd) < 0:
                continue
            self.dirs[Int(wd)] = dir
            for entry in list_dir(dir):
                var full = dir + "/" + entry[0]
                if entry[1]:
                    todo.append(full)
                elif report_files and full not in self.pending:
                    self.pending[full] = now_ns() + SCANNED_WAIT_NS

    def rename_tree(mut self, old: String, new: String):
        """A folder moved inside the tree: the watches under it now carry its new name."""
        var fixes = List[Tuple[Int, String]]()
        for item in self.dirs.items():
            var d = item.value
            if d == old or d.startswith(old + "/"):
                fixes.append((item.key, new + String(d[byte = old.byte_length() :])))
        for f in fixes:
            self.dirs[f[0]] = f[1]

    def forget_tree(mut self, old: String):
        var gone = List[Int]()
        for item in self.dirs.items():
            if item.value == old or item.value.startswith(old + "/"):
                gone.append(item.key)
        for wd in gone:
            _ = _c[c_int]("inotify_rm_watch", c_int(self.fd), c_int(wd))
            _ = self.dirs.pop(wd, String(""))

    def flush_move(mut self):
        """The waiting move out never got its move in: it left the tree."""
        if self.moved_cookie == 0:
            return
        var gone = self.moved_path.copy()
        if self.moved_dir:
            self.forget_tree(gone)
            self.emit(DELETED, gone, "", True)
        elif gone in self.pending:
            _ = self.pending.pop(gone, 0)
        else:
            self.emit(DELETED, gone)
        self.moved_cookie = 0

    def flush_due(mut self):
        var now = now_ns()
        var due = List[String]()
        for item in self.pending.items():
            if item.value <= now:
                due.append(item.key)
        for p in due:
            _ = self.pending.pop(p, 0)
            self.emit(CREATED, p)
        if self.moved_cookie != 0 and now - self.moved_at >= PAIR_WAIT_NS:
            self.flush_move()

    def next_wait_ms(self) -> Int:
        """How long poll() may sleep: until the next file is due, 50 ms at most (the stop flag is checked that often)."""
        var now = now_ns()
        var soonest = now + 50_000_000
        for item in self.pending.items():
            soonest = min(soonest, item.value)
        if self.moved_cookie != 0:
            soonest = min(soonest, self.moved_at + PAIR_WAIT_NS)
        return max(0, (soonest - now + 999_999) // 1_000_000)

    def handle(mut self, wd: Int, mask: Int, cookie: Int, name: String):
        if mask & IN_Q_OVERFLOW:
            self.emit(OVERFLOW, "")
            return
        if mask & IN_IGNORED:
            _ = self.dirs.pop(wd, String(""))
            return
        var dir = self.dirs.get(wd, String(""))
        if dir == "":
            return
        if name == "":  # the watched folder itself (deleted or moved: its parent reports it)
            return
        var path = dir + "/" + name
        var is_dir = (mask & IN_ISDIR) != 0
        if self.moved_cookie != 0 and not ((mask & IN_MOVED_TO) and cookie == self.moved_cookie):
            self.flush_move()
        if mask & IN_CREATE:
            if is_dir:
                self.add_tree(path, True)
            elif path not in self.pending:
                self.pending[path] = now_ns() + CREATED_WAIT_NS
        elif mask & IN_CLOSE_WRITE:
            if path in self.pending:
                _ = self.pending.pop(path, 0)
                self.emit(CREATED, path)
            else:
                self.emit(MODIFIED, path)
        elif mask & IN_MOVED_FROM:
            self.moved_cookie = cookie if cookie != 0 else -1
            self.moved_path = path
            self.moved_dir = is_dir
            self.moved_at = now_ns()
        elif mask & IN_MOVED_TO:
            if self.moved_cookie != 0 and cookie == self.moved_cookie:
                var old = self.moved_path
                self.moved_cookie = 0
                if is_dir:
                    self.rename_tree(old, path)
                elif old in self.pending:  # (renamed before its writer closed it: it's still new, under its new name)
                    var due = self.pending.pop(old, 0)
                    self.pending[path] = due
                else:
                    self.emit(RENAMED, path, old)
            elif is_dir:
                self.add_tree(path, True)
            else:
                self.emit(CREATED, path)
        elif mask & IN_DELETE:
            if is_dir:
                self.forget_tree(path)
                self.emit(DELETED, path, "", True)
            elif path in self.pending:
                _ = self.pending.pop(path, 0)  # (made and removed before it was closed: nothing to report)
            else:
                self.emit(DELETED, path)


def _watch_linux(words: Int) raises:
    var fd = Int(_c[c_int]("inotify_init1", c_int(0x800 | 0x80000)))  # IN_NONBLOCK | IN_CLOEXEC
    if fd < 0:
        _A.store(_word(words, W_ERR), Int64(_errno()))
        raise Error("inotify_init1 failed")
    _A.store(_word(words, W_TID), Int64(Int(_c[c_int]("gettid"))))
    var root = _from_c(Int(_A.load(_word(words, W_ROOT))))
    var st = _Linux(fd, words)
    st.add_tree(root, False)
    if len(st.dirs) == 0:
        _A.store(_word(words, W_ERR), Int64(_errno()))
        _ = _c[c_int]("close", c_int(fd))
        raise Error("can't watch " + root)
    _A.store(_word(words, W_STATE), 1)
    var buf = unsafe_alloc[UInt8](65536)
    var pfd = unsafe_alloc[Int32](2)  # struct pollfd { int fd; short events; short revents }
    var wake = _A.load(_word(words, W_WAKE)) != 0
    while _A.load(_word(words, W_STOP)) == 0:
        pfd[0] = Int32(fd)
        pfd[1] = Int32(1)  # POLLIN
        _ = _c[c_int]("poll", Int(pfd), Int(1), c_int(st.next_wait_ms()))
        var before = st.emitted
        while True:  # drain everything queued (the deadlines below only run on a drained queue)
            var n = _c[Int]("read", c_int(fd), Int(buf), 65536)
            if n <= 0:
                break
            var off = 0
            while off + 16 <= n:
                var at = Int(buf) + off
                var wd = Int(Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=at)[])
                var mask = Int(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=at + 4)[])
                var cookie = Int(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=at + 8)[])
                var len_ = Int(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=at + 12)[])
                var name = _from_c(at + 16) if len_ > 0 else String("")
                st.handle(wd, mask, cookie, name)
                off += 16 + len_
        st.flush_due()
        if wake and st.emitted != before:
            wake_ui()
    buf.unsafe_free()
    pfd.unsafe_free()
    _ = _c[c_int]("close", c_int(fd))


# ---- Mac: FSEvents (built, not run)

comptime _FS_CREATED = 0x100
comptime _FS_REMOVED = 0x200
comptime _FS_RENAMED = 0x800
comptime _FS_MODIFIED = 0x1000
comptime _FS_IS_DIR = 0x20000
comptime _FS_OVERFLOW = 0x2 | 0x4  # MustScanSubDirs, UserDropped


def _fs_callback(stream: Int, info: Int, count: Int, paths: Int, flags: Int, ids: Int) abi("C"):
    """FSEvents' callback, on the watcher's dispatch queue: one record per event (a rename comes as two events,
    the old name and the new: the one still there is RENAMED, the gone one DELETED; FSEvents doesn't pair them)."""
    var emitted = 0
    for i in range(count):
        var path = _from_c(Pointer[Int, MutUntrackedOrigin](unsafe_from_address=paths + 8 * i)[])
        var f = Int(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=flags + 4 * i)[])
        var is_dir = (f & _FS_IS_DIR) != 0
        var exists = _c[c_int]("access", Int(path.as_c_string_span().unsafe_ptr()), c_int(0)) == 0
        if f & _FS_OVERFLOW:
            _emit(info, OVERFLOW, "")
        elif f & _FS_REMOVED and not exists:
            _emit(info, DELETED, path, "", is_dir)
        elif f & _FS_RENAMED:
            _emit(info, RENAMED if exists else DELETED, path, "", is_dir)
        elif is_dir:
            continue
        elif f & _FS_CREATED:
            _emit(info, CREATED, path)
        elif f & _FS_MODIFIED:
            _emit(info, MODIFIED, path)
        else:
            continue
        emitted += 1
    if emitted > 0 and _A.load(_word(info, W_WAKE)) != 0:
        wake_ui()


def _watch_mac(words: Int) raises:
    """FSEventStreamCreate on the root, file-level events, no coalescing delay, on a serial dispatch queue."""
    var cs = String("/System/Library/Frameworks/CoreServices.framework/CoreServices")
    var lib = _c[Int]("dlopen", Int(cs.as_c_string_span().unsafe_ptr()), c_int(2))
    if lib == 0:
        raise Error("no CoreServices")
    var root = _A.load(_word(words, W_ROOT))
    var cfstr = _c[Int]("CFStringCreateWithCString", Int(0), Int(root), UInt32(0x08000100))  # kCFStringEncodingUTF8
    var one = unsafe_alloc[Int](1)
    one[0] = cfstr
    var arr = _c[Int]("CFArrayCreate", Int(0), Int(one), Int(1), _sym("kCFTypeArrayCallBacks"))
    var ctx = unsafe_alloc[Int](5)  # FSEventStreamContext { version, info, retain, release, copyDescription }
    ctx[0] = 0
    ctx[1] = words
    ctx[2] = 0
    ctx[3] = 0
    ctx[4] = 0
    var create = _sym("FSEventStreamCreate")
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=create)
    var f = Pointer(to=raw).unsafe_bitcast[def(Int, def(Int, Int, Int, Int, Int, Int) thin abi("C") -> None, Int, Int, UInt64, Float64, UInt32) thin abi("C") -> Int]()[]
    var stream = f(Int(0), _fs_callback, Int(ctx), arr, UInt64(0xFFFFFFFFFFFFFFFF), Float64(0.0), UInt32(0x10 | 0x2 | 0x40))  # FileEvents | NoDefer | MarkSelf
    if stream == 0:
        raise Error("FSEventStreamCreate failed")
    var label = String("mojoui.watch")
    var queue = _c[Int]("dispatch_queue_create", Int(label.as_c_string_span().unsafe_ptr()), Int(0))
    _c[NoneType]("FSEventStreamSetDispatchQueue", stream, queue)
    if _c[UInt8]("FSEventStreamStart", stream) == 0:
        raise Error("FSEventStreamStart failed")
    _A.store(_word(words, W_STREAM), Int64(stream))
    _A.store(_word(words, W_STATE), 1)
    _ = lib


def _release(words: Int):
    if _A.fetch_add(_word(words, W_REFS), -1) == 1:
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(_A.load(_word(words, W_ROOT)))).unsafe_free()
        _ = _c[c_int]("close", c_int(Int(_A.load(_word(words, W_OUT)))))
        _P(unsafe_from_address=words).unsafe_free()


def _entry(arg: Int) abi("C") -> Int:
    try:
        _watch_linux(arg)
        _A.store(_word(arg, W_STATE), 2)
    except:
        _A.store(_word(arg, W_STATE), -1)
    _release(arg)
    return 0


struct FolderWatcher(Movable):
    """Watches a folder and everything under it. Dropping it stops the thread."""

    var root: String
    var words: Int
    var read_fd: Int
    var wake: Bool
    var started: Bool
    var reason: String
    var partial: String  # a record cut by the end of a read

    def __init__(out self, root: String, wake: Bool = False):
        self.root = String(root.rstrip("/")) if root != "/" else root
        self.words = 0
        self.read_fd = -1
        self.wake = wake
        self.started = False
        self.reason = ""
        self.partial = ""

    def start(mut self):
        """Starts watching on its own thread and returns at once (ready() once every folder has its watch)."""
        if self.started:
            return
        self.started = True
        var fds = List[Int32](length=2, fill=-1)
        if Int(_c[c_int]("pipe", Int(fds.unsafe_ptr()))) != 0:
            self.reason = "no pipe for the watcher"
            return
        self.read_fd = Int(fds[0])
        var w = Int(fds[1])
        comptime nonblock = 4 if CompilationTarget.is_macos() else 2048
        _ = external_call["fcntl", c_int, num_fixed_args=2](c_int(self.read_fd), c_int(4), c_int(nonblock))  # F_SETFL O_NONBLOCK
        _ = external_call["fcntl", c_int, num_fixed_args=2](c_int(self.read_fd), c_int(2), c_int(1))  # FD_CLOEXEC
        _ = external_call["fcntl", c_int, num_fixed_args=2](c_int(w), c_int(2), c_int(1))
        comptime if CompilationTarget.is_linux():
            _ = external_call["fcntl", c_int, num_fixed_args=2](c_int(w), c_int(1031), c_int(1 << 20))  # F_SETPIPE_SZ: 1 MB of events
        var words = unsafe_alloc[Int64](W_WORDS)
        for k in range(W_WORDS):
            _A.store(_word(Int(words), k), 0)
        _A.store(_word(Int(words), W_REFS), 2)
        _A.store(_word(Int(words), W_OUT), Int64(w))
        _A.store(_word(Int(words), W_ROOT), Int64(_cstr(self.root)))
        _A.store(_word(Int(words), W_WAKE), Int64(1 if self.wake else 0))
        self.words = Int(words)
        comptime if CompilationTarget.is_macos():
            _A.store(_word(self.words, W_REFS), 1)  # (FSEvents' queue isn't an owner: dropping the handle ends the stream first)
            try:
                _watch_mac(self.words)
            except e:
                _A.store(_word(self.words, W_STATE), -1)
                self.reason = String(e)
        else:
            var tid = List[Int](length=1, fill=0)
            var entry = _entry  # (pthread_create by address: the engine declares it with its own types, D-1609)
            var rc = _c[c_int]("pthread_create", Int(tid.unsafe_ptr()), Int(0), Pointer(to=entry).unsafe_bitcast[Int]()[], self.words)
            if rc != 0:
                _A.store(_word(self.words, W_STATE), -1)
                _release(self.words)
                self.reason = "no thread for the watcher"
            else:
                _ = _c[c_int]("pthread_detach", tid[0])

    def _state(self) -> Int:
        return Int(_A.load(_word(self.words, W_STATE))) if self.words != 0 else (-1 if self.reason else 0)

    def ready(self) -> Bool:
        """Every folder under the root has its watch (changes from now on are reported)."""
        return self._state() == 1

    def failed(self) -> Bool:
        return self._state() == -1

    def stopped(self) -> Bool:
        """The thread has ended (after stop(); a process that exits right after should see this first)."""
        return self._state() == 2 or self._state() == -1

    def why(self) -> String:
        if self.reason:
            return self.reason
        if self.failed():
            return "can't watch " + self.root + " (error " + String(Int(_A.load(_word(self.words, W_ERR)))) + ")"
        return ""

    def reader_thread(self) -> Int:
        """The watcher thread's id (Linux: gettid; 0 elsewhere or before it runs)."""
        return Int(_A.load(_word(self.words, W_TID))) if self.words != 0 else 0

    def fd(self) -> Int:
        """The pipe events arrive on (readable when there are some), for a loop that sleeps on it."""
        return self.read_fd

    def wait(self, timeout_ms: Int) -> Bool:
        """Sleeps until events are waiting (True) or timeout_ms passes (False). Not for the UI thread."""
        if self.read_fd < 0:
            return False
        var pfd = List[Int32](length=2, fill=0)
        pfd[0] = Int32(self.read_fd)
        pfd[1] = Int32(1)
        var r = _c[c_int]("poll", Int(pfd.unsafe_ptr()), Int(1), c_int(timeout_ms))
        _ = len(pfd)
        return Int(r) > 0

    def take(mut self) -> List[WatchEvent]:
        """What happened since the last take, oldest first. Never waits."""
        var out = List[WatchEvent]()
        if self.read_fd < 0:
            return out^
        var buf = List[UInt8](length=65536, fill=0)
        var text = self.partial
        while True:
            var n = _c[Int]("read", c_int(self.read_fd), Int(buf.unsafe_ptr()), 65536)
            if n <= 0:
                break
            text += String(from_utf8_lossy=Span(buf)[:n])
        var last = text.rfind("\n")
        if last < 0:
            self.partial = text
            return out^
        self.partial = String(text[byte = last + 1 :])
        for line in text[byte=:last].split("\n"):
            var f = line.split("\t")
            if len(f) < 4 or f[0].byte_length() < 2:
                continue
            try:
                var head = String(f[0])
                var kind = Int(String(head[byte=: head.byte_length() - 1]))
                out.append(WatchEvent(kind, String(f[2]), String(f[3]), Int(String(f[1])), head.endswith("d")))
            except:
                pass
        return out^

    def stop(mut self):
        """Asks the thread to stop (within 50 ms). Never waits."""
        if self.words != 0:
            _A.store(_word(self.words, W_STOP), 1)
            comptime if CompilationTarget.is_macos():
                var s = Int(_A.load(_word(self.words, W_STREAM)))
                if s != 0:
                    _c[NoneType]("FSEventStreamStop", s)
                    _c[NoneType]("FSEventStreamInvalidate", s)
                    _A.store(_word(self.words, W_STREAM), 0)

    def __deinit__(deinit self):
        if self.words != 0:
            _A.store(_word(self.words, W_STOP), 1)
            comptime if CompilationTarget.is_macos():
                var s = Int(_A.load(_word(self.words, W_STREAM)))
                if s != 0:
                    _c[NoneType]("FSEventStreamStop", s)
                    _c[NoneType]("FSEventStreamInvalidate", s)
            _release(self.words)
        if self.read_fd >= 0:
            _ = _c[c_int]("close", c_int(self.read_fd))
