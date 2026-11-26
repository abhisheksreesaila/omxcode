# Where the clock stops: undo/redo on the Mac (c33, 2026-11-26, 12:37–12:58) — a diagnostic for the owner

Stress note, 144 Hz, the Mac unlocked and each window in front (locked=0 every native run; the web visible, focused, 143 Hz). Five runs each, p95 / max of 25 steps, ms. The race's rule is unchanged (D-8097); nothing here is a verdict.

| side | where the clock stops | undo | redo |
|---|---|---|---|
| web | benchmark-f034 as it is: a task after the next rAF (the frame begun, its script done; GPU and compositor not waited for) | 9.4/10.6, 9.1/10.0, 11.3/16.8, 9.0/10.1, 8.8/8.9 | 9.1/9.4, 8.8/9.0, 8.7/9.0, 7.5/8.5, 8.8/9.0 |
| web | the second rAF after the change (the frame after the one that drew it: about "shown") | 14.1/14.3, 15.8/16.0, 15.2/17.2, 16.0/16.1, 16.0/18.2 | 14.0/14.0, 14.0/16.0, 14.1/16.0, 14.2/15.6, 15.9/16.0 |
| native | the frame's own code done (the web's end point) | 3.1/11.9, 4.4/13.1, 4.3/6.6, 3.7/13.3, 4.4/8.4 | 8.2/8.8, 6.4/8.2, 6.6/7.2, 8.9/9.0, 7.7/10.2 |
| native | the picture handed to Core Animation after the GPU (the race's) | 5.0/13.1, 7.3/14.3, 6.7/7.8, 7.2/14.6, 7.1/9.6 | 12.2/12.2, 10.2/13.4, 9.4/13.0, 12.1/14.0, 11.8/15.3 |

Like with like: at the web's own end point native is ahead on undo (p95 3.1–4.4 against 8.8–11.3) and level-to-ahead on redo (6.4–8.9 against 7.5–9.1); at "about shown" native (race end point) is ahead on both (undo 5.0–7.3, redo 9.4–12.2 against 14.0–16.0). The race today compares native's later point with the web's earlier one. Which pair to judge by is the owner's call. Scripts: docs/goals/79/probe-c33-f034.mjs (SECOND_RAF=1), native MOJOUI_BENCH_SPLIT.
