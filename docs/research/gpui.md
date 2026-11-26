# What to learn from Zed's GPUI (2026-11-23)

Source read: zed-industries/zed at 58fea3d (2026-11-24 UTC), crates `gpui`, `gpui_macos`, `gpui_apple`, `gpui_linux`, `gpui_wgpu`,
`gpui_platform`, `scheduler` (Apache-2.0: code and ideas usable with credit in NOTICE). `crates/ui` and `crates/editor` are
GPL-3.0: ideas at most, no code; not opened. Ours: branch `bench-nanoui` at 7b9db6d5. Three readers, each claim on our side
grepped; the ones marked **(checked)** were read again or run by the main session. **No race has been run against GPUI:
nothing here says who is faster.** G = `crates/gpui/src`.

## In one paragraph
GPUI draws every pixel of its window; we use the platform's controls and draw only canvases. So most of its layout, focus,
hit-testing and scroll code isn't something we need. What we lack falls in three groups: **text and edges that look a bit
better** (fractional glyph positions, text contrast, pixel-snapped borders, smooth pictures), **never losing or repeating
work in the app layer** (our own faults, found by comparing), and **proof tools** (random tests, a hang monitor, instruction
counts). Our renderer's structure holds up: layers kept on the GPU, culling before shaping, smaller instances, an exact CPU
reference on both platforms. GPUI re-sends the whole window each frame.

