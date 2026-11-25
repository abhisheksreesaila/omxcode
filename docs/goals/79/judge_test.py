"""M6's judge by itself (no GPU, no app): the owner's ruling of 2026-11-24 as the main session reads it (D-8025).
pixi run python docs/goals/79/judge_test.py"""
import importlib.util
from pathlib import Path

sp = importlib.util.spec_from_file_location("c", Path(__file__).resolve().parent.parent / "79-check.py")
c = importlib.util.module_from_spec(sp)
sp.loader.exec_module(c)

# better, very close (3 %), one refresh on both sides, worse
assert c.verdict(5, 10) == "better"
assert c.verdict(103, 100) == "within 3 %" and c.verdict(103.1, 100) == ""
assert c.verdict(18.0, 16.7) == "tie at the display's refresh" and c.verdict(19, 16.7) == ""
assert c.verdict(19.9, 16.7, True) == "tie at the display's refresh" and c.verdict(20.1, 16.7, True) == ""
assert c.verdict(33.4, 33.0) == "within 3 %" and c.verdict(40, 33) == ""  # (two refreshes are no tie)
assert c.verdict(200, 280) == "better"  # (no absolute bar)
assert c.verdict(None, 10) == "" and c.verdict(10, None) == ""
assert c.verdicts([(5, 10), (120, 100)]) == (False, "worse than the web")
assert c.verdicts([(5, 10), (10.1, 10)]) == (True, "within 3 %")

# a whole table: every row better → passes; one missing, one CPU frame, more missed frames, one worse → doesn't
c.OPEN_TEST_OK[0] = True
W = lambda p=16.7, m=16.8: {"p95": p, "max": m, "missed": 1, "n": 100}


def world():
    web = {"cold_desktop_ms": 700, "cold_chromium_ms": 500, "rss_mb": 800, "switch": 50, "switch_max": 60, "omnibar": 30, "omnibar_max": 31, "type page": {"p95": 19.4, "max": 20.3}}
    nat, paced, unwarm, opens = {}, {}, {}, {}
    n = {"p95": 4.0, "max": 5.0, "cpu": 0, "gap_n": 100, "gap_p95": 16.7, "gap_max": 16.8, "gap_over20": 0, "lat_p95": 12, "lat_max": 13}
    o = dict(n, complete_max=200, complete_p95=190, complete_p50=100, press_lat_n=10, press_lat_p95=12, press_lat_max=13, during_p95=3, during_max=4, press_n=10, press_p95=3, press_max=3)
    for note in c.RACE_NOTES:
        web[note] = {s: W() for s in c.RACE_STEPS}
        web[note].update({"web open first": {"p95": 280, "max": 280}, "web open again": {"p95": 270, "max": 270}, "web open gaps": {"p95": 80, "max": 100}, "web open press": {"p95": 14, "max": 14}})
        nat[note] = dict({s: dict(n) for s in c.RACE_STEPS}, open=dict(o))
        paced[note] = dict({s: dict(n) for s in c.RACE_STEPS}, open=dict(o))
        unwarm[note] = {s: dict(n) for s in c.RACE_STEPS}
        opens[note] = {"A": dict(o, snap=False), "B": dict(o, snap=True)}
    start = {"first": 270, "rss": 200, "switch": 4, "switch_max": 5, "omnibar": 2, "omnibar_max": 2, "wswitch": 14, "wswitch_max": 15, "womnibar": 12, "womnibar_max": 13}
    start["second"] = dict(start)
    return web, nat, start, paced, unwarm, opens


TYPED = {"p95": 2.0, "max": 3.0, "cpu": 0, "lat_p95": 16.8, "lat_max": 16.9}


def judged(change=None, machine="linux", live=False, typed=TYPED):
    web, nat, start, paced, unwarm, opens = world()
    if change:
        change(web, nat, start, paced, unwarm, opens)
    return c.race_table(web, nat, start, {}, machine=machine, paced=paced, unwarm=unwarm, opens=opens, live=live, typed=typed)


t, ok = judged()
assert ok and "✗" not in t, [l for l in t.splitlines() if "✗" in l]
assert "≤ 8.3 and ≤ 16.7" in t  # (the marks are still printed)


def fails(change, needle):
    t, ok = judged(change)
    bad = [l for l in t.splitlines() if "✗" in l]
    assert not ok and bad and needle in bad[0], (needle, bad)


