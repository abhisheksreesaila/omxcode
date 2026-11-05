# GOAL 49 (draft): one script over everything on the board: data, video, models, agents

**End goal (owner, 2026-11-04):** "large scale data, large scale video, AI plugins, manipulate through script, and agents
to it all at once through AG-UI." Story over variety: about fifteen short videos, one story, robotics first.
"Script always beats UI, especially in the agent world": the UI is a shell, the script is the driver.
**Framework first:** every piece is a `mojoui/` component with its own test; omxplorer only composes them. A bug or
rough edge found on the way is fixed in the framework. omxplorer is the excuse, the framework is the product.

Base: omxcode main (goal 47's DROID fleet, `videotable`, `asksql`/JOIN LINKED, `videoexport`, goal 48's AG-UI,
D-4755's in-process packs).

## The story (one arc, cut into ~15 clips)
1. 63k robot episodes, 17M telemetry rows open in seconds (goal 47, re-shot).
2. A video is a table: `select * from episode_118` gives its frames.
3. One script joins video, telemetry and the fleet sheet; the answer is a new card.
4. The model shelf: tap +, YOLOX is installed, Apply.
5. Select a section of video, Apply: the boxes appear on every frame of it, instantly.
6. Scrub: the model follows the playhead live.
7. The model's output is a column: chart it next to gripper force.
8. "Find every episode where the object leaves the gripper": the script does it over the whole fleet.
9. Cut and Export: clip with overlays + CSV + the script, for a coworker.
10. The coworker opens the saved recipe on their own robot's video.
11. An agent writes the script through AG-UI; the person only watches and says yes.
12. Supply chain: 50M rows, `classify(description, unspsc)` with a decision model, no training.
13. Only the uncertain rows go to review; the speed numbers.
14. A custom GPU function in the script (a few lines of Mojo, no `main`, no device context).
15. The whole thing is one Mojo program: GUI, GPU, models, agents. Same build on Linux, web, Mac.

## Milestones (draft)
| # | Milestone | Proof |
|---|---|---|
| M0 | The story, written | the 15 clips as beats (caption first, the one card to zoom, the payoff frame, per [demo clips choreographed]); each beat names the agent tool that drives it |
| M1 | `mojoui.script` | a script window component: SQL over every card on the board (sheets, telemetry, and a video as a table of frames through `videotable`); joins are written in the script, so they stay explicit (the "nothing joins until a link exists" rule holds: the script is the link); the result becomes a new card; saved as a recipe file; agent tools `run_script`, `save_recipe`, `open_recipe`; tests over goal 47's truth |
| M2 | Models as functions | `mojoui.models`: a pack contract (input kind → output kind: frame → boxes, frame → mask, text → vector, text → label); YOLOX as the first in-process pack (D-4755: compiled MAX graph through libmax's C API, Mojo end to end, no Python at run time); `detect(frame)` callable in a script; the model shelf (Installed / Download / Cloud) as a component; latency per frame measured |
| M3 | Select, Apply, Export | pick a video range, Apply: results stream in as jobs, frames near the playhead first; overlays drawn by the framework; scrubbing runs the model live; Cut / Export writes the clip with overlays, the CSV and the script (`videoexport`); 0 `SLOW:` at 50 ms |
| M4 | A decision model (System 1) | modelled on TypeSafe's Jev (closed, early access): typed outputs (`Choice` over labels, `Score` 0–100) in one forward pass, not token by token, each with a calibrated confidence and a threshold. Open and local: an encoder that already knows language (MAX's own embedding models first; GLiClass / GLiNER2-style zero-shot classifiers scouted) settles each unique value on the GPU, no training; only rows under the threshold go to System 2, a small open LLM constrained to the top-k labels (`max serve` wrapper, D-4755). Rows per second measured at 1M and 50M; calibration checked against a labelled sample |
| M5 | Your own GPU function | a script can define a small Mojo function body (no `main`, no device context) that the framework compiles once, caches and runs per row or per frame; built-in GPU helpers (atomic add, multiply-add, scan) |
| M6 | Agents do it all | `scripts/scenario.py script` plays the story through agent tools only, and once through AG-UI with the official SDK |
| M7 | Scale + clips | the fleet (17M rows) and a 100M-row table through the same script; the clips recorded, looked at, Liquid dark |

## Open questions
- The decision model: owner named TypeSafe's Jev ("System One" models) as the idea, "any open-source fast System 1 model" as the pick. Jev is closed, so a scouting note picks the open one (licence, size, one-pass, calibration, runs in MAX or ports cheaply).
- Public supply-chain data with UNSPSC labels for M4's truth (or a labelled sample we build).
- Goal 46's vision path (`vision_max.py`) is Python interop; D-4735/D-4755 want packs, so M2 starts from packs, not goal 46.
- Script syntax: SQL plus functions (what agents write best) is the default; the GPU function body in M5 is Mojo.

## Out of bounds
Notebook cells (owner: compile friction); robotics file formats and 3D (later); pushing; the frozen apple-test worktree.
