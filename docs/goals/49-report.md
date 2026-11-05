# Goal 49 report: one script over everything on the board

**End goal (owner, 2026-11-04):** "script always beats UI… the UI becomes a shell and the script becomes the main
driver… pick a section of video and apply, it instantly gives you the answer, then cut or save or export… ship it to
your colleague." Framework first.

**Result: M0–M5 PASS; reviewer PASS (round 2).**

```
M0: PASS  15 beats, 10 tools, all in the app
M1: PASS  parse; run; chain; error; fn; frames; recipe
M2: PASS  video 244 frames; video ⨝ telemetry 244 rows = pyarrow; ⨝ fleet: lab AUTOLab
M3: PASS  range 3.0–8.0 s: applied on frames [45, 120), clip 75 frames, script + CSVs; 0 SLOW at 50 ms
M4: PASS  recipe reopened on F00119: 287 frames, joined 287 = pyarrow; 32 tool calls, agent tools only
M5: PASS  asksql, tablejobs, videotable tests; goal 47 M2 + M4 PASS
```

## What exists now (all in `mojoui/`, each with a test)
- `mojoui.script`: a script is statements (`name = SELECT …;`, `name = fn(args);`), run in order; each result is a
  table later statements read; errors say their line; `${questions}`; a function registry (`ScriptFunctions`)
  where models plug in.
- `mojoui.videoscript`: every video is a table of its frames (no decode); `regions(video, from, to)` runs the GPU
  analyzer over only that section.
- `mojoui.scriptpanel`: the Script window: text, questions, a video section with **Apply** (writes
  `apply_1 = regions(episode, 3.0, 8.0);` into the script and runs it), **Export**, **Open recipe**.
- `mojoui.recipe`: a recipe is a folder: `script.sql` (questions kept), each result as CSV, the applied section as
  a clip. A colleague opens it, answers `${episode}`, runs it on their own episode.
- `tablejobs.ScriptJob`: the script runs off the UI thread. Over 16.8M telemetry rows it lands in 30–60 ms
  (regions over 75 frames on the GPU: ~450 ms).

## 30-second demo
```
cd ../mojo-ui-g49        # (or main, after the merge)
scripts/build.sh omxplorer linux
pixi run python scripts/scenario.py script --media build/g47/full --out build/g49   # agent tools only, prints each step
pixi run python scripts/clips.py script-shots                                       # build/g49/shots/01–08
```
Shots: `build/g49/shots/02-script-ran.png` (four results on the board), `04-applied.png` (Apply on 3–8 s:
583 regions), `07-recipe-reopened.png` (the recipe asking `${episode}` = F00119).

## Three decisions worth a second look
- **D-4902:** models are not in this goal. The script has the slot (`ScriptFunctions`), proved with the GPU
  analyzer. YOLOX `detect()` and a System 1 `classify()` are goal 50. The research says that works in-process
  with no Python (docs/research/goal50-models.md).
- **D-4909:** the Script window is a Dialog. It covers the video while open, so "scrub with the model on the
  frame" (story beat 6) still needs the results drawn on the player and a docked or smaller window.
- **D-4906:** the engine has no `ROUND`/`FLOOR`; `CAST(x AS INT)` rounds, so scripts join a 15 Hz log with
  `CAST(t * 15 AS INT) = frame`. Asked for in docs/plans/needs-mxframe.md.

## Not done / next
- Overlays: Apply's boxes on the player as you scrub (the story's beat 6), and a docked Script window.
- Goal 50: `mojoui.maxrt` (libmax C API, verified by a probe), `classify()` (MiniLM embed → nearest label →
  Qwen3-0.6B for unsure rows), YOLOX-Tiny `detect()` (4–6 days estimated for parity).
- The 15 clips are written as beats (docs/goals/49/story.md); recording them waits for the models.
