# AG-UI in mojoui (goal 35; goal 48: as good as CopilotKit, and faster)

AG-UI (https://docs.ag-ui.com) is an open event protocol between an agent backend and a UI. The app POSTs a
`RunAgentInput` (thread, run, messages, state, tools, context); the run comes back as server-sent events. mojoui speaks
it with generic pieces any app can use; `examples/agentchat` (60 lines) only composes them.

| Piece | What it does |
|---|---|
| `mojoui.http` streams | `Request.stream(END)`: each SSE event is its own Event in `update()`, then the end (docs/http.md) |
| `mojoui.jsonpatch` | `JDoc`, a JSON document you can change, and RFC 6902 JSON Patch on it (atomic) |
| `mojoui.agui` | `Agent`: runs the agent, reads every event, keeps the conversation, the shared state and the run's steps, frontend tools, `resume()` for interrupts, `context`; `LocalAgent`: an agent in the app's own process |
| `mojoui.genui` | the catalog (36 components) → JSON Schema, the validated "UI from data" renderer, `partial_ui` (a screen still streaming, drawable) |
| `mojoui.partialjson` | `complete()`: JSON still arriving, cut to its last whole value and closed |
| `mojoui.agentui` | `Screens`: an agent's render_ui calls previewed while they stream, shown or refused (told why), their actions answered |
| `mojoui.agentchat` | `AgentChat`: the chat any app drops in (panel, sidebar, popup) with everything below |
| `mojoui.datahub`, `mojoui.sheethub` | datasets the app holds that an agent's UI names instead of sending rows (MX frame sheets, the GPU) |

## Goal 48: what a person gets (AgentChat)

```mojo
var chat = AgentChat[SheetHub](url, base=20_000, canvas_base=2000, layout=CHAT_PANEL, title="Assistant")
chat.suggest("Chart a million orders")                        # chips on the welcome screen (the agent's CUSTOM "suggestions" replace them)
chat.offer(Tool("refund_order", "Refund an order", schema), confirm=True)   # asks the person first
var hub = SheetHub(); hub.add("orders", sheet^); chat.set_hub(hub^)          # datasets: rows stay here
# App: requests() → chat.requests(); update(e) → chat.update(e); view() → chat.view() (or chat.over(content): a popup)
#      draw(c, s) → chat.draw(c, s, palette)
```

- **Streaming words** as Markdown (headings, lists, tables, inline code), code blocks cut out with their own **Copy**; a
  **typing indicator** until the agent says or starts anything; **Send becomes Stop** (cancels the run; "Stopped."
  stays); the list **follows the newest words and lets go** when the reader scrolls up; every message **arrives on a
  spring** (`View.arrive()`: libadwaita's AdwSpringAnimation on GTK, a CSS spring on the web; none under reduced motion).
- **Copy and Regenerate** on replies; an **error card with Retry**; **suggestion chips**.
- **Generative UI while it streams**: render_ui's arguments are drawn as they arrive (`partial_ui`: props not yet whole
  left out, a **Skeleton** where more is coming, a loading card before anything is whole); the final screen replaces the
  preview; each chart redraws only when its own data changed.
- **Tool calls with their stage**: in progress (arguments streaming), executing (complete, no result yet), complete (with
  its result); three or more in a row fold into one card ("Used 3 tools · web_search ×3"). The run's **steps**
  (STEP_STARTED / STEP_FINISHED) are a live progress list.
- **Human in the loop**: a tool offered with `confirm=True` shows a **Confirm** card (what it will do, its arguments,
  Reject / Approve) and runs nothing until answered; the answer is the call's result (`{"decision": "approved" |
  "rejected", "arguments": …}`). An **interrupt** (CUSTOM `interrupt`, or LangGraph's and CopilotKit's `on_interrupt`,
  `{question, options}`) shows a choice card; the pick resumes the run with `forwardedProps {"command": {"resume": pick}}`.
- **Datasets**: a DataGrid or ChartView can name a dataset the app holds (`"dataset": "orders"`, with `group_by`, `value`,
  `combine`, `top` for a chart): the agent sends a few hundred bytes, the app shows a million rows; the chart's numbers are
  MX frame's group-by (0.3 ms on the GPU for 1M rows here), its caption says so. The agent hears of the datasets in each
  run's `context`.
- **An agent in the app's process** (`LocalAgent`): no HTTP, no other language; its events go through the same handler
  (2,004 events in 26 ms here, tests/test_local_agent.mojo).

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

- What's sent fits one budget: a RunAgentInput is at most 6 MB (`mojoui.agui.MAX_INPUT_BYTES`: the state, ≤ 4 MB, plus
  the newest messages that fit; the oldest are left out first and `agent.trimmed` says how many). The agent backend
  (scripts/agui_agent.py) accepts up to 8 MB (`MAX_BODY`), so a long chat is trimmed, never refused with a 413
  (tests/test_agui_agent.py checks the two numbers).
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

- The components (goal 48 M0: 36, each the real mojoui component, one catalog: `mojoui.genui.catalog()`, printed as a
  JSON Schema in docs/genui.schema.json, the tool's parameters; `scripts/genui_schema.py` regenerates it):
  - layout: Card, VStack, HStack, Grid, Tabs, Divider, Spacer
  - words: Text, Paragraph, Markdown, CodeBlock (with Copy), Chip, Alert, Skeleton
  - data: Table, DataGrid, ChartView (bars, line), Sparkline, KpiView, Meter, ProgressBar, Timeline, MapView, Breadcrumbs, Icon
  - inputs: Button, TextField, TextArea, Toggle, Checkbox, Dropdown, Slider, Segmented, Radio, DatePicker
  - asking: Confirm (approve or reject)
- Refused, with a message to the agent (a tool result `{"error": "refused: …"}`): an unknown component (WebFrame,
  Script, "card"…), a bad prop (unknown, wrong type, out of range, missing, an action that isn't one word, a bind that
  isn't a state path), more than 8 levels, more than 200 components or 32 KB.
- Text is text: `<script>` an agent writes is shown as words on every host. No component the agent can name runs code,
  loads a page or draws pixels it brings.
- `bind` reads and edits the shared state at a JSON pointer; `action` reports a word back: the first one is render_ui's
  tool result (`{"action": "submit"}`), and the edited state goes with the run.

## Benchmark (goal 48 M5: the same stream into omxcode and CopilotKit)

Written by `pixi run python scripts/agui_bench.py` from docs/goals/48/bench.json (2026-11-04 07:39, median of 3 runs,
ablearn · x86_64 · Linux 7.2.5-3-omarchy). One recorded AG-UI stream (2302 events: 300 words, then a 40-component dashboard as render_ui's
arguments three bytes at a time, state deltas between) replayed into omxcode on GTK, omxcode on the web host, and a
CopilotKit 1.84.1 app (bench/copilotkit: CopilotChat, its Node runtime with an AG-UI HttpAgent, `useFrontendTool("render_ui")`
drawing the partial arguments with plain React components). Both web runners in the same headless Chromium at
1100×900; GTK in its own window, the same size.

| Runner | First UI (burst) | Final screen (burst) | Dropped frames, burst | Dropped frames, paced (~250 events/s) | Peak memory |
|---|---|---|---|---|---|
| omxcode, native GTK | 12 ms | 69 ms | 2 (worst 31 ms) | 0 (worst 4 ms) | 109 MB (process) |
| omxcode, web host | 125 ms | 164 ms | 0 (worst 17 ms) | 0 (worst 17 ms) | 4 MB (JS heap) |
| CopilotKit (React) | 129 ms | 565 ms | 3 (worst 233 ms) | 0 (worst 17 ms) | 42 MB (JS heap) |

How it's measured, from the moment Send is pressed (the web runners: a click, CopilotKit: Enter, as its chat takes it):
first UI, the screen's first component ("Orders, live") is in the page's text (web, checked each animation frame) or the
widget tree (GTK, checked after each main-loop turn): not a paint timestamp. Final screen: its last component ("end of
dashboard") is there: the final state, not every intermediate one (omxcode rebuilds a streaming screen when a component
finishes or 64 bytes arrive; CopilotKit renders as React batches). Dropped frames: web, requestAnimationFrame gaps over
25 ms; GTK, main-loop turns over 16.7 ms. Memory is not the same quantity: web rows are the tab's JS heap (omxcode's web
host works in its server process, not counted); the GTK row is the whole native process (GTK, fonts, the Mojo runtime),
started without the demo's million-row dataset. Paced, every runner ends when the stream does, so that column is about
smoothness, not speed.

What it says:
- **Native GTK**: first UI 11.2× sooner and the final screen 8.2× sooner
  than CopilotKit (69 ms vs 565 ms); paced, 0 stalls (worst main-loop turn 3.9 ms).
- **The web host** reaches the final screen 3.4× sooner than CopilotKit (164 ms vs 565 ms) with
  9.4× less JS heap.

- **CopilotKit's worst frame in a burst**: 233 ms (React reconciling the tool's render at once).
- **Not measured**: other machines, a phone, a real model's pacing (the paced run stands in), CopilotKit's A2UI renderer
  (its v2 API; this uses its documented v1 frontend-tool render), cold start.
- **Only omxcode, in this comparison**: one Mojo file native on GTK and on the web; an agent in the app's own process
  (tests/test_local_agent.mojo: 2,000+ events in ~26 ms through the same handler); a chart over a million rows the agent
  never sends (0.3 ms on the GPU).

## Gallery (goal 48: scripted agents, our components, drawn natively)

Each is one prompt to the scripted agent (`scripts/agui_scenarios.py`); the agent answers with words and a `render_ui`
call built only from catalogued components; examples/agentchat draws it on GTK and the web. Regenerate with
`pixi run python scripts/agui_gallery.py` (the checks' own shots: docs/goals/48/ex-<scenario>-<host>.png).

| Prompt | What the agent built | GTK | Web |
|---|---|---|---|
| Plan a day in Lisbon | MapView (route and six places), chips, an itinerary Timeline, a weather Sparkline, an Alert, buttons | ![](goals/48/ex-trip-tall-gtk.png) | ![](goals/48/ex-trip-tall-web.png) |
| Show me this quarter's sales | four KpiViews, bar and line ChartViews, a DataGrid of products, Meters, an Alert | ![](goals/48/ex-dashboard-tall-gtk.png) | ![](goals/48/ex-dashboard-tall-web.png) |
| Book a table for dinner | TextField, Slider, Dropdown, Radio, Checkbox, DatePicker, TextArea; Book reports back with the values in the shared state | ![](goals/48/ex-booking-tall-gtk.png) | ![](goals/48/ex-booking-tall-web.png) |
| Refund order 1042 | a confirm tool: the approve/reject card, nothing runs until answered | ![](goals/48/ex-approval-tall-gtk.png) | ![](goals/48/ex-approval-tall-web.png) |
| Research home batteries | a plan as steps, three searches folded into one tool card, a ChartView, a Table | ![](goals/48/ex-research-tall-gtk.png) | ![](goals/48/ex-research-tall-web.png) |
| Write the release note for 2.4 | Markdown with a table and a code block (Copy), a rollout Timeline, Chips | ![](goals/48/ex-release-tall-gtk.png) | ![](goals/48/ex-release-tall-web.png) |
| Build me a dashboard | the same dashboard streamed: steps, a backend tool card, the screen growing piece by piece | ![](goals/48/ex-stream-tall-gtk.png) | ![](goals/48/ex-stream-tall-web.png) |
| Show every component | the catalog at a glance | ![](goals/48/ex-catalog-tall-gtk.png) | ![](goals/48/ex-catalog-tall-web.png) |

Mid-stream (GTK, 0.35 s, 0.85 s, done): ![](goals/48/m1-stream-gtk-0.png) ![](goals/48/m1-stream-gtk-1.png) ![](goals/48/m1-stream-gtk-2.png)

## Not for agents

Components an agent can't name, and why (the rest of docs/components.md):
- Code, pages or pixels it would bring: WebComponent, WebFrame, Canvas, Image, Picture, Clipboard (an agent's UI is data
  drawn natively; nothing it sends runs, loads or paints).
- Windows and the app's own frame: MenuBar, Menu, ContextMenu, Dialog, Popover, Toast, Overlay, NavBar, Route, the
  shells, sidebars and toolbars (an agent's UI lives inside the conversation, not around it).
- App-only parts, bound to an app's engine or files: the workbook (PivotTable, Board, sheet objects, FormulaBar,
  Inspector, cell styles, the Island), video and media (VideoSource, Player, MediaTimeline, VideoTable, FrameFeed),
  documents and OCR (PdfSource, Document card, OcrModel), links and drags (Links, Link drag, Draggable, DropTarget,
  Peek), telemetry lanes, Ink strokes, LazyList (a DataGrid covers long lists).

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

**Claude (optional, not run: there is no key here).** `AGUI_LLM_PROVIDER=anthropic` uses the Anthropic SDK's plain
Messages API (`messages.stream` with the tools), which reads `ANTHROPIC_API_KEY` itself; the model is `claude-opus-5-5`
unless `AGUI_LLM_MODEL` says otherwise:

```bash
export ANTHROPIC_API_KEY=…  AGUI_LLM_PROVIDER=anthropic
scripts/agentchat.sh --live
```

Proved without a model by scripts/check.py M3: a stand-in OpenAI-compatible server (scripts/fake_llm.py) answers like a
small model with broken tool JSON; the stream the backend sends validates with the AG-UI SDK, carries the repaired UI,
and the key arrives as a Bearer token and is printed nowhere. The live run against a real model is by hand (unverified
by the checks).
