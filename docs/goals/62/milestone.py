"""Runs one milestone function of an archived goal checker, on the headless display (docs/lessons.md: archived checkers
don't start it): prints RESULT<TAB>[ok, why].

    pixi run python docs/goals/62/milestone.py docs/goals/47-check.py m2"""

import importlib.util
import json
import os
import re
import sys
from pathlib import Path

check, fn = Path(sys.argv[1]).resolve(), sys.argv[2]
root = check.parents[2]
os.chdir(root)
sys.path.insert(0, str(root / "scripts"))
import headless  # noqa: E402

headless.ensure()
# Goals 03–05's checkers were written one folder below the repo (ROOT = parent.parent): archived in docs/goals/ they
# looked for docs/build/… and built nothing (round 3's review). They're loaded as if they still lived in scripts/.
from importlib.machinery import SourceFileLoader  # noqa: E402

below = re.search(r"^ROOT = Path\(__file__\)\.resolve\(\)\.parent\.parent\s*$", check.read_text(), re.M)
where = root / "scripts" / check.name if below else check
spec = importlib.util.spec_from_file_location("archived_check", where, loader=SourceFileLoader("archived_check", str(check)))
mod = importlib.util.module_from_spec(spec)
sys.argv = [str(check)]
try:
    spec.loader.exec_module(mod)
    ok, why = getattr(mod, fn)()
except BaseException as e:  # (a crash, or a SystemExit from a helper, is a failure with its reason)
    import traceback
    traceback.print_exc()
    ok, why = False, f"crashed: {e!r}"
print("RESULT\t" + json.dumps([bool(ok) if ok != "BLOCKED" else False, str(why)[:2000]]), flush=True)
