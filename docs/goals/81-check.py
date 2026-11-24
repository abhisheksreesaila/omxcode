"""Milestone checker for GOAL.md (goal 81: an app layer that never loses, repeats or stalls).
Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/81-check.py [M1 M2 ...]          (default: every milestone; scripts/check runs this)

Written before the work (2026-11-24) from GOAL.md's words; never edited to make a milestone pass (add, don't weaken;
checker bugs are logged in docs/decisions.md with why the fix is not a weakening). The bars live here: tests print
`FACT <name> <value>` lines and this file judges them.

Load (the machine hard-stopped three times on 2026-11-23): everything here runs on CORES, and quiet() refuses a GPU run
while another process holds a GPU or a model job runs. It waits for nothing and never starts anyway: BLOCKED.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
OUT = ROOT / "build" / "g81"
BASE_REV = "2571778d"
CORES = os.environ.get("G81_CORES", "0-3")
MAC = os.environ.get("MAC_SSH", "bhoomijaprasad@100.76.9.101")
MAC_KEY = os.path.expanduser(os.environ.get("MAC_SSH_KEY", "~/.ssh/edx_mac"))

# ---- the bars, from GOAL.md ----
PAIRS_MIN = 5000        # M1: random pairs of screens
GTK_SCREENS_MIN = 300   # M1: random screens through GTK
UNCHANGED_499_MS = 0.25 # M2
GROWTH_MAX = 1.5        # M2: ms per row at 10,000 against 500
PAIR_LISTS_MIN = 2000   # M2: lists compared with the exact table
BURSTS_MIN = 200        # M4
MARK_US_MAX = 1.0       # M5: cost of marking an event
MAC_RATE_TOL = 0.03     # M7
IMAGE_MEAN_MAX = 2.0    # M8: levels against a box filter
HELD_MAX = 1.05         # M9


def run(cmd, timeout, env=None):
    e = dict(os.environ)
    e.update(env or {})
    try:
        return subprocess.run(["taskset", "-c", CORES, "nice", "-n", "5"] + cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=e)
    except subprocess.TimeoutExpired as x:
        return subprocess.CompletedProcess(cmd, 124, str(x.stdout or ""), str(x.stderr or "") + f"\ntimeout after {timeout}s")


def tail(s, n=300):
    return (s or "").strip()[-n:].replace("\n", " | ")


def facts(text):
    out = {}
    for m in re.finditer(r"^FACT (\S+) (\S+)", text, re.M):
        out[m[1]] = m[2]
    return out


def test(path, timeout=1800, env=None, cmd=None):
    """(facts, error): a Mojo or Python test that ends with its own `<name>: ok` line."""
    if not (ROOT / path).exists():
        return {}, f"{path} isn't written"
    c = cmd or (["pixi", "run", "mojo", "run", "-I", ".", "-I", "vendor", path] if path.endswith(".mojo") else ["pixi", "run", "python", path])
    r = run(c, timeout, env)
    said = r.stdout + r.stderr
    name = Path(path).stem.removeprefix("test_")
    if r.returncode != 0 or f"{name}: ok" not in said:
        return facts(said), f"{path} rc {r.returncode}: {tail(said)}"
    return facts(said), None


def quiet():
    """Why a GPU run mustn't start now, or None."""
    r = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        p = line.split(",")
        if len(p) == 2 and p[1].strip().isdigit() and int(p[1]) > 4096:
            return f"process {p[0].strip()} holds {p[1].strip()} MiB of a GPU"
    r = subprocess.run(["pgrep", "-fa", r"llama-(server|perplexity|cli|bench)|speed_study|omx-(day|night)"], capture_output=True, text=True)
    mine = [x for x in r.stdout.splitlines() if "pgrep" not in x and "81-check" not in x]
    return f"a model job runs: {mine[0][:80]}" if mine else None


def mac(cmd, timeout):
    return subprocess.run(["flock", "-w", "5400", os.path.expanduser("~/.cache/omx-mac.lock"), "ssh", "-i", MAC_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                           "-o", "StrictHostKeyChecking=yes", MAC, cmd], capture_output=True, text=True, timeout=timeout)


