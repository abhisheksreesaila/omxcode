"""AG-UI with agent frameworks we didn't write: examples/agentchat (GTK and the web) against Pydantic AI's own AG-UI
adapter (scripts/agui_pydantic.py) and LangGraph's (scripts/agui_langgraph.py). Passes when, for each framework on both
hosts: its words and the screen from its render_ui call are on screen, every request the app sent is a RunAgentInput by
the AG-UI SDK's models and offers render_ui, the tap on "Looks right" went back as a tool message answering its call,
and its reply to it is shown. Pydantic AI's model thinks first: its REASONING events show as "Thought", which opens to
the thinking, and the thinking goes back with the next run. Shots: docs/img/agents/interop-{pydantic,langgraph}-{gtk,web}.png.
(docs/ag-ui-compatibility.md)

  pixi run python scripts/agui_interop.py [pydantic|langgraph]
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
# (framework, its server module, what must be on screen)
FRAMEWORKS = [
    ("pydantic", "agui_pydantic", ("Here is a screen, sent as a render_ui call.", "Hello from Pydantic AI", "Thought",
                                   "Pydantic AI wrote every event of this answer; omxcode drew the screen.", "The app answered render_ui with {'action': 'ok'}.")),
    ("langgraph", "agui_langgraph", ("Here is a screen, sent as a render_ui call.", "Hello from LangGraph",
                                     "LangGraph wrote every event of this answer; omxcode drew the screen.", 'The app answered render_ui with {"action":"ok"}.')),
]


def check(received, out, ran, shown, thought=None):
    from ag_ui.core import RunAgentInput
    problems = [] if ran else [f"didn't run: {out[-500:]}"]
    labels = [l.split(": ", 1)[1] for l in out.splitlines() if l.startswith(("LABEL: ", "BUTTON: "))]
    problems += [f"not on screen: {want!r}" for want in shown if want not in labels]
    if thought and not any(thought.strip() in l for l in out.splitlines()):
        problems.append("the thinking isn't shown when Thought is opened")
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
    if thought and not any(m.role == "reasoning" and thought.strip() in (m.content or "") for m in runs[1].messages):
        problems.append("the thinking didn't go back with the next run")
    return problems, runs


def main():
    import headless
    headless.ensure()
    os.environ["PYDANTIC_AI_NO_BANNER"] = "1"
    import uvicorn
    spec = importlib.util.spec_from_file_location("g35", ROOT / "docs/goals/35-check.py")
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    failed = False
    only = sys.argv[1:]
    for name, module, shown in FRAMEWORKS:
        if only and name not in only:
            continue
        server_mod = importlib.import_module(module)
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        server = uvicorn.Server(uvicorn.Config(server_mod.app, host="127.0.0.1", port=port, log_level="warning"))
        threading.Thread(target=server.run, daemon=True).start()
        while not server.started:
            time.sleep(0.05)
        url = f"http://127.0.0.1:{port}/"
        thought = getattr(server_mod, "THOUGHT", None)
        steps = (f"type:Agent URL={url};type:Message=Show me a screen;tap:Send;pause:2500;" + ("tap:Thought;" if thought else "")
                 + "tap:Looks right;pause:2500")
        os.environ["AGUI_URL"] = url
        for host in ("gtk", "web"):
            if hasattr(server_mod, "reset"):
                server_mod.reset()
            server_mod.received.clear()
            shot = str(SHOTS / f"interop-{name}-{host}.png")
            r, out = g.g5().gtk("agentchat", steps, shot=shot) if host == "gtk" else g.g5().web("agentchat", steps, shot=shot)
            problems, runs = check(list(server_mod.received), out, r is not None, shown, thought)
            failed = failed or bool(problems)
            print(f"FAIL {name} {host}: " + "; ".join(problems) if problems else
                  f"PASS {name} {host}: {len(runs)} runs, each a RunAgentInput by the SDK's models; its screen drawn; the tap answered its render_ui call"
                  + ("; its thinking shown and sent back" if thought else "") + f"; {Path(shot).name}")
        server.should_exit = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
