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

- The film's clips are set with `OMX_ROBOT_SAMPLE` (cold_open.py's SAMPLE): one real sorting clip (scene 3) and three LIBERO
  clips of "put the black bowl in the bottom drawer of the cabinet and close it" (scene 4).
- Typing a phrase is left out on purpose: the report calls it a rough first cut.