fails(lambda w, n, s, p, u, o: p["stress"]["undo"].update(lat_max=40), "undo")
fails(lambda w, n, s, p, u, o: u["stress"]["zoom from 30%"].update(gap_max=40), "not warmed")
fails(lambda w, n, s, p, u, o: p["600"]["pan 30%"].update(gap_over20=3), "more missed frames")
fails(lambda w, n, s, p, u, o: n["600"]["pen"].update(cpu=2), "CPU frames")
fails(lambda w, n, s, p, u, o: o["stress"]["A"].update(complete_max=400), "first open ever")
fails(lambda w, n, s, p, u, o: p["600"].pop("drag one"), "not measured")
fails(lambda w, n, s, p, u, o: w.update(rss_mb=None), "RSS")
fails(lambda w, n, s, p, u, o: s.update(wswitch_max=90), "note switch")
# (continuation 22) typing in a long paragraph: both sides measured, the web's worst key included, no CPU frame
fails(lambda w, n, s, p, u, o: w.update({"type page": None}), "20,000-character")
for typed in (None, dict(TYPED, lat_max=40), dict(TYPED, cpu=3)):
    t, ok = judged(typed=typed)
    assert not ok and any("20,000-character" in l and "✗" in l for l in t.splitlines()), typed
assert c.web_type("WEBTYPE p95: 19.4 max: 20.3 n: 80\n") == {"p95": 19.4, "max": 20.3} and c.web_type("WEBTYPE p95: 1.0 max: 2.0 n: 80 (no editor)") is None and c.web_type("") is None
# over the old marks and still better than the web: passes, and says so
t, ok = judged(lambda w, n, s, p, u, o: n["stress"]["zoom from 30%"].update(p95=9.0, max=21.0))
assert ok and "over: p95 > 8.3, max > 16.7" in t
# the Mac without frames shown: not judged, never ✓, the machine not passed
t, ok = judged(lambda w, n, s, p, u, o: (p.clear(), u.clear(), o.clear()), machine="mac")
assert not ok and "work only, not like-for-like" in t and "| ✓" not in "\n".join(l for l in t.splitlines() if "(frames)" in l)
# the Mac with its frames shown (unlocked, in front: live): judged as Linux's, and fails as Linux's
t, ok = judged(machine="mac", live=True)
assert ok and "work only" not in t and "| ✓" in t, [l for l in t.splitlines() if "✗" in l]
t, ok = judged(lambda w, n, s, p, u, o: p["stress"]["undo"].update(lat_max=40), machine="mac", live=True)
assert not ok and any("undo" in l and "✗" in l for l in t.splitlines())
for out, good in [("BENCHSTATE: undo active=1 key=1 locked=0 activity=0 not held", True), ("BENCHSTATE: a active=1 key=1 locked=1", False), ("BENCHSTATE: a active=0 key=1 locked=0", False),
                  ("BENCHSTATE: a active=1 key=1 locked=-1", False), ("", False), ("BENCHSTATE: a active=1 key=1 locked=0\nBENCHSTATE: b active=1 key=0 locked=0", False)]:
    assert c.mac_live(out) is good, out
# (review 5, M3) the two windows alike, or nothing is judged
S = lambda **k: {"web": k.get("web", [("f034 start", 1.6, 60.0, (1500, 913), True), ("f034 end", 1.6, 59.9, (1500, 913), True)]),
                 "native": k.get("native", [("paced 600 pan", 1.6, 60.0, (1440, 900), True)])}
assert c.unlike(S()) == []
for bad, needle in [(S(web=[]), "isn't known"), (S(native=[]), "isn't known"), (S(web=[("f034 start", 2.0, 60.0, (1500, 913), True)]), "drawn at"),
                    (S(web=[("f034 start", 1.6, 144.0, (1500, 913), True)]), "refreshes"), (S(web=[("f034 start", 1.6, 60.0, (1500, 913), False)]), "visible"),
                    (S(web=[("f034 start", 1.6, 60.0, (1400, 913), True)]), "no 1440x900"), (S(native=[("paced pan", 1.0, 144.0, (1440, 900), True)]), "drawn at"),
                    (S(native=[("paced pan", 1.6, 60.0, (1240, 900), True)]), "not 1440x900"), (S(native=[("paced pan", 1.6, 60.0, (1440, 900), True), ("typing: no BENCHSTATE", 0.0, 0.0, (0, 0), False)]), "BENCHSTATE")]:
    assert any(needle in x for x in c.unlike(bad)), (needle, c.unlike(bad))
    web, nat, start, paced, unwarm, opens = world()
    t, ok = c.race_table(web, nat, start, {}, paced=paced, unwarm=unwarm, opens=opens, typed=TYPED, states=bad)
    assert not ok and "NOT LIKE-FOR-LIKE" in t, needle
