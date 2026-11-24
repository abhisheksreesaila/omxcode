# M2/M3's looks drawn on the CPU (no GPU), compared by the check's own function: a stand-in, not the check
import importlib.util, json, sys
from pathlib import Path
sp = importlib.util.spec_from_file_location("c", "docs/goals/79-check.py"); c = importlib.util.module_from_spec(sp); sp.loader.exec_module(c)
for s in c.M2_SCREENS + c.M3_SCREENS:
    p, sc = c.compare_screen(s, c.REF / f"{s}.png", json.loads((c.REF / f"{s}.boxes.json").read_text()), Path(f"build/wrap/{s}.png"), json.loads(Path(f"build/wrap/{s}.boxes.json").read_text()), 1.6, Path(f"build/wrap/{s}-compare.png"))
    print(s, round(sc, 4), p)
