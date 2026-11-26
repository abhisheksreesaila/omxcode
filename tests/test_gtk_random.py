"""Goal 81, M1: a GTK window patched from screen to screen shows what one built fresh shows.

tests/gtkapps/random steps through random screens (tests/randomview.mojo). Each seed runs twice: as the host does it
(patches and partial rebuilds, on the same widgets all along) and with MOJOUI_ALWAYS_FRESH=1 (the whole screen built
again at every step). After each step every widget's readable properties, words, pictures, places and sizes asked for
(mojoui/hosts/gtktree.mojo) must be the same. Half the seeds in a wide window, where Boards are boards (a narrow one
shows them as lists). Headless (Xvfb).
Run: pixi run python tests/test_gtk_random.py [--no-build] [first seed] [seeds]
"""
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "build" / "g81"
EXE = OUT / "random" / "random"
STEPS = 14
LIBS = [x for lib in ("gtk-4", "adwaita-1", "gobject-2.0", "glib-2.0", "gio-2.0", "fontconfig", "pango-1.0") for x in ("-Xlinker", "-l" + lib)]


def build(app, exe):
    exe.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["pixi", "run", "mojo", "build", "-I", f"tests/gtkapps/{app}", "-I", ".", "-I", "vendor", "hosts/linux_main.mojo", "-o", str(exe)] + LIBS, cwd=ROOT, capture_output=True, text=True)
    return None if r.returncode == 0 else (r.stdout + r.stderr)[-600:]


def dump(seed, wide, fresh):
    tree = OUT / f"tree-{'fresh' if fresh else 'patched'}-{seed}.txt"
    tree.unlink(missing_ok=True)
    env = dict(os.environ, MOJOUI_TEST="treedump:0;" + ";".join(f"tap:Step;treedump:{k + 1}" for k in range(STEPS)), MOJOUI_TREE=str(tree), G81_SEED=str(seed), MOJOUI_TRACE="1")
    if wide:
        env["MOJOUI_WINDOW"] = "1100x800"
    if fresh:
        env["MOJOUI_ALWAYS_FRESH"] = "1"
    r = subprocess.run([str(EXE)], capture_output=True, text=True, timeout=300, env=env)
    return r, (tree.read_text().split("SCREEN ")[1:] if tree.exists() else [])


def one(job):
    seed, wide = job
    a, A = dump(seed, wide, False)
    b, B = dump(seed, wide, True)
    said = a.stdout + a.stderr
    bad = [f"seed {seed}: exit {x.returncode}" for x in (a, b) if x.returncode != 0]
    bad += [f"seed {seed}: {line[:200]}" for line in said.splitlines() if "CRITICAL" in line][:3]
    if len(A) != STEPS + 1 or len(B) != STEPS + 1:
        bad.append(f"seed {seed}: {len(A)} and {len(B)} screens")
    boards = 0
    for x, y in zip(A, B):
        boards += x.count("GtkFixed ")
        if x != y:
            p = next(((u, v) for u, v in zip(x.splitlines(), y.splitlines()) if u != v), ("", ""))
            d = [(u, v) for u, v in zip(p[0].split(), p[1].split()) if u != v][:3]
            bad.append(f"seed {seed} screen {x.splitlines()[0]}: patched {p[0].split()[:1]} fresh {p[1].split()[:1]} {d}")
    return len(A), said.count("TRACE: partial"), boards, bad


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("-")]
    first, count = (int(args[0]), int(args[1])) if len(args) == 2 else (1, 60)
    if "--no-build" not in sys.argv:
        e = build("random", EXE)
        if e:
            print("gtk_random: FAIL (build)", e)
            return 1
    import headless
    headless.ensure()
    jobs = [(s, s % 2 == 0) for s in range(first, first + count)]
    with ThreadPoolExecutor(3) as pool:
        rows = list(pool.map(one, jobs))
    bad = [x for r in rows for x in r[3]]
    print("FACT screens", sum(r[0] for r in rows))
    print("FACT partial", sum(r[1] for r in rows))
    print("FACT boards", sum(r[2] for r in rows))
    print("FACT wrong", len(bad))
    for x in bad[:20]:
        print("  " + x)
    print("gtk_random: ok" if not bad else "gtk_random: FAIL")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
