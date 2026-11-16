# The cold open: robot search in omxplorer (goal 71)

A 34 s opening before film 1 of the deck "omxcore: three short films". It is recorded from the live app on Linux (one RTX 3090,
NVDEC) and cut by `docs/goals/71/cold_open.py` into `build/g71/cold-open.mp4` (1920x1080). Rules: captions first, one card
zoomed, the payoff frozen, never a shrunk recording of the whole window. Every number in the shots below is quoted from
omxcore's `docs/goals/robotics/report.md` at stable 5194d77. The app's own on-screen timings are live readings, not claims.

How to make it again: `pixi run python docs/goals/71/cold_open.py ~/Projects/mxframe/build/robotics/index.parquet`.

## Shots

| # | Starts | Length | On screen | Caption |
|---|---|---|---|---|
| 1 | 0 s | 5 s | The Robot search page opening on the pool: clips from simulated and real robots (held still, then live) | Hours of robot video. Which clips show the same task? |
| 2 | 5 s | 4 s | Zoomed on the pool's line under the title | 1,851 episodes, 8.3 h, 4 LeRobot datasets: opened where they sit |
| 3 | 9 s | 7 s | The pointer taps a clip of a real SO-100 arm, the sorting task; the results fill with the same task, the clip plays; then the hero card zoomed, its line saying the time the ranking took | Show one clip: every episode like it, ranked in ~1 ms on the GPU |
| 4 | 16 s | 9 s | Back to the pool; Pick on three simulated drawer clips; More like these: every result the same drawer task | Pick a few: More like these. 24 of 24 the same task |
| 5 | 25 s | 9 s | Export; the toast names the folder and that LeRobot loads it; frozen | Export: a LeRobot v3 dataset. LeRobotDataset(root=...) loads it |

## Where each number comes from (omxcore's robotics report)

- 1,851 episodes, 8.3 h, 4 datasets: "Pool | 1,851 episodes, 8.3 h, 43 tasks, 4 datasets".
- ~1 ms: "One clip -> every clip like it | ... ranked in ~1 ms".
- 24 of 24: "A few clips -> more like these | 3 picked drawer clips -> 24 of 24 top results the same task".

## Notes for the deck (next goal)

- Cursor pass: done (2026-11-15). The take is recorded with ffmpeg's draw_mouse off (`recordbare:` in scripts/live.py,
  which logs each pointer move and button press as LIVE-PTR / LIVE-BTN lines), and `docs/goals/71/pointer.py` draws a
  white arrow (dark outline, soft shadow, 24 px at the 1440x810 take) at those positions, with a faint press ring on each
  click, before any zoom, so it scales with the picture. X's bare "x" is gone. Before recording, the pointer rests beside
  the hint line, so the first glide starts there. The same pass fixed the island at rest on the robot screen: it said
  "CPU" (the sheet's device, and there's no sheet there); now it names the pool's device ("NVIDIA GeForce RTX 3090 · ready").
- Web copy: `build/g71/cold-open-web.mp4` (1280x720, H.264, CRF 28, no audio, +faststart) and the poster
  `build/g71/cold-open-poster.jpg` (scene 4, the drawer-task results).

- The film's clips are set with `OMX_ROBOT_SAMPLE` (cold_open.py's SAMPLE): one real sorting clip (scene 3) and three LIBERO
  clips of "put the black bowl in the bottom drawer of the cabinet and close it" (scene 4).
- Typing a phrase is left out on purpose: the report calls it a rough first cut.
