# Goal 68 report: add a model like magic, and open a robot fleet's bags (part 1)

Worktree ../mojo-ui-g68, branch goal-68-models-and-bags (base origin/main a52aa958), its own pixi env (D-6801). Not
merged, not pushed. Decisions D-6801–D-6831 (docs/decisions.md), journal 2026-11-12.

## Milestones (`scripts/check`, 2026-11-12)
| # | Result | Commit | Proof |
|---|---|---|---|
| M0 One plugin format | PASS | 765c88af (+ review fixes b6bc80f2, 9a73f0d2, f24c6604) | mojoui.plugins (plugin.json: kind, runner tree/max/torch/onnx/skops). XGBoost JSON + LightGBM text in Mojo match their libraries to 4.3e-7; ONNX + skops in process; a pickle, a `../` path, a link out and a skops file holding `eval` refused. As plugin functions: `detect` (YOLOX, MAX) 34 boxes, `scene` (ResNet-18, MAX) 15 frames, OWLv2 (torch, from the Hub) 30 boxes, `classify()` through e5small; a plugin copied in after the build answered 100,000 rows. mojoui/models.mojo names no model |
| M1 Learn from my labels | PASS | 376c9e93 | GTK, 100k rows, 20 labels → "waiting when speed < 0.2 and person_m ≥ 1.5; person ahead when speed < 0.2 and person_m < 1.5; otherwise moving", right on 19/20 rows it never saw; filled in 52 ms; a changed label relearned in 55 ms (component: 40 ms); the agent over MCP did the same with `label-rows` + `learn` |
| M2 Add a model | PASS | 354307b0 (+ 003b243a) | four models of four kinds the app hadn't seen, stopwatch below; gpt2 said why and downloaded nothing; nomic-embed asked first (the yes is person-only: the agent has no tool for it); Run it on all filled a column (tree), a table (YOLOS, 1,620 boxes in 6.7 s) and a similarity column (BGE, by the agent: 63,344 rows) |
| M3 ROS 2 bags in Mojo | PASS | b5249b2d (+ 003b243a) | 6 bags (5 MCAP: zstd, lz4, stored; 1 rosbag2 sqlite3), 1.42 GB, CC BY 4.0; 31,727 messages / 919,328 fields equal to mcap+mcap_ros2 and rosbags (0 differences; a planted difference caught); every topic of all six read in 2.1 s; H.264 (r2b) and JPEG (NavWareSet) cameras → videos mojoui.video plays |
| M4 A fleet in one sheet | PASS | 546edbf4 | 6 runs, 920 moments × 83 columns (every topic joined at 10 Hz), 104 stop rows, read in 1.9 s; story.json with 4 questions; in the app: 19 cameras made videos in 14.2 s, a picked moment moved the hero run's camera; 20 stops labelled → "person ahead when moved_m ≥ 1 and person_m < 2; waiting when moved_m ≥ 1 and person_m ≥ 2; otherwise not started" (19/20 held out); component: 84 of 84 unlabelled stops right |
| M5 Polish | PASS | 9023f0e0 (+ 003b243a) | the four flows in headless Chromium on the web host, every state shot (empty, error, before, answer); nothing on screen moved when an answer arrived; the agent opened the bags by path, labelled 20 stops, Learn named person_m |
| M6 Nothing regressed | PASS | (run on f24c6604) | goal 47 M0–M8, goal 59 M1–M2, goal 62 M1 (via docs/goals/68/regress.py, see below), the component matrix, message ranges, scripts/seek_lint.py |

M0, M1, M4 and M6 come from the full run on f24c6604; M2, M3 and M5 were rerun on 003b243a (three small changes after
it: the can't-run reason in a trace line, the example line moved below the field, empty types counting in the column
cap). M6's regressions did not rerun on 003b243a.

## The stopwatch (M2, final run)
| Model (kind) | How it came in | Paste → first answer | Download | After the download | Its first answer |
|---|---|---|---|---|---|
| stops (tabular: XGBoost JSON trained by the check) | a dropped file | 0.1 s | none | 0.0 s | row 1: moving |
| google/vit-base-patch16-224 (picture classifier) | pasted | 15.7 s | 330 MB in 12.9 s | 2.7 s | the frame at 0.0 s: sliding door 46% |
| hustvl/yolos-tiny (detector) | pasted | 176.8 s | 25 MB in 174.1 s | 2.6 s | person × 2 (best 100%), boxes drawn |
| BAAI/bge-small-en-v1.5 (text embedder) | the agent's add-model | 6.5 s | 128 MB in 3.6 s | 2.9 s | "Pour the contents of the cup into the bowl": most like it "Pour the contents in the cup into the bowl" 1.00 |

