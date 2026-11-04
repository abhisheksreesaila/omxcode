# CopilotKit: how it does AG-UI and generative UI (research, 2026-11-04)

Why: omxcode already has an AG-UI client (`mojoui.agui`), a validated `render_ui` frontend tool with 13 catalogued
components (`mojoui.genui`, `mojoui.agentui`, see `docs/agui.md`). This note records what CopilotKit, the reference
AG-UI frontend, ships, so we can match it feature for feature and beat it on speed.

Sources are primary: the CopilotKit docs (fetched as Markdown by appending `.md`, e.g.
`https://docs.copilotkit.ai/reference/hooks/useFrontendTool.md`), the
[CopilotKit repo](https://github.com/CopilotKit/CopilotKit) (`main`, ~38.5k stars), the
[AG-UI docs](https://docs.ag-ui.com), the [AG-UI repo](https://github.com/ag-ui-protocol/ag-ui) (dojo in `apps/dojo`),
and the [A2UI repo](https://github.com/google/A2UI). CopilotKit's current API is "v2"
(`@copilotkit/react-core/v2`); v1 names (`useCopilotAction`, `useCoAgentStateRender`, `useLangGraphInterrupt`) are
deprecated but still documented.

---

## 1. Generative-UI patterns

CopilotKit sorts them into three families
([overview](https://docs.copilotkit.ai/concepts/generative-ui-overview),
[hook guide](https://docs.copilotkit.ai/concepts/which-hook)):
**controlled** (you wrote the component; the agent picks it and fills props), **declarative** (the agent sends a
UI description in a spec, A2UI, rendered from your catalog), **open-ended** (the agent ships HTML/JS that runs in a
sandboxed iframe: MCP Apps, Open Generative UI).

### The one status machine every tool renderer gets
Every tool-call renderer receives `{name, args|parameters, status, result}` with three states
([useRenderTool](https://docs.copilotkit.ai/reference/hooks/useRenderTool)):

| status | args | result | wire events that cause it |
|---|---|---|---|
| `inProgress` | `Partial<T>`, partial-JSON-parsed **while `TOOL_CALL_ARGS` deltas stream** | – | `TOOL_CALL_START`, each `TOOL_CALL_ARGS` |
| `executing` | complete `T` | – | `TOOL_CALL_END`; the handler (or the human) is running |
| `complete` | complete `T` | string | handler returned, or `TOOL_CALL_RESULT` for a backend tool |

The component re-renders on every args delta, so a card fills in field by field
([useComponent: "Props arrive partial while the tool call streams"](https://docs.copilotkit.ai/reference/hooks/useComponent)).
Runtime args are JSON-parsed but **not validated** against the Zod schema.

### Pattern by pattern

| Pattern (v2 hook; v1 name) | Agent sends | UI at each stage |
|---|---|---|
| **Frontend tool** [`useFrontendTool`](https://docs.copilotkit.ai/reference/hooks/useFrontendTool) (v1 [`useCopilotAction`](https://docs.copilotkit.ai/reference/v1/hooks/useCopilotAction)) | A tool call to a tool the page advertised in `RunAgentInput.tools` | inProgress: e.g. "Fetching weather for {city}…" with a pulse; executing: handler runs in the browser with an `AbortSignal` tied to Stop; complete: result card. Options: `available: enabled/disabled/remote`, `reconnectBehavior: passive/resume-pending` (re-run an unanswered call after reload), `webmcp` (also expose to browser agents via `document.modelContext`). |
| **Component as tool** [`useComponent`](https://docs.copilotkit.ai/reference/hooks/useComponent), [guide](https://docs.copilotkit.ai/generative-ui/tool-based) | Tool call whose args are the component's props | The component itself, mounted at `TOOL_CALL_START`, props filling in as args stream. `followUp: false` stops the agent after drawing. |
| **Backend tool rendering** [`useRenderTool`](https://docs.copilotkit.ai/reference/hooks/useRenderTool), [`useDefaultRenderTool`](https://docs.copilotkit.ai/reference/hooks/useDefaultRenderTool) | `TOOL_CALL_*` + `TOOL_CALL_RESULT` for a tool that ran on the server | Named renderer, or the `"*"` wildcard. The built-in default is an expandable card: status, tool name + main argument, opening to args and result. `render: () => null` hides a tool. Renderers are kept after unmount so history still draws. |
| **Human in the loop (tool form)** [`useHumanInTheLoop`](https://docs.copilotkit.ai/reference/hooks/useHumanInTheLoop) (v1 `renderAndWaitForResponse`) | A tool call with no handler | inProgress: "Preparing confirmation…"; executing: the card gets `respond(result)`, e.g. Delete/Cancel buttons or a form; complete: "Items deleted." The run waits until `respond` is called. |
| **Interrupt (agent pauses itself)** [`useInterrupt`](https://docs.copilotkit.ai/reference/hooks/useInterrupt) (v1 [`useLangGraphInterrupt`](https://docs.copilotkit.ai/reference/v1/hooks/useLangGraphInterrupt)) | `RUN_FINISHED` with `outcome.type: "interrupt"` and `interrupts[]` (`{id, reason, message?, toolCallId?, responseSchema?, expiresAt?}`); legacy: `CUSTOM on_interrupt` | Card in the chat (or returned for manual placement, `renderInChat: false`) with `resolve(payload)` / `cancel()`. Resume = a new run on the same thread with `resume[].interruptId`; waits for every open interrupt; expired ones refused. See AG-UI [interrupt-resume](https://docs.ag-ui.com/spec/1.0/basic/patterns/interrupt-resume.md). |
| **State rendering** [`useAgent`](https://docs.copilotkit.ai/reference/hooks/useAgent) + [state rendering](https://docs.copilotkit.ai/generative-ui/state-rendering) (v1 [`useCoAgentStateRender`](https://docs.copilotkit.ai/reference/v1/hooks/useCoAgentStateRender), per `nodeName`) | `STATE_SNAPSHOT` / `STATE_DELTA` (RFC 6902) | Any component reading `agent.state` re-renders; progress ("Researching 2/5"), drafts, dashboards, inside or outside chat. `StateStreamingMiddleware` maps a tool argument into a state key **per token** so a document assembles live. |
| **Shared state (two-way)** [shared state](https://docs.copilotkit.ai/shared-state) | Agent: snapshot/delta. UI: `agent.setState(...)`, sent with the next run | Both sides edit one object (dojo recipe demo). |
| **Reasoning** [reasoning](https://docs.copilotkit.ai/generative-ui/reasoning) | `REASONING_START/MESSAGE_*/END` | "Thinking…" with a pulsing dot, expanded live as Markdown, collapses to "Thought for X seconds" with a chevron. Replaceable via the `reasoningMessage` slot. |
| **Activity messages** (AG-UI [activity](https://docs.ag-ui.com/spec/1.0/events/activity.md)) | `ACTIVITY_SNAPSHOT` / `ACTIVITY_DELTA` (JSON Patch) with an open `activityType` and a `messageId` | A non-text message that keeps its place in the transcript (web search progress, checklist, A2UI surface, MCP App, retry hint). [`useRenderActivityMessage`](https://github.com/CopilotKit/CopilotKit/blob/main/packages/react-core/src/v2/hooks/use-render-activity-message.tsx). |
| **A2UI, declarative** [A2UI](https://docs.copilotkit.ai/generative-ui/a2ui): [fixed schema](https://docs.copilotkit.ai/generative-ui/a2ui/fixed-schema), [dynamic schema](https://docs.copilotkit.ai/generative-ui/a2ui/dynamic-schema) | A2UI operations (`createSurface`, `updateComponents`, `updateDataModel`) as a tool result or streamed tool args; middleware turns them into activity events | Fixed: the surface appears instantly when the tool returns (only data is generated). Dynamic: a secondary LLM writes the tree; cards render progressively as items arrive. Catalog = `definitions.ts` (Zod + description, sent to the LLM) + `renderers.tsx` + `createCatalog(..., {includeBasicCatalog: true})`. |
| **"Generative UI" standard catalog** (new, experimental; dojo `generative_ui_tool` / `generative_ui_markdown`) | Runtime injects a **`render_ui` tool** (`transport: "tool"`) or asks for ```` ```a2ui ```` fences in Markdown (`transport: "markdown"`); A2UI 1.0 operations | Each complete operation renders as soon as it arrives; the server validates each one and reports rejects back to the model. A not-yet-streamed child renders **nothing**, not a grey box ([boundaries.tsx](https://github.com/CopilotKit/CopilotKit/blob/main/packages/react-core/src/v2/generative-ui/boundaries.tsx): "A grey block in its place would read as a broken layout"). Per-node error boundary with Retry. `GenerativeUISurface` = a named place on the page (not the chat) the agent may render into, with a `fallback`. |
| **Open Generative UI** [docs](https://docs.copilotkit.ai/generative-ui/open-generative-ui) | Tool `generateSandboxedUi` streaming HTML/CSS/JS | Sandboxed iframe: styles apply first, HTML streams in progressively, then JS expressions run one by one; may load Chart.js/D3/Three via CDN; optional `sandboxFunctions` for two-way calls. |
| **MCP Apps** [docs](https://docs.copilotkit.ai/generative-ui/mcp-apps) | An MCP tool with an attached UI resource (`MCPAppsMiddleware`, HTTP or SSE transport) | The server's HTML in a sandboxed iframe in the chat, zero frontend code; stored in thread history and restored on reconnect (needs a stable `serverId`). |

The AG-UI [Generative UI draft](https://docs.ag-ui.com/drafts/generative-ui.md) adds a two-step idea: the main agent
calls a light `generateUserInterface(description, data, output)` tool and a dedicated UI generator builds the UI
(OpenAI's 1024-char tool-description limit and weak `oneOf`/`$ref` support are the stated reasons).

---

## 2. Polish details

**Chat shells** ([prebuilt components](https://docs.copilotkit.ai/prebuilt-components)): `CopilotChat` (inline),
`CopilotSidebar` (collapsible, wraps content), `CopilotPopup` (floating bubble); all the same view. Plus
`CopilotThreadsDrawer` (thread list; needs a paid licence when self-hosted, otherwise shows a locked view).

**Message list** ([CopilotChatMessageView](https://docs.copilotkit.ai/reference/components/CopilotChatMessageView)):
- Typing cursor: a pulsing dot after the last message while `isRunning` (`cursor` slot).
- Virtualized rows (`@tanstack/react-virtual`, above ~50 messages), `transformMessages` and `groupMessages` hooks.
- **Tool-call display modes** (`toolCallDisplay`): `grouped` (default: consecutive calls collapse into one card,
  "Used 3 tools · run_command ×2, read_file", naming the running one), `line` (quiet text like "Thought for 4s"),
  `stacked` (latest on top, click fans out), `turn` ("Working" line with a timer; narration fades to muted once a call
  follows; at the end everything folds into "Worked for 9s" leaving only the reply), `separate`.
- Auto-scroll: `use-stick-to-bottom`, `autoScroll` prop, a **scroll-to-bottom button** when scrolled up, a **feather**
  (gradient fade at the bottom of the scroll area) ([slots](https://docs.copilotkit.ai/custom-look-and-feel/slots)).
- `connectingIndicator` spinner while a thread's history is restored; `welcomeScreen` when empty (gets `input` and
  `suggestionView` to lay out).

**Assistant message** ([CopilotChatAssistantMessage](https://docs.copilotkit.ai/reference/components/CopilotChatAssistantMessage)):
Markdown via Streamdown with GFM tables, KaTeX math, syntax-highlighted code (`rehype-pretty-code`/Shiki) with copy;
toolbar with **copy, thumbs up/down (with a comment box), read aloud, regenerate**, each shown only when its callback
exists; the toolbar is hidden on the latest message while it streams.

**User message** ([CopilotChatUserMessage](https://docs.copilotkit.ai/reference/components/CopilotChatUserMessage)):
right-aligned, `pre-wrap`, **edit**, **branch navigation** ("2/3") when a message was regenerated.

**Input** ([CopilotChatInput](https://docs.copilotkit.ai/reference/components/CopilotChatInput)): auto-growing textarea
(to 5 rows) that switches to a stacked layout when multi-line; send turns into a **Stop** button while running
(Stop aborts the run and the handlers' `AbortSignal`); voice mode with a live waveform recorder; attach-file button;
a `toolsMenu` with nested submenus and separators; mobile keyboard height tracking (`use-keyboard-height`).

**Suggestions** ([useConfigureSuggestions](https://docs.copilotkit.ai/reference/hooks/useConfigureSuggestions)):
chips above the input. Static `{title, message}` or dynamic (`instructions`, min/max 1–3, generated by an agent);
`available: before-first-message | after-first-message | always`; per-chip loading state.

**Errors**: `onError` on provider and chat with codes like `agent_connect_failed`; `RUN_ERROR` banner pattern in the
dojo `error_flow` demo (category + correlation ids, raw exception kept server-side; cleared on next `RUN_STARTED`);
per-node error boundary with Retry inside generated UI; A2UI recovery (below).

**Theming**: slot system everywhere: each slot takes a replacement component, a `className` (Tailwind, merged with
`twMerge`), or a partial props object, plus a `children` render-prop for whole layouts; CSS variables and shadcn design
tokens ([CSS customization](https://docs.copilotkit.ai/custom-look-and-feel/css));
labels object for every string; generated UI styled by `--a2ui-*` variables with built-in dark values under `.dark`.

**Dev tooling**: the CopilotKit Inspector (event stream viewer, localhost only), the
[A2UI Composer](https://a2ui-composer.ag-ui.com/) gallery/editor.

Note what CopilotKit does **not** emphasise: motion. Animations are Tailwind `animate-pulse` / `animate-bounce`
examples; there is no spring/morph system. Users asked for smoother token rendering
([#1871 "chunky rendering of streaming tokens"](https://github.com/CopilotKit/CopilotKit/issues/1871)).

---

## 3. The AG-UI dojo

Live at [dojo.ag-ui.com](https://dojo.ag-ui.com); feature list in
[`apps/dojo/src/config.ts`](https://github.com/ag-ui-protocol/ag-ui/blob/main/apps/dojo/src/config.ts), each demo run
against every integration (LangGraph, Mastra, CrewAI, ADK, Strands, Pydantic AI, …). Event types from the reference
servers in `integrations/server-starter-all-features/python/examples/example_server/`.

| Demo (id) | What it shows | Events exercised |
|---|---|---|
| Agentic Chat (`agentic_chat`) | Chat + a frontend tool `change_background` that restyles the page | TEXT_MESSAGE_START/CONTENT/END, TOOL_CALL_START/ARGS/END, MESSAGES_SNAPSHOT |
| Backend Tool Rendering (`backend_tool_rendering`) | A server tool (weather) drawn as a card in chat | TOOL_CALL_* + TOOL_CALL_RESULT, text |
| Human in the loop (`human_in_the_loop`) | Agent proposes steps (`generate_task_steps`); user ticks/unticks checkboxes, "Execute Plan"; agent adapts to missing steps | TOOL_CALL_START/ARGS/END (frontend tool, no handler), text |
| Interrupt (`interrupt`) | Backend tool suspends mid-run to ask for a meeting time; in-chat time picker; resume | RUN_FINISHED `outcome: interrupt` (or CUSTOM `on_interrupt`), resume run |
| Tool Approval (`tool_approval`) | Backend tool `record_expense` needs Approve/Reject before it runs | RUN_FINISHED interrupt, resume, TOOL_CALL_RESULT |
| Agentic Generative UI (`agentic_generative_ui`) | Long task: a step list whose items tick through pending → done live | STATE_SNAPSHOT then a stream of STATE_DELTA (JSON Patch on `/steps/i/status`) |
| Tool Based Generative UI (`tool_based_generative_ui`) | Haiku generator; each haiku is a styled card from the tool args | TOOL_CALL_* (args streamed into the card), MESSAGES_SNAPSHOT |
| Shared State (`shared_state`) | Recipe card both user (skill, time, ingredients controls) and agent edit | STATE_SNAPSHOT both ways (state in RunAgentInput) |
| Predictive State Updates (`predictive_state_updates`) | Document editor: agent's rewrite appears character by character with green/red diff, then a `confirm_changes` accept/reject card | CUSTOM `PredictState` (`[{state_key:"document", tool:"write_document", tool_argument:"document"}]`), TOOL_CALL_ARGS mapped to state, HITL tool |
| Agentic Chat Reasoning / Citations / Multimodal | Thinking card; answers carrying source chips; image input | REASONING_*, text with source metadata, multimodal user content |
| Subgraphs / Multi-Agent / Deepagents Subagents | Supervisor hands work to specialists; subagent messages grouped under one card keyed by `subagentRunId`, pausing for approval | STEP_STARTED/FINISHED, SUBAGENT_STARTED/FINISHED/ERROR, interrupts |
| A2UI Fixed / Dynamic / Advanced / Recovery | Fixed-schema flight cards; LLM-generated surfaces; custom progress renderer + action handlers; invalid surface regenerated without a flash, clean hard-failure after 3 tries | ACTIVITY_SNAPSHOT/DELTA carrying A2UI operations, `a2ui_recovery` activity |
| Generative UI (Tool) / (Markdown) | Runtime-injected `render_ui` tool, or ```` ```a2ui ```` fences; "Show my budget as a chart", "Compare three laptops in a table" | TOOL_CALL_ARGS (operations streamed), context entries carrying the catalog |
| Background Agents | Long Mastra task progress as its own activity | ACTIVITY_* |
| Error Flow | Backend raises; categorised error banner | RUN_ERROR |
| A2A Chat, VNext Chat, Crew Chat, Observational Memory | Transport/framework variants | – |

---

## 4. A2UI (Google)

Yes, CopilotKit supports it: runtime `a2ui: {}` adds `A2UIMiddleware`; the renderer is `@copilotkit/a2ui-renderer`
([CopilotKit A2UI](https://docs.copilotkit.ai/generative-ui/a2ui)). Spec site [a2ui.org](https://a2ui.org), repo
[google/A2UI](https://github.com/google/A2UI). JSON Lines, one self-contained message per line, transport-agnostic
(A2A, AG-UI, SSE, WebSocket) ([data flow](https://github.com/google/A2UI/blob/main/docs/public/concepts/data-flow.md)).

**Server → client messages**

| v0.8 | v0.9 / 1.0 | Meaning |
|---|---|---|
| `surfaceUpdate {surfaceId, components[]}` | `createSurface {surfaceId, catalogId, sendDataModel?}` then `updateComponents {surfaceId, components[]}` | Define/replace components (a flat list with ids; parents reference child ids) |
| `dataModelUpdate {surfaceId, contents[]}` (typed `valueString`/`valueMap`…) | `updateDataModel {surfaceId, path, value}` | Set data at a JSON Pointer |
| `beginRendering {surfaceId, root}` | (implicit: render once the root exists) | Start drawing; lets the client buffer before first paint |
| `deleteSurface {surfaceId}` | `deleteSurface` | Remove |

**Client → server**: `action {name, surfaceId, context}` (v0.9: `{"event": {"name", "context"}}` on the Button), the
context's `{path}` values resolved at click time; `VALIDATION_FAILED` errors back to the agent when it sent JSON
that breaks the catalog; with `sendDataModel: true` the whole data model rides along on each outgoing message
([actions](https://github.com/google/A2UI/blob/main/docs/public/concepts/actions.md)).

**Data binding** ([data binding](https://github.com/google/A2UI/blob/main/docs/public/concepts/data-binding.md)):
structure (components) and state (data model) are separate. Any prop is a literal or `{"path": "/user/name"}`
(RFC 6901 JSON Pointer; v0.8 wrapped literals as `{literalString}`). Changing data re-renders bound components, no
component update needed. Lists use a template: `children: {template: {dataBinding: "/products", componentId:
"product-card"}}`, with paths **scoped to the item** inside. Inputs bind two-way (TextField `value`, CheckBox `value`,
Slider, ChoicePicker, DateTimeInput write to their path). Inputs may carry `checks` (validation). Text interpolation
only via `formatString("Hello ${/user/name}")`. Performance advice in the spec: batch updates per 16 ms frame, diff
components, send granular paths.

**Basic catalog** ([catalog.json](https://github.com/google/A2UI/blob/main/catalogs/basic/v1/catalog.json), v1.0, 18):
Text (variant h1–h5/caption/body), Image (fit, variant avatar/icon/feature/header), Icon, Video, AudioPlayer, Row,
Column (justify, align), List (direction), Card (one child), Tabs, Modal (trigger, content), Divider (axis), Button
(child, variant primary/borderless, action), TextField (label, value, variant short/long/number/obscured), CheckBox,
ChoicePicker (options, multi/single, chips, filterable; v0.8 `MultipleChoice`), Slider (min, max, steps),
DateTimeInput (enableDate, enableTime, min, max). Catalog **functions**: required, regex, length, numeric, email,
formatString, formatNumber, formatCurrency, formatDate, pluralize, openUrl, and, or, not.

**CopilotKit's own "standard UI" catalog** (68 components,
[`generative-ui/standard`](https://github.com/CopilotKit/CopilotKit/tree/main/packages/react-core/src/v2/generative-ui/standard)),
the one its `render_ui` tool uses, is much larger than A2UI's basic catalog:
- layout: Box Column Row Grid GridItem Card Flow FlowItem Carousel CarouselItem CarouselMediaItem Spacer Divider Tabs
- text: Title Text Caption Label Bold Italic Underline Strikethrough Badge Blockquote Code Markdown Math ShimmerText Link Tooltip
- inputs: Button Pressable Form TextField TextArea Select CheckBox Radio RadioGroup Slider SegmentedControl ChoicePicker DateTimeInput
- feedback: PulseIndicator FlashcardFlip Popover PopoverTrigger PopoverContent Modal
- data: Table TableSection TableRow TableCell List ListItem **Chart** (bar line area scatter pie donut; horizontal, dots, bar radius) **Map**
- media: Image Icon Favicon Svg Video AudioPlayer HtmlView
- composites: LinkCard Citation FollowUp EntityCard ImageGrid

Each component has a positional "parameter order" (a compact calling form for the model), `extends`/`omit`/`overrides`
to compose catalogs, and the catalog is serialised into the agent's context so the model knows what exists.

---

## 5. Known limits and complaints (where we can win)

- **Bundle weight.** `@copilotkit/react-core` added ~15 MB to a production bundle through non-tree-shakeable deps
  ([#4893](https://github.com/CopilotKit/CopilotKit/issues/4893)); barrel file pulled mermaid, shiki, streamdown
  ([#3653](https://github.com/CopilotKit/CopilotKit/issues/3653)); full Prism, ~214 kB gzip, on first load even with no
  code block ([#7423](https://github.com/CopilotKit/CopilotKit/issues/7423), open); bundle explosion in v1.5+
  ([#3225](https://github.com/CopilotKit/CopilotKit/issues/3225)). Deps include KaTeX, Streamdown, Shiki, TanStack
  Virtual, use-stick-to-bottom, Zod.
- **Re-render cost while streaming.** `useAgent` forced a React update on every AG-UI event, so the scroll jumped on
  every token ([#3499](https://github.com/CopilotKit/CopilotKit/issues/3499)); `useInterrupt` re-renders
  ([#6934](https://github.com/CopilotKit/CopilotKit/issues/6934)); message fingerprint memo misses in-place mutation,
  so activity/tool messages did not redraw ([#6327](https://github.com/CopilotKit/CopilotKit/issues/6327),
  [#4676](https://github.com/CopilotKit/CopilotKit/issues/4676)); random keys in CodeBlock flickered
  ([#2669](https://github.com/CopilotKit/CopilotKit/issues/2669)).
- **Long threads.** Message view freezes mid-run in long multi-tool runs, state still flowing
  ([#6301](https://github.com/CopilotKit/CopilotKit/issues/6301), open); sending in a virtualized thread jumps the view
  up 10–20 messages, then glides back over ~1.5 s, every time
  ([#7494](https://github.com/CopilotKit/CopilotKit/issues/7494), open); Vue deep-cloned run state 6× per row,
  84% of main thread, 12–76 s freezes ([#7507](https://github.com/CopilotKit/CopilotKit/issues/7507)); popup rescrolls
  from top on every resize ([#6172](https://github.com/CopilotKit/CopilotKit/issues/6172)).
- **State correctness.** `getStateByRun` lags one STATE_DELTA and keeps ghost keys after a shrinking snapshot
  ([#8193](https://github.com/CopilotKit/CopilotKit/issues/8193), opened today).
- **Platforms.** React first; Angular, Vue, React Native and web-components packages exist but trail: A2UI does not
  render in React Native ([#5785](https://github.com/CopilotKit/CopilotKit/issues/5785)), RN streaming-fetch bugs
  ([#8099](https://github.com/CopilotKit/CopilotKit/issues/8099), [#7436](https://github.com/CopilotKit/CopilotKit/issues/7436)).
  No native desktop. Styling assumes Tailwind (the `cpk:` prefix left Markdown unstyled for non-Tailwind users,
  [#5072](https://github.com/CopilotKit/CopilotKit/issues/5072)).
- **Schema trust.** Tool args are not validated against the schema at run time; an A2UI prop declared as a plain
  `z.string()` but sent as `{path}` crashes React with error #31 (fixed-schema page). Validation exists only on the
  server path for the new `render_ui`.
- **Commercial edges.** Threads drawer, Intelligence (memory, learning, analytics) need a licence token or cloud key;
  a "Powered by CopilotKit" banner reserves space above the input when the token is missing or invalid.
- **Motion.** No spring/morph layer; token rendering called "chunky" ([#1871](https://github.com/CopilotKit/CopilotKit/issues/1871)).

### Where omxcode stands against this (from `docs/agui.md`)
Has: AG-UI client with text, tool calls, state snapshot/delta (atomic JSON Patch, refused deltas reported), messages
snapshot, steps, custom; frontend tools; a validated `render_ui` with 13 components, refusal messages back to the
agent, caps (depth 8, 200 components, 32 KB), two-way `bind` to state paths, button `action`s.
Missing relative to CopilotKit: REASONING_* and ACTIVITY_* (counted and ignored today); interrupts
(`RUN_FINISHED.outcome`, resume); rendering `render_ui` from **partial** args while TOOL_CALL_ARGS stream; the
three-state renderer contract for arbitrary tools and a default tool card with grouping; Chart/List-template/Tabs/
Modal/Select/DateTime/Image/Markdown/Code components; suggestions, message toolbar (copy/regenerate/thumbs/edit/
branches), stop button wired to abort, scroll-to-bottom + feather, reasoning card, A2UI wire compatibility.
