"""mojoui.watch.file_stamp agrees with the operating system (probe fixes, D-1705): (modified time in ns, size) for a
file with a nanosecond time set, a sparse file over 4 GiB, an empty file, and (0, -1) for a missing one. On Linux it
reads statx, whose struct has one layout on every architecture (the kernel's include/uapi/linux/stat.h), so no offset
depends on x86-64; the module must also compile for aarch64 Linux (checked here with --emit object).
Run: pixi run python tests/test_file_stamp.py     Prints `file stamp: ok`.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE = '''from mojoui.watch import file_stamp
from std.sys import argv
def main():
    for i in range(1, len(argv())):
        var s = file_stamp(String(argv()[i]))
        print("STAMP", s[0], s[1])
'''


def main():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        a, big, empty = d / "a.md", d / "big.bin", d / "empty"
        a.write_text("hello")
        os.utime(a, ns=(1_700_000_000_123_456_789, 1_700_000_000_987_654_321))
        with open(big, "wb") as f:
            f.truncate((5 << 30) + 7)
        empty.touch()
        files = [a, big, empty, d / "missing"]
        probe = d / "probe.mojo"
        probe.write_text(PROBE)
        r = subprocess.run(["pixi", "run", "mojo", "run", "-I", str(ROOT), str(probe), *map(str, files)], cwd=ROOT,
                           capture_output=True, text=True, timeout=600)
        got = [tuple(int(x) for x in l.split()[1:]) for l in r.stdout.splitlines() if l.startswith("STAMP")]
        want = [(f.stat().st_mtime_ns, f.stat().st_size) if f.exists() else (0, -1) for f in files]
        if r.returncode != 0 or got != want:
            sys.exit(f"file stamp: FAIL: got {got}, the system says {want}\n{r.stderr[-600:]}")
        print(f"file stamp: agrees with os.stat on {len(files)} cases (ns time, 5 GiB sparse, empty, missing)")
        obj = d / "probe-aarch64.o"
        r = subprocess.run(["pixi", "run", "mojo", "build", "-I", str(ROOT), str(probe), "--target-triple", "aarch64-unknown-linux-gnu",
                            "--emit", "object", "-o", str(obj)], cwd=ROOT, capture_output=True, text=True, timeout=900)
        if r.returncode != 0 or not obj.exists():
            sys.exit(f"file stamp: FAIL: doesn't compile for aarch64 Linux: {r.stderr[-600:]}")
        src = (ROOT / "mojoui/watch.mojo").read_text()
        body = src[src.index("def file_stamp"):src.index("def walk_files")]
        if '"stat"' in body.split("comptime if CompilationTarget.is_macos()")[0] or '"statx"' not in body:
            sys.exit("file stamp: FAIL: Linux reads struct stat at fixed offsets (its layout differs by architecture); use statx")
        print("file stamp: compiles for aarch64 Linux; Linux reads statx (one layout everywhere)")
    print("file stamp: ok")


if __name__ == "__main__":
    main()
