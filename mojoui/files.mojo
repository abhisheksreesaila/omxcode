# mojoui.files: small file helpers every document app needs: names from paths, the recent-files list
# (one path per line in <config>/recent.txt, newest first, at most 10) and settings (key=value lines in
# <config>/settings.txt).

from std.os.path import getsize, isdir, isfile
from std.sys import CompilationTarget
from std.os import listdir, stat
from mojoui.shared import environment, make_dir, arguments, serial
from mojoui.libc import file_identity, chmod, unlink, rename, open_append, open_read, fsync, write_fd, close, getpid, clock_gettime, flock


def file_name(path: String) -> String:
    var i = path.rfind("/")
    return String(path[byte = i + 1 :]) if i >= 0 else path


def file_stem(path: String) -> String:
    var name = file_name(path)
    var dot = name.rfind(".")
    return String(name[byte=:dot]) if dot > 0 else name


def file_size(path: String) raises -> Int:
    """The file's size in bytes."""
    return getsize(path)


def file_exists(path: String) -> Bool:
    """Whether a regular file is at `path`."""
    return isfile(path)


def file_argument_in(words: List[String], suffixes: List[String]) -> String:
    """The first of `words` after the program's own name (words[0]) that ends in one of `suffixes` (any case) and names
    a file, or "". A Python host's own words (mojoui/hosts/web.py, its build folder) never match."""
    for i in range(1, len(words)):
        var low = words[i].lower()
        for s in suffixes:
            if low.endswith(s.lower()) and file_exists(words[i]):
                return words[i]
    return ""


def file_argument(suffixes: List[String]) -> String:
    """The file the window was started with (`app path/to/file.csv`, a launcher entry's %f), or "" (see file_argument_in)."""
    return file_argument_in(arguments(), suffixes)


def config_dir(app: String) -> String:
    """Where an app keeps its settings: $OMX_CONFIG if set (tests), else ~/.config/<app>."""
    return environment("OMX_CONFIG", environment("HOME", ".") + "/.config/" + app)


def data_dir(app: String) -> String:
    """Where an app keeps what a person makes in it (its documents' database): $OMX_DATA if set (tests), else the
    platform's place: ~/Library/Application Support/<app> on a Mac, $XDG_DATA_HOME/<app> or ~/.local/share/<app> elsewhere."""
    var given = environment("OMX_DATA", "")
    if given != "":
        return given
    var home = environment("HOME", ".")
    comptime if CompilationTarget.is_macos():
        return home + "/Library/Application Support/" + app
    var xdg = environment("XDG_DATA_HOME", "")
    return (xdg if xdg.startswith("/") else home + "/.local/share") + "/" + app


def adopt_config(app: String, old: String):
    """An app that changed its name keeps its settings and recent files: each of ~/.config/<old>'s files is copied into
    ~/.config/<app> when <app> has no such file yet (the old folder stays, for an older build)."""
    if environment("OMX_CONFIG", "") != "":
        return
    var was = environment("HOME", ".") + "/.config/" + old
    for name in ["recent.txt", "settings.txt"]:
        try:
            with open(config_dir(app) + "/" + name, "r") as f:
                _ = f.read()
            continue  # (already there)
        except:
            pass
        try:
            var text: String
            with open(was + "/" + name, "r") as f:
                text = f.read()
            make_dir(config_dir(app))
            with open(config_dir(app) + "/" + name, "w") as f:
                f.write(text)
        except:
            pass


def read_recent(app: String) -> List[String]:
    """The files opened last (newest first). On the public web copy (MOJOUI_PUBLIC=1) none: each visitor's own list lives
    only in its session (goal 62: a second visitor saw the first's files, with their server paths)."""
    var out = List[String]()
    if environment("MOJOUI_PUBLIC") == "1":
        return out^
    try:
        with open(config_dir(app) + "/recent.txt", "r") as f:
            for line in f.read().split("\n"):
                var p = String(line.strip())
                if p != "":
                    out.append(p)
    except:
        pass
    return out^


