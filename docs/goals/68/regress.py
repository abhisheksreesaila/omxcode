"""Goal 68 M6: an older goal's checker run from here (docs/lessons.md: archived checkers don't start the headless
display, so this does first), with the paths it hard-codes pointed at this worktree's copies where they moved.

    pixi run python docs/goals/68/regress.py 47 M0 M1 …      (prints the checker's own "Mn: PASS|FAIL|BLOCKED why" lines)

Overrides (each said on its first line of output): goal 59's DEMO (build/demo) → build/g47/full (the same DROID clips,
F00118.mp4 among them); goal 62's G47 (another session's worktree, gone) → build/g47/full."""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "docs/goals/62"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    goal, ms = sys.argv[1], sys.argv[2:]
    import headless

    headless.ensure()
    mod = load(f"g{goal}check", ROOT / f"docs/goals/{goal}-check.py")
    if goal == "59":
        mod.DEMO = ROOT / "build/g47/full"
        print("OVERRIDE: goal 59's DEMO = build/g47/full", flush=True)
    if goal == "62":
        import harness

        harness.G47 = ROOT / "build/g47/full"
        mod.G47 = harness.G47
        print("OVERRIDE: goal 62's G47 = build/g47/full", flush=True)
    for m in ms:
        try:
            ok, why = mod.MILESTONES[m]()
        except Exception as e:  # noqa: BLE001
            import traceback

            traceback.print_exc()
            ok, why = False, f"{type(e).__name__}: {e}"
        word = "PASS" if ok else ("BLOCKED" if ok is None else "FAIL")
        print(f"{m}: {word}  {why}", flush=True)


if __name__ == "__main__":
    main()
