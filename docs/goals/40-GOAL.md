# GOAL 40: Sketch, omxcode draws

**End goal (owner, 2026-10-30):** "keep the scope very small, hyper focused… do one thing and if it works then
contribute back to the framework and not throw it away and actually put this as a showcase in the gallery: this
framework supports drawing, this is the drawing app." The yardstick is Personal Note's canvas (ink with pressure,
pan/zoom); the audit that found the gap is `~/Projects/personalnotev2/docs/research/omxcode-gap-audit.md` (family 1).

Framework first: everything another app would need goes into `mojoui/` with its own test (CLAUDE.md "Components first");
`examples/sketch` only composes. Look: omxqua Liquid (themes/liquid), touch first.

## Milestones
| # | Milestone | Proof (`pixi run python docs/goals/40-check.py`) |
|---|---|---|
| M0 | Ink model (`mojoui/ink.mojo`) | `tests/test_ink.mojo` prints `ink outline: ok` (a stroke's points + pressures become one closed outline polygon, no NaN, width follows pressure within 5 %), `ink pressure: ok` (no device pressure → a width from speed, stated in the docstring), `ink smooth: ok` (the outline passes through every input point's neighbourhood, ≤ 0.5 px off), `ink hit: ok` (a point within a stroke's width hits it, one 2 px outside doesn't: the eraser's test) |
| M1 | Filled paths + layer transforms in the Scene | `tests/test_scene_polygon.mojo` prints `polygon cpu: ok` (SurfacePainter fills a polygon antialiased: inside 255, outside 0, an edge pixel strictly between), `polygon scene: ok` (a Scene records it as a new op and replays into a SurfacePainter equal to painting directly), `layer transform: ok` (a layer drawn once and shown at another offset and scale equals drawing it there, within 1 level of AA); GTK replays the op as a GskPath fill and the transform as gtk_snapshot translate/scale on the kept node |
| M2 | Pressure in events | `Event.pressure` (0 = the device has none); GTK reads GDK_AXIS_PRESSURE on press and every move; the web host and the Mac host pass it through (built, unrun on the Mac); a test step `stroke:K=x,y,p;x,y,p;…` on GTK sends a press, moves and a release carrying those pressures; a headless run of examples/sketch prints one `SKETCH PRESSURE: p` per point equal to the injected values |
| M3 | examples/sketch | one Mojo file: pen, eraser, three ink colours, undo, clear, pan (two-finger scroll or space-drag), zoom (pinch or ctrl-scroll) around the pointer; a headless GTK run of a scripted session (the checker's SESSION) prints `SKETCH: tool=… strokes=… points=… zoom=… pan=…` on every change, with the expected values in order; a new generic GTK test step `render:K=path` paints canvas K with a SurfacePainter into a PNG; writes `docs/goals/40/sketch-gtk.png` (the window), and the canvas in that shot matches a SurfacePainter render of the same strokes (mean difference ≤ 8 levels); `scripts/build.sh sketch web` and `scripts/build.sh sketch mac` succeed |
| M4 | Fast enough to draw on | `scripts/sketch_bench.py` writes `docs/goals/40/bench.json` (fresh for the sources: its commit's mojoui/ink.mojo, scene.mojo, hosts/gtk.mojo and examples/sketch equal HEAD's): 1,000 strokes, ≥ 100,000 points, headless GTK (renderer recorded); frame time p95 ≤ 16.7 ms while panning, while zooming and while drawing a new stroke; the strokes' layer is rebuilt 0 times during pan and zoom (only transformed) |
| M5 | In the gallery, back in the library | `docs/gallery/index.html` has a Drawing section with `img/sketch-gtk.png` and `img/sketch-web.png` (both exist, not blank); `scripts/components.py --check` passes and docs/components.md lists the ink stroke, the polygon fill, the layer transform and pressure; `docs/llms.txt` names `mojoui.ink`; EXPERIMENTS.md's newest entry is goal 40 |

## Done means
The checker prints PASS for M0–M5; the reviewer passes it; the gallery's Drawing section previewed for the owner.
The Mac is built, not run: it runs on the owner's Mac when it's set up (a later step, not this goal).

## Out of bounds
Pushing; the frozen `../mojo-ui-apple-test`; `GOAL.md` and `scripts/check.py` (goal 39 owns them on its branch);
windows on the owner's desktop (everything headless); new dependencies beyond the pixi env.

## Assumptions (instead of asking)
- Branch `goal-40-sketch` from local `main` at b79fc66 (76 ahead of origin, has the Mac job threads); worktree `../mojo-ui-g40`.
- Decision numbers D-1200 onward, so they don't collide with goal 39's D-1000s.
- Variable width is drawn as a filled outline (one polygon per stroke), not a stroke with a fixed width: every host fills a path; only GTK strokes one.
- The web keeps its JPEG canvas stream; pen latency on the web isn't a goal here.
- Speed is measured headless (Xvfb, GTK's renderer recorded), not on the desktop (out of bounds).

## Budget
80 turns.