def remember(app: String, path: String, mut recent: List[String]):
    """Puts path first in the list (and on disk)."""
    var out = List[String]()
    out.append(path)
    for p in recent:
        if p != path and len(out) < 10:
            out.append(p)
    recent = out^
    if environment("MOJOUI_PUBLIC") == "1":  # (the public copy: the list stays in this session, never on disk)
        return
    try:
        make_dir(config_dir(app))
        with open(config_dir(app) + "/recent.txt", "w") as f:
            for p in recent:
                f.write(p + "\n")
    except:
        pass


def read_setting(app: String, key: String, fallback: String = "") -> String:
    """One value from <config>/settings.txt ("skin=dark"), or the fallback. The public web copy keeps none on disk (a
    visitor's choices stay in its session: one visitor's Light opened the next one's Start screen, goal 62's review)."""
    if environment("MOJOUI_PUBLIC") == "1":
        return fallback
    try:
        with open(config_dir(app) + "/settings.txt", "r") as f:
            for line in f.read().split("\n"):
                var eq = line.find("=")
                if eq > 0 and String(line[byte=:eq]).strip() == key:
                    return String(String(line[byte=eq + 1:]).strip())
    except:
        pass
    return fallback


def write_setting(app: String, key: String, value: String):
    """Sets one value in <config>/settings.txt, keeping the others (never on the public web copy)."""
    if environment("MOJOUI_PUBLIC") == "1":
        return
    var lines = List[String]()
    var found = False
    try:
        with open(config_dir(app) + "/settings.txt", "r") as f:
            for line in f.read().split("\n"):
                var eq = line.find("=")
                if eq > 0 and String(line[byte=:eq]).strip() == key:
                    lines.append(key + "=" + value)
                    found = True
                elif String(line.strip()) != "":
                    lines.append(String(line))
    except:
        pass
    if not found:
        lines.append(key + "=" + value)
    try:
        make_dir(config_dir(app))
        with open(config_dir(app) + "/settings.txt", "w") as f:
            for l in lines:
                f.write(l + "\n")
    except:
        pass


def remove_tree(path: String) raises:
    """Deletes `path` and everything under it (rm -r). A symlink is removed, never followed: what it points at stays.
    A missing path is no error."""
    from std.os import listdir, remove, rmdir
    from std.os.path import isdir, islink, exists
    if islink(path) or (exists(path) and not isdir(path)):
        remove(path)
        return
    if not isdir(path):
        return
    for name in listdir(path):
        remove_tree(path + "/" + name)
    rmdir(path)


def visitor_path_ok(path: String, own: String) -> Bool:
    """A path a person typed, before the app opens it: anywhere on a desktop; on the public web copy only inside `own`,
    the visitor's own folder (no "..", no other place on the server: goal 62's review found Open recipe reading any)."""
    if environment("MOJOUI_PUBLIC") != "1":
        return True
    var p = String(path.strip())
    return own != "" and p.startswith(own.rstrip("/") + "/") and p.find("..") < 0


def safe_name(text: String, fallback: String) -> String:
    """A file name made from text the app didn't choose (a cell, a table's name): only letters, digits, '.', '_' and
    '-', no leading dot, at most 100 bytes; `fallback` when nothing is left (goal 62 round 6: a pack named by a cell
    reading ../../../x wrote outside its folder)."""
    var out = String("")
    for b in text.as_bytes():
        var c = Int(b)
        if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 46 or c == 95 or c == 45:
            if out.byte_length() < 100 and not (out == "" and c == 46):
                out += chr(c)
    return out if out != "" else fallback


def export_path(folder: String, name: String, ext: String, fallback: String) -> String:
    """The one seam every export names its file through: `folder`/safe name + ext, and only ever directly inside
    `folder` (a name that would leave it becomes `fallback`)."""
    var base = String(folder.rstrip("/"))
    var path = base + "/" + safe_name(name, fallback) + ext
    var rest = String(path[byte = base.byte_length() + 1 :])
    if rest.find("/") >= 0 or rest.startswith("."):
        return base + "/" + safe_name(fallback, "export") + ext
    return path


