# mojoui.files: small file helpers every document app needs: names from paths, the recent-files list
# (one path per line in <config>/recent.txt, newest first, at most 10) and settings (key=value lines in
# <config>/settings.txt).

from std.os.path import getsize, isfile
from mojoui.shared import environment, make_dir


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


def config_dir(app: String) -> String:
    """Where an app keeps its settings: $OMX_CONFIG if set (tests), else ~/.config/<app>."""
    return environment("OMX_CONFIG", environment("HOME", ".") + "/.config/" + app)


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
