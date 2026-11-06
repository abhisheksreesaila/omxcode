# GOAL 48: AG-UI as good as CopilotKit, and faster

**End goal (owner, 2026-11-04):** "make sure AG-UI protocol support in MX app is as good, if not better than CopilotKit…
when I pick up a component, it's just so lovely, very nicely done. That is the level of polish… if I ask for a map I
should have a map… the existing components we have built we should be able to render… really, really good examples
using our components… a good USP compared to CopilotKit: our streaming is faster, ours is in process, we use GPUs."
Base: main 9ae87cb (goal 35's AG-UI: client, render_ui, 13 components). Research: docs/research/copilotkit.md.
Framework first: every generic piece goes in `mojoui/` with its own test; examples only compose.

## Milestones
| # | Milestone | Proof (`docs/goals/48-check.py`) |
|---|---|---|
| M0 | Every general component, by data | the genui catalog grows from 13 to ≥ 36 components, each the real mojoui component: layout (Card, VStack, HStack, Grid, Tabs, Divider, Spacer), words (Text, Paragraph, Markdown, CodeBlock, Chip, Alert, Skeleton), data (Table, DataGrid, ChartView bars/line/area, Sparkline, KpiView, Meter, ProgressBar, Timeline, MapView, Breadcrumbs, Icon), inputs (Button, TextField, TextArea, Toggle, Checkbox, Dropdown, Slider, Segmented, Radio, DatePicker), Confirm; docs/genui.schema.json regenerated; `tests/test_genui.mojo` renders every catalogued component from a sample node and refuses a bad prop for each (prints `catalog: ok N`); the app-only ones (workbook, video, OCR) stay out, listed in docs/agui.md |
| M1 | Streaming generative UI | while render_ui's args stream in, the UI builds piece by piece (a tolerant partial-JSON reader; parts not yet arrived show a Skeleton); every tool call (frontend or backend) has a status: in progress, executing, complete, with a tool card for backend calls; STEP events show as a live progress list; STATE_SNAPSHOT/DELTA re-render bound UI in place; `tests/test_agui_stream.mojo` (partial args at every byte cut parse or wait, never crash) and a GTK + web run of the `stream` scenario with ≥ 3 shots taken mid-stream that differ |
| M2 | Human in the loop | a frontend tool marked `confirm` shows an approve/reject card (what, why, the args) and runs nothing until answered; the answer goes back as the tool result; an interrupt (CUSTOM `interrupt`) shows a choice card and resumes the run with the pick; GTK + web, the agent receives each answer (SDK-validated RunAgentInput) |
| M3 | The chat, polished (mojoui.agentchat) | a framework `AgentChat` composite any app drops in (panel, sidebar, popup): streaming words as Markdown with code blocks and a copy action, a typing indicator, Stop (cancels the run), auto-scroll that yields when the reader scrolls up, suggestion chips (from the app or the agent's CUSTOM `suggestions`), message actions (copy, regenerate), an error state with Retry, new cards arrive on a spring (Liquid); `examples/agentchat` becomes a thin app over it; GTK + web shots in Liquid light and dark |
| M4 | Examples worth showing | ≥ 6 scripted scenarios, each built only from catalogued components, each run on GTK and the web with shots: a trip with a map (MapView: route, places), a sales dashboard (KPIs, a chart, a data grid), a booking form (date picker, dropdown, slider, radio; its values reach the agent), an approval (Confirm), a research plan (steps with live progress), a release note (Markdown, code, timeline); `docs/agui.md`'s gallery shows them; a person reading a shot can tell what it is |
| M5 | Faster, in process, GPU | (a) an in-process agent: `mojoui.agui` takes events from a Mojo `LocalAgent` (no HTTP, no Python) through the same handler; (b) a data reference: render_ui can bind a DataGrid/ChartView to a dataset the app holds (an MX frame query by name), so an agent shows 1M rows without sending them; (c) `scripts/agui_bench.py` replays one recorded stream (≥ 2,000 events: words, a 40-component dashboard streamed as args, state deltas) into omxcode GTK, omxcode web and a CopilotKit React app in the same Chromium, and writes docs/goals/48/bench.json: time to first paint of agent UI, time to the last event drawn, frames over 16 ms, peak memory; every loss stated in docs/agui.md |
| M6 | Nothing regressed | goal 35's checks (M0–M3) pass; `scripts/components.py` matrix fresh with the Agent column updated; docs/agui.md rewritten for the new pieces |

## Out of bounds
Pushing or merging into main; the frozen `../mojo-ui-apple-test`; pip; deleting .pixi; paid services, sign-ups or
keys (the live model path stays by hand); running agent-supplied code or pixels (UI stays data, catalog-only);
lowering a proof or editing a milestone to pass.

## Assumptions (taken instead of asking; the owner is asleep)
- "Map" = the existing offline MapView (route, places), not a tile server; no network tiles.
- "GPUs" = the data reference path (MX frame on the GPU when present) and GPU-drawn charts/grids; an in-process LLM is
  out of scope (omxconsole's engine is Python, D-4735); the in-process agent is a Mojo agent function, scripted.
- The CopilotKit comparison uses its open-source React packages from npm, no Copilot Cloud, no key; the same stream is
  replayed to both through a local AG-UI endpoint. If CopilotKit can't be made to consume it, M5(c) reports why with
  evidence and benchmarks against a minimal React renderer instead (stated as such).
- Scripted agents drive every check; the live-model path is unchanged and unverified here.

## Budget
150 turns. Done means: 48-check PASS for M0–M6; the reviewer passes it; docs/report.md short with shots.
