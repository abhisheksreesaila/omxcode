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

## The USP, measured (docs/agui.md "Benchmark", written from docs/goals/48/bench.json, 2026-11-04 03:36)
Same 2302-event stream, median of 3; both web runners in the same Chromium. This run was taken by the
checker while other worktrees' checks loaded the machine (load average ~16): an earlier quiet run had GTK 63 ms, web
128 ms, CopilotKit 516 ms to the final screen.

| | first UI | final screen | dropped frames, paced |
|---|---|---|---|
| omxcode native GTK | 31 ms | 126 ms | 0 |
| omxcode web host | 227 ms (loss) | 227 ms | 73 (loss) |
| CopilotKit 1.84.1 | 166 ms | 562 ms | 0 |

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
- The web host drops frames under a steady stream (each change swaps DOM; long chats make it big). Next fix.
- MapView is the offline map (route, places, scale): no streets, coast or tiles.
- CopilotKit was driven through its documented v1 frontend-tool render, not its new A2UI renderer; no A2UI wire support
  on our side yet.
- Scripted agents only; no live model was run. Not run on the Mac or phone.

## What's next
Make the web host patch only changed views (the dropped-frame loss), then A2UI messages on the same catalog.
