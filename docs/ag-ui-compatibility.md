# omxcode and AG-UI: what's compatible, and how we know

omxcode apps (written in Mojo, drawn natively on Linux with GTK and in the browser) are [AG-UI](https://docs.ag-ui.com)
clients. An omxcode app sends a standard `RunAgentInput` to an AG-UI agent, reads the standard event stream back, and
can draw screens the agent sends as a frontend tool call (`render_ui`). Every claim below has a check you can run. What
isn't proven is listed as such.

## The evidence

| Claim | How it's checked | Run it |
|---|---|---|
| **It reads AG-UI as the official SDK writes it** | Five streams are recorded with the official Python SDK (`ag-ui-protocol` 1.0.0) and kept in [`tests/fixtures/agui/`](../tests/fixtures/agui/). The check first re-records them and requires them to match byte for byte, then validates every event with the SDK's own models. The Mojo client reads each stream. Its conversation (messages, roles, tool calls, tool call ids), its shared state (snapshots and JSON Patch deltas) and how it saw the run end must equal an independent reading written in Python. Its count of events by type must match the stream's. | `pixi run python docs/goals/35-check.py M1` |
| **What it sends is a valid `RunAgentInput`** | Against a live agent, every request the app sends is validated with the SDK's `RunAgentInput` model. The second run must carry the assistant's tool call, a tool message answering it, and the state the client kept. | the same M1 |
| **It works with agent frameworks we didn't write** | Two frameworks' own AG-UI code serve scripted models: Pydantic AI's adapter (`pydantic_ai.ui.ag_ui`, `pydantic-ai-slim` 2.66.0) in [`scripts/agui_pydantic.py`](../scripts/agui_pydantic.py), and LangGraph's integration (`ag-ui-langgraph` 0.0.47, its `LangGraphAgent` and FastAPI endpoint over a LangGraph graph) in [`scripts/agui_langgraph.py`](../scripts/agui_langgraph.py). Every event on the wire is the framework's. Our files only play the model, a scripted one whose words and `render_ui` arguments we wrote, so it needs no key. The real app, [`examples/agentchat`](../examples/agentchat/app.mojo), on both GTK and the web, for each framework: its words and its `render_ui` screen are drawn. Both requests validate as `RunAgentInput`. Tapping a button sends a tool message that answers the framework's call, and its reply is shown. Pydantic AI's model also thinks first: its `REASONING_*` events show as "Thought", which opens to the thinking, and the thinking goes back with the next run as a `reasoning` message. Shots: Pydantic AI on [GTK](img/agents/interop-pydantic-gtk.png) and [the web](img/agents/interop-pydantic-web.png); LangGraph on [GTK](img/agents/interop-langgraph-gtk.png) and [the web](img/agents/interop-langgraph-web.png). | `pixi run python scripts/agui_interop.py` |
| **Chunk events are read by the official client's rules** | `TEXT_MESSAGE_CHUNK`, `TOOL_CALL_CHUNK` and `REASONING_MESSAGE_CHUNK` are read as modelled on `@ag-ui/client` 1.0's `transformChunks`. Only the first chunk has to name its message or call (and a tool call's first chunk its tool). A chunk without an id goes on the open one. A new id, or the next event of another kind, ends it, and a tool call sent as chunks is then whole and gets answered. The test feeds these events to the client and to the chat, including a `render_ui` screen sent as chunks. Neither framework above sends chunks, so this is our test of the rules, not a framework's stream. Where we differ from it: a first chunk without its id is refused and the run goes on (the official client throws); a tool chunk that reuses a used call id is refused (it starts a second call with that id); a text chunk naming a message that already exists adds to it (it starts a new message with the same id); subagents' chunks aren't kept apart. | `pixi run python docs/goals/48-check.py M1` (`tests/test_agui_chunks.mojo`) |
| **JSON Patch state deltas are applied exactly** | RFC 6902: Appendix A's cases and more, compared with the `jsonpatch` library's results. A patch that fails changes nothing. | the same M1 |
| **Agent-built screens are data, checked before drawing** | `render_ui`'s parameters are a JSON Schema generated from the catalog of 36 components ([`docs/genui.schema.json`](genui.schema.json), checked valid as Draft 2020-12). On every test case, the Mojo validator must reach the same verdict as `jsonschema`. Anything outside the catalog is refused, and the refusal goes back to the agent as the tool's result. No code from the agent runs. | `pixi run python docs/goals/35-check.py M2` |
| **Screens draw while they stream** | `render_ui`'s arguments are drawn as they arrive. Every byte cut of a test screen (compact JSON and the spaced JSON that Python's `json.dumps` writes) must close to JSON that parses, and once a screen shows, no later cut may fall back to loading. Mid-stream shots must differ on GTK and the web. | `pixi run python docs/goals/48-check.py M1` |
| **The same stream works in CopilotKit** | One recorded AG-UI stream (2,302 events) is replayed into omxcode and into a CopilotKit 1.84.1 app ([`bench/copilotkit`](../bench/copilotkit): its runtime with an AG-UI `HttpAgent`, `CopilotChat`, and `useFrontendTool("render_ui")`). CopilotKit's own chat hosts a plain React component we wrote for `render_ui`, and the check is that the screen's last component's text appears in both. This shows omxcode and CopilotKit read the same protocol. It is not a test of omxcode against CopilotKit's runtime. | `pixi run python scripts/agui_bench.py` |

## Events

| Read and acted on | `RUN_STARTED`, `RUN_FINISHED`, `RUN_ERROR`, `TEXT_MESSAGE_START` / `CONTENT` / `END`, `TOOL_CALL_START` / `ARGS` / `END` / `RESULT`, `STATE_SNAPSHOT`, `STATE_DELTA` (JSON Patch), `MESSAGES_SNAPSHOT`, `STEP_STARTED` / `FINISHED`, `CUSTOM` (each one in a recorded SDK stream); `REASONING_START` / `MESSAGE_START` / `MESSAGE_CONTENT` / `MESSAGE_END` / `END` (Pydantic AI's stream, above) |
|---|---|
| Read and acted on, tested by our own events | `TEXT_MESSAGE_CHUNK`, `TOOL_CALL_CHUNK`, `REASONING_MESSAGE_CHUNK` |
| Counted and ignored | `REASONING_ENCRYPTED_VALUE` (not sent back yet), `ACTIVITY_*`, `RAW`, `SUBAGENT_*` (a subagent's events aren't kept apart from its parent's) |

Also supported: frontend tools (the app offers tools, the agent calls them, the app's answer goes back as a tool
message), shared state sent with each run, `context`, and interrupts that wait for the person (approve, reject or
answer, then resume), tested with our scripted agent on GTK and the web (`docs/goals/48-check.py M2`). Limits: a request
is at most 6 MB (the state is at most 4 MB, and the oldest messages are left out first, never refused). A screen is at
most 8 levels deep, 200 components and 32 KB.

## Not tested yet

- Agent frameworks other than Pydantic AI, LangGraph and our own. CrewAI, Mastra, the Microsoft Agent Framework and
  others publish AG-UI adapters, and none of them has been run against omxcode.
- CopilotKit's runtime as the server for an omxcode app, and CopilotKit's A2UI and other generative-UI specs.
  omxcode's screens come from its own catalog through `render_ui`.
- A real model in these checks. The checks use scripted models, so that they're repeatable. Small local models were
  run by hand through our own agent backend, which repairs their tool-call JSON (docs/agui.md, "The live demo"). Claude
  hasn't been run.
- Sending the thinking back. A `reasoning` message goes back with the next run, which `ag-ui-protocol` 1.0.0's
  `RunAgentInput` and Pydantic AI accept. LangGraph's scripted model doesn't think, so its handling isn't run, and a
  server on an AG-UI SDK older than the reasoning events may refuse the whole request: such an app sets
  `agent.send_reasoning = False`.
- The Mac. omxcode builds for the Mac, but agents haven't been run there.

## Versions

`ag-ui-protocol` 1.0.0 (Python SDK), `@ag-ui/client` 1.0.2 (its chunk rules), `pydantic-ai-slim` 2.66.0, `ag-ui-langgraph` 0.0.47 with `langgraph` 1.2.20,
CopilotKit 1.84.1, Mojo 1.1. The reference for the client and the agent chat: [docs/agui.md](agui.md). The walkthrough:
[agents.html](https://abhisheksreesaila.github.io/omxcode/agents.html).
