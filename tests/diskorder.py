"""The order in which things really reach the disk (continuation 23; Linux): a held file is written, its bytes synced, renamed to its
own name, its folder synced, and only then is the one it stands for removed; a save is in the notes file's log, synced, before it
is said to have landed. Read from the system calls themselves (tests/diskorder.c, preloaded).
   pixi run mojo build -I . -I vendor tests/outboxchild.mojo -o build/outboxchild
   pixi run mojo build -I . -I vendor -I examples/pnote tests/savechild.mojo -o build/savechild && python3 tests/diskorder.py"""
import os, shutil, subprocess, sys
from pathlib import Path
R = Path(__file__).resolve().parents[1]
W = R / "build/diskorder"
shutil.rmtree(W, ignore_errors=True)
(W / "unsaved").mkdir(parents=True, mode=0o700)
(W / "cfg").mkdir()
so = W / "diskorder.so"
subprocess.run(["gcc", "-shared", "-fPIC", "-O1", "-o", str(so), str(R / "tests/diskorder.c"), "-ldl"], check=True)
ENV = dict(os.environ, LD_PRELOAD=str(so), OMX_CONFIG=str(W / "cfg"), MODULAR_DEBUG="")


def ops(f):
    return [l.split("\t") for l in f.read_text().splitlines()] if f.exists() else []


log = W / "held.log"
p = subprocess.Popen([str(R / "build/outboxchild"), str(W / "unsaved"), "sp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=dict(ENV, DISKORDER=str(log)))
p.stdout.readline()


def send(*a):
    p.stdin.write(" ".join(map(str, a)) + "\n")
    p.stdin.flush()
    while not p.stdout.readline().startswith("END"):
        pass


import time
for op in [("load",), ("put", 1, 1, "v1"), ("put", 1, 2, "v2"), ("drop", 1)]:
    send(*op)
    time.sleep(0.5)
    with open(log, "a") as f:
        f.write("-- after\t" + " ".join(map(str, op)) + "\t\n")
p.stdin.write("quit\n"); p.stdin.close(); p.wait()
L = ops(log)
names = [l for l in L if l[0] != "write" or ".tmp-" in l[1]]
for l in L:
    print("  ", l[0], Path(l[1]).name, Path(l[2]).name)


def at(kind, test, start=0):
    for i in range(start, len(L)):
        if L[i][0] == kind and test(L[i]):
            return i
    raise SystemExit(f"diskorder: no {kind} after {start}")


put2 = at("-- after", lambda l: l[1] == "put 1 1 v1")
w = at("write", lambda l: ".new.json.tmp-" in l[1], put2)
r1 = at("rename", lambda l: l[2].endswith(".new.json"), w)
s = at("sync", lambda l: l[1].endswith(".new.json"), r1)
r2 = at("rename", lambda l: l[1].endswith(".new.json") and l[2].endswith(".json"), s)
d = at("sync", lambda l: Path(l[1]).name == "unsaved", r2)
u = at("unlink", lambda l: l[1].endswith(".json"), d)
first = min(i for i in range(put2, len(L)) if L[i][0] == "unlink" and L[i][1].endswith(".json"))
assert put2 < w < r1 < s < r2 < d < u == first, (put2, w, r1, s, r2, d, u, first)
print("ok   held: written, its bytes, its name, the folder, then the one it stands for")

log = W / "save.log"
q = subprocess.Popen([str(R / "build/savechild"), str(W / "notes.db"), "3"], stdout=subprocess.PIPE, text=True, cwd=R, env=dict(ENV, DISKORDER=str(log)))
marks = []
for l in q.stdout:
    if l.startswith(("TYPED", "LANDED")):
        with open(log, "a") as f:
            f.write("-- " + l.split()[0] + "\t" + l.split()[1] + "\t\n")
q.wait()
L = ops(log)
open_at = None
n = 0
for i, l in enumerate(L):
    if l[0] == "-- TYPED":
        open_at = i
    if l[0] == "-- LANDED":
        wal = [k for k in range(open_at, i) if L[k][0] == "write" and L[k][1].endswith("-wal")]
        syn = [k for k in range(open_at, i) if L[k][0] == "sync" and L[k][1].endswith("-wal")]
        assert wal and syn and syn[-1] > wal[-1], ("a save landed without its log synced", L[open_at:i + 1])
        n += 1
assert n == 3, n
print("ok   a save: in the log, the log synced, then said to have landed (3 of 3)")
print("diskorder: ok")
