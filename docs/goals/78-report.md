# Goal 78 report: a free canvas, live resizing, keys, and video you can see

Worktree ../mojo-ui-g78, branch `goal-78-free-canvas` (from origin/main cd885df4). Decisions D-7801 to D-7817, journal 2026-11-18.
Check: `pixi run python docs/goals/78-check.py` (M1–M4; shots in `build/g78/`).

## What was built

**Framework first.** `mojoui/freeboard.mojo` is the free placement model (its own test, `tests/test_freeboard.mojo`, 14 groups):
`handle_at` (four edges, four corners, the title band), `drag_rect` (a move or a resize from where the press began, soft snap
within 8 pt to a neighbour's edges, to the tiling's 8 pt gap beside it, else to an equal width/height, guides to draw; Alt turns
snap off), `extent` (the window, or the cards plus 160 pt once one reaches past it), `first_free`, `sync`, `tidy` (the old
dwindle tiling, run fresh), `nearest` / `nudge` / `grow` / `fill` for the keys, zoom steps, `arrange_menu` (21 actions, each on
Super and on Alt), and `FreeCanvas(...)`, the Board with its focus ring, guides and zoom. Tiling stays: Tidy uses it, and
Settings ▸ "Tile the cards" keeps the old tiled board.

**Hosts.** GTK and the web send a free Board's drags to the app on every motion frame (`BOARD_LIVE`), so the card's content is laid
out live and there is no jump on release; zoom (GTK child transforms, web CSS zoom); Ctrl+wheel; the page's scroll reported
(`BOARD_VIEW`, used by Fill); click-to-focus (`BOARD_PICK`); cursors for each handle; the dragged card on top. New framework bits
on the way: `Canvas(hover=True)` (a `HOVER` gesture) and `.cursor(name)` (a patch), Super in shortcut names on both hosts, and the
web takes size-only diffs as patches (it used to rebuild the whole screen, which would have swapped the dragged card each frame).
AppKit holds a free Board's cards like a tiled one's (clipped, with the grip); live drags, zoom and the eight handles are
GTK and web only.

**omxplorer** composes it: free canvas by default; an older .omx (no `"canvas"` key) opens tiled; a free .omx keeps the zoom and
the table's place (charts and pivots keep their own x, y, w, h); View ▸ Canvas (Tidy, Zoom out, Actual size); the Arrange keys;
a table column linked to a player card's `file` draws its cells as links. A small framework sample, `examples/canvas`, shows the
model alone.

## Review round 1 (NEEDS WORK) and what changed

1. **"Tile the cards" was dead**: CANVAS_MODE had ABOUT_CLOSE's number (77), whose branch came first. Now 94; KEEP_INSPECTOR has
   its own version bump back; `scripts/msgs.py` now fails when two `m ==` messages share a number (it only checked ranges).
   M4 ticks the Settings checkbox (no OMX_CANVAS) and reads `canvas=tiled` and the tiled rects, then unticks it (D-7819).
2. **Web heights**: a card's height resize also resizes what's inside it (a chart's canvas, the grid), which was a whole-screen
   rebuild that dropped the drag. Size-only changes anywhere inside a free card now go to the web as size marks applied as
   styles. Every drag starts afresh (hosts mark the first frame, FIRST_FRAME; round 1 also ended a drag on any other board event, which round 2 found wrong: see below).
   M1 drags S and NW of a chart and of the table, then a second drag of each, on GTK and the web, frame by frame (D-7820, D-7821).
3. **Performance**: live drag frames (and their end) no longer bump omxplorer's version, which every canvas's version adds; a
   hover redraws only the grid; GTK draws a resized canvas at its new size by itself. Measured with 10 cards on GTK (build/g78/m1-perf.txt, round 2's run): update median 0.4 ms, p95 0.6 ms, max 0.8 ms; to the laid-out frame median 16.9 ms, p95 25.8 ms (one display frame); one canvas drawn per frame (the resized card's); 0 SLOW lines at the 50 ms budget (D-7822).
4. **The default look**: goal 73 M3's measurements now also run on the free canvas (78 M4 `depth`, cards found from the hosts'
   own boxes): 16 cards pass 73 M3's step, rim and shadow thresholds (GTK and web, light and dark, tiled and free, an unfocused table and the free canvas's focused chart; build/g78/m4-depth.txt). A tiled bottom row's shadow can't be read: it falls outside the page's scroller (D-7826). Goal 73 M3 itself, goal 73 M2 and goal 47's directed DROID clip still run tiled
   (OMX_CANVAS=tiled): **the directed DROID clip (docs/img/clip-robots*.mp4, goal 47) shows the tiled layout, not the default
   free canvas**; it was not re-recorded.
