"""Goal 77 M7a–M7f: the Stage (GOAL.md, D-7780). One function per milestone, each returning (state, why).

    pixi run python docs/goals/77-check.py M7A M7B ...

Milestones not built yet report BLOCKED. examples/stage shows the framework pieces without a model (GTK headless and the
web host in headless Chromium); M7f runs the real omx.
"""


def m7a():
    return ("BLOCKED", "the Stage shell: not built yet")


def m7b():
    """Live tiles (mojoui.livetiles): the unit test, examples/livetiles built for Linux and the web, then on GTK (headless)
    and the web host (headless Chromium) a promotion sampled frame by frame from the app's own record (the surface moves
    monotonically to its new rect within 3 %, settles <= 1.1 s, the words at the final rect and size on every frame), a
    synthetic drag that reorders and a grip drag that resizes; pictures docs/goals/77/m7b-*.png. scripts/g77_livetiles_check.py."""
    import importlib.util
    from pathlib import Path

    path = Path(__file__).resolve().parents[2] / "scripts/g77_livetiles_check.py"
    spec = importlib.util.spec_from_file_location("g77_livetiles_check", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.run()


def m7c():
    return ("BLOCKED", "agent-driven tiles: not built yet")


def m7d():
    return ("BLOCKED", "the TV: not built yet")


def m7e():
    return ("BLOCKED", "sides, pins and charms: not built yet")


def m7f():
    return ("BLOCKED", "omx on the Stage: not built yet")
