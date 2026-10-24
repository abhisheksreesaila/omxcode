# GOAL 30: the island, and 100 million rows that never freeze the window

**Why (owner, 2026-10-21):** "dynamic island 100M demo is the sexiest demo." Today a median over 100M rows holds the
window for 0.69 s and a month chart for 0.48 s (docs/goals/29/bench.txt). MX frame **23edc59** (STABLE.md) runs a query
as a `Job` on its own thread, with progress and cancel. The island (D-255, direction B: a pill where the document and
GPU chips are, tinted by state) shows that work while the window stays live, and the chart moves to its answer when it
lands.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | The new engine, everywhere | vendor/MXFRAME_COMMIT says 23edc59; omxplorer and every example build for Linux, the web, Mac and iPhone (their platforms lists); a chart computed through a job equals the same chart computed in place, for 6 specs (tests/test_chart_job.mojo) |
| M1 | Queries off the window | at 100M rows in memory on GTK, opening the file (added: D-276), then picking Median, then By month: the window keeps drawing while each job runs (no gap between frames over 50 ms, traced), the chart's figures equal the in-place answer, and a second pick while the first runs cancels it (only the newest lands); the status bar's figures for a selected column at 100M come from a job too |
| M2 | `Island`, a component | `mojoui/island.mojo` with its own test: states idle, running (progress 0–1, a rate), done, undo (a countdown), error; the capsule's width, height and radius move to a new state's size over 320 ms on the calm curve, the face cross-fades, at once when less motion is asked; its actions are hit areas; drawn on a Canvas, so GTK and the web draw the same (pixel check of each state on both); in docs/components.md |
| M3 | omxplorer wears the island | the document and GPU chips and the toasts are gone; a running query reads "Median of revenue by region · 43%" with a rate; done reads "✓ 0.69 s on <GPU>" and returns to idle after 4 s; an edit shows Undo, and tapping it undoes; an error stays until seen; tapping the island opens its panel: the document, Recent (each operation with its time, Undo on the undoable) and Device (GPU, the last 12 timings, p50 and p95); GTK and the web |
| M4 | The 100M demo | `scripts/clips.py island` records the native window over 100M rows: open, ask "median by region", the island runs and lands, the bars move, then "by month, as a line"; a still beside it (docs/img/clip-island-100m.mp4, .jpg); each frame of the clip that shows the island running also shows the window responding (the cursor blinks in the ask field) |
| M5 | Nothing regressed | goal 29's checks (M0–M5; every earlier goal inside them) |

## Out of bounds
Tiling, tile defaults and the jitter on a combine switch (goal 31's draft: docs/goals/31-draft.md); the twin island and
the agent's state (direction C, when the agent ships); a Mac title-bar island (Mac builds; jobs run serially there unless
built threaded); the web host's own threads (the web runs the native binary: its jobs are the server's); pushing.

## Assumptions (instead of asking)
- 100M rows means build/data/orders_100m (goal 29's bench file), in memory on this machine's RTX 3090.
- The island polls its jobs on its own Canvas's frames (`on_frame`) while something runs: no new host timer.
- "Never freezes" is a 50 ms frame gap at most while a job runs (the engine's own work on the UI thread, such as
  handing the result over, can take a frame or two; 16 ms everywhere is goal 31's).

## Done means
PASS for M0–M5, the reviewer passes it, a short `docs/report.md`; merged into main locally. Budget: 80 turns.
