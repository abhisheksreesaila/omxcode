# Goal 59 report: one command to set up, and your own model as a script function

`scripts/check` (docs/goals/59-check.py): M0–M5 PASS (2026-11-06), Linux, RTX 3090 × 2 (shared with another project's model server).

| # | Result |
|---|---|
| M0 | a fresh clone, empty omxcode, Hugging Face and torch caches: `scripts/setup` did env, build, demo data (DROID slice: 1.2 GB in ~11 s, 2,018 episodes, 265 clips, F00118 included), the torch env and three packs (run once more after the neighbour filled the GPU and setup stopped, saying so); goal 51's models scenario in the clone: classify 341 rows, detect 737 boxes, the agent's apply-scene 75 rows; a second run 1 s, every step skipped; a failed install (a stand-in pixi failing as the xkb race does) cleaned and installed again by setup; `--no-models` |
| M1 | `from_torch.py torchvision:resnet18`: MAX = torch's top label on 5/5 pictures, logits (up to 18.45) within 0.035; a network written from scratch (BN with real statistics, residual add, cat, mul, avg-pool, flatten order): 5/5, within 4e-8; an Upsample stops it by name |
| M2 | packs found by model.json alone; Apply offers detect, scene; Mojo's labels = torch's on the 5 pictures; Mojo's centre square = Python's, float for float (exact); scene(clip, 3, 4): 15 rows; the page's GROUP BY line counts 15; without the pack (and with a failed and a shadowing one): nothing extra |
| M3 | omxplorer (GTK, headless, dark): Apply scene on 3–8 s of F00118 → a 75-row card (label, score, frame, t); docs/img/models-scene.png, looked at |
| M4 | docs/models.html: 3 code blocks, each a run of its file's lines; the picture; limits (layers, kinds, Linux + NVIDIA); README's Try it is clone + scripts/setup; linked from start, the slides, llms.txt |
| M5 | goal 51 M2, M3, M4; goal 54 M1; goal 58 M0 |

Found on the way (fixed): the demo's 2,018 episodes put every verb under robot_data.py's 1,000-episode cutoff (classify had one label); a pack compiled by an older MAX crashed inside MAX (packs now carry max.version); the data step's Python wrote mojoui/__pycache__ after the build (the second run rebuilt); the torch env's install hit the xkb race; a neighbour's model server filled both GPUs (setup picks the roomiest card and stops with what to do; scripts/gpuroom.py for checks); scene()'s labels cleared detect's boxes on the player.

Reviewer: round 1 NEEDS WORK (NOTICE, the build skip, M0/M5 at HEAD, eight smaller), round 2 PASS; its three notes taken (pixi clean -e default, an unreadable GPU said so, the check's retry reads the latest run).

Unverified: setup on a Mac (it should skip the packs with a line; not run there); a machine without the pixi package cache (Mojo, MAX and torch downloads: pixi's, not ours); the page's look on a phone.
