"""Records the film's AG-UI scenes: examples/agentchat on the web asked "Plan a day in Lisbon" by the scripted agent
(scenario trip), its render_ui arguments slowed SLOW times so each piece can be seen; then "Book tickets" tapped.
Writes lisbon/NN.jpg (the frames that differ, with their times) and lisbon/run.json: the frames, every AG-UI event
the agent sent with its time on the same clock, and the tool result the app sent back, as the agent got it.
Then run build_film.py.

  scripts/build.sh agentchat web && pixi run python docs/launch/series/record_lisbon.py
"""

import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent / "lisbon"
sys.path.insert(0, str(ROOT / "scripts"))
import agui_agent  # noqa: E402
import agui_scenarios  # noqa: E402
import drive  # noqa: E402
from PIL import Image, ImageChops  # noqa: E402

SLOW = 14  # the scripted agent's 15 ms between argument pieces, as 210 ms (the film's label says so)

events = []  # (run, event, delay ms): what each run sent, in order
runs = []  # when each run's request came (s since the clock started)
clock = [None]
stream_call = agui_scenarios.stream_call
agui_scenarios.stream_call = lambda r, name, args, parent, pieces, delay: stream_call(r, name, args, parent, pieces, delay * SLOW)
add = agui_agent.Run.add
init = agui_agent.Run.__init__


def run_init(self, inp):
    init(self, inp)
    runs.append(time.time() - clock[0] if clock[0] else 0.0)


def run_add(self, event, delay=0):
    if event.type.value.startswith("TEXT") and delay:
        delay *= 4  # (the words, slowed too, to read)
    events.append((len(runs) - 1, event.model_dump(by_alias=True, exclude_none=True), delay))
    add(self, event, delay)


agui_agent.Run.__init__ = run_init
agui_agent.Run.add = run_add


def main():
    tmp = Path(tempfile.mkdtemp())
    shots = []  # (path, t)

    def during(page):
        i = 0

        def snap(until):
            nonlocal i
            while time.time() - clock[0] < until:
                p = tmp / f"f{i:03d}.jpg"
                page.screenshot(path=str(p), type="jpeg", quality=85)
                shots.append((p, time.time() - clock[0]))
                i += 1
                time.sleep(0.03)
        snap(7.0)
        shots.append(("tap", time.time() - clock[0]))
        page.get_by_text("Book tickets").first.click()
        snap(9.5)
        return ""

    with agui_agent.Server(scenario="trip", record=True) as srv:
        steps = f"type:Agent URL={srv.url};type:Message=Plan a day in Lisbon;tap:Send"
        # the clock starts when the question is sent: the first run's request
        first_init = agui_agent.Run.__init__

        def start_clock(self, inp):
            if clock[0] is None:
                clock[0] = time.time()
            first_init(self, inp)
        agui_agent.Run.__init__ = start_clock
        r, out = drive.web_run(ROOT / "build/agentchat/web", steps, viewport=(1000, 1150), env={"AGUI_URL": srv.url}, during=during)
        if r.returncode:
            sys.exit(out[-800:])
        inputs = list(srv.inputs)
    # frames that differ
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir()
    frames, prev, tap = [], None, None
    for p, t in shots:
        if p == "tap":
            tap = t
            continue
        im = Image.open(p).convert("RGB")
        small = im.convert("L").resize((250, 288))
        if prev is None or max(ImageChops.difference(small, prev).get_flattened_data()) > 24:
            name = f"{len(frames):02d}.jpg"
            im.resize((720, 828), Image.LANCZOS).save(OUT / name, quality=80, optimize=True)
            frames.append({"t": round(t, 3), "f": name})
            prev = small
    # events on the frames' clock: each run's events from its request's arrival, after their delays
    timed_events, at = [], {}
    for run, ev, delay in events:
        at[run] = at.get(run, runs[run]) + delay / 1000
        timed_events.append({"t": round(at[run], 3), "run": run, "type": ev["type"],
                             "d": ev.get("delta") or ev.get("toolCallName") or ev.get("stepName") or ""})
    result = next((m.get("content") for m in reversed(inputs[-1].get("messages", [])) if m.get("role") == "tool"), None)
    json.dump({"slow": SLOW, "tap": round(tap, 3), "frames": frames, "events": timed_events, "result": result},
              open(OUT / "run.json", "w"), ensure_ascii=False)
    shutil.rmtree(tmp)
    print(f"{len(frames)} frames, {len(timed_events)} events, {len(inputs)} runs; tool result: {result}")


if __name__ == "__main__":
    main()
