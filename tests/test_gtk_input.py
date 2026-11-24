"""Goal 81, M4: input that comes while a rebuild waits is neither lost, nor sent twice, nor out of order; what was for a
view that's gone goes with it; and the host's own writes into controls are never sent as a person's.

tests/gtkapps/input changes its screen's shape on every event (a full rebuild every eleventh). Each `burst:` step fires
several real signals in one turn, no main loop between: all but the first come while a rebuild waits. What reached
update() (the app's log) must be what was sent. Allowed: a field's older words when newer ones of the same field follow
straight after, the "" that GTK's set_text says first, and wheel moves added up. Headless (Xvfb).
Run: pixi run python tests/test_gtk_input.py [--no-build] [seeds]
"""
import os
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts"))
from test_gtk_random import OUT, build

EXE = OUT / "input" / "input"
FIELD, AREA, TOGGLE, CHOICE, LEVEL, PART, DOT, SUBMIT, ROW, CANVAS, SET, FIND, BACK = 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 39
PRESS, KEY, WHEEL = 4, 7, 9
CARD = 22


class Model:
    """What the app does, as far as the test needs it."""
    def __init__(self):
        self.here = [True] * 4
        self.v = {CHOICE: 0, LEVEL: 10, PART: 0, DOT: 0}

    def does(self, m, number):
        if m in self.v:
            self.v[m] = number
        elif m == SET:
            for k in (CHOICE, PART, DOT):
                self.v[k] = (self.v[k] + 1) % 3
            self.v[LEVEL] = (self.v[LEVEL] + 7) % 100
        elif 30 <= m < 34:
            self.here[m - 30] = False
        elif m == BACK:
            self.here = [True] * 4


def make(rng, model, words):
    """A burst: (the step, what update() should hear: (message, text or None, number or None))."""
    items, want = [], []
    used = set()
    here = list(model.here)  # (what's on screen when it's fired)
    now = Model()
    now.here, now.v = list(model.here), dict(model.v)
    dropped = set()
    for _ in range(rng.randint(2, 7)):
        k = rng.randrange(18)
        item = exp = None
        if k == 0:
            item, exp = "a", (1, None, None)
        elif k == 1:
            item, exp = "b", (2, None, None)
        elif k == 2 and SET not in used:
            used.add(SET)
            item, exp = "set", (SET, None, None)
        elif k == 3 and "back" not in used and not dropped and not any(i.startswith("x") for i in items):
            used.add("back")
            item, exp = "back", (BACK, None, None)
        elif k == 4 and "back" not in used:
            d = rng.randrange(4)
            if d not in dropped:
                dropped.add(d)
                item, exp = f"drop{d}", (30 + d, None, None)
        elif k in (5, 6) and "back" not in used:
            t = rng.randrange(4)
            if here[t]:
                item, exp = f"x{t}", ((40 + t, None, None) if now.here[t] else None)
        elif k in (7, 8):
            w = f"words {next(words)}"
            item, exp = f"field={w}", (FIELD, w, None)
        elif k == 9:
            w = f"words {next(words)}"
            item, exp = f"area={w}", (AREA, w, None)
        elif k == 10 and TOGGLE not in used:
            used.add(TOGGLE)
            item, exp = "toggle", (TOGGLE, None, None)
        elif k == 11:
            m, tag = rng.choice([(CHOICE, "drop"), (PART, "seg"), (DOT, "radio")])
            if m not in used:
                used.add(m)
                n = (model.v[m] + 2) % 3
                item, exp = f"{tag}={n}", (m, None, n)
        elif k == 12 and LEVEL not in used:
            used.add(LEVEL)
            n = (model.v[LEVEL] + 40) % 100
            item, exp = f"slide={n}", (LEVEL, None, n)
        elif k == 13:
            n = rng.randrange(5)
            item, exp = f"list={n}", (ROW, None, n)
        elif k == 14:
            c = rng.choice("abcdefgh")
            item, exp = f"canvas=k{c}", (CANVAS, c, KEY)
        elif k == 15:
            n = rng.randint(1, 3)
            item, exp = f"canvas=w{n}", (CANVAS, n, WHEEL)
        elif k == 17:
            c = rng.randrange(3)
            item, exp = f"card{c}=drop", (CARD, f"card{c}", None)
        elif k == 16:
            item, exp = rng.choice([("^Ctrl+F", (FIND, None, None)), ("canvas=p", (CANVAS, None, PRESS)), ("field=!", (SUBMIT, None, None))])
        if item is None:
            continue
        items.append(item)
        if exp is not None:
            want.append(exp)
            now.does(exp[0], exp[2] if exp[2] is not None else 0)
    return items, want, now


