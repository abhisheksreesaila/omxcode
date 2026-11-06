# GOAL 51: models as functions in the script, in the app's own process

**End goal (owner, 2026-11-04):** "given a video we want to be able to apply a quick classifier or segment anything…
as a plugin where it runs natively… the same program that is using the GUI, crunching through GPU is the same program
that's running AI"; and for tables, "a decision model… run it against the spreadsheet data and immediately get an
answer" ("any decision model which can give you the answer, please use it"). Framework first: every piece in `mojoui/`
with its own test; omxplorer only composes. No Python in the running app (packs are built once, on our side).

Base: main 1a621e7 (goal 49's script, Script window, recipes). Worktree ../mojo-ui-g51, branch goal-51-models.
Research: docs/research/goal50-models.md (in-process MAX from Mojo through libmax's C API: verified by probe).
(Numbered 51: a parallel session's goal 50 is omxconsole native, ../mojo-ui-g50.)

## Milestones
| # | Milestone | Proof (`docs/goals/51-check.py`) |
|---|---|---|
| M0 | `mojoui.maxrt` | load a pack (a `.mef` + `.safetensors`, built by `scripts/packs/tiny.py`) through libmax's C API, run it on the CPU and on the GPU from Mojo, inputs and outputs as host arrays; the package root found without the caller setting anything; `tests/test_maxrt.mojo` prints `cpu: ok`, `gpu: ok` (the numbers equal Python's), `nopython: ok` (the test binary links no libpython) |
| M1 | Text embeddings in Mojo | `scripts/packs/minilm.py` builds MiniLM-L6 (Apache-2.0) as a pack; `mojoui/wordpiece.mojo` tokenizes as the Python reference does (ids equal on 200 fleet task texts); `mojoui/textembed.mojo` gives vectors whose cosine with the Python pack's ≥ 0.999 on those texts; `tests/test_textembed.mojo` prints `wordpiece: ok`, `embed: ok` and a rows/s line |
| M2 | `classify()` in a script | `name = classify(table, column, labels_table, label_column);` (mojoui.models' registry, composed with the video functions): each unique value once, nearest label by cosine, columns value, label, score, margin; on the DROID fleet, `classify(fleet, task, verbs, verb)` (verbs: the fleet's distinct verbs) agrees with fleet.verb on ≥ 20 points more rows than always answering the most common verb; through omxplorer's Script window by agent tools only; its time and rows/s printed |
| M3 | YOLOX-Tiny as a pack | `scripts/packs/yolox.py` (build side: Megvii's Apache-2.0 weights, BN folded, im2col convs) builds the pack and a reference from Megvii's own code on 5 fixed images; Mojo runs the pack in-process (decode + NMS in Mojo): every reference box with score ≥ 0.3 has a Mojo box of the same class with IoU ≥ 0.9, and no extra Mojo box ≥ 0.5; ms per frame printed |
| M4 | `detect()` on a video section | `name = detect(video, from_s, to_s);` in a script and an **Apply detect** button (the Script window's functions); rows frame, t, kind (COCO class), score, x, y, w, h; the boxes drawn on the video card's player; on the featured DROID episode's 3–8 s: rows only inside the section, ≥ 1 `person` or object row per frame on ≥ 50% of frames; 0 `SLOW:` at 50 ms; shots in build/g51/shots looked at |
| M5 | Nothing regressed | goal 49's check M1–M4 on this tree |

## Done means
51-check PASS for M0–M5, the reviewer passes it, M2's and M4's shots were looked at.

## Out of bounds
Pushing; the frozen ../mojo-ui-apple-test; the parallel goal 50 worktree (../mojo-ui-g50); pip; deleting .pixi; paid
services; secrets; lowering a proof; Ultralytics (AGPL) or LFM2 (revenue cap) models; compiling a model at app start.

## Assumptions (taken instead of asking)
- Packs (`.mef`, `.safetensors`, vocab) live in `build/packs/` and are made by `scripts/packs/*.py` (not in git:
  large, device-specific). The app finds them by name; a missing pack is an error that says which script makes it.
- MAX's 3x3 `conv2d` is slow on sm_86 (research: 115x): YOLOX's convs are written as im2col + matmul.
- M2's proof uses the robot fleet (real data, labels we have) instead of UNSPSC: no public labelled UNSPSC set is
  known; the owner's supply-chain data can run through the same `classify()` later. The small-LLM second pass for
  low-margin rows (research) is left for later: margin is a column, so a script can pick those rows.
- Linux + NVIDIA only for packs (libmax); the Mac is a later check (scripts/mac-ci), phones and web can't load packs.

## Budget
150 turns.