5. **Keys in a field**: the web's and GTK's shortcut handlers skip arrows, Home/End/Page and Alt+letter while a field has focus;
   AppKit gives ⌥-only shortcuts no key equivalent. On a Mac the Arrange actions therefore have no keys (AppKit maps Ctrl to ⌘
   and ignores Super): they are in the Mac menu bar's Arrange menu, and zoom is off there. M2 types in the formula bar: the keys
   pass to the field, then fire again on the grid (D-7823).
6. **Links**: "=" is refused only when the last word is entirely a number: `fleet.clip = Robot runs 2024.file` is a key link
   (unit test both ways, D-7824).
7. **AppKit zoom**: `mojoui.freeboard.HOST_ZOOMS` (GTK and the web): elsewhere the zoom items are disabled, the zoom stays 100,
   a saved zoom reads as 100, and omxplorer's View ▸ Canvas shows only Tidy (D-7825).

## Review round 2 (NEEDS WORK) and what changed

1. **A scroll mid-drag made the card jump** (a bug D-7821 brought in): omxplorer ended the drag on every board event but a drag
   frame, so the "view" event a scroll sends (GTK 120 ms after it stops, the web 150 ms) rebased the drag on the already-moved rect.
   Now only a zoom ends a drag; FIRST_FRAME starts each new one. M1 scrolls and sends "view" half way through a chart's E drag and the
   table's S drag (GTK: `freedrag …,alt+view`; the web: a real scroll and a 400 ms hold, button down): every frame equals resized(start,
   total offset). With the round-1 line put back the GTK proof fails (the chart 540 → 630 instead of 570); that run was redone in round 3 with its console saved: `build/g78/r4-gtk-heights-with-round1-line.txt` (the verdict) and `.log` (the host's output) (D-7827).
2. **Web size marks carry the screen version** (data-v); BOARD_JS drops a mark from another screen. M1 appends a stale and a current
   mark in the page: the stale one is dropped, the current one applied (D-7828).
3. **Thicker proofs**: after every web drag the table's grid and the chart's canvas keep the distance to their card's height they had
   before any drag (67 and 166 pt on the web; the grid's is its 44 pt title band plus the card's padding); unit tests for on_drag's
   decoding (1108 = move, no snap, first frame), set_zoom's clamping, and FIRST_FRAME rebasing (test_freeboard: 17 groups) (D-7829).

Round 2's runs (consoles saved): `build/g78/r3-m123.txt` (78-check M1, M2, M3: **PASS**) and `build/g78/r3-m4.txt` (M4's own parts
**PASS**: save/open, an older .omx tiled, the Settings checkbox, depth on both modes, the DROID story; BLOCKED only because the chain
was skipped with G78_SKIP_76=1). The chain wasn't rerun for round 2: its changes touch only free-canvas drags and the web's size
marks, which goal 76 M1/M2 and goal 73 M1–M3 (M2, M3 run tiled) don't exercise; they passed on round 1's fixes (above and below).

## Review round 3 (NEEDS WORK) and what changed

1. **A zoom mid-drag jumped the card by its whole offset**: omxplorer ended the drag on a zoom, and the next frame rebased on the moved
   rect while the offset was still counted from the press. Now no board event ends a drag; the hosts restart the press when the zoom
   changes mid-drag: from the last frame they sent, at the new zoom, as a FIRST_FRAME (GTK keeps the zoom the offsets are measured at,
   their base and the last offset sent; the web keeps z, x0, y0 the same way). **The model**: frames up to the zoom (frame m) are
   start + pointer / old zoom; frame k after it is frame m's rect + (pointer since frame m) / new zoom (the app truncates to whole
   points). M1 Ctrl+wheels to 91 % half way through a chart's E drag on GTK (`freedrag …,alt+zoom`) and the web (Ctrl held, a real
   wheel notch, the button down): e.g. GTK frame 3 = 660 + int(30 / 0.91) = 692, frame 4 = 660 + int(60 / 0.91) = 725. The
   rebase unit test no longer locks in the doubled offset: it shows a FIRST_FRAME restart with offset 0 keeps the card, then only
   the movement since counts (D-7830).
   On the web this also found a second bug: the wheel lost the board's pointer capture in Chromium with no lostpointercapture or
   pointerup, the next move went to a canvas, and the drag stalled with no end. The free drag now follows the pointer on the window
   for its whole life (D-7831).
