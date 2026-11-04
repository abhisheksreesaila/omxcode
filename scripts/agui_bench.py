"""Goal 48 M5(c): one recorded AG-UI stream, replayed into omxcode on GTK, omxcode on the web and a CopilotKit app in
the same Chromium; writes docs/goals/48/bench.json.

  pixi run python scripts/agui_bench.py [--runs 3] [--only omxcode-gtk,omxcode-web,copilotkit]

The stream: the scripted agent's "bench" scenario (scripts/agui_scenarios.py), > 2,000 events: 300 words, then a
40-component dashboard as render_ui's arguments three bytes at a time, with state deltas between. "burst" sends them as
fast as the socket takes them; "paced" waits 4 ms before each word and argument piece (~250 events/s, a fast model).

What is measured, the same way for every runner, from the moment Send is pressed:
  first_ui_ms       the agent's screen's first component ("Orders, live") is on screen
  last_event_ms     its last component ("end of dashboard") is on screen: every event drawn
  frames_over_16ms  web: requestAnimationFrame gaps over 25 ms (at least one 60 Hz frame dropped) until the end;
                    GTK: main-loop turns that took over 16.7 ms (the UI thread missed a frame)
  peak_mb           web: the tab's peak JS heap (performance.memory; omxcode's web host does its work in its server
                    process, not counted); GTK: the whole process's peak resident memory (VmHWM: GTK, fonts, the Mojo
                    runtime and, when there is one, the GPU driver), started without the demo's million-row dataset
Each number is the median of --runs runs. CopilotKit runs its own Node runtime (bench/copilotkit/server.mjs) in front of
the same agent, as its docs deploy it; omxcode's web host is its own server too.
"""

import json
import os
import platform
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "docs" / "goals" / "48"
FIRST, LAST = "Orders, live", "end of dashboard"
PROMPT = "Show me orders"
VIEW = (1100, 900)

INSTRUMENT = """(() => {
  const B = window.__bench = {t0: 0, first: -1, last: -1, over: 0, frames: 0, worst: 0, heap: 0};
  let prev = 0;
  const has = (t) => document.body.textContent.includes(t);
  function tick(now) {
    if (B.t0 && B.last < 0) {
      if (prev) { const d = now - prev; B.frames++; if (d > 25) B.over++; if (d > B.worst) B.worst = d; }
      prev = now;
      if (performance.memory) B.heap = Math.max(B.heap, performance.memory.usedJSHeapSize);
      if (B.first < 0 && has(%(first)s)) B.first = now - B.t0;
      if (has(%(last)s)) B.last = now - B.t0;
    }
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
  return true;
})()""" % {"first": json.dumps(FIRST), "last": json.dumps(LAST)}

RESULT = "new Promise(ok => { const w = () => (window.__bench.last >= 0 ? ok(JSON.stringify(window.__bench)) : setTimeout(w, 50)); w(); })"


def stream_events(scenario):
    import agui_agent
    from ag_ui.core import RunAgentInput
    inp = RunAgentInput(thread_id="t", run_id="r1", state={}, messages=[], tools=[], context=[], forwarded_props={})
    return len(agui_agent.scripted(inp, scenario))


def gtk_run(scenario):
    import agui_agent
    exe = ROOT / "build" / "agentchat" / "linux" / "agentchat"
    with agui_agent.Server(scenario=scenario) as srv:
        steps = f"type:Agent URL={srv.url};type:Message={PROMPT};tap:Send;watch:{FIRST}|{LAST}=90000"
        r = subprocess.run([str(exe)], cwd=ROOT, capture_output=True, text=True, timeout=180,
                           env=dict(os.environ, MOJOUI_TEST=steps, AGUI_URL=srv.url, MOJOUI_WINDOW=f"{VIEW[0]}x{VIEW[1]}", AGENTCHAT_ORDERS="0"))
    m = re.search(r"WATCH: first=([\d.-]+) last=([\d.-]+) stalls=(\d+) worst=([\d.]+) turns=(\d+) peak_mb=(\d+)", r.stdout)
    if not m or float(m.group(2)) < 0:
        raise RuntimeError("GTK run: no WATCH line or never finished:\n" + (r.stdout + r.stderr)[-800:])
    return {"first_ui_ms": float(m.group(1)), "last_event_ms": float(m.group(2)), "frames_over_16ms": int(m.group(3)),
            "worst_ms": float(m.group(4)), "peak_mb": int(m.group(6))}


