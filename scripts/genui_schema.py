"""docs/genui.schema.json from the genui catalog (mojoui.genui.schema(), printed by tests/test_genui.mojo).

  pixi run python scripts/genui_schema.py           # regenerate
  pixi run python scripts/genui_schema.py --check   # exit 1 when the file isn't what the catalog prints now
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "genui.schema.json"


def generated():
    exe = ROOT / "build" / "test_genui"
    exe.parent.mkdir(exist_ok=True)
    b = subprocess.run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", "tests/test_genui.mojo", "-o", str(exe)],
                       cwd=ROOT, capture_output=True, text=True)
    if b.returncode != 0:
        sys.exit("tests/test_genui.mojo doesn't build:\n" + (b.stdout + b.stderr)[-2000:])
    r = subprocess.run([str(exe)], cwd=ROOT, capture_output=True, text=True)
    line = next((l for l in r.stdout.splitlines() if l.startswith("SCHEMA: ")), None)
    if line is None:
        sys.exit("test_genui printed no SCHEMA line:\n" + (r.stdout + r.stderr)[-2000:])
    return json.loads(line[len("SCHEMA: "):])


def main():
    schema = generated()
    if "--check" in sys.argv:
        kept = json.loads(OUT.read_text())
        if kept != schema:
            sys.exit("docs/genui.schema.json is stale: run scripts/genui_schema.py")
        print(f"docs/genui.schema.json is current ({len(schema['$defs']['components'])} components)")
        return
    OUT.write_text(json.dumps(schema, indent=1) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(schema['$defs']['components'])} components)")


if __name__ == "__main__":
    main()