2. **The web's mid-drag scroll proof could pass without scrolling** (and did: on its first run the page was already at its bottom).
   It now scrolls 40 pt whichever way the page can go, and fails unless scrollTop changed by 40 and a request hook counted at least
   one "view" post before the next frame (D-7832).
3. The round-1-line failure is now saved (see round 2, item 1). With that line back, the zoom drag fails too.

Round 3's runs (consoles saved): `build/g78/r4-m123.txt` (78-check M1, M2, M3: **PASS**; perf with 10 cards: update median 0.4 ms,
p95 0.5 ms, one canvas drawn per frame, 0 SLOW; the web scroll step 630 → 590 and 0 → 40 pt with one view post each) and
`build/g78/r4-m4.txt` (M4's own parts **PASS**: save/open, an older .omx tiled, the Settings checkbox, depth on both modes, the DROID
story, which drags; BLOCKED only because goal 76's chain was skipped with G78_SKIP_76=1: round 3 changes only free-canvas drags, which
goal 76 M1/M2 and goal 73 M1–M3 don't exercise).

## Results (78-check)

| | Result |
|---|---|
| M1 | **PASS**: test_freeboard 14 ok; GTK: telemetry at the first free spot (0, 640, 640x320); the fleet table's right edge dragged 900 pt past the window, its width read on each of 6 motion frames (1566 … 2316), telemetry untouched, canvas scrolled right (1060 + 1416 of 2476); each of the 8 handles of the telemetry card resized it live (4 frames each, the cursor named per handle), the table untouched, overlap allowed; a snapped move shows its guide; a new chart goes to a free spot and nothing moves; Ctrl+- four times (33 %) shows every card; Ctrl+0 and Ctrl+wheel (91 %, back to 100); Super+T tiles with no overlap. Web, real mouse: the same (widths per frame, 8 handles with their cursors, zoom 33 %, Alt+T) |
| M2 | **PASS**: a press on a card and a click in the table focus them; 10 Super keys and 10 Alt keys each did exactly their one thing (focus, 32 pt and 8 pt moves, grow/shrink, fill the visible window and back, tidy); the arrows alone moved the table's selection (rows 4 → 6) and no card. Web with the real keyboard (Meta is Super on Linux): the same 20 keys; arrows row 6 → 8 |
| M3 | **PASS**: test_playcells (▶ for video, ♪ for audio, empty cells plain, a column that plays nowhere plain; the offset error). GTK: `plays.clip = video.file` makes clip's cells links (accent, ▶ / ♪, header play mark); the pointer on a link: a pointer cursor and an underline; on an empty clip cell or another column: plain; the header tooltip "clip plays in video: click a cell to play it"; a click plays F00118.mp4 in the video card; "plays.t = video.t +1.2" is refused: an offset needs "~" (a time link). Web: the pointer shows over clip cells, not the empty one, and a real click opens the video card |
| M4 | its own parts **PASS** (save/open, an older .omx tiled, the DROID story); goal 76's check M1 and M2 PASS, M3: goal 73 M1–M4 PASS, then its local AppKit cross build fails (this machine's known libSystem link failure, as on main; mac-ci green). As `78-check.py M4` runs goal 76 inside, it reports FAIL until that build step works here; with `G78_SKIP_76=1` it says BLOCKED with the rest passing (build/g78/run-final-4.txt) |