def web_run(scenario):
    import agui_agent
    import drive

    def measure(page):
        page.evaluate(INSTRUMENT)
        page.evaluate("window.__bench.t0 = performance.now()")
        page.locator("[data-kind=button]").filter(has_text="Send").first.click()
        return "BENCH: " + page.evaluate(RESULT) + "\n"

    with agui_agent.Server(scenario=scenario) as srv:
        r, out = drive.web_run(ROOT / "build" / "agentchat" / "web", f"type:Agent URL={srv.url};type:Message={PROMPT}", viewport=VIEW,
                               env={"AGUI_URL": srv.url, "AGENTCHAT_ORDERS": "0"}, during=measure)
    line = next((l for l in out.splitlines() if l.startswith("BENCH: ")), None)
    if r.returncode != 0 or line is None:
        raise RuntimeError("web run failed:\n" + out[-800:])
    b = json.loads(line[len("BENCH: "):])
    return {"first_ui_ms": round(b["first"], 1), "last_event_ms": round(b["last"], 1), "frames_over_16ms": b["over"],
            "worst_ms": round(b["worst"], 1), "peak_mb": round(b["heap"] / 1e6, 1)}


def copilotkit_run(scenario):
    import agui_agent
    from playwright.sync_api import sync_playwright
    app = ROOT / "bench" / "copilotkit"
    port = 5180 + (os.getpid() % 500)
    with agui_agent.Server(scenario=scenario) as srv:
        server = subprocess.Popen(["node", "server.mjs"], cwd=app, env=dict(os.environ, PORT=str(port), AGUI_URL=srv.url),
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            for _ in range(100):
                try:
                    import urllib.request
                    urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1)
                    break
                except Exception:
                    time.sleep(0.1)
            with sync_playwright() as p:
                import drive
                browser = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
                page = browser.new_page(viewport={"width": VIEW[0], "height": VIEW[1]})
                page.goto(f"http://127.0.0.1:{port}/", wait_until="networkidle")  # (Enter before CopilotKit has connected is ignored)
                box = page.locator("textarea").first
                box.wait_for(timeout=30000)
                box.fill(PROMPT)
                page.evaluate(INSTRUMENT)
                page.evaluate("window.__bench.t0 = performance.now()")
                box.press("Enter")
                b = json.loads(page.evaluate(RESULT))
                page.screenshot(path=str(OUT / f"bench-copilotkit-{scenario}.png"))
                browser.close()
        finally:
            server.terminate()
    return {"first_ui_ms": round(b["first"], 1), "last_event_ms": round(b["last"], 1), "frames_over_16ms": b["over"],
            "worst_ms": round(b["worst"], 1), "peak_mb": round(b["heap"] / 1e6, 1)}


RUNNERS = {"omxcode-gtk": gtk_run, "omxcode-web": web_run, "copilotkit": copilotkit_run}


def median(rows):
    out = {}
    for k in rows[0]:
        vals = [r[k] for r in rows]
        out[k] = statistics.median(vals)
    return out


def main():
    import headless
    headless.ensure()
    runs = int(sys.argv[sys.argv.index("--runs") + 1]) if "--runs" in sys.argv else 3
    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else list(RUNNERS)
    if "omxcode-gtk" in only or "omxcode-web" in only:
        for host in ("linux", "web"):
            b = subprocess.run(["scripts/build.sh", "agentchat", host], cwd=ROOT, capture_output=True, text=True)
            if b.returncode != 0:
                sys.exit(f"agentchat doesn't build for {host}: {(b.stdout + b.stderr)[-500:]}")
    if "copilotkit" in only and not (ROOT / "bench/copilotkit/dist").exists():
        b = subprocess.run("npm ci && npm run build", shell=True, cwd=ROOT / "bench/copilotkit", capture_output=True, text=True)
        if b.returncode != 0:
            sys.exit(f"bench/copilotkit doesn't build: {(b.stdout + b.stderr)[-500:]}")
    old = json.loads((OUT / "bench.json").read_text()) if (OUT / "bench.json").exists() else {}
    result = {"stream": "bench (scripts/agui_scenarios.py)", "events": stream_events("bench"), "paced_events": stream_events("bench_paced"),
              "runs": runs, "viewport": list(VIEW), "machine": f"{platform.node()} · {platform.processor() or platform.machine()} · {platform.system()} {platform.release()}",
              "when": time.strftime("%Y-%m-%d %H:%M"), "definitions": __doc__.split("What is measured", 1)[1].split("Each number")[0].strip(),
              "runners": old.get("runners", {})}
    for name in only:
        row = {}
        for scenario in ("bench", "bench_paced"):
            samples = []
            for _ in range(runs):
                samples.append(RUNNERS[name](scenario))
            m = median(samples)
            m["samples"] = samples
            row[scenario] = m
        flat = {k: v for k, v in row["bench"].items() if k != "samples"}
        flat["burst"] = row["bench"]
        flat["paced"] = row["bench_paced"]
        result["runners"][name] = flat
        print(name, "burst:", {k: v for k, v in row["bench"].items() if k != "samples"}, "paced:", {k: v for k, v in row["bench_paced"].items() if k != "samples"}, flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "bench.json").write_text(json.dumps(result, indent=1) + "\n")
    print("wrote docs/goals/48/bench.json")


if __name__ == "__main__":
    main()
