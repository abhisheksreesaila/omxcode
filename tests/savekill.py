"""The save thread against the machine (goal 79, continuation 21, item 3): kill -9 at each stage of a save and at random
moments, another process holding the file for 30 s, a really full disk. After each: the file is whole (SQLite's own check), the
note, its search words, its revision and the change feed agree, nothing that landed is gone, nothing typed is lost while the
program lives, and the next start goes on.   pixi run python tests/savekill.py [random kills, 40]"""
import json, os, random, re, shutil, signal, sqlite3, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
W = ROOT / "build/savekill"
DB = W / "notes.db"
CHILD = ROOT / "build/savechild"
CFG = W / "cfg"
bad = []


def env(**more):
    return dict(os.environ, OMX_CONFIG=str(CFG), MODULAR_DEBUG="", **more)


def fresh():
    shutil.rmtree(W, ignore_errors=True)
    CFG.mkdir(parents=True)


def start(rounds, db=DB, **more):
    return subprocess.Popen([str(CHILD), str(db), str(rounds)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env(**more), cwd=ROOT)


def state(db=DB):
    """(content's last number, revision) of the note, and what is wrong with the file."""
    c = sqlite3.connect(db, timeout=10)
    why = []
    if c.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        why.append("integrity_check")
    content, rev, nid, rid = c.execute("SELECT content, revision, id, resource_id FROM notes ORDER BY id LIMIT 1").fetchone()
    md = json.loads(content)["markdown"]
    m = re.search(r" #(\d+)$", md)
    n = int(m.group(1)) if m else 0
    if m and [int(x) for x in re.findall(r" #(\d+)", md)] != list(range(1, n + 1)):
        why.append("a number is missing in the text")
    body = c.execute("SELECT body FROM note_search WHERE note_id = ?", (nid,)).fetchone()[0]
    if body != md:
        why.append("the search words aren't the note's")
    ch = c.execute("SELECT MAX(revision) FROM workspace_changes WHERE resource_kind = 'note' AND resource_id = ?", (rid,)).fetchone()[0]
    if ch != rev:
        why.append(f"change feed at revision {ch}, the note at {rev}")
    seq = c.execute("SELECT sequence FROM workspace_state WHERE id = 1").fetchone()[0]
    if seq != c.execute("SELECT MAX(sequence) FROM workspace_changes").fetchone()[0]:
        why.append("the sequence isn't the last change's")
    c.close()
    for f in CFG.rglob("unsaved-*.json"):
        try:
            json.loads(f.read_text())
        except ValueError:
            why.append(f"{f.name} is torn")
    return n, rev, why


def note(ok, what):
    print(("ok   " if ok else "BAD  ") + what, flush=True)
    if not ok:
        bad.append(what)


def run_lines(p, until, secs=60):
    out, by = [], time.time() + secs
    while time.time() < by:
        l = p.stdout.readline()
        if not l:
            break
        out.append(l.rstrip())
        if until(l):
            break
    return out


def last(out, word):
    ns = [int(l.split()[1]) for l in out if l.startswith(word + " ")]
    return ns[-1] if ns else 0


subprocess.run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", "-I", "examples/pnote", "tests/savechild.mojo", "-o", str(CHILD)], cwd=ROOT, check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
fresh()
p = start(3)
out = run_lines(p, lambda l: l.startswith("CLOSED"))
p.wait()
n, rev, why = state()
note(n == 3 and not why, f"three saves and closed: #{n} {why}")

# kill -9 at each stage: before the commit the old text stands whole, after it the new one does
for stage, want in [("begun", 0), ("written", 0), ("before commit", 0), ("committed", 1)]:
    n0 = state()[0]
    p = start(5, MOJOUI_SAVE_STAGE=stage)
    out = run_lines(p, lambda l: l.startswith("STAGE"))
    p.send_signal(signal.SIGKILL)
    p.wait()
    n, rev, why = state()
    note(n == n0 + want and not why, f"killed at '{stage}': #{n0} → #{n} {why}")
    p = start(1)  # (the next start: goes on from there)
    out = run_lines(p, lambda l: l.startswith("CLOSED"))
    p.wait()
    n2, _, why = state()
    note(n2 == n + 1 and not why, f"     and the next start goes on: #{n2} {why}")

# kill -9 at random moments
kills = int(sys.argv[1]) if len(sys.argv) > 1 else 40
rnd = random.Random(79)
lost = torn = 0
for k in range(kills):
    n0 = state()[0]
    p = start(100000)
    out = run_lines(p, lambda l: l.startswith("READY"))
    time.sleep(rnd.random() * 0.4)
    p.send_signal(signal.SIGKILL)
    out += p.stdout.read().splitlines()
    p.wait()
    n, rev, why = state()
    landed = last(out, "LANDED")
    if why:
        torn += 1
        print("    ", k, why)
    if n < max(landed, n0):
        lost += 1
        print("    ", k, f"landed #{landed}, the file has #{n}")
note(lost == 0 and torn == 0, f"{kills} random kills: {lost} lost what had landed, {torn} left the file wrong")

# another process holds the file for 30 s
n0 = state()[0]
lock = subprocess.Popen([sys.executable, "-c", f"import sqlite3,time\nc=sqlite3.connect({str(DB)!r},isolation_level=None)\nc.execute('BEGIN IMMEDIATE')\nprint('held',flush=True)\ntime.sleep(30)\nc.execute('ROLLBACK')"], stdout=subprocess.PIPE, text=True)
lock.stdout.readline()
p = start(1)
out = run_lines(p, lambda l: l.startswith("TYPED"), 20)
time.sleep(2)
held = list(CFG.rglob("unsaved-*.json"))
note(len(held) == 1 and f"#{n0 + 1}" in held[0].read_text(), "locked by another process: the edit is on disk meanwhile")
out += run_lines(p, lambda l: l.startswith("CLOSED"), 60)
p.wait()
lock.wait()
n, rev, why = state()
worst = next((int(l.split()[1]) for l in out if l.startswith("WORST")), 10**9)
note(n == n0 + 1 and not why and not list(CFG.rglob("unsaved-*.json")), f"after 30 s it landed: #{n} {why}")
note(worst < 60_000, f"the window's longest stop meanwhile: {worst / 1000:.1f} ms")

# the program killed while it waits: the edit is held, opens, lands
n0 = state()[0]
lock = subprocess.Popen([sys.executable, "-c", f"import sqlite3,time\nc=sqlite3.connect({str(DB)!r},isolation_level=None)\nc.execute('BEGIN IMMEDIATE')\nprint('held',flush=True)\ntime.sleep(60)"], stdout=subprocess.PIPE, text=True)
lock.stdout.readline()
p = start(1)
run_lines(p, lambda l: l.startswith("TYPED"), 20)
time.sleep(2)
p.send_signal(signal.SIGKILL)
p.wait()
lock.kill()
lock.wait()
p = start(1)
out = run_lines(p, lambda l: l.startswith("CLOSED"), 60)
p.wait()
n, rev, why = state()
note(n == n0 + 2 and not why, f"killed while it waits for the lock: the edit came back and landed: #{n0} → #{n} {why}")

# a really full disk: a small tmpfs in a namespace of our own
script = f"""set -e
mount -t tmpfs -o size=16m none {W}/tiny
cp {DB} {W}/tiny/notes.db
mkdir -p {W}/tiny/cfg
dd if=/dev/zero of={W}/tiny/fill bs=1k 2>/dev/null || true
truncate -s -96K {W}/tiny/fill
OMX_CONFIG={W}/tiny/cfg {CHILD} {W}/tiny/notes.db 1 > {W}/full.txt 2>&1 || true
rm {W}/tiny/fill
OMX_CONFIG={W}/tiny/cfg {CHILD} {W}/tiny/notes.db 1 >> {W}/full.txt 2>&1 || true
cp {W}/tiny/notes.db* {W}/after/
"""
(W / "tiny").mkdir(exist_ok=True)
(W / "after").mkdir(exist_ok=True)
n0 = state()[0]
c = sqlite3.connect(DB)
c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
c.close()
r = subprocess.run(["unshare", "-rm", "bash", "-c", script], capture_output=True, text=True)
if r.returncode:
    note(False, "a tmpfs of our own couldn't be made: " + r.stderr[-200:])
else:
    t = (W / "full.txt").read_text()
    n, rev, why = state(W / "after/notes.db")
    note("TOLD" in t and "MAYCLOSE False" in t, "a full disk: told, and the window doesn't close without saying so: " + " | ".join(l for l in t.splitlines() if l.startswith(("TOLD", "MAYCLOSE"))))
    note(not why and n == n0 + 1, f"     the file is whole; with room again a save lands: #{n} {why}")
print("savekill: " + ("ok" if not bad else f"{len(bad)} BAD"))
sys.exit(1 if bad else 0)
