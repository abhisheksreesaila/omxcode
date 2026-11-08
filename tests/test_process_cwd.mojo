# Goal 64: mojoui.process starts a program in another directory (Process.start's `cwd`), which the port's gates
# need (the skill's scripts only run from the skill root). Offline.
#   scripts/mojo_flare.sh build tests/test_process_cwd.mojo -o build/test_process_cwd
from std.os import makedirs
from mojoui.process import Process, file_tail
from mojoui import libc


def main() raises:
    var dir = String("build/g64/cwdtest")
    makedirs(dir, exist_ok=True)
    var log = dir + "/out.txt"
    _ = libc.unlink(log)
    var p = Process.start(["pwd"], log, List[String](), dir)
    for _ in range(100):
        if not p.running():
            break
        _ = libc.poll(0, 0, 20)
    var text = String(file_tail(log, 4000).strip())
    if not text.endswith("/" + dir):
        raise Error("pwd in " + dir + " printed " + text)
    print("process cwd: ok")
