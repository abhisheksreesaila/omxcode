"""A field change that arrives while the GTK host is rebuilding isn't lost (D-1321).

examples/fieldcheck rebuilds its screen on every change; the `type:` step's gtk_editable_set_text changes the text
twice ("" then the new text), so the second change always arrives during the first's pending rebuild.
Run: pixi run python tests/test_field_queue.py   (builds examples/fieldcheck; headless)
"""
import os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
TYPED = ["hello", "hi there", "x", "", "après 🍋", "zz"]


def main():
    if "--no-build" not in sys.argv:
        b = subprocess.run(["scripts/build.sh", "fieldcheck", "linux"], cwd=ROOT, capture_output=True, text=True)
        if b.returncode != 0:
            print("field queue: FAIL (build)", b.stdout[-400:], b.stderr[-400:])
            return 1
    import headless
    headless.ensure()
    steps = ["pause:300"] + [f"type:Query={t}" for t in TYPED] + ["pause:300"]
    env = dict(os.environ, MOJOUI_TEST=";".join(steps))
    r = subprocess.run([str(ROOT / "build/fieldcheck/linux/fieldcheck")], cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    apps = re.findall(r"FIELDCHECK: app=(.*) rows=\d+", r.stdout)
    # every typed value reached the app, in order, and the app ends where the field ends
    at, missing = 0, []
    for t in TYPED:
        while at < len(apps) and apps[at] != t:
            at += 1
        if at == len(apps):
            missing.append(t)
    if r.returncode != 0 or missing or not apps or apps[-1] != TYPED[-1]:
        print(f"field queue: FAIL (exit {r.returncode}; never reached the app: {missing}; app's last text {apps[-1:]!r}, typed {TYPED[-1]!r})")
        return 1
    print(f"field queue: ok ({len(TYPED)} values typed into a field that rebuilds the screen on every change; the app's text followed each)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