## Our own faults, found by comparing
| # | Fault | Proof | Where |
|---|---|---|---|
| F1 | **Two LazyLists in a window stop updating** once one is scrolled: the drawn-row range is kept once per app, not per list. After that neither list refreshes. `examples/keeper` has two lists. Also on `main` | **(checked, reproduced on GTK)** img/gpui-two-lists.png: right list keeps "old"; pressing again leaves the left at "new" instead of "newer"; without scrolling it works | hosts/gtk.mojo:447, 6869 |
| F2 | **Add a row on top of a long list: past ~500 rows every widget is rebuilt** | **(checked, timed)** 499 rows: 1,498 of 1,501 widgets kept; 600 rows: 1 of 1,804 | diff.mojo:182 |
| F3 | **Comparing an unchanged list costs n²** | **(checked, timed)** 50 rows 0.03 ms, 200: 0.30, 499: 1.74; 600 (past the cut-off): 0.14 | diff.mojo:189 |
| F4 | **Clicks, keys and scrolls are dropped while a rebuild waits** (one idle turn; lower priority than redraw) | code **(checked)**; a lost click not reproduced | gtk.mojo:2864, 6578, 6128, 6359 |
| F5 | Mac, iPhone, Android and web **rebuild the whole screen on a shape change** (D-244's choice); Mac never releases the old controls (its own comment) | code **(checked on Mac)** | appkit.mojo:2118, 2289; uikit 864; android 438; web.py 2629 |
| F6 | Metal re-sends every used glyph row for each new glyph (goal 80 fixed GL only) | code **(checked)** | gpu2d_metal.mojo:1277 |
| F7 | Glyph pages are a fixed 2,048 rows: a frame that needs more prints `GLYPHPAGES` and draws wrong glyphs | code **(checked)**; not reproduced | gpu2d.mojo:201, 584 |
| F8 | One GPU failure turns the GPU off until restart; no reset check | code **(checked)** | gtk.mojo:3433 |
| F9 | Pictures: nearest-neighbour scaling, all of a scene's pictures copied into every rebuilt frame, hashed whole on GL | code **(checked)** | gpu2d.mojo:769; gpu2d_gl.mojo:1598; scene.mojo:221 |

## Worth borrowing, ranked
**A. People would see it**
1. **Glyphs at quarter pixels.** G/window.rs:5301, text_system.rs:51 (4 positions across, 1 down). Ours already rasterizes and
   caches at a quarter-pixel offset but always passes 0 and rounds (gpu2d.mojo:911) **(checked)**. Small. Mac first: its advances are
   unrounded. On Linux it must still match headless Chromium (D-7903), so measure against goal 79's references.
2. **Text contrast and gamma** (gpui_wgpu/src/shaders.wgsl:30, from Microsoft Terminal, MIT); on the Mac, heavier strokes by text
   brightness (gpui_apple/src/text_system.rs:225). Ours blends raw coverage; D-7936 already lists gamma as a known miss. Tune to
   Chromium, not to GPUI. Small to medium; the CPU reference changes with it.
3. **Snap chrome to device pixels, strokes at least 1 px** (G/window.rs:3690) **(checked)**. Opt-in (moving things would jitter). Small.
4. **Smooth pictures**, rounded corners on them, an id per picture instead of its pixels (G/assets.rs:43). Small, then medium.
5. Border and fill in one shape (clean inner corners); font features (tabular numbers in canvases); mixed left/right text. Medium each.

**B. Never hang, never lose input**
6. Fix F1–F4 (small); then keep widgets on every host (F5; large, Mac first).
7. **Hang monitor**: an always-on ring of what the UI thread did, a thread that reports late frames (G/profiler/journal.rs:39,
   hang/monitor.rs:56). GPUI's reports after the fact; a live one would also see a hang in progress. Ours (`MOJOUI_BUDGET_MS`) is
   off by default and doesn't time applying changes to widgets. Medium.
8. Focus and reveal by tag (`Focus(tag, n)`, `Reveal(tag, n)`); shortcuts scoped to a tag; latest-wins requests. Small to medium.
9. A real list: any row content, selection, scroll-to, keep the place when rows are inserted (G/elements/list.rs:489). Large, on
   GtkListView / NSTableView / web, not a drawn list.

**C. Proof**
10. **Random tests: patched screen = fresh screen** (G/randomized_element_tree.rs). Small; the gate for 6. Ours is hand-written cases.
11. **Instructions and allocations per frame** (G/bench.rs), steadier than time on a card whose clocks move. Small on Linux.
12. Mac frame clock from `CAMetalDisplayLink` (gpui_apple/src/display_link.rs:57); ours is a 60 Hz timer, so never 120 Hz
   **(checked)**; stop when the window is hidden. Medium: an earlier display link never fired on the owner's Mac (D-560). Whether
   that Mac's screen does 120 Hz wasn't established.

**D. Only with a measured reason:** opaque rectangles first with depth, window-wide batching, analytic paths on GL (an 8× buffer
saved on non-NVIDIA cards), exact springs, accessible children inside canvases (worth it on its own merits; medium to large).

**Not worth it:** entities/observers (messages are simpler for agents), taffy (native layout), hitboxes, tab stops, tooltips
(the platform's), element arenas, LCD text, hot reload.

## What ours does better
Layers, finished strokes and tiles stay on the GPU; culling before shaping (GPUI shapes and rasterizes first); changed ASCII
text without a shaper; smaller instances (64 vs ~160 bytes a box, 80 vs ~112 a glyph, computed); exact shadows (GPUI now uses an
approximate closed form; the one we borrowed is its older one); one CPU reference both backends are tested against; GPU time measured;
Linux draw-ahead and dmabuf offload; platform controls with their accessibility, IME and spell-check; any native or web child
(GPUI's new `NativeView` is Mac only).

## The race (not run)
Feasible. GPUI renders headless on Linux on the real GPU (gpui_platform/src/gpui_platform.rs:93). Frame CPU = `Window::draw`; GPU =
`render_scene` plus a ~10-line patch that waits for it. Bench file inside a full zed checkout (`crates/gpui_platform/benches/`).
Two versions per scene: painted by hand (renderer against renderer) and idiomatic (includes layout, labelled). Same protocol as
goal 80 (D-8030). Cost: one large Rust build (time unmeasured), throttled because of the machine's hard stops.

## Not checked
Nothing was rendered side by side: every "visible" claim needs a picture. Windows/web/iOS GPUI; start-up; Android and UIKit hosts beyond
the cited lines; Intel and AMD cards; GPUI's editor.