def media_path_ok(path: String, own: List[String]) -> Bool:
    """A video or document path read from a table's cell, before the app opens it: anywhere on a desktop; on the public
    web copy only inside the starter (OMX_STARTER) or one of the visitor's own folders (round 6: a cell naming any .mp4
    on the server played it, or cut it into a pack)."""
    if environment("MOJOUI_PUBLIC") != "1":
        return True
    var p = String(path.strip())
    if p == "" or p.find("..") >= 0:
        return p == ""
    var starter = String(environment("OMX_STARTER").rstrip("/"))
    if starter != "" and p.startswith(starter + "/"):
        return True
    for f in own:
        if f != "" and p.startswith(String(f.rstrip("/")) + "/"):
            return True
    return False


# ------------------------------------------------ private files (review 3, MUST 7): what an app keeps of its user's documents

struct FileLock(Movable):
    """A file only its holder has (flock): held until release(), this value's end or the process's, however it ends. Says
    "someone is alive" to other processes, and to other holders in this one. What is held is the file that has the name:
    one removed and made again between opening and locking isn't (its device and inode against the name's)."""

    var fd: Int
    var path: String

    def __init__(out self):
        self.fd = -1
        self.path = ""

    def __deinit__(deinit self):
        if self.fd >= 0:
            _ = close(self.fd)

    def take(mut self, path: String) -> Bool:
        """Made if missing (0600) and taken, not waited for. False: another holds it, the file system has no locks, or the
        file was removed meanwhile (ask again)."""
        self.release()
        if environment("MOJOUI_NO_FLOCK", "") == "1":  # (tests: a file system without locks)
            return False
        var fd = open_append(path)
        if fd < 0:
            return False
        if flock(fd, 2 | 4) != 0:
            _ = close(fd)
            return False
        var mine = file_identity("", fd)  # (nothing is written: a full disk has locks too)
        var same = mine[0] >= 0 and file_identity(path) == mine
        if not same:
            _ = close(fd)
            return False
        self.fd = fd
        self.path = path
        return True

    def held(self) -> Bool:
        return self.fd >= 0

    def release(mut self):
        if self.fd >= 0:
            _ = close(self.fd)
        self.fd = -1
        self.path = ""


def sync_file(path: String) -> Bool:
    """The file's bytes are on the disk itself (its name maybe not: sync_dir)."""
    var fd = open_read(path)
    if fd < 0:
        return False
    var ok = fsync(fd) == 0
    return close(fd) == 0 and ok


def sync_dir(path: String) -> Bool:
    """The names in the folder `path` lies in are on the disk itself: what was made, renamed and removed there."""
    var slash = path.rfind("/")
    var dir = open_read(String(path[byte=0:slash]) if slash > 0 else ("/" if slash == 0 else String(".")))
    if dir < 0:
        return False
    var ok = fsync(dir) == 0
    _ = close(dir)
    return ok


def bytes_sum(addr: Int, n: Int) -> Int:
    """A fingerprint of n bytes, eight at a step (a kept view's pixels: 5 MB in about a millisecond)."""
    var h = UInt64(0xCBF29CE484222325) ^ UInt64(n)
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var i = 0
    while i + 8 <= n:
        h = (h ^ p.unsafe_offset(i).unsafe_bitcast[UInt64]()[]) * 0x9E3779B97F4A7C15
        h ^= h >> 29
        i += 8
    while i < n:
        h = (h ^ UInt64(p.unsafe_offset(i)[])) * 0x100000001B3
        i += 1
    return Int(h >> 2)


def private_dir(dir: String) -> Bool:
    """The folder, made if missing (its parents too), readable by this user alone (0700, also when it was there). False
    when it can't be made or written."""
    if dir == "":
        return False
    var made = List[String]()  # (a folder made now: its name reaches the disk too, and its parents')
    var up = dir
    while up != "" and up != "/" and not file_exists(up) and not isdir(up):
        made.append(up)
        var slash = up.rfind("/")
        up = String(up[byte=0:slash]) if slash > 0 else String("")
    make_dir(dir)
    for m in made:
        _ = sync_dir(m)
    _ = chmod(dir, 0o700)
    var probe = dir + "/.probe-" + String(getpid()) + "-" + String(serial())
    if not _write_new(probe, 0, 0):
        _ = unlink(probe)
        return False
    _ = unlink(probe)
    return True


