"""An AG-UI agent we didn't write the protocol side of: LangGraph's own AG-UI integration (ag_ui_langgraph, its
LangGraphAgent and add_langgraph_fastapi_endpoint), over a one-node graph whose chat model is scripted (no key,
deterministic). It streams a sentence, then calls the app's frontend tool render_ui with a screen, its arguments in
pieces; the graph stops there, so the app answers the tool (a button), and the next run says what came back.
Every AG-UI event on the wire is ag_ui_langgraph's; this file only plays the model. (docs/ag-ui-compatibility.md)

The app's tools reach the graph through its state: ag_ui_langgraph puts RunAgentInput.tools in state["tools"] (and
state["ag-ui"]["tools"]); the node binds them to the model, which calls render_ui only if it was offered.

  pixi run python scripts/agui_langgraph.py [--port 8791]       then: AGUI_URL=http://127.0.0.1:8791/ … examples/agentchat
"""

import argparse
import json
import sys
from typing import Any

from ag_ui_langgraph import LangGraphAgent, add_langgraph_fastapi_endpoint
from fastapi import FastAPI, Request
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, AIMessageChunk, ToolMessage
from langchain_core.outputs import ChatGeneration, ChatGenerationChunk, ChatResult
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, MessagesState, StateGraph

SCREEN = {"ui": {"component": "Card", "title": "Hello from LangGraph", "subtitle": "An AG-UI agent built with another framework", "children": [
    {"component": "Text", "text": "LangGraph wrote every event of this answer; omxcode drew the screen."},
    {"component": "HStack", "children": [{"component": "Chip", "text": "AG-UI", "hue": 1}, {"component": "Chip", "text": "LangGraph", "hue": 2},
                                         {"component": "Chip", "text": "Mojo", "hue": 3}]},
    {"component": "HStack", "children": [{"component": "Button", "label": "Looks right", "action": "ok", "style": "prominent"},
                                         {"component": "Button", "label": "Something's off", "action": "off"}]}]}}

received = []  # every RunAgentInput the app sent, as JSON (scripts/agui_interop.py checks them)


class ScriptedChat(BaseChatModel):
    """Plays the model: a sentence and a render_ui call, or, once the tool is answered, what the app answered."""
    tools: list = []  # names of the tools bound with bind_tools

    @property
    def _llm_type(self) -> str:
        return "scripted"

    def bind_tools(self, tools, **kwargs: Any):
        return self.model_copy(update={"tools": [t["name"] if isinstance(t, dict) else t.name for t in tools]})

    def _chunks(self, messages):
        last = messages[-1]
        if isinstance(last, ToolMessage):
            yield AIMessageChunk(content=f"The app answered render_ui with {last.content}.")
            return
        for word in "Here is a screen, sent as a render_ui call.".split(" "):
            yield AIMessageChunk(content=word + " ")
        if "render_ui" not in self.tools:
            yield AIMessageChunk(content=f"(The app offered no render_ui tool; it offered {self.tools}.)")
            return
        # Like OpenAI and Anthropic stream it: a first piece with the name and id and no arguments, then the arguments.
        # (ag_ui_langgraph turns the first piece into TOOL_CALL_START and drops any arguments it carries.)
        yield AIMessageChunk(content="", tool_call_chunks=[{"name": "render_ui", "args": "", "id": "call-1", "index": 0}])
        args = json.dumps(SCREEN)
        for i in range(0, len(args), 40):
            yield AIMessageChunk(content="", tool_call_chunks=[{"name": None, "args": args[i:i + 40], "id": None, "index": 0}])

    def _stream(self, messages, stop=None, run_manager=None, **kwargs):
        for chunk in self._chunks(messages):
            gen = ChatGenerationChunk(message=chunk)
            if run_manager:
                run_manager.on_llm_new_token(chunk.content if isinstance(chunk.content, str) else "", chunk=gen)
            yield gen

    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        whole = None
        for gen in self._stream(messages, stop, run_manager, **kwargs):
            whole = gen if whole is None else whole + gen
        msg = whole.message
        return ChatResult(generations=[ChatGeneration(message=AIMessage(content=msg.content, tool_calls=msg.tool_calls, id=msg.id))])


class State(MessagesState):
    tools: list  # the app's frontend tools, filled by ag_ui_langgraph from RunAgentInput.tools


async def chat(state: State, config):
    model = ScriptedChat().bind_tools(state.get("tools") or [])
    return {"messages": [await model.ainvoke(state["messages"], config)]}


builder = StateGraph(State)
builder.add_node("chat", chat)
builder.add_edge(START, "chat")
builder.add_edge("chat", END)  # no tool node: a frontend tool call ends the run, and the app answers it
saver = InMemorySaver()
graph = builder.compile(checkpointer=saver)


def reset():
    """Forgets every thread the app used (scripts/agui_interop.py: each host's run starts a new conversation on
    thread-1). Call before clearing `received`."""
    for thread in {body.get("threadId") for body in received}:
        saver.delete_thread(thread)

app = FastAPI()


@app.middleware("http")
async def record(request: Request, call_next):
    if request.method == "POST":
        body = json.loads(await request.body())
        received.append(body)
        print("RUN:", json.dumps({"tools": [t["name"] for t in body.get("tools", [])], "last": (body.get("messages") or [{}])[-1]})[:600], flush=True)
    return await call_next(request)


add_langgraph_fastapi_endpoint(app, LangGraphAgent(name="omxcode_langgraph", graph=graph), path="/")

if __name__ == "__main__":
    import uvicorn
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8791)
    a = ap.parse_args()
    print(f"LangGraph AG-UI agent on http://127.0.0.1:{a.port}/", file=sys.stderr)
    uvicorn.run(app, host="127.0.0.1", port=a.port, log_level="warning")
