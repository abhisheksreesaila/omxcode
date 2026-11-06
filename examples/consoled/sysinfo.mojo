# What consoled reads about the machine: the host name, a process's memory, the GPUs (nvidia-smi), files' sizes.

from std.os import getenv, listdir
from std.os.path import exists, getsize, isdir, join
from mojoui.process import file_tail


def hostname() -> String:
    """The machine's name (Linux: /proc/sys/kernel/hostname; else $HOSTNAME, else "localhost")."""
    try:
        if exists("/proc/sys/kernel/hostname"):
            with open("/proc/sys/kernel/hostname", "r") as f:
                return String(f.read().strip())
    except:
        pass
    var h = getenv("HOSTNAME")
    return h if h != "" else "localhost"


def rss_mb(pid: Int) -> Float64:
    """A process's resident memory in MB (Linux /proc/<pid>/status VmRSS; -1 when unknown)."""
    try:
        with open("/proc/" + String(pid) + "/status", "r") as f:
            for line in f.read().split("\n"):
                if line.startswith("VmRSS:"):
                    var kb = atol(String(line[byte = 6 :]).strip().split(" ")[0])
                    return Float64(Int(Float64(kb) / 1024.0 * 10 + 0.5)) / 10
    except:
        pass
    return -1


def tree_bytes(path: String) -> Int:
    """Every file's size under a folder (links followed: a Hugging Face snapshot's files are links into its blobs)."""
    var total = 0
    try:
        if not isdir(path):
            return getsize(path) if exists(path) else 0
        for name in listdir(path):
            var p = join(path, name)
            if isdir(p):
                total += tree_bytes(p)
            elif exists(p):
                total += getsize(p)
    except:
        pass
    return total
