# Goal 77 report: omx shows and points (M7: the Stage)

**Update 2026-11-22: done and merged (main 9c47cc75).** The ring measures were re-based on the ring's own rect (owner: "yes"); themes are built once per scheme (D-7889), after which 32 of 32 picture runs were clean (the crash's root cause is still open); the final M7F on the merged tree passed (G72 M3–M6, G77 M1–M6, four picture runs, 77-check M7F; build/g77/final-proof/, docs/journal.md 2026-11-22); the Stage then ran on the owner's M4 after two Apple-host fixes (D-7893, D-7894). The rest of this report is the 2026-11-19 state.

**State (2026-11-19 evening):** M0–M6 passed earlier (commit 057460f4). M7a–M7e PASS. M7f FAIL on two points that need the owner (below). Not merged to main, not pushed (reviewer: NEEDS WORK).

## M7: the Stage, built from the owner-approved prototype (docs/goals/77/stage-prototype.html)
| Milestone | State | What it is |
|---|---|---|
| M7a Stage shell | PASS | mojoui.stage: top bar, a passive left column, the centre panel, a live right column, the sides shaded behind; omxqua's new **Counter** family (themes/omxqua.mojo; omxqua repo commit 8501429, local) |
| M7b Live tiles | PASS | mojoui.livetiles: an exact 4x3 grid for 1–6 tiles; water spring (settles ~0.73 s, 1.2 % overshoot); words never stretched (measured in pixels); press-in; drag; corner resize |
| M7c Agent-driven tiles | PASS | genui `LiveTiles` (AG-UI render_ui), `Screens.patch` (JSON Patch) / CUSTOM ui_patch, a `tiles` tool; promote → large tile, 0 holes, ring on it (IoU 1.0) |
| M7d The TV | PASS | mojoui.stagetv: the chat bar grows over the centre on gitaway's soft spring (0.79 s, 1.7 %), card left, conversation right, swap in place, × or quiet closes |
| M7e Sides, pins, charms | PASS | mojoui.stagefeed (passive left, live right, urgent centre), drag to Pinned, mojoui.charms (bag, pennant, hat, umbrella, tag, turkey), occasions, 2 columns on a phone |
| M7f omx on the Stage | FAIL | omx composes all of it (voice-first chat bar, TV for every card, tiles from the assistant + agent, pointer). See below |

Pictures: docs/goals/77/m7a-* … m7f-* (m7f-{desktop,phone}-{light,dark}-{home,tv,point}.png).

## Why M7f fails, and what is needed
1. **Goal 77 M3 (web) and M4: the ring's pixel measures.** The ring lands on the right part (proved by its own rect), but the old measures count teal pixels on the whole page / in a band, which the Counter theme (teal data colours, a dark route line) and Iso's scaling make unsound. The reviewer recommends re-basing both on the ring's own rect (share of a band round `OMX POINT … ring=`, a negative control on the faded frame, the floor calibrated on stored passing runs). **Needs the owner's approval** (it changes the checker of milestones that passed before; D-7872, D-7874).
2. **An intermittent crash** (D-7876/D-7885): about 1 run in 40, a segfault freeing a theme's surfaces after a tile transition, in three apps; likely C-side memory corruption (GTK/pango) surfacing in tcmalloc; ASan clean on the Mojo side; hardening landed, root cause open.
- Goal 72 M3 and goal 77 M2 failed once on model answers; both PASS on rerun (build/g77/rerun-*.txt).
- After the fix pass, build/g77/m7f/results.json is stale; the real-model runs are redone once (1) is decided.

## Next
Approve or reject the ring measure; then rerun scripts/g77_m7f_run.py, chase the crash with the glibc shim, fresh reviewer, merge.
