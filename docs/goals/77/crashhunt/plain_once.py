"""One short stage sequence (loop.py's 'plain' step) with LOOP_PRELOAD, output under TAG."""
import importlib.util, os, sys
from pathlib import Path
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("sides", ROOT / "scripts/g77_stage_sides_check.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import headless; headless.ensure()
tag = sys.argv[1]
env = {"MOJOUI_TEST": f"wait:600;waitfor:7:18=6000;waitfor:7:16=6000;shot:{OUT}/{tag}.png;wait:300", "MOJOUI_WINDOW": "1280x820", "STAGE_TRACE": str(OUT / f"{tag}.trace")}
if os.environ.get("LOOP_PRELOAD"): env["LD_PRELOAD"] = os.environ["LOOP_PRELOAD"]
r = m.sh([os.environ.get("LOOP_BIN", str(ROOT / "build/stage/linux/stage"))], 1200, env)
(OUT / f"{tag}.out").write_text(r.stdout); (OUT / f"{tag}.err").write_text(r.stderr)
print("exit", r.returncode); print(r.stderr[-3000:])