def mac_test(script, name, timeout=3600):
    """A test run on the M4 by scripts/mac81 <script>: (facts, error, blocked)."""
    helper = ROOT / "scripts" / "mac81"
    if not helper.exists():
        return {}, "scripts/mac81 isn't written", False
    try:
        r = run([str(helper), script], timeout)
    except Exception as x:
        return {}, str(x), False
    said = r.stdout + r.stderr
    if r.returncode == 75 or "UNREACHABLE" in said or "LOCKED" in said:
        return {}, tail(said), True
    if r.returncode != 0 or f"{name}: ok" not in said:
        return facts(said), f"{script} on the M4 rc {r.returncode}: {tail(said)}", False
    return facts(said), None, False


def num(f, k, d=float("nan")):
    try:
        return float(f[k])
    except (KeyError, ValueError):
        return d


def need(checks):
    bad = [why for ok, why in checks if not ok]
    return ("FAIL", "; ".join(bad)) if bad else ("PASS", "; ".join(why for _, why in checks))


def m1():
    f, e = test("tests/test_diff_random.mojo")
    if e:
        return "FAIL", e
    g, e = test("tests/test_gtk_random.py", 3600)
    if e:
        return "FAIL", e
    return need([(num(f, "pairs") >= PAIRS_MIN, f"{f.get('pairs')} pairs"), (num(f, "wrong") == 0, f"{f.get('wrong')} wrong"),
                 (num(f, "twice") == 0, f"{f.get('twice')} widgets used twice"), (num(f, "mutants_missed") == 0, f"{f.get('mutants_missed')} mutants missed of {f.get('mutants')}"),
                 (num(f, "mutants") >= 2, f"{f.get('mutants')} mutants"),
                 (num(g, "screens") >= GTK_SCREENS_MIN, f"GTK {g.get('screens')} screens"), (num(g, "wrong") == 0, f"GTK {g.get('wrong')} wrong"),
                 (num(g, "partial") >= GTK_SCREENS_MIN / 2, f"GTK {g.get('partial')} were partial updates")])


def m2():
    f, e = test("tests/test_diff_long.mojo", cmd=["pixi", "run", "mojo", "run", "-O3", "-I", ".", "-I", "vendor", "tests/test_diff_long.mojo"])
    if e:
        return "FAIL", e
    return need([(num(f, f"lost_{n}") == 0, f"{n} rows: {f.get(f'lost_{n}')} old widgets lost") for n in (600, 2000, 10000)]
                + [(num(f, "same_499_ms") <= UNCHANGED_499_MS, f"499 unchanged {f.get('same_499_ms')} ms"),
                   (num(f, "growth") <= GROWTH_MAX, f"per row at 10,000 / 500: {f.get('growth')}"),
                   (num(f, "lists") >= PAIR_LISTS_MIN and num(f, "fewer") == 0, f"{f.get('lists')} lists, {f.get('fewer')} with fewer pairs than the exact table")])


def m3():
    f, e = test("tests/test_gtk_lists.py", 1800)
    if e:
        return "FAIL", e
    return need([(num(f, "stale") == 0, f"{f.get('stale')} stale rows of {f.get('rows')} read"), (num(f, "rows") >= 60, f"{f.get('rows')} rows read"),
                 (num(f, "moved") == 0, f"{f.get('moved')} scroll positions moved"), (num(f, "runs") >= 3, f"{f.get('runs')} runs")])


def m4():
    f, e = test("tests/test_gtk_input.py", 3600)
    if e:
        return "FAIL", e
    return need([(num(f, "bursts") >= BURSTS_MIN, f"{f.get('bursts')} bursts"), (num(f, "lost") == 0, f"{f.get('lost')} lost of {f.get('sent')}"), (num(f, "sent") >= 500, f"{f.get('sent')} sent"),
                 (num(f, "twice") == 0, f"{f.get('twice')} twice"), (num(f, "disorder") == 0, f"{f.get('disorder')} out of order"), (num(f, "echoes") == 0, f"{f.get('echoes')} of the host's own writes sent")])


