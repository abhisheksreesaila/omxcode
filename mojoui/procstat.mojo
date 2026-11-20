# mojoui.procstat (goal 79's race): this process's age and resident memory, for hosts' timing and memory steps
# (firstscreen:, rss:). Linux reads /proc; other systems answer -1 until they get theirs.


def proc_age_ms() -> Float64:
    """How long this process has been running (ms): /proc/uptime less /proc/self/stat's start time (clock ticks)."""
    try:
        var up = String(open("/proc/uptime", "r").read())
        var stat = String(open("/proc/self/stat", "r").read())
        var close = stat.rfind(")")
        var fields = String(stat[byte=close + 2:]).split(" ")
        var start_ticks = Float64(Int(String(fields[19])))
        var uptime = Float64(String(up.split(" ")[0]))
        return (uptime - start_ticks / 100.0) * 1000.0
    except:
        return -1.0


def rss_mb() -> Float64:
    try:
        var st = String(open("/proc/self/status", "r").read())
        for line in st.split("\n"):
            if String(line).startswith("VmRSS:"):
                var parts = String(line).split()
                return Float64(Int(String(parts[1]))) / 1024.0
    except:
        pass
    return -1.0


