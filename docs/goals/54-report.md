# Goal 54 report: shell A, and cards that tile

**End goal (owner, 2026-11-05):** fewer islands (a ribbon joined to the menu bar, the bottom joined to the bottom edge)
and cards that tile like Hyprland ("snaps… no dragging problems, no overlapping problems… professional on day one").
Owner picked shell A of `docs/design/chrome/options.html`.

## Result: M0–M4 PASS, reviewer round 2 PASS
```
M0: PASS  insert, remove, resize, swap, fit, text, random (2,000 operations, up to 12 cards)
M1: PASS  10 layouts, no overlap, gaps 8, never a scroll; corner drag -120 then +60 pt, the facing cards moved with the edge; swap exact; 0 SLOW
M2: PASS  edges are chrome and the docked lines are there, light and dark; the board fits at 1920×1080 with titles
M3: PASS  web: cards [1, 2, 3, 2] through open, insert, chart, close; no overlap
M4: PASS  regions, diff_keep, script ok; goal 49 M1–M4 and goal 51 M4 PASS
```

## What changed
- `mojoui/tiling.mojo`: a split tree (Hyprland's dwindle). A new card halves the focused one along its longer side;
  closing gives the space back; a corner drag moves the shared edge (the edge follows the pointer); a drop swaps.
- `mojoui/boardtiles.mojo`: any app's cards kept in step with the tiling (found again by tag and place).
- `Board(clips=True)`: each card held to exactly its tile on GTK (as the web always did), so nothing spills over.
- Liquid's chrome docked: menu bar + toolbar one band on top, tabs + status on the bottom edge, rail and inspector
  flush with a 1 px line, no floating chrome, light and dark, GTK and web.
- The window really resizes now: the inline toolbar used to force 1,713 pt; it's a ribbon (icon over title) at
  ≥ 1,680 pt and icons only below.

## Try it
`scripts/omxplorer.sh build/g47/full/fleet.csv` → Create table → insert a table, a chart, a video: each splits the card
you last touched. Drag a card's corner to resize, its title onto another card to swap, × to close.
Shots: `build/g54/compare.html` (mockup beside the app), `m1-tiles.png` (1280×800, five cards), `m2-shell-light.png`,
`m2-shell-dark.png`, `m2-shell-wide.png`, `m3-web.png`.

## Worth a second look
- D-5406: GTK clips a card's contents at its tile (a narrow video card cuts its "Make a reel" button).
- D-5409: at 1,440 pt the toolbar shows icons only; titles need 1,680. Ribbon tabs would bring titles back at 1,440.
- D-5404/D-5411: the resize proof shrinks then grows; neighbours in a nested column share the space, as Hyprland does.

## Next
Ribbon tabs (titles at 1,440); a per-card minimum so narrow cards reflow instead of clipping; prove dragging on the web.
