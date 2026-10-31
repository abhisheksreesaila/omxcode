# mojoui.watch's hard cases (goal 45, review round 1), each in a temp folder of its own (removed at the end):
#   names     a name with a newline, one with a tab: each arrives whole, as one event
#   bytes     a name that isn't UTF-8: one event, exact False, path_bytes the real bytes
#   rename    a folder renamed inside the tree: DELETED (is_dir) for the old name, CREATED for each file under the new
#             one, and a later write under the new name is reported under it
#   overflow  the kernel's queue overflowed (the reader held while 20,000 events queue): one OVERFLOW, and a folder
#             made afterwards is still watched
#   partial   a folder the system won't watch (mode 000): the watcher is partial(), says why, and watches the rest
#   drop      a watcher dropped with its pipe full: its thread ends before the drop returns (no thread left, no SIGPIPE)
# Prints `edges <case>: ok` per case and `edges: all ok`; raises on the first failure.
#   pixi run mojo run -I . tests/test_watch_edges.mojo
from std.ffi import c_int
from std.memory import Pointer
from mojoui.watch import FolderWatcher, WatchEvent, list_dir, _c, CREATED, MODIFIED, DELETED, OVERFLOW
from mojoui.clock import now_ns


def write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def mkdir(path: String):
    var p = path
    _ = _c[c_int]("mkdir", Int(p.as_c_string_span().unsafe_ptr()), c_int(0o755))
    _ = p.byte_length()


def chmod(path: String, mode: Int):
    var p = path
    _ = _c[c_int]("chmod", Int(p.as_c_string_span().unsafe_ptr()), c_int(mode))
    _ = p.byte_length()


def rename(old: String, new: String):
    var a = old
    var b = new
    _ = _c[c_int]("rename", Int(a.as_c_string_span().unsafe_ptr()), Int(b.as_c_string_span().unsafe_ptr()))
    _ = a.byte_length() + b.byte_length()


def shell(cmd: String):
    var c = cmd
    _ = _c[c_int]("system", Int(c.as_c_string_span().unsafe_ptr()))
    _ = c.byte_length()


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        out.append(p[i])
    return out^


def temp_dir() raises -> String:
    var tpl = bytes_of("/tmp/mojoui-watch-XXXXXX")
    tpl.append(0)
    _ = _c[Int]("mkdtemp", Int(tpl.unsafe_ptr()))
    _ = len(tpl)
    return String(from_utf8=Span(tpl)[: len(tpl) - 1])


def threads() -> Int:
    return len(list_dir("/proc/self/task"))


def collect(mut w: FolderWatcher, ms: Int) -> List[WatchEvent]:
    var out = List[WatchEvent]()
    var until = now_ns() + ms * 1_000_000
    while now_ns() < until:
        _ = w.wait(20)
        for e in w.take():
            out.append(e.copy())
    return out^


def describe(evs: List[WatchEvent]) -> String:
    var s = String("")
    for e in evs:
        s += e.kind_name() + (" dir " if e.is_dir else " ") + e.path.replace("\n", "\\n").replace("\t", "\\t") + "; "
    return s


def ready(mut w: FolderWatcher) raises:
    w.start()
    var t0 = now_ns()
    while not w.ready():
        if w.failed():
            raise Error(w.why())
        if now_ns() - t0 > 5_000_000_000:
            raise Error("not ready in 5 s")
        _ = w.wait(5)


def pressure(dir: String) raises -> Int:
    """A watcher whose pipe fills (30,000 changes nobody takes), then dropped here; returns its pipe size."""
    var w = FolderWatcher(dir)
    ready(w)
    var size = w.pipe_size
    for i in range(30000):
        write(dir + ("/a.txt" if i % 2 == 0 else "/b.txt"), "x")
    _ = _c[c_int]("poll", Int(0), Int(0), c_int(300))
    return size  # (w is dropped here: its __deinit__ must stop the thread, blocked in a write, and wait for it)


