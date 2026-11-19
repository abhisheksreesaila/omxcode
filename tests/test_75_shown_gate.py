"""75-check's time-to-screen gate for visible desktop runs (D-7576), proven on recorded FRAMEBENCH lines: the gate can't
be run visibly here (test windows stay off the owner's monitor), so this checks its parser and thresholds instead.
Run: pixi run python tests/test_75_shown_gate.py     Prints `shown gate: ok`.
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("check75", ROOT / "docs/goals/75-check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

# recorded: build/g75/desk-whiteboard-gpu.log (testscreen, 11-18), the offloaded whiteboard draw step
TESTSCREEN = ("FRAMEBENCH: draw n=300 missed=0 unchanged=0 renderer=gpu2d-GL(GskGLRenderer) p50=2.3 p95=3.5 max=4.1 "
              "paint_p95=1.0 raster_p95=3.5 offload=300 offload_refused=0 shown_n=300 shown_p50=15.2 shown_p95=15.7 "
              "shown_max=17.3 gpu_frames=300 ahead=0 ahead_dropped=0")


def line(what, n, shown_n, p95, mx, offload):
    return (f"FRAMEBENCH: {what} n={n} missed=0 renderer=gpu2d-GL(GskGLRenderer) p50=2.0 p95=4.2 max=5.8 "
            f"offload={offload} shown_n={shown_n} shown_p50=31.4 shown_p95={p95} shown_max={mx} gpu_frames={n}")


# the visible 1.6x desktop's numbers in D-7572's runs: GL textures draw shown p50 31.2–32.2, finish 29.7–29.8;
# offload ~1.7 ms later
BASE = "\n".join([line("draw", 300, 300, 32.6, 34.1, 0), line("finish", 100, 100, 30.4, 33.0, 0)])


def expect(cond, what):
    if not cond:
        sys.exit(f"shown gate: FAIL: {what}")


def main():
    base = check.benches(BASE)
    expect(base["draw"]["shown_max"] == "34.1" and base["finish"]["shown_p95"] == "30.4", f"parser: {base}")

    # level with GL textures (D-7572's offload: ~1.7 ms later): passes
    ok = check.benches("\n".join([line("draw", 300, 300, 33.9, 36.0, 300), line("finish", 100, 100, 32.1, 34.9, 100)]))
    expect(check.shown_bad("draw", ok["draw"], base["draw"]) == "", "level run flagged")
    expect(check.shown_steps(ok, base, "whiteboard", ["draw", "finish"]) == "", "level run flagged (steps)")
    # exactly at the bounds: passes (≤)
    edge = check.benches(line("draw", 300, 300, round(32.6 + check.SHOWN_P95_SLACK, 1), round(34.1 + check.SHOWN_MAX_SLACK, 1), 300))
    expect(check.shown_bad("draw", edge["draw"], base["draw"]) == "", f"edge flagged: {check.shown_bad('draw', edge['draw'], base['draw'])}")
    # a frame never presented
    lost = check.benches(line("draw", 300, 298, 33.0, 35.0, 300))
    expect("shown_n 298 of 300" in check.shown_bad("draw", lost["draw"], base["draw"]), "lost frame not flagged")
    # one frame a refresh and more behind GL textures' worst
    late = check.benches(line("draw", 300, 300, 33.0, 51.0, 300))
    expect("shown_max 51.0 > 50.8" in check.shown_bad("draw", late["draw"], base["draw"]), check.shown_bad("draw", late["draw"], base["draw"]))
    # the typical frame drifting behind
    drift = check.benches(line("finish", 100, 100, 34.7, 40.0, 100))
    expect("shown_p95 34.7 > 34.6" in check.shown_bad("finish", drift["finish"], base["finish"]), check.shown_bad("finish", drift["finish"], base["finish"]))
    # no baseline, or no shown columns: never a silent pass
    expect("no GL-texture baseline" in check.shown_bad("draw", ok["draw"], None), "missing baseline passed")
    bare = check.benches("FRAMEBENCH: draw n=300 missed=0 p50=2.0 p95=4.2 max=5.8")
    expect("no shown_n" in check.shown_bad("draw", bare["draw"], base["draw"]), "missing shown columns passed")
    # steps filter: only the named steps are gated
    expect(check.shown_steps({"draw": late["draw"]}, base, "whiteboard", ["finish"]).startswith("finish"), "filter ignored")

    # testscreen (MOJOUI_TESTSCREEN unset): printed, not gated, and says so
    ts = check.benches(TESTSCREEN)
    check.VISIBLE = False
    bad, note = check.shown_gate("whiteboard", ts, ["draw"])
    expect(bad == "" and "not gated" in note and "draw:15.7/17.3" in note, f"testscreen: {bad!r} {note!r}")
    # visible: the gate applies against the baseline (stored as if taken earlier in the same check)
    check.VISIBLE = True
    check._BASE["whiteboard"] = base
    bad, note = check.shown_gate("whiteboard", late, ["draw"])
    expect("shown_max" in bad and "vs GL textures" in note, f"visible late: {bad!r}")
    bad, note = check.shown_gate("whiteboard", ok, ["draw", "finish"])
    expect(bad == "", f"visible ok: {bad!r}")
    print("shown gate: ok")


if __name__ == "__main__":
    main()
