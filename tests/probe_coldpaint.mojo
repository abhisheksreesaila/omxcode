# Evidence, not a check (goal 79, continuation 18): the same board paint (40 objects of 1 200 lifted: what a drag's first
# frame paints), run back to back and after the thread slept: what idling costs the machine's clock, not the code.
#   pixi run mojo run -I . -I vendor tests/probe_coldpaint.mojo
from std.time import sleep
from std.os import getenv
from std.sys import CompilationTarget
from std.ffi import external_call, c_int
from mojoui.scene import Scene
from mojoui.macactivity import InputActivity
from mojoui.clock import now_ns
from mojoui.pagedesk import DeskView, BoardLook, BoardTools
from mojoui.objectlayer import ObjectLayer


def policy(mode: String):
    """macOS thread policies for this thread (process-local): "qos": user interactive; "rt": time constraint (a frame's
    work every 8.3 ms, as render and audio threads declare)."""
    comptime if CompilationTarget.is_macos():
        if getenv("MOJOUI_ACTIVITY") == "1" or getenv("MOJOUI_ACTIVITY") == "2":  # (held through the run: NSProcessInfo, user-initiated and latency-critical)
            var a = InputActivity()
            _ = a.touch()
            print("COLDPAINT: activity held, begun", a.begun)
        if mode == "qos" or mode == "rt":
            print("COLDPAINT: qos", external_call["pthread_set_qos_class_self_np", c_int](c_int(33), c_int(0)))
        if mode == "rt":
            var p: List[UInt32] = [200000, 60000, 200000, 1]  # (24 MHz ticks: period 8.3 ms, computation 2.5, constraint 8.3; preemptible)
            print("COLDPAINT: time constraint", external_call["thread_policy_set", c_int](external_call["mach_thread_self", UInt32](), c_int(2), Int(p.unsafe_ptr()), UInt32(4)))
            _ = len(p)


def main() raises:
    print("COLDPAINT: mode", getenv("CP_MODE", "plain"))
    policy(getenv("CP_MODE"))
    var layer = ObjectLayer()
    for i in range(1200):
        _ = layer.add_sticky(Float64(i % 40) * 120, Float64(i // 40) * 110, 90, "Sticky " + String(i))
    var v = DeskView(-300, -200, 0.5)
    var look = BoardLook()
    var none = List[Int]()
    for _ in range(3):
        var sc = Scene(1440, 900, 1.0)
        look.paint(sc, layer, v, 1440, 900, 1.0, none)
    var vis = BoardTools().visible_objects(layer, v, 1440, 900)
    var ids = List[Int]()
    for m in range(min(40, len(vis))):
        ids.append(layer.objs[vis[m]].id)
    for ms in [0, 2, 8, 16, 50, 200, 1000]:
        var times = List[Int]()
        for r in range(30 if ms < 1000 else 10):
            var d = Scene(1440, 900, 1.0)
            look.paint(d, layer, v, 1440, 900, 1.0, none)
            if ms > 0:
                sleep(Float64(ms) / 1000)
            var sc = Scene(1440, 900, 1.0)
            var t0 = Int(now_ns())
            look.paint(sc, layer, v, 1440, 900, 1.0, ids)
            times.append((Int(now_ns()) - t0) // 1000)
        sort(times)
        print("COLDPAINT: idle", ms, "ms: the lift's paint p50", times[len(times) // 2], "us, max", times[len(times) - 1], "us")
    print("coldpaint: ok")
