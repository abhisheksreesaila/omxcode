"""The AG-UI streams the Mac run of examples/agentchat replays (ci/mac/agui_replay.py): the scripted agent's Lisbon trip
(scenario trip), its first run and its answer to "Book tickets", recorded with the official SDK's encoder. Two first
runs: one for an app that holds the Tagus picture (the run's context lists it: the trip shows a Picture), one for an app
that doesn't (no ffmpeg on the runner: no picture decoded, so no Picture sent). Writes ci/mac/agentchat-*.sse and copies
the picture to ci/mac/tagus.jpg.

  pixi run python scripts/mac_agentchat_streams.py
"""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from ag_ui.core import AssistantMessage, Context, FunctionCall, RunAgentInput, ToolCall, ToolMessage, UserMessage  # noqa: E402
from agui_agent import ENC, scripted  # noqa: E402

OUT = ROOT / "ci" / "mac"
PICTURES = Context(description="Pictures the app holds. Show one with render_ui: a Picture with \"name\".",
                   value=json.dumps([{"name": "tagus", "shows": "an illustration of the Tagus at sunset from a viewpoint", "width": 1200, "height": 640}]))
ASK = [UserMessage(id="u1", role="user", content="Plan a day in Lisbon")]


def run(run_id, messages, context):
    return RunAgentInput(thread_id="thread-1", run_id=run_id, state={}, messages=messages, tools=[], context=context, forwarded_props={})


def write(name, events):
    (OUT / name).write_text("".join(ENC.encode(e) for e, _ in events))
    return events


for variant, context in (("picture", [PICTURES]), ("plain", [])):
    first = write(f"agentchat-{variant}-1.sse", scripted(run("thread-1-run1", ASK, context), "trip"))
    call = next(e for e, _ in first if e.type.value == "TOOL_CALL_START")
    args = "".join(e.delta for e, _ in first if e.type.value == "TOOL_CALL_ARGS")
    answered = ASK + [AssistantMessage(id=call.parent_message_id or "a1", role="assistant", tool_calls=[
        ToolCall(id=call.tool_call_id, type="function", function=FunctionCall(name="render_ui", arguments=args))]),
        ToolMessage(id="t1", role="tool", tool_call_id=call.tool_call_id, content='{"action":"book"}')]
    write(f"agentchat-{variant}-2.sse", scripted(run("thread-1-run2", answered, context), "trip"))
    print(variant, "Picture" in args, len(first), "events in run 1")
shutil.copy(ROOT / "examples/agentchat/pictures/tagus.jpg", OUT / "tagus.jpg")