web, nat, start, paced, unwarm, opens = world()
t, ok = c.race_table(web, nat, start, {}, paced=paced, unwarm=unwarm, opens=opens, typed=TYPED, states=S())
assert ok and "The two windows" in t and "NOT LIKE" not in t
c.STATES["web"].clear(); c.STATES["native"].clear()
c.web_states("x", "WEBSTATE: when=start headed=1 dpr=1.6 raf=60.00 inner=1500x913 screen=2150x900 visible=visible focus=1 browser=1 renderer=y\n")
c.native_states("x", "BENCHSTATE: pan active=1 key=1 locked=0 scale=1.6 refresh=60 size=1440x900 activity=0 not held\n")
assert c.unlike(c.STATES) == []
c.web_states("headless", "nothing\n")
assert any("visible" in x for x in c.unlike(c.STATES))
c.STATES["web"].clear(); c.STATES["native"].clear()
# the fair rule: off, and what it would say
assert c.FAIR_RULE is False
R = lambda p=16.7, m=16.8, k=0: (p, m, k)
assert c.fair_row([R()] * 5, [R(16.7, 17.0)] * 4 + [R(16.7, 40.0, 1)]) == ((16.7, 16.8), (16.7, 17.0), (0, 1))
assert c.fair_row([R()] * 4, [R()] * 5) is None and c.fair_row([R()] * 4 + [None], [R()] * 5) is None
c.FAIR_RULE = True
fair = {(n, st): {"web": [R(16.7, 16.8, 1)] * 5, "warm": [R()] * 5, "notwarm": [R()] * 5} for n in c.RACE_NOTES for st in c.RACE_STEPS[1:]}
t, ok = c.race_table(web, nat, start, {}, paced=paced, unwarm=unwarm, opens=opens, typed=TYPED, states=S(), fair=fair)
assert ok and "median of 5 runs" in t
fair[("600", "undo")] = dict(fair[("600", "undo")], warm=[R(16.7, 16.8)] * 4 + [R(16.8, 25.6)])
t, ok = c.race_table(web, nat, start, {}, paced=paced, unwarm=unwarm, opens=opens, typed=TYPED, states=S(), fair=fair)
assert ok  # (one run's late frame)
fair[("600", "undo")] = dict(fair[("600", "undo")], warm=[R(16.8, 25.6)] * 3 + [R()] * 2)
t, ok = c.race_table(web, nat, start, {}, paced=paced, unwarm=unwarm, opens=opens, typed=TYPED, states=S(), fair=fair)
assert not ok and any("undo" in l and "✗" in l for l in t.splitlines())  # (most runs')
fair[("600", "undo")] = dict(fair[("600", "undo")], warm=[None] + [R()] * 4)
t, ok = c.race_table(web, nat, start, {}, paced=paced, unwarm=unwarm, opens=opens, typed=TYPED, states=S(), fair=fair)
assert not ok
c.FAIR_RULE = False
# (review 8, S2) something of the worktree's running beside a race is seen: a program under it, a server told of its files; not this run's own
import os, shutil, subprocess, sys, tempfile, time
assert c.ours_running() == [], c.ours_running()
with tempfile.TemporaryDirectory() as t:
    shutil.copy(shutil.which("sleep"), t + "/asleep")
    ps = [subprocess.Popen(a, start_new_session=True, env=dict(os.environ, **e)) for a, e in [([t + "/asleep", "30"], {}), ([sys.executable, "-c", "import time; time.sleep(30)"], {"PERSONAL_NOTE_DB": t + "/notes.db"}), ([sys.executable, "-c", "import time; time.sleep(30)", "elsewhere"], {})]]
    time.sleep(0.5)
    own = c.ours_running(t)
    assert len(own) == 2 and any("asleep" in x for x in own), own
    for p in ps:
        p.kill()
        p.wait()
print("judge: ok")
