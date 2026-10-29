"""Shoots omxplorer's drag screen on the web N times (default 12) and fails unless every shot equals goal 32's golden
(within its 0.5 %): a drag whose canvas is rebuilt under it lost its last moves in 3 runs of 12 (2026-10-28, D-761).

  pixi run python scripts/web_drag_reliable.py [N]      (needs build/omxplorer/web)
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def main(n):
    import headless
    headless.ensure()
    spec = importlib.util.spec_from_file_location("goal32", ROOT / "docs/goals/32-check.py")
    g32 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g32)
    app, screen, settings, steps = next(r for r in g32.side.screens() if r[:2] == ("omxplorer", "drag"))
    off = []
    for i in range(n):
        problem = g32.side.shoot_web(app, screen, settings, steps)
        c = g32.pixel_change(g32.GOLDEN / f"{app}-{screen}-web.png", g32.side.OUT / f"{app}-{screen}-web.png")
        print(f"{i}: {c:.3%} {problem or ''}", flush=True)
        if problem or c > 0.005:
            off.append(i)
    print(f"web drag: {n - len(off)} of {n} equal the golden" + (f"; off: {off}" if off else ": ok"))
    return not off


if __name__ == "__main__":
    sys.exit(0 if main(int(sys.argv[1]) if len(sys.argv) > 1 else 12) else 1)
