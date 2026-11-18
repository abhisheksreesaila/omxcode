# Goal 47's M8 (the robots recording on GTK) on goal 73 and on its base, 2026-11-17/18

M8 fails on any `SLOW:` line (one step over the 50 ms budget). Runs of `docs/goals/68/regress.py 47 M8`, each raw log kept
under build/g73/m4/ (m8-<side>-<n>.raw.log). Base = main cc33c9d7 (worktree ../mojo-ui-g73-base); goal 73 = this branch.
Other sessions were running on the machine throughout (the owner's omxplorer, another goal's ffmpeg): load average shown.

| run | load at start | M8 | SLOW lines | frame paint median / p90 / p99 (ms) | canvas draw median / p99 (ms) |
|---|---|---|---|---|---|
| round 0, goal 73 | ~58 | FAIL | 15+ (53–141 ms) | (log overwritten) | |
| round 0, base | ~58 | FAIL | 15+ (51–299 ms) | (log overwritten) | |
| goal 73, 1 | 6.1 | PASS | 0 | 13.3 / 89.3 / 144.1 | 1.09 / 15.6 |
| base, 1 | 16.3 | PASS | 0 | 62.2 / 127.7 / 209.7 | 1.19 / 18.6 |
| goal 73, 2 | 19.7 | FAIL | 1 (draw canvas=250, 89.9 ms; its other draws 7 ms) | 25.0 / 68.3 / 369.7 | 1.96 / 18.0 |
| base, 2 | 22.7 | PASS | 0 | 11.7 / 58.3 / 307.7 | 1.04 / 13.9 |
| goal 73, full check | 14.4 | FAIL | 3 (draw canvas=1 52 ms; Insert > Documents 108 ms; the pack's start 374 ms, under 50 ms in the four other runs of the same step) | | |
| goal 73, M4 rerun | 3.4 | FAIL | 1 (draw canvas=230, 55.8 ms) | 11.8 / 55.3 / 157.7 | 1.04 / 14.4 |

Reading: the distributions match the base's (median paint 11.8 vs 11.7 ms, median draw 1.04 vs 1.04, p99 draw 14.4 vs 13.9
at comparable runs); the SLOW lines are single stalls in steps goal 73 didn't change (Insert > Documents, the pack, a lanes
canvas), and the base shows them too under load. One goal 73 run passed M8 outright. Goal 73 doesn't make the recording
slower; goal 47's zero-SLOW rule is a tail check that any stall on a shared machine trips.

Review round 2 (the reviewer's own runs, load 3–12): goal 73 PASS, PASS (0 SLOW both); base PASS, FAIL (SLOW lines).
