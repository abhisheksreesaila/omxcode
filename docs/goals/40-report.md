# Goal 40 report: Sketch, omxcode draws

**Result:** M0–M5 pass (`pixi run python docs/goals/40-check.py`; the final run's output is below). Not yet reviewed by the reviewer subagent.

## 30-second demo
```bash
cd ../mojo-ui-g40
scripts/build.sh sketch linux && build/sketch/linux/sketch           # draw; Pan tool or space+drag; wheel zooms around the pointer; ctrl+z
SKETCH_STROKES=1000 build/sketch/linux/sketch                          # the bench's page: 1,000 strokes, then pan and zoom
scripts/build.sh sketch web && pixi run python mojoui/hosts/web.py build/sketch/web   # the same file in a browser
pixi run python scripts/sketch_bench.py --no-build                     # docs/goals/40/bench.json (headless)
```

## Screenshots
- `docs/gallery/img/sketch-gtk.png` (GTK, two strokes with injected pressure over 160 seeded ones)
- `docs/gallery/img/sketch-web.png` (web, same page)
- `docs/goals/40/sketch-gtk.png` + `sketch-ref.png` (M3's GTK window vs the CPU render of its canvas, 0.0 levels apart)

## Numbers (docs/goals/40/bench.json)
1,000 strokes, 101,000 points, headless Xvfb, GskCairoRenderer: p95 frame 2.0 ms pan, 2.6 ms zoom, 1.8 ms draw (frame = gesture + redraw + paint + display round trip + a full render of the canvas: an upper bound). The ink layer is rebuilt 0 times during pan and zoom.

## Decisions worth a second look
1. **D-1216, layer textures.** On cairo a kept render node is re-filled every frame (32 ms for 1,000 strokes), so a moved, kept layer is drawn once into a texture and moved. Cost: zooming past 0.75–1.34× of the texture's scale re-renders once; between those points the texture is softer. GTK's GPU renderers might not need it (they weren't measured).
2. **D-1215, what a "frame" is.** GTK's paint phase measured ~0 ms with every stroke on screen, so the bench adds a synchronous full render of the canvas. That makes the bench honest but pessimistic, and it isn't the latency a person feels.
3. **D-1212, `render:` uses the app's pixel draw().** It compares GTK's renderer with what the app paints on the CPU, not the Scene replay; an app whose draw() and draw_scene() differ would be compared against its own draw().

Also: the Liquid PROMINENT buttons (active tool, active ink) show dark text on teal in the GTK and web shots: low contrast. That's a theme question, left alone.

## Unverified
- A real pen on GTK (only injected pressures through the `stroke:` step); a pen on the web; the Mac (built, never run), its tablet pressure included.
- GTK's GPU renderers (ngl/vulkan): everything was measured on cairo, headless.

## Next step
Run `build/sketch/mac/SketchMojo.app` on the owner's Mac; then a Metal path for the layer transform (the audit's "native viewport").

## Final checker run
```
M0 PASS: tests/test_ink.mojo: ink outline: ok, ink pressure: ok, ink smooth: ok, ink hit: ok
M1 PASS: tests/test_scene_polygon.mojo: polygon cpu: ok, polygon scene: ok, layer transform: ok; GTK replays both
M2 PASS: GTK: pressures [0.2, 0.5, 0.9, 1.0] reached the app
M3 PASS: 7 steps as expected (SKETCH: tool=pan strokes=2 points=7 zoom=2.00 pan=-540,-357); GTK vs CPU 0.0 levels; web and mac built
M4 PASS: 1000 strokes, 101000 points on GskCairoRenderer: p95 pan 2.0, zoom 2.6, draw 1.8 ms; ink layer kept
M5 PASS: gallery Drawing section, matrix, llms.txt and EXPERIMENTS updated
```
