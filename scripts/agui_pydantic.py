"""An AG-UI agent we didn't write the protocol side of: Pydantic AI's own AG-UI adapter (pydantic_ai.ui.ag_ui), with its
FunctionModel standing in for a model (no key, deterministic). It thinks first (Pydantic AI sends that as REASONING_*
events), streams a sentence, then calls the app's frontend tool
render_ui with a screen, its arguments in pieces; when the app answers the tool (a button), it says what came back.
Every AG-UI event on the wire is Pydantic AI's; this file only plays the model. (docs/ag-ui-compatibility.md)

  pixi run python scripts/agui_pydantic.py [--port 8790]        then: AGUI_URL=http://127.0.0.1:8790/ … examples/agentchat
"""

import argparse
import json
import sys

from pydantic_ai import Agent
from pydantic_ai.messages import ModelRequest, ToolReturnPart
from pydantic_ai.models.function import AgentInfo, DeltaThinkingPart, DeltaToolCall, FunctionModel
from pydantic_ai.ui.ag_ui import AGUIAdapter
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.routing import Route

SCREEN = {"ui": {"component": "Card", "title": "Hello from Pydantic AI", "subtitle": "An AG-UI agent built with another framework", "children": [
    {"component": "Text", "text": "Pydantic AI wrote every event of this answer; omxcode drew the screen."},
    {"component": "HStack", "children": [{"component": "Chip", "text": "AG-UI", "hue": 1}, {"component": "Chip", "text": "Pydantic AI", "hue": 2},
                                         {"component": "Chip", "text": "Mojo", "hue": 3}]},
    {"component": "HStack", "children": [{"component": "Button", "label": "Looks right", "action": "ok", "style": "prominent"},
                                         {"component": "Button", "label": "Something's off", "action": "off"}]}]}}

THOUGHT = "The person wants a screen. I'll send it as a render_ui call, built from the app's catalog."

received = []  # every RunAgentInput the app sent, as JSON (scripts/agui_interop.py checks them)


async def model(messages, info: AgentInfo):
    last = messages[-1]
    answered = [p for p in last.parts if isinstance(p, ToolReturnPart)] if isinstance(last, ModelRequest) else []
    if answered:
        yield f"The app answered render_ui with {answered[-1].content}."
        return
    tools = [t.name for t in info.function_tools]
    for word in THOUGHT.split(" "):
        yield {0: DeltaThinkingPart(content=word + " ")}
    for word in "Here is a screen, sent as a render_ui call.".split(" "):
        yield word + " "
    if "render_ui" not in tools:
        yield f"(The app offered no render_ui tool; it offered {tools}.)"
        return
    args = json.dumps(SCREEN)
    for i in range(0, len(args), 40):
        yield {1: DeltaToolCall(name="render_ui" if i == 0 else None, json_args=args[i:i + 40], tool_call_id="call-1" if i == 0 else None)}


agent = Agent(FunctionModel(stream_function=model))


async def run(request: Request):
    body = json.loads(await request.body())
    received.append(body)
    print("RUN:", json.dumps({"tools": [t["name"] for t in body.get("tools", [])], "last": (body.get("messages") or [{}])[-1]})[:600], flush=True)
    return await AGUIAdapter.dispatch_request(request, agent=agent)


app = Starlette(routes=[Route("/", run, methods=["POST"])])

if __name__ == "__main__":
    import uvicorn
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8790)
    a = ap.parse_args()
    print(f"Pydantic AI AG-UI agent on http://127.0.0.1:{a.port}/", file=sys.stderr)
    uvicorn.run(app, host="127.0.0.1", port=a.port, log_level="warning")
