# AG-UI in mojoui (goal 35)

AG-UI (https://docs.ag-ui.com) is an open event protocol between an agent backend and a UI. The app POSTs a
`RunAgentInput` (thread, run, messages, state, tools); the run comes back as server-sent events. mojoui speaks it with
generic pieces any app can use; `examples/agentchat` only composes them.

| Piece | What it does |
|---|---|
| `mojoui.http` streams | `Request.stream(END)`: each SSE event is its own Event in `update()`, then the end (docs/http.md) |
| `mojoui.jsonpatch` | `JDoc`, a JSON document you can change, and RFC 6902 JSON Patch on it (atomic) |
| `mojoui.agui` | `Agent`: runs the agent, reads every event, keeps the conversation and the shared state, frontend tools |
| `mojoui.genui` | the catalog → JSON Schema generator and the validated "UI from data" renderer (M2) |

## The client

```mojo
var agent = Agent("http://127.0.0.1:8765/", PIECE, END)      # PIECE / END: the app's two messages for the stream
agent.offer(Tool("ask_user", "Ask the user", '{"type":"object",…}'))
agent.say("Hello")                                            # a user message
agent.run(self.http)                                          # POST RunAgentInput, streamed back
# update(): if e.message == PIECE or e.message == END: var what = agent.handle(e)    (EV_TEXT, EV_TOOL_END, EV_STATE…)
for c in agent.pending(): agent.answer(c.id, '{"answer": "blue"}')                  # frontend tool calls
agent.run(self.http)                                          # the answer and the state go with the next run
```

- Events read: RUN_STARTED/FINISHED/ERROR, TEXT_MESSAGE_START/CONTENT/END/CHUNK, TOOL_CALL_START/ARGS/END/CHUNK/RESULT,
  STATE_SNAPSHOT, STATE_DELTA (JSON Patch; a delta that doesn't apply leaves the state as it was: `EV_STATE_REFUSED`,
  `state_error`), MESSAGES_SNAPSHOT, STEP_STARTED/FINISHED, CUSTOM. Others (REASONING_*, RAW, ACTIVITY_*) are counted
  and ignored.
- Proved by tests/test_agui.mojo against five streams recorded with the official AG-UI Python SDK (`ag-ui-protocol`
  1.0.0; `scripts/agui_agent.py --record`), compared with an independent reading in scripts/check.py, and live against
  the scripted agent, whose received RunAgentInputs validate with the SDK's own models (goal 35 M1).

## The agent backend (scripts/agui_agent.py)

The official SDK's events and `EventEncoder` over HTTP. `--serve --scenario chat|ui|bad|tools` is the scripted,
deterministic agent every check uses; `--serve --live` is a real model (below).

## UI from data (mojoui.genui)

An agent builds UI by calling the frontend tool `render_ui` with `{"ui": node}`; a node is one catalogued component:

```json
{"ui": {"component": "Card", "title": "Signup", "children": [
  {"component": "TextField", "placeholder": "Your name", "bind": "/form/name"},
  {"component": "Toggle", "label": "Subscribe", "bind": "/form/subscribe"},
  {"component": "Button", "label": "Submit", "action": "submit", "style": "prominent"}]}}
```

- The components: Card, VStack, HStack, Text, Paragraph, Divider, Table, Sparkline, Meter, Button, TextField, Toggle,
  Segmented. Their props and limits are one catalog (`mojoui.genui.catalog()`), printed as a JSON Schema
  (docs/genui.schema.json, the tool's parameters).
- Refused, with a message to the agent (a tool result `{"error": "refused: …"}`): an unknown component (WebFrame,
  Script, "card"…), a bad prop (unknown, wrong type, out of range, missing, an action that isn't one word, a bind that
  isn't a state path), more than 8 levels, more than 200 components or 32 KB.
- Text is text: `<script>` an agent writes is shown as words on every host. No component the agent can name runs code,
  loads a page or draws pixels it brings.
- `bind` reads and edits the shared state at a JSON pointer; `action` reports a word back: the first one is render_ui's
  tool result (`{"action": "submit"}`), and the edited state goes with the run.

## Run it

```bash
scripts/agentchat.sh            # the scripted agent and the app on GTK ("Hello", "Show me sales as a chart", "Make me a signup form")
scripts/agentchat.sh --web      # the same on the web
```

## The live demo (an agent backed by a real model)

One OpenAI-compatible path (owner, 2026-10-27, D-710). Every setting is an environment variable, read by name; no key
is printed, logged or stored, and none ever reaches the app (the backend holds it).

**The OMX Console (the default: local models, no cloud, no key leaves the machine).** The console serves models behind
an OpenAI-compatible endpoint at `http://127.0.0.1:11435/v1`, with a key per app:

```bash
cd ~/Projects/mxstudio/mxconsole
pixi run mxc serve qwen2.5-0.5b        # (or a bigger model: small ones are weak at tool calls)
pixi run mxc keys new agentchat        # prints a key once
export MXC_API_KEY=…                   # in the shell that runs the demo
cd ~/Projects/mxapp/mojo-ui-agui && scripts/agentchat.sh --live
```

| Variable | Default | What |
|---|---|---|
| `AGUI_LLM_BASE_URL` | `http://127.0.0.1:11435/v1` | any OpenAI-compatible chat API |
| `AGUI_LLM_MODEL` | `qwen2.5-0.5b` | a model the endpoint serves (`qwen2.5-7b-instruct` or larger builds UI more reliably) |
| `AGUI_LLM_KEY_VAR` | `MXC_API_KEY` | the NAME of the variable holding the key (sent as `Authorization: Bearer …`; unset: no header) |

Small models break tool-call JSON, so the backend repairs it before it reaches the app: code fences and chatter
stripped, single quotes, trailing commas and Python literals fixed, a bare node wrapped in `{"ui": …}`, component names
matched case-insensitively with common synonyms (chart → Sparkline, row → HStack), common prop synonyms (data →
values). A UI written into the words instead of a tool call is lifted out. The model sees a short render_ui schema and
an explicit list of the components in its system prompt; the app still validates the full schema and refuses the rest.

**Claude (optional).** `AGUI_LLM_PROVIDER=anthropic` uses the Anthropic SDK, which reads `ANTHROPIC_API_KEY` itself
(model `claude-opus-5-5` unless `AGUI_LLM_MODEL` says otherwise; low effort; the server-side refusal fallback on):

```bash
export ANTHROPIC_API_KEY=…  AGUI_LLM_PROVIDER=anthropic
scripts/agentchat.sh --live
```

Proved without a model by scripts/check.py M3: a stand-in OpenAI-compatible server (scripts/fake_llm.py) answers like a
small model with broken tool JSON; the stream the backend sends validates with the AG-UI SDK, carries the repaired UI,
and the key arrives as a Bearer token and is printed nowhere. The live run against a real model is by hand (unverified
by the checks).