M4: a free .omx reopens with every card where it was (and its zoom); an older .omx opens tiled (table 704 + 8 + chart 704 across
1416). The DROID story with the owner's demo data: row 80's F01596.mp4 plays in the video card, the fleet table 3816 wide shows
all 22 columns (uuid drawn), the video moved beside it, telemetry under, the page scrolled right (3134 + 1416 of 4550).
Goal 76's check (run 1, everything on the free canvas, build/g78/run-76-free.txt): M1 PASS, M2 PASS; M3 FAIL inside goal 73:
73 M2 and M3 (the tiling's geometry and the cards' edges where the tiling puts them) and, inside the chain, goal 47 M8's directed
clip (it finds the chart inside the telemetry card's column) and goal 68 M0 (it reads build/g68/learn/moments.csv, which its own
later milestone writes: a fresh worktree has none; nothing to do with this goal). Run 2, with the three changes below
(build/g78/run-76-m3-b.txt, build/g76/m3/73-check.log): **73-check M1, M2, M3, M4 PASS** (goal 68 M0–M6 with goal 47 M0–M8,
59 M1–M2 and 62 M1 inside; scenario robots exit 0, 0 SLOW lines; components fresh; decisions lint ok). 76 M3 then stops at its
own last step, `scripts/build.sh omxplorer mac`: the Linux→Mac cross link fails on this machine with undefined libSystem and
runtime symbols (_exit, _asin, _nanosleep, KGEN_…), as on main; the Mac is covered by scripts/mac-ci (GitHub macos-26 native
build and run, green twice). Goal 47 M8 didn't hit its single-SLOW-frame flake in run 2.

## Older check steps changed (only where they measured the tiling)

The free canvas is the default now; three older proofs measure the tiling geometry itself, so they run omxplorer with the new
run-level override `OMX_CANVAS=tiled` (the same tiling engine they were written against, kept as "Tile the cards"). No assertion
was changed or removed.

