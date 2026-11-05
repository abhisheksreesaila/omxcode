"""AG-UI with an agent framework we didn't write: examples/agentchat (GTK and the web) against Pydantic AI's own AG-UI
adapter (scripts/agui_pydantic.py). Passes when, on both hosts: Pydantic AI's words and the screen from its render_ui
call are on screen, every request the app sent is a RunAgentInput by the AG-UI SDK's models and offers render_ui, the
tap on "Looks right" went back as a tool message answering Pydantic AI's call, and Pydantic AI's reply to it is shown.
Shots: docs/img/agents/interop-gtk.png, interop-web.png. (docs/ag-ui-compatibility.md)

  pixi run python scripts/agui_interop.py
"""

import importlib.util
import os
import socket
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
SHOTS = ROOT / "docs" / "img" / "agents"
SHOWN = ("Here is a screen, sent as a render_ui call.", "Hello from Pydantic AI",
         "Pydantic AI wrote every event of this answer; omxcode drew the screen.", "The app answered render_ui with {'action': 'ok'}.")


def check(received, out, ran):
    from ag_ui.core import RunAgentInput
    problems = [] if ran else [f"didn't run: {out[-500:]}"]
    labels = [l.removeprefix("LABEL: ") for l in out.splitlines() if l.startswith("LABEL: ")]
    problems += [f"not on screen: {want!r}" for want in SHOWN if want not in labels]
    runs = []
    for body in received:
        try:
            runs.append(RunAgentInput.model_validate(body))
        except Exception as e:
            problems.append(f"a request isn't a RunAgentInput: {e!r}"[:300])
    if len(runs) != 2:
        return problems + [f"{len(runs)} runs (want the question, then the answer to render_ui)"], runs
    if not all(any(t.name == "render_ui" for t in r.tools) for r in runs):
        problems.append("a run doesn't offer render_ui")
    tool = [m for m in runs[1].messages if m.role == "tool"]
    calls = [c for m in runs[1].messages if m.role == "assistant" for c in (m.tool_calls or [])]
    if not tool or not calls or tool[-1].tool_call_id != calls[-1].id or calls[-1].function.name != "render_ui":
        problems.append("the second run doesn't carry Pydantic AI's render_ui call and a tool message answering it")
    elif tool[-1].content != '{"action":"ok"}':
        problems.append(f"the tool message is {tool[-1].content!r}")
    if runs[0].thread_id != runs[1].thread_id:
        problems.append("the two runs aren't one thread")
    return problems, runs


def main():
    import headless
    headless.ensure()
    os.environ["PYDANTIC_AI_NO_BANNER"] = "1"
    import uvicorn
    import agui_pydantic
    spec = importlib.util.spec_from_file_location("g35", ROOT / "docs/goals/35-check.py")
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    server = uvicorn.Server(uvicorn.Config(agui_pydantic.app, host="127.0.0.1", port=port, log_level="warning"))
    threading.Thread(target=server.run, daemon=True).start()
    while not server.started:
        time.sleep(0.05)
    url = f"http://127.0.0.1:{port}/"
    steps = f"type:Agent URL={url};type:Message=Show me a screen;tap:Send;pause:2500;tap:Looks right;pause:2500"
    os.environ["AGUI_URL"] = url
    failed = False
    for host in ("gtk", "web"):
        agui_pydantic.received.clear()
        shot = str(SHOTS / f"interop-{host}.png")
        r, out = g.g5().gtk("agentchat", steps, shot=shot) if host == "gtk" else g.g5().web("agentchat", steps, shot=shot)
        problems, runs = check(list(agui_pydantic.received), out, r is not None)
        failed = failed or bool(problems)
        print(f"FAIL {host}: " + "; ".join(problems) if problems else
              f"PASS {host}: {len(runs)} runs, each a RunAgentInput by the SDK's models; Pydantic AI's screen drawn; the tap answered its render_ui call; {Path(shot).name}")
    server.should_exit = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