def main() raises:
    var root = temp_dir()
    var w = FolderWatcher(root)
    ready(w)

    # names with a newline and a tab
    write(root + "/line\nbreak.txt", "1")
    write(root + "/tab\there.txt", "2")
    var evs = collect(w, 300)
    if len(evs) != 2 or evs[0].path != root + "/line\nbreak.txt" or evs[1].path != root + "/tab\there.txt" or evs[0].kind != CREATED or not evs[0].exact:
        raise Error("names: " + describe(evs))
    print("edges names: ok", flush=True)

    # a name that isn't UTF-8
    var raw = bytes_of(root + "/bad")
    raw.append(0xFF)
    raw.extend(bytes_of(".txt"))
    var want = raw.copy()
    raw.append(0)
    var fd = _c[c_int]("open", Int(raw.unsafe_ptr()), c_int(0x41), c_int(0o644))  # O_WRONLY | O_CREAT
    if Int(fd) < 0:
        raise Error("bytes: open failed, errno " + String(Int(Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=_c[Int]("__errno_location"))[])))
    _ = len(raw)
    _ = _c[c_int]("close", fd)
    evs = collect(w, 300)
    if len(evs) != 1 or evs[0].exact or evs[0].path_bytes != want or evs[0].kind != CREATED:
        raise Error("bytes: " + describe(evs))
    print("edges bytes: ok (" + evs[0].path + ")", flush=True)

    # a folder renamed inside the tree
    mkdir(root + "/a")
    mkdir(root + "/a/deep")
    write(root + "/a/x.txt", "x")
    write(root + "/a/deep/y.txt", "y")
    _ = collect(w, 300)
    rename(root + "/a", root + "/b")
    evs = collect(w, 300)
    var gone = 0
    var made = List[String]()
    for e in evs:
        if e.kind == DELETED and e.is_dir and e.path == root + "/a":
            gone += 1
        elif e.kind == CREATED and not e.is_dir:
            made.append(e.path)
        else:
            raise Error("rename: unexpected " + describe(evs))
    if gone != 1 or len(made) != 2 or not (root + "/b/x.txt" in made) or not (root + "/b/deep/y.txt" in made):
        raise Error("rename: " + describe(evs))
    write(root + "/b/deep/y.txt", "again")
    evs = collect(w, 300)
    if len(evs) != 1 or evs[0].kind != MODIFIED or evs[0].path != root + "/b/deep/y.txt":
        raise Error("rename, then a write under the new name: " + describe(evs))
    print("edges rename: ok", flush=True)

    # the kernel's queue overflows
    w.hold(True)
    for i in range(20000):
        write(root + ("/b/x.txt" if i % 2 == 0 else "/b/deep/y.txt"), "z")
    w.hold(False)
    var overflows = 0
    var until = now_ns() + 10_000_000_000
    while overflows == 0 and now_ns() < until:
        _ = w.wait(50)
        for e in w.take():
            if e.kind == OVERFLOW:
                overflows += 1
    if overflows != 1:
        raise Error("overflow: " + String(overflows) + " OVERFLOW events")
    _ = collect(w, 200)
    mkdir(root + "/c")
    write(root + "/c/z.txt", "z")
    evs = collect(w, 300)
    if len(evs) != 1 or evs[0].path != root + "/c/z.txt" or evs[0].kind != CREATED:
        raise Error("after the overflow: " + describe(evs))
    print("edges overflow: ok", flush=True)

    # a folder the system won't watch
    var root2 = temp_dir()
    mkdir(root2 + "/locked")
    mkdir(root2 + "/open")
    chmod(root2 + "/locked", 0)
    var w2 = FolderWatcher(root2)
    ready(w2)
    if not w2.partial() or w2.missed() != 1 or w2.why().find("no permission") < 0:
        raise Error("partial: partial=" + String(w2.partial()) + " missed=" + String(w2.missed()) + " why=" + w2.why())
    write(root2 + "/open/f.txt", "f")
    evs = collect(w2, 300)
    if len(evs) != 1 or evs[0].path != root2 + "/open/f.txt":
        raise Error("partial, the rest: " + describe(evs))
    chmod(root2 + "/locked", 0o755)
    print("edges partial: ok (" + w2.why() + ")", flush=True)

    # dropped with its pipe full
    var root3 = temp_dir()
    var before = threads()
    var t0 = now_ns()
    var size = pressure(root3)
    var took = Float64(now_ns() - t0) / 1e6
    var after = threads()
    if size < 65536 or after != before:
        raise Error("drop: pipe " + String(size) + " bytes, threads " + String(before) + " before, " + String(after) + " after")
    print("edges drop: ok (pipe " + String(size) + " bytes; threads " + String(before) + " → " + String(after) + "; " + String(Int(took)) + " ms with the writes)", flush=True)

    w.stop()
    w2.stop()
    for d in [root, root2, root3]:
        shell("rm -rf '" + d + "'")
    print("edges: all ok", flush=True)