1. `docs/goals/73/m2.py` `check()`: sets `OMX_CANVAS=tiled` (it asserts that a corner drag moves the neighbouring tiles, that
   cards tile with 8 pt gaps and keep 300x200, and that the Board grows by what the cards below couldn't give).
2. `docs/goals/73/m3.py` `check()`: sets `OMX_CANVAS=tiled` (it finds the cards' edges at the pixels the tiling puts them).
3. `docs/goals/47-check.py` `clip()`: runs `scripts/clips.py robots-shots` / `robots` with `OMX_CANVAS=tiled` (the directed
   clip's beats find the chart inside the telemetry card's column, as the tiling lays them out).

Goal 76's M1 and M2 passed on the free canvas unchanged (its "the Board fits its room at launch" is why the canvas only adds its
margin once a card reaches past the window, D-7805).

## Keys under Hyprland

Hyprland (Omarchy) binds Super+arrows to `movefocus` before any app sees them, so on the owner's desktop the Alt scheme is the
one that works as is: Alt+arrows focus, Shift+Alt+arrows move 32 pt, Ctrl+Shift+Alt+arrows move 8 pt (Super's fine move is
Super+Shift+Alt; Alt can't stand in for itself), Ctrl+Alt+arrows resize, Alt+F fill, Alt+T tidy. To hand Super+arrows to
omxplorer instead, in `~/.config/hypr/bindings.conf` (after Omarchy's own):

```
unbind = SUPER, LEFT
unbind = SUPER, RIGHT
unbind = SUPER, UP
unbind = SUPER, DOWN
bind = SUPER, LEFT, pass, class:^(dev\.mojoui\..*)$
bind = SUPER, RIGHT, pass, class:^(dev\.mojoui\..*)$
bind = SUPER, UP, pass, class:^(dev\.mojoui\..*)$
bind = SUPER, DOWN, pass, class:^(dev\.mojoui\..*)$
```

The catch: `pass` sends the key to that window wherever focus is, and Super+arrows no longer move Hyprland's focus anywhere.
Unverified on the owner's desktop (the window class is GTK's application id, `dev.mojoui.App` or `dev.mojoui.bg.<name>`).

## Shots (build/g78/)

- Wide fleet scrolled right: `m1-gtk-1-wide-scrolled-right.png`, `m1-web-1-wide-scrolled-right.png`; the DROID story with the video beside it: `m4-3-droid-story-scrolled-right.png`
- Live resize mid-drag: `m1-gtk-25a.png` (the NW handle half way), `m1-gtk-11a.png` (the table's right edge half way), `m1-web-2-live-resize-mid-drag.png`
- Zoomed out: `m1-gtk-3-zoomed-out.png`, `m1-web-3-zoomed-out.png`
- Tidy: `m1-gtk-4-tidy.png`, `m1-web-4-tidy.png`
- The video column styled: `m3-gtk-1-video-column.png`, hovered `m3-gtk-2-hover-link.png`, `m3-web-2-hover-link.png`; played `m3-gtk-3-played.png`; the offset error `m3-gtk-4-offset-error.png`
- Keys: `m2-gtk-0-focused.png`, `m2-gtk-s7-Super-F.png` (Fill), `m2-gtk-a2-Shift-Alt-ArrowLeft.png`, `m2-web-s7-super-f-fill.png`
- Mac (GitHub macos-26, native build): `build/mac-ci/44465494607/report-macos-26/omxcode-report-omxplorer/`

## Not done, unverified, honest notes

- **The directed DROID clip** (docs/img/clip-robots*.mp4, goal 47) still shows the tiled layout (it runs with OMX_CANVAS=tiled), not the default free canvas; not re-recorded.
- **Audio cells**: drawn with ♪, but mojoui has no audio player: clicking one says "<file> is audio: playing audio isn't built yet".
- **Mac**: AppKit builds and runs omxplorer on GitHub's macos-26 runner (scripts/mac-ci, runs 44464220133 and 44465494607, green);
  the free canvas there is a clipped Board with the corner grip, no live drags, edge handles, zoom or guides (GTK and web only).
  The Linux→Mac cross link fails on this machine (missing libSystem symbols), as on main: 76-check M3's own `build.sh omxplorer
  mac` step fails here for that reason.
- **Hyprland pass-through binds**: written above, not tried on the owner's desktop.
- **Auto-scroll while dragging at the window's edge** is not built: a real hand drags to the edge, lets go, scrolls, drags again
  (the checks drive 900 pt drags with the host's own gesture signals / CDP mouse moves past the viewport).
- GTK's zoomed canvases are the 100 % texture scaled down (the cards' own labels are drawn at the zoomed size); fine at ≤ 100 %,
  soft above it.
- Not done: the reviewer, the merge to main, the push and the Linux download (the contract's "Done means"; out of this
  sub-agent's scope: never push or merge).

## After review round 1: the chain (2026-11-19)
- Goal 76's M3 (goal 73 M1–M4 with 71 → 70 → 68 → 47 inside) on 5b948f72: goal 73 M1–M3 PASS; its M4 FAIL in that run on goal
  68 M2 ("Run it on all didn't fill the similarity column") and goal 47 M8 (SLOW lines), both while the GPU was busy with other
  work. Rerun alone on the same build with the GPU free: `68-check M2: PASS` (BGE's similarity column filled by the agent) and
  `47-check M8: PASS ... 0 SLOW on GTK`. The full chain was not rerun end to end after that.
  Their printed verdicts (`M2: PASS … a similarity column (BGE, by the agent)`, `M8: PASS … 0 SLOW on GTK`) are kept in
  build/g78/solo-reruns-68m2-47m8.txt (the console of that run, copied there; the checks write no file of their own).

## Review rounds 4 and 5 (web drags)
- Round 4: a Ctrl+wheel after the last frame then a release with no move put the card back at the press on the web; the release
  is now flagged FIRST_FRAME when the zoom changed (D-7833), and a drag reads the zoom from the board on the page, since a zoom's
  answer can replace the pressed element (D-7834). M1's zoom-then-release proof fails without D-7833 (chart0 back at 725, its
  last frame 790: build/g78/r6-m1-without-release-fix.txt) and passes with it (r6-m1.txt); before D-7834 it passed both ways.
- Round 5: a release the page never saw (Alt+Tab, let go elsewhere) ends the drag where its last frame left the card, with that
  frame's Alt (D-7835). M1's lost-release proof fails without it (chart0 at width 240, its last frame 718:
  r7-m1-without-lost-release-fix.txt) and passes with it (r7-m1.txt).
- GitHub's macOS 15 and 26 runs: success on 3fffa2ca (44601025991) and on ea8ef1f8 (round 3); rounds 4–5 changed only the web host.
