# Goal 64, security audit round 1: the two places where the Mojo had silently diverged from the Python version it
# copies, each pinned here so it cannot drift back (docs/lessons.md: encode the lesson in structure).
#   1. `name` on POST /admin/ports becomes a folder that is bound read-write into the porting agent's sandbox, so
#      it must pass the Python's NAME_RE before any path is made from it; "name": ".." would otherwise bind
#      MXC_HOME itself — porter.json and mst.db — writable inside the sandbox.
#   2. expose.start_time must read /proc/<pid>/stat's starttime (field 22), not a field that changes while the
#      process runs: it is what tells our Caddy from a reused pid, so a wrong field means a leftover LAN proxy is
#      neither found nor stopped.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_port_boundary.mojo -o build/test_port_boundary
from mojoui import libc
from ports import port_name_ok
from expose import start_time


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    for good in ["weird", "gpt2", "smollm3-3b", "a.b_c-1", "Qwen2"]:
        check(port_name_ok(String(good)), "a plain name must go through: " + String(good))
    for bad in ["..", ".", "../porter.json", "../skills/modular", "a/b", "/etc", "", ".hidden", "-lead",
                "with space", "tab\there", "new\nline", "weird;rm", "x" * 65]:
        check(not port_name_ok(String(bad)), "must be refused as a port name: " + String(bad))

    # starttime does not change while a process runs (a vsize-like field would)
    var me = libc.getpid()
    var first = start_time(me)
    check(first != "", "this process's start time must be readable")
    for _ in range(200):
        _ = String("churn") * 50  # (move the heap, so a memory-sized field would change)
    check(start_time(me) == first, "the start time must be stable: " + first + " then " + start_time(me))
    check(start_time(999_999_998) == "", "a pid that isn't there has no start time")
    print("port boundary: ok")
