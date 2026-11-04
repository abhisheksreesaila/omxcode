# Goal 48 report: AG-UI as good as CopilotKit, and faster

**End goal (owner, 2026-11-04):** AG-UI support at CopilotKit's level of polish, every existing component usable by an
agent ("if I ask for a map I should have a map"), really good examples built from our components, and a USP: faster
streaming, in process, GPUs. Worktree `../mojo-ui-g48`, branch `goal-48-agui` (off main 9ae87cb). Not merged, not pushed.

## How far it got
`scripts/check` (docs/goals/48-check.py; build/check-goal48.log):

| # | Milestone | Result |
|---|---|---|
| M0 | Every general component, by data: catalog 13 → 36, each rendered and refused in tests | PASS |
| M1 | Streaming generative UI: drawn while render_ui's args stream, Skeletons, tool stages, steps, state | PASS |
| M2 | Human in the loop: confirm tools (approve/reject), interrupts that resume the run | PASS |
| M3 | AgentChat: Markdown + code Copy, typing, Stop, Retry, Regenerate, suggestions, springs, panel/sidebar/popup | PASS |
| M4 | Six examples on GTK and the web (trip with a map, dashboard, booking, approval, research, release) | PASS |
| M5 | In process (LocalAgent), 1M-row datasets an agent never sends (GPU), benchmark vs CopilotKit | PASS |
| M6 | Goal 35's checks, the component matrix, docs/agui.md | PASS |

## 30-second demo
```bash
cd ../mojo-ui-g48
scripts/agentchat.sh                      # the scripted agent + the chat on GTK; try the chips, or type:
                                          #   "Plan a day in Lisbon", "Chart a million orders", "Refund order 1042"
pixi run python scripts/agui_gallery.py   # every example, tall shots on GTK and the web (docs/goals/48/ex-*-tall-*.png)
pixi run python scripts/agui_bench.py     # the benchmark → docs/goals/48/bench.json
```
Shots: docs/agui.md's Gallery (trip, dashboard, booking, approval, research, release, streaming, catalog) and
build/g48-orders.png (a million rows, charted in 0.3 ms on the GPU, nothing sent by the agent).

## The USP, measured (docs/agui.md "Benchmark", written from docs/goals/48/bench.json, 2026-11-04 07:39)
Same 2302-event stream, median of 3; both web runners in the same Chromium. Re-run after the web host's frame fix
(D-4747); the goal's own run (03:36, a loaded machine) had the web host at 73 dropped frames paced.

| | first UI | final screen | dropped frames, burst | dropped frames, paced |
|---|---|---|---|---|
| omxcode native GTK | 12 ms | 69 ms | 2 | 0 |
| omxcode web host | 125 ms | 164 ms | 0 | 0 |
| CopilotKit 1.84.1 | 129 ms | 565 ms | 3 (worst 233 ms) | 0 |

Plus what CopilotKit doesn't do here: an agent in the app's own process (2,004 events in 26 ms), a chart over a million
rows the agent never sends (0.3 ms on the GPU), the same app native and on the web.

## Three decisions worth a second look
- **D-4744** datasets are a `Hub` trait the agent UI is generic over (MX frame's `SheetHub` in its own module): the first
  version put the engine inside genui and every app had to link it.
- **D-4741** GTK draws Lucide icons before the old Adwaita mapping (check, calendar, search, star, heart, home change on
  GTK in older apps too; they drew image-missing on the checks' display).
- **D-4745** the example offers render_ui itself and AgentChat's developer mode keeps the "streamed: N pieces" line, so
  goal 35's archived checks pass unchanged.

## Review
Reviewer round 1: NEEDS WORK (a crash cutting non-ASCII agent text, a quadratic partial-JSON path a hostile agent could
use to freeze the UI, docs numbers older than bench.json, a stopped stream's preview loading forever, the web replaying
.arrive() on every swap: 86 replays for 2 views); all fixed with tests. Round 2: PASS (deferred, non-blocking: a preview group-by cache, MAX_UIS never freed, sampledata
living in mojoui, the M0/M1 proofs only partly strengthened).

## Honest limits
- ~~The web host drops frames under a steady stream~~ fixed after the goal (D-4747): the cause was the page script
  running five hooks per swapped element (2,722 `whole()` calls in one reply), not the DOM swaps; now 0 dropped frames
  in both runs (CopilotKit: 3 in the burst). Full-screen swaps on a shape change remain (two 17 ms style passes).
- MapView is the offline map (route, places, scale): no streets, coast or tiles.
- CopilotKit was driven through its documented v1 frontend-tool render, not its new A2UI renderer; no A2UI wire support
  on our side yet.
- Scripted agents only; no live model was run. Not run on the Mac or phone.

## What's next
A2UI messages on the same catalog; then the web host patching only changed views on a shape change (no longer a measured loss).
