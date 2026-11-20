"""D-7885: M7E's GTK sequence (as loop.py) once under valgrind memcheck, Mojo's heap routed to glibc (shim/kgen_glibc.so) so
memcheck sees every block: an invalid write into freed memory is reported with the writer's, the freer's and the maker's stacks.

    pixi run python build/g77/crashloop/vg.py [short]
"""
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402

spec = importlib.util.spec_from_file_location("sides", ROOT / "scripts/g77_stage_sides_check.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
short = "short" in sys.argv
BIN = Path(os.environ.get("LOOP_BIN", str(OUT / "bin/stage")))
VG = ["pixi", "exec", "-s", "valgrind", "valgrind", "--tool=memcheck", "--error-limit=no", "--num-callers=40", "--track-origins=no",
      "--read-var-info=no", "--show-leak-kinds=none", "--leak-check=no", "--undef-value-errors=no", "--trace-children=no",
      f"--log-file={OUT}/vg-%p.log"]
days = ""
for label, charm, _ in (m.DAYS[:2] if short else m.DAYS):
    days += f"tap:{label};wait:6000;tap:Charms;wait:3000;tap:Charms;wait:2000;"
# (the drag needs the tiles' rects from a trace; under valgrind the pin/unpin is driven by taps only)
steps = "wait:8000;" + days + f"tap:{m.RAIN};wait:6000;tap:{m.PLAIN};wait:5000;scheme:dark;wait:5000"
headless.ensure()
env = dict(os.environ, MOJOUI_TEST=steps, MOJOUI_WINDOW="1280x820", STAGE_TRACE=str(OUT / "vg.trace"),
           LD_PRELOAD=str(OUT / "shim/kgen_glibc.so"), GSK_RENDERER=os.environ.get("GSK_RENDERER", "cairo"))
r = subprocess.run(VG + [str(BIN)], env=env, capture_output=True, text=True, timeout=7000)
(OUT / "vg.out").write_text(r.stdout)
(OUT / "vg.err").write_text(r.stderr)
print("rc", r.returncode)
