# SaveOutbox in real processes that are killed at random moments, also while they start (review 5's probe, kept): no version a
# process was told is kept is lost. MOJOUI_NO_FLOCK=1: a file system without locks.
#   pixi run mojo build -I . -I vendor tests/outboxchild.mojo -o build/outboxchild && python3 tests/outboxkill.py [seeds]
import subprocess, random, os, sys, shutil, time, json
from pathlib import Path
R = Path(__file__).resolve().parents[1]
D = R / ("build/outboxkill_" + ("n" if os.environ.get("MOJOUI_NO_FLOCK") else "f"))


class P:
    def __init__(s):
        s.p = subprocess.Popen([str(R / "build/outboxchild"), str(D), "sp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        s.own = {}  # id -> the version it has (held or spilled)
        s.p.stdout.readline()

    def send(s, *a):
        try:
            s.p.stdin.write(" ".join(map(str, a)) + "\n")
            s.p.stdin.flush()
        except BrokenPipeError:
            pass

    def take(s):
        out = []
        while True:
            l = s.p.stdout.readline()
            if not l:
                return out, False
            if l.startswith("END"):
                return out, l.split()
            out.append(l.split())


def texts_there():
    """What every held file says (one settled or removed while this reads: the folder again)."""
    for _ in range(200):
        try:
            return [f.read_text() for f in sorted(D.glob("*.json"))]
        except FileNotFoundError:
            pass
    raise SystemExit("the folder never stood still")


def run(seed):
    rnd = random.Random(seed)
    shutil.rmtree(D, ignore_errors=True)
    D.mkdir(mode=0o700)
    allt, superseded, landed, copied, procs, n = set(), set(), set(), set(), [], 0

    def got(p, out):
        for l in out:
            if l[0] == "HAVE":
                p.own[int(l[1])] = l[3]
            elif l[0] == "COPY":
                copied.add(l[2])

    for step in range(220):
        k = rnd.random()
        if k < 0.2 or not procs:
            if len(procs) < 5:
                new = [P() for _ in range(rnd.choice([1, 1, 2, 3]))]
                for p in new:
                    p.send("load")
                for p in new:
                    dead = rnd.random() < 0.35
                    if dead:
                        time.sleep(rnd.random() * 0.004)
                        p.p.kill()
                    out, ok = p.take()
                    if not dead and ok:
                        got(p, out)
                        procs.append(p)
                    else:
                        for l in out:  # (a copy it offered before it died may have been made)
                            if l[0] == "COPY":
                                copied.add(l[2])
                        p.p.kill()
                        p.p.wait()
        elif k < 0.7:
            p, i = rnd.choice(procs), rnd.randrange(4)
            n += 1
            t = f"t{n}"
            p.send("put" if rnd.random() < 0.7 else "spill", i, rnd.randrange(5), t)
            out, ok = p.take()
            if ok and ok[1] == "ok":
                allt.add(t)
                if i in p.own:
                    superseded.add(p.own[i])
                p.own[i] = t
        elif k < 0.8:
            p = rnd.choice(procs)
            if p.own:
                i = rnd.choice(list(p.own))
                p.send("drop", i)
                p.take()
                landed.add(p.own.pop(i))
        else:
            p = procs.pop(rnd.randrange(len(procs)))
            if rnd.random() < 0.35:  # (killed with a write just asked for: kept or not, the one before it isn't lost)
                i = rnd.randrange(4)
                n += 1
                t = f"k{n}"
                p.send("put", i, rnd.randrange(5), t)
                time.sleep(rnd.random() * 0.0015)
                p.p.kill()
                p.p.wait()  # (before the folder is looked at: a write it was in the middle of may still land, and stand for the one before)
                if any(t in x for x in texts_there()) and i in p.own:
                    superseded.add(p.own[i])
            elif rnd.random() < 0.6:
                p.p.kill()
            else:
                p.send("quit")
            p.p.wait()
    for p in procs:
        p.p.kill()
        p.p.wait()
    p = P()
    p.send("load")
    out, ok = p.take()
    got(p, out)
    files = " ".join(texts_there())
    lost = {t for t in allt - superseded - landed - copied if f'"{t}"' not in files or t not in p.own.values()}
    p.send("quit")
    p.p.wait()
    q = P()  # (names of owners that ended with nothing left go at the next start)
    q.send("load")
    q.take()
    q.send("quit")
    q.p.wait()
    owners = {f.name.split(".")[1] for f in D.glob("*.json")}
    tmp = [f.name for f in D.iterdir() if "tmp" in f.name]
    return len(allt), sorted(lost), len(tmp), sum(f.suffix == ".lock" and f.name.split(".")[1] not in owners for f in D.iterdir())


seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 100
bad = total = 0
for s in range(1, seeds + 1):
    texts, lost, tmp, locks = run(s)
    total += texts
    if lost or locks > 1:
        bad += 1
        print("seed", s, "texts", texts, "LOST", lost, "tmp", tmp, "locks", locks)
print(f"outboxkill{' without locks' if os.environ.get('MOJOUI_NO_FLOCK') else ''}: {seeds} seeds, {total} versions kept, {bad} bad" + (": ok" if not bad else ""))
sys.exit(1 if bad else 0)
