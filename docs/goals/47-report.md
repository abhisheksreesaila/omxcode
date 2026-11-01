# Goal 47 report: "Why did the robot drop it?" (real robot data, one story)

**End goal (owner, 2026-10-31):** one story for the launch videos: spreadsheets + analytics + robotics on real public data,
in omxplorer in Liquid dark, with video, charts and documents joined by explicit links. Contract: docs/goals/47-GOAL.md,
docs/goals/47-check.py. Branch `t3/robot-story-droid-data` (from main e670647).

## Result
See "Milestones" at the end (the check's own lines). In short: the DROID fleet (63,344 real episodes, 13 labs, 16.8M
telemetry rows) is the sheet; a chart and a pivot by lab; the featured failure's video plays beside four lanes of its
telemetry on one cursor, opened by links alone; two questions in words answered by `JOIN LINKED` over 16.8M rows in
tens of milliseconds (16–42 ms in the check's runs); the DROID paper, which every row names as its source, with its
"recorded at 15Hz" marked; a pack per picked failure. 0 `SLOW:` lines at a 50 ms budget, through agent tools and on GTK,
both on the headless display (Xvfb, CPU drawing: the guide's 16 ms budget is for real displays).

## The story, beat by beat (what the data supports)
1. **The fleet.** 63,344 episodes from 13 labs (DROID's success and failure sets, CC-BY-4.0), one row each: lab, robot, date,
   task, verb, outcome, duration, frames, grasp counts, peak joint speed, clip. *Chart:* average success by lab, PennPAL 95 %
   … RAD 61 %. *Pivot:* episodes by lab × outcome.
2. **A failure opens.** Pick F00118 (AUTOLab robot 44bb9c36, 2023-11-21, 16 s; task "Place the peach shirt and two yellow
   towels inside the brown box", inferred from the nearest success): its video plays in the `episode` card and its 244
   telemetry rows become four lanes (joint velocities ×7, gripper, position xyz, rotation roll/pitch/yaw unwrapped) with
   the gripper's close/open marked, on the video's clock. **The featured failure, where the object visibly drops: F00118.**
   The gripper closes at 5.3 s and reads 0.97 (almost shut: a pinch on thin cloth) all the way over the box; at 12.7 s it
   starts to open while still over the box's edge, and the shirt falls and lands hanging on the box's outside wall (13.0 s).
   (D-4718: an earlier pick, F00119, was wrong: frame by frame its shirt goes into the box.)
3. **Asked in words.** "failures where the gripper closed, let go and closed again" → 2,997 episodes (`JOIN LINKED`:
   fleet ⨝ telemetry on the episode key the person linked; 16.8M rows; 37–42 ms in the check's runs; the engine picks CPU or GPU, the log doesn't say which). "episodes within 30% of the
   arm's joint speed limit" → 4 episodes: **no episode in 63k exceeds the Panda's 2.175 rad/s**; the fastest reaches
   1.89 rad/s (87 %). The limit is in limits.csv (libfranka's published control parameters); inserted as a table, its
   rows draw the limit as dashed lines on the lanes (tests/test_robot_follow.mojo "card"); the recorded story doesn't
   insert it.
4. **The paper.** The DROID paper (arXiv 2403.12945v2, CC-BY-4.0) is a document card. Every fleet row's `source` names the
   same paper (the dataset has one), so the key link `fleet.source = paper.file` marks the same chosen passage (page 15:
   "All DROID data is recorded at 15Hz") for any row: provenance, not a per-row join. It
   is read from the PDF's own text ("PDF text" reader), not OCR.
5. **A pack.** "the failures I picked" (F00118 and two failures beside it on the same bench, F00119 and F00124) → Export pack: per episode a
   PDF (its facts, the frame at the gripper's release, the lanes' readout there, the paper's page with its passage marked)
   and a 6 s clip.
6. **Scale.** The same view over every episode on disk: 63,344 rows in the sheet, 16,847,616 telemetry rows in a card
   (landed in ~0.6 s as a job). The first slice waits for the log's key index (one pass over 16.8M codes in a job,
   mojoui/logindex.mojo); after that an episode is sliced exactly in ~2 ms. Joins in tens of ms.

**What the data doesn't support (said plainly):** DROID has no force or torque, so "dropped" is read from the gripper and the
video. The gripper features computed per episode (missed grasp, slip, regrasp) were tuned on one AUTOLab robot and **don't
predict failure across labs** (a slip shows in 18 % of successes too); the story uses them as filters, not as a detector.
Failure episodes carry no instruction in DROID: their task is the nearest success on the same robot the same day
(`task_from` says so).

## Record it yourself
Everything runs on Linux (GTK) from this worktree. One time:
```
pixi run python -I scripts/robot_data.py build/g47/full        # ~2 min with clips cached (first run ~15 min): fleet, telemetry, clips, paper
scripts/build.sh omxplorer linux
```
Re-record the clip and the 11 shots exactly as committed (headless, ~2 min): `pixi run python scripts/clips.py robots`
→ docs/img/clip-robots.mp4, build/g47/shots/. Play the whole story through agent tools (prints a transcript you can read
aloud): `pixi run python scripts/scenario.py robots --media build/g47/full --out build/g47/robots`.

To record by hand (your screen recorder; a 1920×1200 window reads best): `pixi run build/omxplorer/linux/omxplorer`, then:

| Beat | Click path | Say |
|---|---|---|
| 1 Fleet | Open (toolbar) → build/g47/full/fleet.csv → Create table | "63,000 real robot episodes from 13 labs, DROID, public. One row per episode." |
| 1 Chart | Chart (toolbar) → type in its field `average success_pct by lab, largest first` ↵ | "Success by lab, from 95 % down to 61 %, in under a millisecond." |
| 1 Pivot | Pivot (toolbar) → Value `n`, Rows `lab`, Columns `outcome` | "How many episodes each lab ran, and how many failed." |
| 2 Telemetry | Table (toolbar) → telemetry.parquet | "Every frame of every episode: 16.8 million rows of joint velocities, gripper and pose." |
| 2 Links | Links (toolbar) → type each, ↵: `fleet.episode = telemetry.episode`, `fleet.clip = episode.file`, `telemetry.t ~ episode.t +0`, `fleet.source = paper.file` | "Nothing joins until I link it: the episode key, its video file, the clock, its paper." |
| 2 The drop | close the inspector (View → Inspector); F00118 is row 1,927 of the fleet: scroll there and click it (or first run the "picked" query of beat 5 and click F00118 in its card: the same links open it) → seek to 0:08 → play | "This one failed. Its video and its telemetry, on one cursor. The gripper is almost shut, a pinch on the shirt; at 12.7 seconds it opens over the edge, and the shirt falls outside the box." |
| 4 Paper | Documents (toolbar) → build/g47/full/paper → Reader: PDF text → Fields: `recorded at, frequency of, Franka` ↵ → Highlight: recorded at → click the row again | "The dataset's paper, linked by its source: recorded at 15 Hz, a Franka Panda." |
| 3 Ask | Query (toolbar) → Ask in words: `failures where the gripper closed, let go and closed again`, SQL: scripts/scenario.py's ROBOT_SQL1 → Run | "A question in words, a join over 16.8 million rows, 40 milliseconds: 2,997 failures re-grasped." |
| 3 Spec | Query → `episodes within 30% of the arm's joint speed limit`, ROBOT_SQL2 → Run | "Against the spec: no episode ever exceeds the arm's 2.175 rad/s; four come within 30 %." |
| 5 Pack | Query → `the failures I picked`, ROBOT_SQL3 → Run → pick F00118 → Export pack | "A pack per failure: the frame where it let go, its telemetry, the paper's page." |
| 6 Scale | (the status bar and the cards' row counts) | "All 63,000 episodes, nothing froze. Next: the full 67k with every camera." |

## Growing it
- On disk now (28 GB of the 80 GB cap): video for 3,546 episodes (one camera, the original sample + 2,000 successes + 1,000
  failures from `~/data/robot-scout-tools/grow_droid.py`), telemetry for 63,344 (the grow script fetches whole ~730-episode
  data files, so its 136 files already hold nearly every episode; `scripts/robot_grow_telemetry.py` adds data files only).
- To 10k episodes with video: `grow_droid.py jnogga/droid_success <dst> 8000` and `… droid_failure <dst> 2000` (≈ 70 GB for one
  camera at ~7 MB an episode, ≈ 50 min), then `scripts/robot_data.py` again (it cuts a clip per episode with video; ~2 min
  per 1,000).
- Beyond: 67k is DROID's ceiling with 720p video; the telemetry table is already the whole fleet. 1M and 100M episodes would
  have to repeat or synthesise rows (say so on screen).

## What the framework gained (mojoui/; omxplorer only composes)
- `lerobot.py`: a LeRobot (v3) dataset as episodes and telemetry (a Python source plugin, like ocr_torch.py): quaternions made
  continuous and unwrapped, gripper events with hysteresis. `tests/test_lerobot.py`.
- `signal.mojo` (unwrap, smooth, steps, peaks) and `telemetrychart.mojo` (lanes from column families, one cursor, marks, spec
  lines); the track card shows a multichannel log as lanes (Raw/Smoothed). `tests/test_telemetry.mojo`.
- `trackcard.series_where`: one recording's rows of a long log, by key, binary-searched when the log is grouped.
- `MediaCards.named`: a video card with a name whose file follows a selected row.
- Links: a key link onto a video card's `file` plays the row's file; one onto a log table slices it into the lanes; a card is
  reached once per column (D-4714); answers derive lineage from the sheet's own table (D-4715).
- Documents: a Reader choice (OCR model | PDF text) for born-digital PDFs (D-4713).
- omxplorer: the sheet's grid is settable to a row (agents) and follows its links; files from 4 MB open in a job (an 11 MB
  CSV took 161 ms on the UI thread, D-4711); packs of rows with a file link get a frame and the lanes' readout.

## Not done or unverified
- Web host (M9): not done. The scenario runs on the web build through the agent host (the same module), but no browser
  drive of the page was run.
- Mac: not run.
- The clip has no narration or captions; the owner records the voice-over.
- Only the left external camera; wrist and right views were not fetched (3× the bytes).

## Milestones
docs/goals/47-check.py, full run on the final data, after review round 1 (build/g47/check-full.txt):
```
M0: PASS  63,344 episodes, 13 labs, 13,746 failures; hero F00118 (244 frames, clip ok); two runs byte-equal; lerobot + droid ok
M1: PASS  signal; lanes; draw; seek; follow; index; slice; moment; card; named; page
M2: PASS  telemetry episode=F00118 244 rows, 16 channels, 1.8 ms; cursor = player at 3 seeks; 0 SLOW at 50 ms
M3: PASS  chart: success by 13 labs = truth (PennPAL 95.11 … RAD 61.35); by verb, 16 verbs = truth; pivot: failure/success/total for all 13 labs = fleet.csv
M4: PASS  regrasped 2,997 = truth; within 30% of the limit ['F04415', 'F11745', 'S05574', 'S20210'] = parquet; both asked in words, JOIN LINKED written out
M5: PASS  page 15: the marked box reads '15Hz. Each DROID trajectory'
M6: PASS  3 picked failures: a PDF each (its id; the frame at its last gripper release, its time = the parquet's; the paper's field and page) and a clip
M7: PASS  63,344 episodes, table landed telemetry.parquet in 582.5 ms (16,847,616 rows); queries ['40.7 ms (2,997 rows)', '15.6 ms (4 rows)', '0.5 ms (3 rows)']; 0 SLOW
M8: PASS  clip 41.7 s; 11 shots at 1440×900, luminance 0.13–0.26; 0 SLOW on GTK
```
