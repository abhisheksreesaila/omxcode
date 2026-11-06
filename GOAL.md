# GOAL 56: omxplorer on the owner's Mac, and omxqua's latest details

**End goal (owner, 2026-11-06):** "you can test this on the mac as well, we have connection to mac… omxplorer, it needs
to have the latest design principles from omxqua, and omxcore (gpu rendering etc)… go on autopilot and dazzle me."
Goal 54's shell A and tiling, proven on the owner's own Mac (Apple M4, Metal, a real screen) instead of only GitHub's
GPU-less runners; and omxqua v0.1.6's details (2026-11-05: the focus ring, tabular figures) in the framework's Look, so
every Liquid app gets them. omxcore: the vendored engine is already its newest stable (834ef9a, STABLE.md 2026-10-29;
everything newer is in review with breaking builder changes), so nothing to vendor; the Mac build runs it on Metal.

Base: main 1247c2d. Worktree ../mojo-ui-g56, branch goal-56-omxqua. (55 is another session's.)

## Milestones
| # | Milestone | Proof (`docs/goals/56-check.py`) |
|---|---|---|
| M0 | Sentences size their card | `mojoui.sentence.sentence_lines` counts the lines `Sentence` draws at every width (tests/test_sentence.mojo); a chart card's title bar is as tall as its sentence's lines (mojoui.sheetpage), its words broken for the tile's width |
| M1 | The owner's Mac | `scripts/mac-ssh` builds omxplorer natively on the owner's Mac (Metal) and runs docs/goals/56/mac.steps with appearance=system; from its report: the window keeps 1440 wide through the import (a fixed width that also filled shrank it to 1200); a jump 1920 → 1440 lands at 1440 (the labelled ribbon held it at 1529); after `scheme:light` the chrome corners are light, after `scheme:dark` dark; every chart sentence ends above its card's body and none of its words is squeezed to nothing; no two Board cards overlap; `tap:close-limits` finds the button by its tag and the limits card is gone after it; a corner drag of -100 changes the table card's width by -100 ± 10 and `dragcard:chart0=chart1` swaps their frames exactly (end_tiled_drag, which a real drag's end also calls; the drag's start — which corner, the cancel — and the snap-back of the dragged view are run only by a real drag, unverified by a step); the island says the Apple GPU is ready (its spoken words, in the dump) |
| M2 | omxqua's focus ring | Look.focus (the accent, 2 px, 2 px clear, keyboard only) written by GTK and the web; GTK (the gallery in Liquid): a button given keyboard focus has the accent on all four sides 2–4 px outside its bounds, and not before; web (omxplorer in Chromium): Tab to the first focusable control → its computed outline is 2px solid in the app's accent (--o-accent), offset 2px |
| M3 | Tabular figures everywhere | Liquid's TypeScale.tabular on GTK too (D-301's debt): the gallery's "1,111.11" and "8,888.88" are equally wide under Liquid and not without it; the web's computed font-feature-settings says tnum |
| M5 | The page shows it | docs/omxplorer.html's "The look" shows the same tiled board in Liquid dark on the Mac (the M1 run's last picture), Linux (GTK) and the web (Chromium): docs/img/omxplorer-shell-{mac,linux,web}.jpg, each 1440×900 with dark corners, looked at (owner, 2026-11-06: "this will need new screenshots obviously… dark mode version") |
| M4 | Nothing regressed | goal 54's check M1, M2 and M3 pass on this tree; tests/test_tiling, test_boardtiles, test_sentence ok |

## Done means
56-check PASS for M0–M5, the reviewer passes it, the Mac's pictures were looked at.

## Out of bounds
Pushing (main is pushed only after the reviewer's PASS and green checks, per the owner's standing OK); the frozen
../mojo-ui-apple-test; other sessions' worktrees (g50, g52, g53, g55); pip; deleting .pixi or anything on the owner's Mac
outside ~/omxcode-g54; lowering a proof; vendoring an omxcore commit that isn't in its STABLE.md.

## Assumptions (taken instead of asking)
- The owner's Mac may be used for runs (they offered it); windows open on its screen for a minute each run.
- The Mac keeps its native focus ring (system accent); omxqua's accent ring is GTK's and the web's for now.
- omxplorer stays dark by default (D-1241); the Mac proof sets appearance=system to see both.

## Budget
80 turns.
