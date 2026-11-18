# GOAL 71: robot search by example in omxplorer, on omxcore stable 5194d77

**End goal (owner, 2026-11-14, issue omxcode#9):** omxcore stable `5194d77` adds robot data to the engine; "the show opens in
omxplorer with the robot search demo, then the slides." Owner: "I don't have the deck; we need to prepare it once you're done and
have the great and latest app." So this goal is the app and a recorded cold open; the deck is the next goal.

Base: main 0cfcdb8a (goal 70 in, fast-forwarded 2026-11-14). Worktree ../mojo-ui-g71, branch goal-71-robot-search. Decisions
D-71xx. Goal 70's contract is archived as docs/goals/70.md. omxcore (~/Projects/mxframe) is read-only: sources come out with
`git archive 5194d77` only; its `robotics` pixi env and `build/robotics` (the pool's index, 1,851 episodes) are only read, as the
reference and the data.

## Milestones
| # | Milestone | Proof (`docs/goals/71-check.py`; PASS, FAIL or BLOCKED each) |
|---|---|---|
| M0 | Re-vendor the stable | vendor/OMXCORE_COMMIT names 5194d77 and how to rebuild it; the Mojo 1.2 patch rebased as vendor/patches/omxcore-5194d77-mojo12.patch; scripts/engine_lineage.py proves vendor/omxcore.mojoc is that archive + patch; the F-204 builder changes absorbed (`Query.base`, `q.table()`, lazy joins); omxplorer and every example whose `needs` says omxcore build for Linux; goal 70's engine tests pass; `from omxcore.robot import open_dataset, MomentIndex, export` builds beside Flare; the Mac apps on the engine (built `-D MXFRAME_SERIAL`) add no undefined symbol over goal 70's objects |
| M1 | The pool, a framework piece | `mojoui/robotpool.mojo` (no omxplorer code): opens the index and its datasets in-process, lists each episode's facts (dataset, episode, task, robot, seconds) through the engine; `like(one)`, `like(several)` with an optional robot filter, `export(picks, folder)`. tests/test_robotpool: 1,851 episodes, 8.3 h, 4 datasets; for 10 seeded clips and 3 seeded triples the top 24 equal omxcore's Python `idx.search(like=...)` (same episodes, same order, scores within 1e-4); a warm one-clip search ≤ 5 ms on the GPU; an export of 3 picks loads with `LeRobotDataset(root=...)` and its episode count and frame count equal the picks' |
| M2 | Clips, decoded by the engine | the pool gives an episode's poster frame and a short loop of frames (decoded by the engine: NVDEC here, dav1d elsewhere), downscaled for a card; equal to omxcore Python's `ds.decode` within 3/255 per channel; 24 posters in ≤ 1.5 s cold, 0 ms when cached; a framework `ClipGrid` (a grid of clips: poster, title, a badge, selected / picked states, a playing clip) with its test on GTK and the web host; components.md regenerated |
| M3 | The demo screen | omxplorer opens a Robot search screen (Liquid light): the pool's line (episodes, hours, datasets, on the GPU), a robot filter, a grid of clips; tap one → the episodes like it, ranked, each with its task and score and the time the search took; pick three → "More like these"; Export → a toast naming the folder and that LeRobot loads it. scripts/live.py with real input on GTK (headless): click a clip, the results equal M1's for that clip; pick 3, the results equal M1's triple; Export, the folder loads in lerobot; screenshots at desktop (1440×900) and phone (390×844) width, every text inside its card, nothing clipped (layout read from the view tree) |
| M4 | The cold open | docs/goals/71/cold-open.md: a 30–60 s shot list (captions first, one clip zoomed, the payoff frozen) whose every number is quoted from omxcore's docs/goals/robotics/report.md (the check greps each one there); build/g71/cold-open.mp4 recorded on Linux from the live app, 30–60 s, 1920×1080, every caption's scene present (frames differ, none blank) |
| M5 | Nothing regressed | goal 70's 70-check M3 (goal 68's checker and goal 47's inside it), the component matrix, decisions lint, libc and seek lints |

## Done means
71-check PASS for M0–M5 (a BLOCKED says exactly what is missing); a fresh reviewer subagent passes it; docs/goals/71-report.md
with shots and the cold open; EXPERIMENTS.md. Committed after each passing milestone; merged to main locally when the reviewer
passes; not pushed (the owner pushes).

## Out of bounds
Editing, committing, branching or pushing in ~/Projects/mxframe (asks go in the report as omxcore `mxframe` issues to open);
the other worktrees; pushing; pip (pixi only); lowering a proof or deleting a test; typed-phrase search (needs EmbeddingGemma
in Python; the report's own verdict: a rough first cut); the deck (next goal).

## Assumptions (instead of asking)
- In-process Mojo (`omxcore.robot`) over `mx robot` or the C library: omxplorer is all-Mojo and the GPU call should be direct.
- The reference for "equal" is omxcore's Python `omxcore.robot` in its `robotics` env (the checkout's, which contains 5194d77).
- Clips are shown from frames the engine decodes, not from omxcore's pre-made H.264 previews.
- Phone width is checked at 390×844; no iPhone run. Amended (D-7107): on the web host in Chromium, not GTK, since a GTK
  window can't be narrower than omxplorer's menu bar (581 points); the phone run taps one poster and reads every tagged
  view's rect.
- Budget: 150 turns.
