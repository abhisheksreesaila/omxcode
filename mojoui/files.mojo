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
    var out = List[String]()
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
    try:
        make_dir(config_dir(app))
        with open(config_dir(app) + "/recent.txt", "w") as f:
            for p in recent:
                f.write(p + "\n")
    except:
        pass


def read_setting(app: String, key: String, fallback: String = "") -> String:
    """One value from <config>/settings.txt ("skin=dark"), or the fallback."""
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
    """Sets one value in <config>/settings.txt, keeping the others."""
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
