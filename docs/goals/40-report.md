# Goal 40 report: Sketch, omxcode draws

**Result:** M0–M5 pass (`pixi run python docs/goals/40-check.py`; the final run's output is below). Review round 1: NEEDS WORK, fixed in a74ebbe and the commits after it (below); awaiting re-review.

## 30-second demo
```bash
cd ../mojo-ui-g40
scripts/build.sh sketch linux && build/sketch/linux/sketch           # draw; scroll (two fingers), the Pan tool or space+drag pans; ctrl+scroll or pinch zooms; ctrl+z
SKETCH_SCENE=gallery build/sketch/linux/sketch                         # the gallery's page
SKETCH_STROKES=1000 build/sketch/linux/sketch                          # the bench's page: 1,000 strokes, then pan and zoom
scripts/build.sh sketch web && pixi run python mojoui/hosts/web.py build/sketch/web   # the same file in a browser
pixi run python scripts/sketch_bench.py --no-build                     # docs/goals/40/bench.json (headless)
```

## Screenshots
- `docs/gallery/img/sketch-gtk.png` (GTK, the gallery page: "omxcode" lettered in pressure strokes, three tapered waves, a pressure ramp from 0.1 to 1.0, a doodle; 32 strokes)
- `docs/gallery/img/sketch-web.png` (web, the same page)
- `docs/goals/40/sketch-gtk.png` + `sketch-ref.png` (M3's GTK window vs the CPU render of its canvas, 0.0 levels apart); `sketch-gtk-2.png` + `sketch-ref-2.png` (M3's second session: texture, append, erase, wheel pan; 0 pixels off)

## Numbers (docs/goals/40/bench.json, commit a74ebbe)
1,000 strokes, 101,000 points, headless Xvfb, GskCairoRenderer, on a machine shared with other sessions' builds (load ~4 on 24 cores). A frame = gesture + redraw + paint + display round trip + a full render of the canvas (an upper bound).

| phase | p95 ms | max ms | textures rendered | p95 over 5 runs | what the max is |
|---|---|---|---|---|---|
| pan (120) | 3.0 | 37.4 | 1 | 1.8–12.6 | the first pan: the ink layer's texture rendered once (the page starts unmoved, so it has none) |
| zoom (120) | 6.0 | 56.8 | 4 | 3.1–7.9 | the zoom leaving 0.75–1.34× of the texture's scale: rendered again, 4 times |
| deepzoom (120, at 8×) | 13.1 | 35.1 | 0 | 8.9–26.4 | cairo scaling the capped 4096 px texture onto the canvas every frame (no re-render; was 108 ms p95, 120 renders) |
| draw (120 moves) | 2.7 | 3.6 | 0 | 1.6–3.7 | |
| finish (24 short strokes) | 3.1 | 6.0 | 24 (appends) | 2.6–5.8 | release frames max 6.0, the frame after max 2.9 (was 36.6 / 33.3) |
| erase (37 hits) | 22.6 | 22.6 | 38 (mends) | 14.1–22.6 | rebuilding the 1,000-stroke node + the clipped mend (was 35.4) |

The ink layer is built 0 times during pan and zoom (`built_by_layer` has no "ink"); finish appends 24 times and builds 0; erase rebuilds it 38 times (a removal can't reuse the node).

## Review round 1 (NEEDS WORK) and what changed
1. **Scroll didn't pan.** `Canvas(scroll_pans=True)` and a new gesture WHEEL: a plain or two-finger scroll pans, ctrl+scroll and pinch zoom; GTK, the web (a trackpad pinch is a ctrl wheel) and the Mac (built, not run). Canvases that don't opt in keep zoom-on-scroll: goal 6's checker passes its drag/zoom (M2) and web wheel (M6) proofs; omxplorer, lens, workbook, particles build. New GTK step `wheel:K=dx,dy`. The web was driven by hand in headless Chromium: a plain wheel posted WHEEL (dx −30, dy −100), ctrl+wheel zoomed to 119%. D-1218.
2. **"ink" in the host.** Builds are counted per layer key (`built_by_layer`, `appended_by_layer`); the bench reads "ink". D-1223.
3. **Texture reuse past the cap.** Compared against the clamped scale; deepzoom phase added: 120 → 0 re-renders. D-1221.
4. **The frame after a stroke or an erase.** finish and erase phases; a layer that only gained ops appends to its node and texture (D-1219), one that only lost ops mends the texture in the box they were in (D-1220). Max reported for every phase.
5. **Docs.** Pen pressure is 🔨 on GTK in docs/components.md (only injected), with the reason and the 4096 px note printed under the table; gallery and EXPERIMENTS say "not tried with a real pen" (GTK, web; the Mac built, not run). M3 gained a far-off pixel count and a second session through the new paths, both mutation-tested (D-1222).
6. **Showcase.** A generated gallery page (D-1225); the active tool/ink buttons keep white text on the accent in toolbars, fixed in the shared skins base for GTK and the web (D-1224; no other app has a prominent toolbar button).

## Decisions worth a second look
1. **D-1216, layer textures.** On cairo a kept render node is re-filled every frame (32 ms for 1,000 strokes), so a moved, kept layer is drawn once into a texture and moved. Cost: zooming past 0.75–1.34× of the texture's scale re-renders once; between those points the texture is softer. GTK's GPU renderers might not need it (they weren't measured).
2. **D-1215, what a "frame" is.** GTK's paint phase measured ~0 ms with every stroke on screen, so the bench adds a synchronous full render of the canvas. That makes the bench honest but pessimistic, and it isn't the latency a person feels.
3. **D-1212, `render:` uses the app's pixel draw().** It compares GTK's renderer with what the app paints on the CPU, not the Scene replay; an app whose draw() and draw_scene() differ would be compared against its own draw().

4. **D-1219/D-1220, append and mend.** Generic in the host: any layer that grows at its end, or loses ops, gets the cheap path. The mend still walks every path on cairo (clipped), which is why erase stays 14–23 ms.
5. **The 4096 px texture cap** (D-1216): on a big page at a big zoom the ink is softer until the zoom comes back; noted in docs/components.md.

## Unverified
- A real pen on GTK (only injected pressures through the `stroke:` step); a pen on the web; the Mac (built, never run), its tablet pressure and scroll-pan included.
- A real touchpad's two-finger scroll and pinch on GTK (the checker sends wheel notches; touchpad pixels go through the same code path, unexercised).
- GTK's GPU renderers (ngl/vulkan): everything was measured on cairo, headless.
- Erasing on 1,000 strokes: 14–23 ms p95, over a 60 Hz frame in some runs; deepzoom 9–26 ms p95. Neither is an M4 phase; both are stated, not fixed.
- Timings are from a loaded shared machine and vary run to run (see the 5-run column).

## Next step
Run `build/sketch/mac/SketchMojo.app` on the owner's Mac; then a Metal path for the layer transform (the audit's "native viewport").

## Final checker run
```
M0 PASS: tests/test_ink.mojo: ink outline: ok, ink pressure: ok, ink smooth: ok, ink hit: ok
M1 PASS: tests/test_scene_polygon.mojo: polygon cpu: ok, polygon scene: ok, layer transform: ok; GTK replays both
M2 PASS: GTK: pressures [0.2, 0.5, 0.9, 1.0] reached the app
M3 PASS: 7 steps as expected (SKETCH: tool=pan strokes=2 points=7 zoom=2.00 pan=-540,-357); GTK vs CPU 0.0 levels, 0 pixels > 40 off; session 2 (texture, append, erase, scroll pans): SKETCH: tool=eraser strokes=2 points=6 zoom=1.00 pan=30,-60, 0.0 levels, 0 pixels; web and mac built
M4 PASS: 1000 strokes, 101000 points on GskCairoRenderer: p95 pan 3.0, zoom 6.0, draw 2.7 ms; ink layer kept
M5 PASS: gallery Drawing section, matrix, llms.txt and EXPERIMENTS updated
```
