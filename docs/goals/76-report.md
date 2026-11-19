# Goal 76 report: a tabbed ribbon; the side panels closed until asked (2026-11-18)

The owner asked to hide the side panel and inspector and move the left side to the top, and picked from two mockups a
**tabbed ribbon** (Home · Insert · Data · Format · View) and **docked panels, closed by default**. Contract: docs/goals/76.md.
Built by a delegate in ../mojo-ui-g76 (M1, M2, part of M3; it stalled mid-M3), finished in ../mojo-ui-g76-fix after two
review rounds.

## M1: mojoui.ribbon
- `Ribbon(tabs, selected, on_tab, leading, trailing)`: one row of tab names (the app mark leading, the status island
  trailing), one band of the selected tab's captioned groups; compact mode (icons only) under COMPACT_W.
- `View.hidden()` on GTK, web, AppKit and UIKit: the other tabs' tools stay in the tree, so agents and test steps reach
  them (D-7601); the Inspector gained a close button; examples/ribbon in Liquid.
- Shots: build/g76/m1/.

## M2: omxplorer wears it
- No menu bar row, no toolbar row, no rail. Home, Insert (From a file: Table, Documents, Video, Picture, Open, Bags; Make;
  Connect: Links), Data, Format, View, and a contextual Report tab. A leading File menu; the other menus stay hidden in the
  tree for their shortcuts (Ctrl+S, Ctrl+Shift+I, Ctrl+Shift+C fire on GTK and the web; a Mac keeps its system menu bar).
- The check diffs the old menu bar's, toolbar's and rail's 57 messages against the ribbon's: none lost (D-7613's three swaps).
- Panels start closed (the old "inspector=yes" is no longer read; a person's choice is kept as panels=open); inserting a card
  opens no panel; a panel opens from its button, menu item, shortcut, or a tap that asks for it; ✕ closes it; Esc closes it
  from anywhere no cell is being edited (review rounds 1 and 2: the window's Escape item, D-7620, and Esc a card's canvas
  took, D-7623); closed, the board takes the full width (1416 at 1440).
- Shots: build/g76/m2/gtk-1-launch.png, gtk-tab-{home,insert,data,format,view,report}.png, gtk-3-links-docked.png,
  gtk-9-compact.png, web-*.png.

## M3: nothing regressed
- Goal 73's whole check on the final code: M1, M2, M3 PASS; M4 (goal 71's M5 chain) PASS in parts across runs on code that
  differs only in check scripts: goal 68 M0–M5 PASS; M6's goal 47 M0–M7 PASS and M8 PASS on its own rerun (one 50.72 ms
  canvas draw in the full run, the load-sensitive stall goal 73's m8-compare.md documents); goal 59 M1/M2, goal 62 M1 PASS;
  `scripts/scenario.py robots` exit 0 with 0 SLOW; component matrix current; decisions lint ok.
- Older checks updated only where goal 76 moved what they pressed (no assertion or budget changed): goal 73's steps (D-7618),
  goal 62's visitor and harness (D-7624: its data path pointed at a deleted folder), scenario.py's pivot (D-7625).
- Environment, not code: a fresh worktree has no build/g47/full or build/demo (goal 68 M0 and goal 59 M2 failed until the
  data was there; the chain builds g47/full itself late).
- AppKit: the Linux cross build fails at the link step with missing libSystem symbols (_exit, _asin, _opendir…) on this
  machine, and fails the same way on goal 73's commit (d51a7218): not this goal. The Mac build ran on GitHub's macOS runner
  (scripts/mac-ci): see below.

## Not done / unverified
- Narrow windows (1000 wide): the status bar wraps to three lines and the cards run off the bottom; already so on main
  (review round 2); follow-up: one-line status items with an ellipsis.
- iPhone: a hidden view's wrapper hides too (D-7622), not run on a device.
- GTK's `escape` test step proves the window's Escape item fires, not that a real key from a ribbon button reaches it (GTK
  gives the keyboard to the first canvas after a rebuild); the real-key paths are proven on the web and from a card's canvas.
- The Links error for `a.t = b.t +0` reads "t +0 isn't a column"; it should say an offset needs `~` (owner hit it, follow-up).
- Which fleet rows have a video isn't visible (owner, follow-up: draw a video-linked column's cells as links).
