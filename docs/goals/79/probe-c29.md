# Probe c29: is the Mac's stress undo/redo race asymmetric? (2026-11-25, 20:50–21:08)

**Not measured: the Mac's front window was a system notification dialog** (`lsappinfo front` = UserNotificationCenter, 20:59–21:07, ten checks a minute apart). The screen was unlocked (BENCHSTATE locked=0), but pnote's window never became active (active=0 key=0, twice), so mac-unlocked refused, rightly: a window behind a dialog isn't the race's state. Dismissing it is the owner's. Linux couldn't stand in: scripts/gpu-free said NO (another project's job, load 5).

| | what | stress undo p95 / max | stress redo p95 / max | first two steps |
|---|---|---|---|---|
| (a) | web, benchmark-f034 as it is | not run | not run | — |
| (b) | web, an idle pause of 1 s before undo and before redo (probe-c29-f034.mjs, PAUSE_MS=1000) | not run | not run | — |
| (c) | native as the race runs it | (c28, same code: 14.4 / 14.9 paced; work 4.6–7.8 / 5.0–13.2) | (c28: 17.7 / 18.4 paced; work 8.6–11.3 / 9.7–14.6) | (c28: 10–14 ms of work, later steps 2–3) |
| (d) | native kept awake through the pause | not built | not built | — |

**What reading the two benches found (no measurement needed):**
- The web's undo and redo rows run **no requestAnimationFrame loop**: benchmark-f034 times each of the 25 steps from the JS call (`leaferEdits.undo()`) to one rAF plus a setTimeout after it, in a page.evaluate loop. The suspected loop through the pause isn't there for these two rows (it is for the frame-gap rows: pan, zoom, drags, pen, typing).
- **The web has no pause:** its undo loop starts right after thirty mouse drags, and its redo loop straight after the undo loop's last step. Native's framebench ends each step by settling (until the host is idle, at most 1 s), and the test runner takes the step's picture before the next step starts. So native's first redo step comes after an idle Mac, and the web's after 25 busy steps. That's an asymmetry in state by construction. Whether it explains the loss is what (b) measures: (b) gives the web native's idle.
- The end points differ the other way: the web stops at a task after the rAF (the frame is begun, not shown); native at its picture handed over (shown). Native's end point is the later one.

**To run when the Mac's front is clear:** the probe script is docs/goals/79/probe-c29-f034.mjs (PN's benchmark-f034 with PAUSE_MS and each step's time printed, nothing else changed); put it in the Mac's omxcode-g79-web/pn/scripts/ and run, five times each, interleaved with native's `framebench:desk=undo,25;framebench:desk=redo,25` (race-stress.db, as c28):
`cd omxcode-g79-web/pn && PAUSE_MS=0|1000 node --import ./.g79/headed.mjs scripts/probe-c29-f034.mjs --gpu --dpr=1 --note=stress --only=undo`
