# Probe c29 (run as c30, 2026-11-26 10:13–10:18): is the Mac's stress undo/redo race asymmetric? (2026-11-25, 20:50–21:08)

**Not measured: the Mac's front window was a system notification dialog** (`lsappinfo front` = UserNotificationCenter, 20:59–21:07, ten checks a minute apart). The screen was unlocked (BENCHSTATE locked=0), but pnote's window never became active (active=0 key=0, twice), so mac-unlocked refused, rightly: a window behind a dialog isn't the race's state. Dismissing it is the owner's. Linux couldn't stand in: scripts/gpu-free said NO (another project's job, load 5).

| | what | stress undo p95 / max | stress redo p95 / max | first two steps |
|---|---|---|---|---|
| (a) | web, benchmark-f034 as it is | not run | not run | — |
| (b) | web, an idle pause of 1 s before undo and before redo (probe-c29-f034.mjs, PAUSE_MS=1000) | not run | not run | — |
| (c) | native as the race runs it | (c28, same code: 14.4 / 14.9 paced; work 4.6–7.8 / 5.0–13.2) | (c28: 17.7 / 18.4 paced; work 8.6–11.3 / 9.7–14.6) | (c28: 10–14 ms of work, later steps 2–3) |
| (d) | native kept awake through the pause | not built | not built | — |

## Run (c30, 2026-11-26 10:13–10:18): the Mac's front Finder, pnote active=1 key=1 locked=0 every native run, the web visible and focused at 143 Hz; five interleaved rounds under one flock (raw: probe-c30-raw.txt)

p95 / max of 25 steps, ms (the web's: benchmark-f034's own "to the frame after"; native's: the race's paced latency, key to picture handed over)

| | round 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| (a) web undo, no pause | 8.7 / 8.7 | 7.6 / 11.4 | 10.7 / 14.2 | 9.4 / 9.5 | 11.5 / 18.5 |
| (a) web redo, no pause | 8.6 / 9.2 | 7.1 / 7.1 | 8.6 / 8.6 | 8.9 / 8.9 | 9.1 / 9.1 |
| (b) web undo, 1 s idle first | 8.6 / 10.2 | 8.7 / 10.2 | 8.8 / 8.8 | 9.5 / 9.6 | 8.5 / 8.8 |
| (b) web redo, 1 s idle first | 8.6 / 8.6 | 8.6 / 8.7 | 7.1 / 7.3 | 8.8 / 8.9 | 7.0 / 7.3 |
| (c) native undo | 11.6 / 14.9 | 13.6 / 15.0 | 16.8 / 17.7 | 13.3 / 15.1 | 12.3 / 12.4 |
| (c) native redo | 14.8 / 15.8 | 15.7 / 16.0 | 15.9 / 17.9 | 15.1 / 17.0 | 12.6 / 14.5 |
| (d) native kept awake | not built (not cheap: a host change and a Mac build; (b) answered the question) | | | | |

First two steps, the web after 1 s idle: 0.8–1.2 then 5.9–10.2 ms (its first rAF comes at once on an idle display); without the pause 4.0–6.0 then 4.9–8.4.

**Decision (D-8098):** the pause is not the asymmetry: the web is as fast after a 1 s idle as without one. Native's undo/redo are slower in this measure (p95 11.6–16.8 against the web's 7.0–11.5). The two still end at different points: the web at the task after its frame's rAF (its CPU work done, its GPU and compositor not waited for), native when its picture is handed to the screen (after its GPU). Next: native timed to the web's end point as well (its frame's CPU done), beside the stricter one, to split end point from work; and the generic native cost looked for in mojoui. The tie rule and thresholds unchanged.

**What reading the two benches found (no measurement needed):**
- The web's undo and redo rows run **no requestAnimationFrame loop**: benchmark-f034 times each of the 25 steps from the JS call (`leaferEdits.undo()`) to one rAF plus a setTimeout after it, in a page.evaluate loop. The suspected loop through the pause isn't there for these two rows (it is for the frame-gap rows: pan, zoom, drags, pen, typing).
- **The web has no pause:** its undo loop starts right after thirty mouse drags, and its redo loop straight after the undo loop's last step. Native's framebench ends each step by settling (until the host is idle, at most 1 s), and the test runner takes the step's picture before the next step starts. So native's first redo step comes after an idle Mac, and the web's after 25 busy steps. That's an asymmetry in state by construction. Whether it explains the loss is what (b) measures: (b) gives the web native's idle.
- The end points differ the other way: the web stops at a task after the rAF (the frame is begun, not shown); native at its picture handed over (shown). Native's end point is the later one.

**To run when the Mac's front is clear:** the probe script is docs/goals/79/probe-c29-f034.mjs (PN's benchmark-f034 with PAUSE_MS and each step's time printed, nothing else changed); put it in the Mac's omxcode-g79-web/pn/scripts/ and run, five times each, interleaved with native's `framebench:desk=undo,25;framebench:desk=redo,25` (race-stress.db, as c28):
`cd omxcode-g79-web/pn && PAUSE_MS=0|1000 node --import ./.g79/headed.mjs scripts/probe-c29-f034.mjs --gpu --dpr=1 --note=stress --only=undo`
