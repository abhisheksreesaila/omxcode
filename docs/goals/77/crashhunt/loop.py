"""D-7876 hunt: M7E's GTK sequences (scripts/g77_stage_sides_check.py) in a loop with full stdout/stderr kept per run.

    pixi run python build/g77/crashloop/loop.py N [tag]
"""
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("sides", ROOT / "scripts/g77_stage_sides_check.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
OUT = Path(__file__).resolve().parent
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20
TAG = sys.argv[2] if len(sys.argv) > 2 else "run"


BIN = Path(os.environ.get("LOOP_BIN", str(OUT / "bin/stage")))


def _gtk(steps, trace, window="1280x820", timeout=300):
    import headless
    headless.ensure()
    trace.unlink(missing_ok=True)
    return m.sh((["taskset", "-c", os.environ["LOOP_CPU"]] if os.environ.get("LOOP_CPU") else []) + [str(BIN)], timeout, dict({"MOJOUI_TEST": steps, "MOJOUI_WINDOW": window, "STAGE_TRACE": str(trace)}, **({"LD_PRELOAD": os.environ["LOOP_PRELOAD"], "MALLOC_CHECK_": "3", "MALLOC_PERTURB_": "165"} if os.environ.get("LOOP_PRELOAD") else {})))


m.gtk = _gtk


def keep(name, r):
    (OUT / f"{name}.out").write_text(r.stdout)
    (OUT / f"{name}.err").write_text(r.stderr)
    return r.returncode


# calibrate once (as check_gtk does)
t1 = OUT / f"{TAG}-plain.trace"
r = m.gtk(f"wait:600;waitfor:7:18=6000;waitfor:7:16=6000;shot:{OUT}/plain.png;wait:300", t1)
keep(f"{TAG}-plain", r)
ev = m.events(t1)
zone, canvas = m.zones(ev)
tl = m.tiles_line(ev, 4)
s = tl["tiles"]["todo"]
x0, y0 = s[0] + s[2] / 2, s[1] + s[3] / 2
x1, y1 = zone[0] + zone[2] / 2, zone[1] + min(zone[3] / 2, 60)
path = ";".join(f"{x0 + (x1 - x0) * k / 10:.0f},{y0 + (y1 - y0) * k / 10:.0f},0.5" for k in range(11))
days = ""
for label, charm, _ in m.DAYS:
    days += f"tap:{label};wait:1700;shot:{OUT}/c-{charm}.png;tap:Charms;wait:900;shot:{OUT}/c-{charm}-off.png;tap:Charms;wait:500;"
steps = (f"wait:1500;stroke:stage.tiles={path};wait:1500;shot:{OUT}/pinned.png;tap:Unpin To do;wait:1500;shot:{OUT}/unpinned.png;"
         + days + f"tap:{m.RAIN};wait:1700;shot:{OUT}/rain.png;tap:{m.PLAIN};wait:1200;scheme:dark;wait:1200;shot:{OUT}/dark.png;wait:200")
log = []
for i in range(N):
    for kind, st, win in (("run", steps, "1280x820"), ("phone", f"wait:1800;shot:{OUT}/phone.png;wait:200", "390x844")):
        name = f"{TAG}-{i:02d}-{kind}"
        t0 = time.time()
        try:
            rr = m.gtk(st, OUT / f"{name}.trace", window=win, timeout=600)
            rc = keep(name, rr)
        except Exception as e:  # timeout
            rc = f"exc {e!r}"
        log.append({"i": i, "kind": kind, "rc": rc, "s": round(time.time() - t0, 1)})
        print(json.dumps(log[-1]), flush=True)
        if rc == 0:
            (OUT / f"{name}.trace").unlink(missing_ok=True)
(OUT / f"{TAG}-summary.json").write_text(json.dumps(log, indent=1))
bad = [x for x in log if x["rc"] != 0]
print(f"{TAG}: {len(log) - len(bad)}/{len(log)} clean; bad: {bad}")
