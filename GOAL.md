# GOAL 54: omxplorer shell A, and cards that tile

**End goal (owner, 2026-11-05):** "there are too many islands… the top half… has to be like a ribbon where you connect
it to the menu bar… even the bottom has to be connected to the bottom… [cards] by default… like Hyprland… it snaps,
I can increase something, decrease the size, it fits nicely… no dragging problems, no overlapping problems… professional
on day one." Owner picked shell **A** of `docs/design/chrome/options.html` ("by far the best"): ribbon joined to the
title bar, status bar on the bottom edge, inspector docked flush right, no floating chrome. Framework first: the tiling
is a `mojoui` component with its own test; the docked look is the theme's; omxplorer only composes.

Base: main 809ec81. Worktree ../mojo-ui-g54, branch goal-54-shell. (52 and 53 are other sessions' goals.)

## Milestones
| # | Milestone | Proof (`docs/goals/54-check.py`) |
|---|---|---|
| M0 | `mojoui.tiling` | a split tree as a tiling window manager keeps windows: a new card splits the focused one along its longer side; closing one gives its space to its sibling; resizing moves the card's shared edge (both neighbours change, each keeps a minimum size); a drop on another card swaps them; the layout fits any size; saved and read back as text. `tests/test_tiling.mojo` prints `insert: ok`, `remove: ok`, `resize: ok`, `swap: ok`, `fit: ok`, `text: ok`, and `random: ok` (2,000 random operations at random sizes: never an overlap, every card inside, every gap 8, every card ≥ its minimum where the space allows) |
| M1 | omxplorer's Board tiles | every card on the Board (the sheet's table, charts, pivots, videos, table, track and document cards) placed by `mojoui.tiling`; GTK, driven by real gestures (`MOJOUI_TEST`): open the fleet, insert the telemetry table, a chart, the featured video, a query's answer; close one; drag one card's corner (its edge moves, its neighbour gives way); drag one card onto another (they swap); the window 1440×900 → 1280×800. After every step the `BOARD:` lines show no overlap, every card inside the board, gaps 8 ± 1; after the corner drag the neighbour's size changed by the same amount; after the drop the two rects swapped; 0 `SLOW:` at 50 ms |
| M2 | Shell A on GTK, light and dark | Liquid's chrome docked: menu bar and toolbar one band on the window's top edge, sheet tabs and status bar one band on the bottom edge, the inspector flush right and the rail flush left, each with a 1 px line where it meets the board; no margin, radius or shadow on chrome. Pixels in a 1440×900 shot: the top-left, top-right, bottom-left and bottom-right corners and the right edge mid-height are chrome, not backdrop, in Liquid light and Liquid dark; the shots sit beside the mockup's on one compare page, looked at |
| M3 | The web host too | `scripts/omxplorer.sh web`'s build in headless Chromium (`scripts/drive.py`): the same edge pixels are chrome; after inserting two cards and closing one, no overlap |
| M4 | Nothing regressed | `tests/test_regions.mojo`, `tests/test_diff_keep.mojo`, `tests/test_script.mojo` ok; goal 49's check M1–M4 and goal 51's M4 on this tree |

## Done means
54-check PASS for M0–M4, the reviewer passes it, M1's and M2's shots were looked at next to the mockup.

## Out of bounds
Pushing; the frozen ../mojo-ui-apple-test; other sessions' worktrees (../mojo-ui-g50, g52, g53); pip; deleting .pixi;
lowering a proof; skins other than Liquid (Ledger, Graphite, Blueprint keep their own looks); the Mac and phones
(their chrome reads the same Surfaces, unverified here).

## Assumptions (taken instead of asking)
- A split tree (Hyprland's dwindle) replaces goal 31's parked row tiling; `tests/test_tiling.mojo` is rewritten.
- Resizing uses the Board's existing corner drag (the card's right and bottom edges move); no separate gap handle.
- Moving uses the existing header drag: dropped on a card it swaps, dropped elsewhere it snaps back.
- The rail stays, docked left (it inserts tables, documents, videos, pictures).
- Saving the tiling in .omx files is out of scope (cards other than charts aren't saved today either).

## Budget
160 turns (raised from 80 on 2026-11-05, D-5407: M0–M1 took about 75; the owner asked to continue).