def m5():
    f, e = test("tests/test_hang.py", 1800)
    if e:
        return "FAIL", e
    return need([(num(f, "during") == 1, f"said during the hang: {f.get('during')}"), (num(f, "after") == 1, f"and after: {f.get('after')}"), (num(f, "named") == 1, f"names its message: {f.get('named')}"),
                 (num(f, "short_said") == 0, f"100 ms ones said: {f.get('short_said')}"), (num(f, "mark_us") <= MARK_US_MAX, f"{f.get('mark_us')} µs a mark"),
                 (num(f, "private") == 0, f"private words in the log: {f.get('private')}"), (num(f, "log_lines_max") <= 200, f"log ≤ {f.get('log_lines_max')} lines"), (num(f, "off_said") == 0, f"off: {f.get('off_said')} said")])


def m6():
    f, e, blocked = mac_test("glyphs", "gpu2d_metal_glyphs")
    if e:
        return ("BLOCKED" if blocked else "FAIL"), e
    return need([(num(f, "rows_over") == 0, f"uploads over the glyph's own rows: {f.get('rows_over')}"), (num(f, "frames") >= 100, f"{f.get('frames')} frames"), (num(f, "worst") <= 1, f"worst {f.get('worst')} levels"),
                 (num(f, "old_tests") == 2, f"{f.get('old_tests')} of 2 older Metal tests pass")])


def m7():
    f, e, blocked = mac_test("clock", "mac_clock")
    if e:
        return ("BLOCKED" if blocked else "FAIL"), e
    hz, want = num(f, "ticks_per_s"), num(f, "screen_hz")
    return need([(abs(hz - want) <= MAC_RATE_TOL * want, f"{hz} ticks/s, screen {want} Hz"), (num(f, "hidden_ticks") == 0, f"hidden: {f.get('hidden_ticks')}"), (num(f, "idle_ticks") == 0, f"idle: {f.get('idle_ticks')}"),
                 (num(f, "fallback_ok") == 1, f"fallback timer: {f.get('fallback_ok')}")])


def m8():
    why = quiet()
    if why:
        return "BLOCKED", why
    f, e = test("tests/test_gpu2d_image.mojo")
    if e:
        return "FAIL", e
    checks = [(num(f, "worst_mean") <= IMAGE_MEAN_MAX, f"worst mean {f.get('worst_mean')} levels"), (num(f, "cases") >= 8, f"{f.get('cases')} cases"), (num(f, "unscaled_diff") == 0, f"unscaled differs in {f.get('unscaled_diff')}"),
              (num(f, "copied") == 0, f"copied {f.get('copied')} pixels"), (num(f, "hashed") == 0, f"hashed {f.get('hashed')}"), (num(f, "uploads") == 0, f"uploads {f.get('uploads')}")]
    g, e, blocked = mac_test("image", "gpu2d_metal_image")
    if e:
        s, w = need(checks)
        return (("BLOCKED" if blocked and s == "PASS" else "FAIL"), w + "; Mac: " + e)
    return need(checks + [(num(g, "worst_mean") <= IMAGE_MEAN_MAX, f"Metal worst mean {g.get('worst_mean')}"), (num(g, "uploads") == 0, f"Metal uploads {g.get('uploads')}")])


def m9():
    why = quiet()
    if why:
        return "BLOCKED", why
    f, e = test("tests/test_g81_regress.py", 7200)
    if e:
        return "FAIL", e
    return need([(num(f, "held_worst") <= HELD_MAX, f"held-out worst {f.get('held_worst')}×"), (num(f, "held_cells") >= 10, f"{f.get('held_cells')} cells"),
                 (num(f, "tests_failed") == 0, f"{f.get('tests_failed')} of {f.get('tests')} tests fail"), (num(f, "builds_failed") == 0, f"{f.get('builds_failed')} of {f.get('builds')} builds fail"),
                 (num(f, "matrix") == 1, f"components matrix current: {f.get('matrix')}")])


ALL = {f"M{i}": globals()[f"m{i}"] for i in range(1, 10)}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    bad = False
    for k in (sys.argv[1:] or list(ALL)):
        s, why = ALL[k]()
        bad |= s == "FAIL"
        print(f"{k}: {s}  {why}", flush=True)
    sys.exit(1 if bad else 0)