def _write_new(path: String, addr: Int, n: Int) -> Bool:
    var fd = open_append(path)  # (made 0600)
    if fd < 0:
        return False
    var done = 0
    while done < n:
        var w = write_fd(fd, addr + done, n - done)
        if w <= 0:
            _ = close(fd)
            return False
        done += w
    return close(fd) == 0


def private_write_parts(path: String, parts: List[Tuple[Int, Int]], durable: Bool = False) -> Bool:
    """A file made of byte runs (address, count), readable by this user alone, in place in one step or not at all: written
    under a name of its own (no two processes share one), then renamed over the old; nothing is left behind when the disk
    is full. False when it couldn't be written (the old file stays). That holds however the process ends. durable: it holds
    when the power goes too (its bytes reach the disk before its name does, then the name; some 15 ms, not for a UI thread);
    without it a power cut can leave an empty file under the name."""
    var tmp = path + ".tmp-" + String(getpid()) + "-" + String(serial())
    _ = unlink(tmp)
    var ok = True
    for p in parts:
        if not _write_new(tmp, p[0], p[1]):
            ok = False
            break
    if len(parts) == 0:
        ok = _write_new(tmp, 0, 0)
    if ok:
        _ = chmod(tmp, 0o600)
        ok = (not durable or sync_file(tmp)) and rename(tmp, path) == 0
    if not ok:
        _ = unlink(tmp)
        return False
    return not durable or sync_dir(path)


def private_write(path: String, text: String, durable: Bool = False) -> Bool:
    """private_write_parts of a text."""
    var ok = private_write_parts(path, [(Int(text.unsafe_ptr()), text.byte_length())], durable)
    _ = text.byte_length()
    return ok


def clean_temps(dir: String, older_s: Int = 60) -> Int:
    """Temporary files an ended process left in `dir` (private_write's, and the old fixed ".tmp"): removed when older than
    older_s; how many."""
    var n = 0
    try:
        for name in listdir(dir):
            var f = String(name)
            if f.find(".tmp-") < 0 and not f.endswith(".tmp") and not f.startswith(".probe-"):
                continue
            var path = dir + "/" + f
            if age_s(path) >= older_s and unlink(path) == 0:
                n += 1
    except:
        pass
    return n


def _wall_ns() -> Int:
    var ts = List[Int](length=2, fill=0)  # struct timespec { seconds; nanoseconds }
    _ = clock_gettime(0, Int(ts.unsafe_ptr()))  # CLOCK_REALTIME (the real one: MOJOUI_NOW freezes what an app shows, not files)
    var ns = ts[0] * 1_000_000_000 + ts[1]
    _ = len(ts)
    return ns


def age_s(path: String) -> Int:
    """Seconds since the file last changed (-1: no such file)."""
    try:
        return (_wall_ns() - Int(stat(path).st_mtimespec.as_nanoseconds())) // 1_000_000_000
    except:
        return -1


def keep_under(dir: String, suffix: String, most_bytes: Int) -> Int:
    """A cache folder's files ending in `suffix` held to most_bytes together: the ones changed longest ago go first. How
    many went."""
    var paths = List[String]()
    var sizes = List[Int]()
    var ages = List[Int]()
    var total = 0
    try:
        for name in listdir(dir):
            var f = String(name)
            if not f.endswith(suffix):
                continue
            var st = stat(dir + "/" + f)
            paths.append(dir + "/" + f)
            sizes.append(Int(st.st_size))
            ages.append(Int(st.st_mtimespec.as_nanoseconds()))
            total += Int(st.st_size)
    except:
        pass
    var gone = 0
    while total > most_bytes and len(paths) > 0:
        var at = 0
        for i in range(1, len(ages)):
            if ages[i] < ages[at]:
                at = i
        if unlink(paths[at]) == 0:
            gone += 1
        total -= sizes[at]
        _ = paths.pop(at)
        _ = sizes.pop(at)
        _ = ages.pop(at)
    return gone