def judge(got, want):
    """(lost, twice or not asked for, out of order) of one burst's log."""
    heard = [g for g in got if not (g[0] in (FIELD, AREA) and g[1] == "")]
    # wheel moves add up
    def add(rows):
        out = []
        for r in rows:
            if out and r[0] == CANVAS and r[2] == WHEEL and out[-1][0] == CANVAS and out[-1][2] == WHEEL:
                out[-1] = (CANVAS, out[-1][1] + r[1], WHEEL)
            else:
                out.append(r)
        return out
    h = add([(g[0], -g[4] // 40, WHEEL) if g[0] == CANVAS and g[2] == WHEEL else (g[0], g[1] if g[0] in (FIELD, AREA, CARD) or (g[0] == CANVAS and g[2] == KEY) else None,
             g[2] if g[0] in (CHOICE, LEVEL, PART, DOT, ROW, CANVAS) else None) for g in heard])
    w = add(want)
    slim = []
    for k, e in enumerate(w):
        later = w[k + 1] if k + 1 < len(w) else None
        if e[0] in (FIELD, AREA) and later and later[0] == e[0] and e not in h:
            continue
        slim.append(e)
    lost = [e for e in slim if h.count(e) < slim.count(e)]
    extra = [e for e in h if h.count(e) > slim.count(e)]
    return lost, extra, (not lost and not extra and h != slim), h, slim


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("-")]
    seeds = int(args[0]) if args else 12
    if "--no-build" not in sys.argv:
        e = build("input", EXE)
        if e:
            print("gtk_input: FAIL (build)", e)
            return 1
    import headless
    headless.ensure()
    bursts = sent = lost = twice = disorder = echoes = bad = 0
    shown = 0
    for seed in range(seeds):
        rng = random.Random(8100 + seed)
        words = iter(range(1, 100000))
        model, steps, wants = Model(), [], []
        log = OUT / f"input-{seed}.log"
        while len(wants) < 25:
            items, want, after = make(rng, model, words)
            if len(items) < 2:  # (nothing held: another)
                continue
            model = after
            steps += ["burst:" + "~".join(items), f"logmark:{log}"]  # (each burst runs to a settled screen before the mark)
            wants.append((items, want))
        log.unlink(missing_ok=True)
        env = dict(os.environ, MOJOUI_TEST=";".join(steps), G81_LOG=str(log), MOJOUI_WINDOW="1000x800")
        r = subprocess.run([str(EXE)], capture_output=True, text=True, timeout=120, env=env)
        if r.returncode != 0 or "TEST:" in r.stdout or "CRITICAL" in r.stderr:
            bad += 1
            print(f"  seed {seed}: exit {r.returncode}", [x for x in (r.stdout + r.stderr).splitlines() if "TEST:" in x or "CRITICAL" in x][:4])
        text = log.read_text() if log.exists() else ""
        parts = text.split("MARK\n")
        for (items, want), part in zip(wants, parts):
            got = []
            for line in part.splitlines():
                f = line.split("\t")
                got.append((int(f[0]), f[1], int(f[2]), int(f[3]), int(f[4])))
            a, b, c, h, w = judge(got, want)
            bursts += 1
            sent += len(items)
            lost += len(a)
            mine = [e for e in b if e[0] in {x[0] for x in want}]
            twice += len(mine)
            echoes += len(b) - len(mine)
            disorder += 1 if c else 0
            if (a or b or c) and shown < 8:
                shown += 1
                print(f"  seed {seed}: {'~'.join(items)}\n    heard {h}\n    sent  {w}")
        if len(parts) != len(wants) + 1:
            bad += 1
            print(f"  seed {seed}: {len(parts) - 1} bursts logged of {len(wants)}")
    print("FACT bursts", bursts)
    print("FACT sent", sent)
    print("FACT lost", lost)
    print("FACT twice", twice)
    print("FACT disorder", disorder)
    print("FACT echoes", echoes)
    ok = bad == 0 and lost == twice == disorder == echoes == 0
    print("gtk_input: ok" if ok else "gtk_input: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
