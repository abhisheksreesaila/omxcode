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