All four answered under 3 s after their download (the contract: under 2 minutes). Download times follow this
connection, which swung from 25 MB in 2.2 s to 25 MB in 174 s between runs (an earlier run moved ViT's 330 MB in 708 s).

## Screenshots (build/g68/shots/)
- Learn: m1-1-empty, m1-2-label-column, m1-3-labelled, m1-4-learned, m1-5-relearned (GTK); m5-learn-1-empty, m5-learn-2-error, m5-learn-3-labelled, m5-learn-4-learned (web)
- Add a model: m2-0-empty, m2-cant-run, m2-consent, m2-image-1-line, m2-image-2-downloading, m2-image-3-answer, m2-detect-1-answer, m2-detect-2-running, m2-detect-3-ran, m2-detect-4-table, m2-tree-1-answer, m2-tree-2-ran, m2-tree-3-column (GTK); m5-add-1-empty, m5-add-2-error, m5-add-4-answer (web)
- Open bags and the fleet: m4-0-start, m4-1-reading, m4-2-fleet, m4-3-one-cursor, m4-4-stops-sheet, m4-5-learned (GTK); m5-bags-1-start, m5-bags-2-fleet, m5-fleet-1-stops, m5-fleet-2-learned (web)

GTK dialogs are windows of their own: docs/goals/68/gtk.py grabs the headless X display (`grab:` steps).

## Review
Three rounds, by a fresh reviewer each time, covering correctness, ease of use on the screenshots and the security of
M0/M2. Round 1 FAIL on all three; round 2 FAIL (security and correctness); round 3 security PASS, correctness PASS once
the empty-type "diamond" was bounded (003b243a). Fixed with tests (D-6829–D-6831):
- a model's own code runs only after a person's yes, recorded by the app for repo@commit (the button has no agent tool; a dropped folder or plugin.json can't grant it);
- skops loads only scikit-learn/NumPy/SciPy classes;
- no MAX pack from a drop;
- Hub files checked by sha256;
- crafted bags (bad lengths, cycles, huge arrays, wide schemas, large chunks) refused, and sqlite bags opened read-only;
- tree files validated at load.

Ease of use passed with notes (below).

## What's not done, and what's unverified
- **GTK fleet layout:** the camera card is clipped when the fleet's story tiles five cards (m4-2-fleet). The web host shows it whole (m5-bags-2-fleet). A ticket, not fixed.
- **GTK dialogs on Xvfb:** they open at the top-left. Xvfb has no window manager; on a desktop they're centred (not checked here).
- **Toolbar buttons:** the right group (Learn from labels, Add a model, Links) is icon-only with tooltips.
- **Segmenters:** none from the Hub yet. OWLv2 runs as a plugin; SAM 2.1 stays in mojoui/visionmodel.mojo (the visionmodel tests weren't rerun).
- **Bag formats not read:** protobuf channels (NavWareSet's /annotations), XCDR2, wstring. TF, point clouds and camera calibration aren't joined into moments.
- **Learn:** formula columns aren't carried over a Learn (D-6811), and a table with removed rows would shift results (omxplorer doesn't remove rows today).
- **The consent record:** keyed by repo@commit, not by the folder's content. A plugins folder filled by hand could copy an allowed source (round 3, LOW).
- **The defaults:** OMX_PACKS defaults to a relative build/packs.
- **Goal 62's checker:** it points at another session's G47 folder, which is gone. M6 ran it with G47 = build/g47/full, and goal 59's DEMO = build/g47/full (same DROID clips), through docs/goals/68/regress.py.
- **Unverified:** the Mac and iPhone hosts (never built for this goal); the web host's Add a model with PyTorch models (the web was checked with a tree file and the Hub's preflight; torch models were checked on GTK and through the agent host); XCDR2 bags.

## Owner decisions
- The owner may say "merge and push". Nothing is merged or pushed.
- Part 2 waits for the owner to try part 1: bigger models, the full fleet, policy training and the film.
- The fleet's robot name comes from folder names (`r2b_galileo` → r2b; D-6825). Confirm, or name a better source.
