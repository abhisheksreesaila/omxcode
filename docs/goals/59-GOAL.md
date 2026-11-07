# GOAL 59: one command to set up, and your own model as a script function

**End goal (owner, 2026-11-06: "yes start", option 2 of goal 58's next steps; memories any-model-not-accuracy,
no-excuses-fund):** a newcomer clones omxcode, runs `scripts/setup`, and has omxplorer, the robot demo data and the
models working, with no step done by hand. Then they add their own model and call it from omxplorer's Script window,
without editing any Mojo: a PyTorch network converts into a pack (`scripts/packs/from_torch.py`), the pack describes
itself (`model.json`), and the framework finds it, so its function shows up in scripts and in a video's Apply menu.
A page, "Add your own model", walks through it with the real code.

Today (fresh clone, 2026-11-05 and today): the env installs, but there is no demo data (the robot fleet is made from
~30 GB fetched by a script outside the repo), the e5 pack fails without the fleet, YOLOX's source and weights must be
put in ~/.cache by hand, a half-installed env needs `rm -rf .pixi`, and a model is added by editing the hard-coded
list in mojoui/models.mojo. No doc explains adding one.

Base: main 6ca7f58 (Mojo 1.2). Worktree ../mojo-ui-g59, branch goal-59-onboard. (57 is another session's.)

## Milestones
| # | Milestone | Proof (`docs/goals/59-check.py`) |
|---|---|---|
| M0 | One command | a fresh clone of this branch on the home disk, with empty Hugging Face and omxcode caches: `scripts/setup` exits 0 and prints each step (env, build, demo data, packs) with its time; the demo data has a fleet.csv of at least 100 episodes with clips, telemetry, limits and ATTRIBUTION.txt, all fetched from the public sources; build/packs has e5small and yolox; the models scenario (goal 51) passes in that clone; a second `scripts/setup` skips every step and takes under 60 s; a failed install (the xkb race, simulated by a stand-in pixi whose first install fails) is cleaned and installed again by setup, not by hand |
| M1 | Any CNN converts | `from_torch.py torchvision:resnet18 …` (and a small custom torch module) converts with no per-model code; the MAX pack's outputs match torch on the test pictures (same top-1, logits within 0.05); a module with an op it can't convert fails naming that op |
| M2 | Packs describe themselves | a pack's model.json (function, kind, labels, input) is all the framework needs: ModelFunctions finds `scene` (the ResNet pack) with no Mojo edits; `scene(video, from_s, to_s)` returns label, score, frame, t rows; the Apply menu lists it; removing the pack removes the function; classify and detect unchanged (goal 51's M2–M4) |
| M3 | In omxplorer | driven on GTK (headless): open the fleet and a clip, run `labels = scene(<clip>, 3, 8);` in the Script window: a table card of labels lands; looked at |
| M4 | The page | docs/models.html "Add your own model": the three steps with code that is in the repo (the check finds each snippet in its file), the M3 picture, honest limits (which layers convert, Linux + NVIDIA); README's Try it is `git clone` + `scripts/setup`; linked from start.html, the learn index and llms.txt |
| M5 | Nothing regressed | goal 51's check (models), goal 54's M1, goal 58's M0 |

## Done means
59-check PASS for M0–M5, the reviewer passes it, the page and the M3 picture were looked at.

## Out of bounds
Pushing before the reviewer's PASS and green checks; republishing the robot data or model weights (setup fetches
them from their own public homes); the frozen ../mojo-ui-apple-test; other sessions' worktrees (g50, g52, g53, g55,
g57); pip; deleting anything outside this goal's own scratch folders; lowering a proof; tuning model accuracy (the
point is that any model plugs in).

## Assumptions (taken instead of asking)
- ResNet-18 (torchvision, BSD-3, ImageNet labels) is the third model: a different kind (pictures to labels) from
  e5 (text vectors) and YOLOX (boxes). Its labels on lab footage will be ImageNet's ("desk", "microwave"): honest, and
  not the point.
- The demo set is a slice of DROID (a few whole packed files from jnogga/droid_success and droid_failure, CC-BY-4.0),
  made by the existing scripts/robot_data.py; the full 13 GB set stays a separate, documented step.
- The pixi package cache stays warm in M0 (re-downloading Mojo and torch proves pixi, not us); the HF and omxcode
  caches start empty.
- Setup on a Mac does the env, build and data and skips the packs with a line saying why (packs are Linux + NVIDIA,
  goal 51); proven only on Linux here, unless time allows the owner's Mac.

## Budget
120 turns.
