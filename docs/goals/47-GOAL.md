# GOAL 47: "Why did the robot drop it?" (the robot fleet, on real public data)

**End goal (owner, 2026-10-31):** one story for the launch videos, posted Sunday night: spreadsheets + analytics + robotics on
REAL public data, in omxplorer in Liquid dark. Video, charts and documents joined by explicit links (goal 41's links,
time links, JOIN LINKED, the document card, the pack). Data: DROID (CC-BY-4.0) in its LeRobot 720p ports, already on disk
in ~/data/robot-scout, grown with the grow script (orchestrator steer, same day: telemetry for every episode first, video
only for the episodes the story opens; a featured failure where the object visibly drops).

Base: main e670647. Framework first: every generic piece goes in `mojoui/` with its own test; omxplorer only composes.

## Milestones
| # | Milestone | Proof (`docs/goals/47-check.py`) |
|---|---|---|
| M0 | Fleet data + truth | `scripts/robot_data.py OUT` (over `mojoui/lerobot.py`, the generic LeRobot source; `tests/test_lerobot.py` ok) writes fleet.csv (one row per episode: lab, robot, date, task, verb, success, duration, frames, grasp features, clip), telemetry.parquet (every frame: joint velocities, gripper, position, unwrapped rotation, speed, events), per-episode clips, limits.csv, the DROID paper, truth.json; ≥ 13 labs; the featured failure has video; two runs of the small sample: fleet.csv, limits.csv, truth.json byte-equal |
| M1 | Signal + telemetry lanes (mojoui) | `mojoui/signal.mojo` (unwrap, smooth, steps, peaks), `mojoui/telemetrychart.mojo` (lanes from column families, one cursor, marks, spec lines), the track card shows a multichannel log as lanes; `tests/test_telemetry.mojo` prints `signal: ok`, `lanes: ok`, `draw: ok`, `seek: ok` |
| M2 | A row opens its episode (links) | key link `fleet.clip = episode.file` plays the row's clip in a named video card (`MediaCards.named`); key link `fleet.episode = telemetry.episode` slices that episode's rows into the lanes (`series_where`, binary search on a grouped log); time link `telemetry.t ~ episode.t` binds the cursor. A headless GTK run over the full fleet prints `OPEN:` and `SLICE:` for the featured failure, the cursor agrees with the player within one frame at 3 seeks, 0 `SLOW:` at 50 ms |
| M3 | The fleet, pivoted | a pivot and a chart of success by lab (13 labs) and by task verb on the full fleet; their numbers equal truth's |
| M4 | Asked in words | "failures where the gripper closed then reopened" and "episodes faster than the arm's spec" answered with `JOIN LINKED` over fleet ⨝ telemetry (taught to the AskBook); the answers equal truth's sets |
| M5 | The paper, linked by key | the DROID paper (CC-BY-4.0) as a document card; a key link from the fleet to the paper's passage; picking a row marks the passage (15 Hz, Franka Panda, Robotiq 2F-85) |
| M6 | A pack | Export pack for the picked failures: per episode a PDF (≥ 2 pages, its id, a frame, the telemetry) |
| M7 | Scale | the same view over every episode on disk (63k fleet, ~17M telemetry rows): opens as jobs, 0 `SLOW:`; the times are printed; docs say how to grow (grow scripts, disk) |
| M8 | The story, delivered | `scripts/scenario.py robots` plays it end to end through agent tools only; shots of each beat at 1440 wide in build/g47/shots/; docs/img/clip-robots.mp4 30–45 s; Liquid dark (mean luminance 0.10–0.30); the report's "record it yourself" section |
| M9 | Web host (if cheap) | the scenario's first beats on the web build |

## Done means
47-check PASS for M0–M8 (M9 if done), the reviewer passes it, the shots and the clip exist and were looked at.

## Out of bounds
Pushing, merging into main, the frozen `../mojo-ui-apple-test`, pip, deleting .pixi, paid services, secrets; lowering a proof.

## Assumptions (instead of asking)
- DROID failures carry no instruction: their task is the nearest success on the same robot the same day (`task_from` says so).
- No force data in DROID: "dropped" is read from the gripper (a hold that closes further, or an early open) and the video.
- The Franka joint velocity limits come from libfranka's published control parameters (a number with its source, not a
  redistributed document); the linked document is the DROID paper (arXiv 2403.12945v2, CC-BY-4.0).
- Headless Xvfb draws on the CPU, so the budget in checks is 50 ms.
