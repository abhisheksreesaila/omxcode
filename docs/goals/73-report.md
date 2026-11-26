# Goal 73 report: links you type with help, a Board that grows, cards with depth (2026-11-17)

The owner ran the DROID links story in the Linux download and asked for four things now (the ribbon waits): autocomplete
in the Links field, cards that can be made big, a canvas that grows as cards are added, and more depth. Contract:
docs/goals/73.md. Built as three milestones in parallel worktrees (g73-links, g73-board, g73-look), merged into
goal-73-links-canvas.

## M1: Links autocomplete (mojoui.links)
- `Links.complete(draft)`: no dot → card names (`fleet.`, `telemetry.`, `episode.`); `card.par` → that card's columns;
  after a whole end → `=` and `~`; then the second end the same way. Replaces only the word being typed; at most 8.
- The Links panel shows them as chips under the field (agent tools `link-pick-k`); Return on a partial draft takes the first
  completion (on an empty field: the first card's name), and so does Return on a whole-looking draft whose last word only
  begins a column the app offers (`clip.mp4.fr`, review round 1: a video card's columns aren't in a table schema, so the
  check couldn't refuse it); a whole link links as before. Nothing links until Return (links stay explicit).
- The host proofs type only `fl`; everything after is Return and chip taps (GTK by widget, the web host by the chips' agent
  tools), the link made by Return on the chips' draft.
- The app feeds video cards (`file`, `t`, `frame`) and document folders beside its tables (`know_card`).
- Found on the way: GTK put a stale held text back into a field after the app cleared it (D-7304); chips three to a row
  widened the inspector over the card beside it, now packed by width (D-7306, M1 checks the panel holds still).
- Shots: build/g73/m1/gtk-2-fl.png … gtk-8-linked.png.

## M2: a Board that grows (mojoui.tiling, mojoui.boardtiles)
- Why it "snapped": the resize already waited for the drag to end, but the Board was exactly the window's room and the tiling
  clamped every neighbour to its minimum. Now a drag past the room makes the Board taller (only the dragged card's row grows;
  the others keep their pixels) and the page scrolls; dragging a bottom card up gives the height back.
- A new card that would squeeze any card under 300×200 goes in a new row below; the page scrolls it into view.
- Proof: GTK and web, real drags: +600 pt drag → table +600, Board 672 → 1272; 7 cards each ≥ 300×200.
- Shots: build/g73/m2/gtk-2-grown-bottom.png, gtk-4-seven-cards.png, web-*.png.

## M3: cards with depth (themes/liquid)
- Light: canvas #d7dee9 (gradient #dde4ee → #cfd8e4) under white cards with a hairline edge and one soft shadow; quiet text
  ink3 #4f5d72 (it was 3.8:1, under 4.5, before this goal). Dark: canvas #0b0d12 under #1b1f27 cards.
- Measured on the shots: light card/canvas step +10.4 L* (GTK), +10.7 (web), was ~7.8; dark +5.8/+6.2, was ~2.4. 36 text
  pairs ≥ 4.5:1 (lowest 4.64).
- The thresholds (step ≥ 8 L* light, ≥ 5 dark; a shadow check in light only) are this goal's own choice, not the contract's.
  Dark's depth comes from the step and the rim; its shadow barely shows on a near-black canvas (0.2–0.9 L*), so "the same,
  inverted" is met by the lift, not by a visible shadow.
- Shots: build/g73/m3/{gtk,web}-{light,dark}{,-before}.png.

## M4: nothing regressed
- Goal 71's M5 chain (70 → 68 → 47) run on the merged branch. Goal 68 M0 failed only on a fresh worktree's missing
  moments.csv (made by a later milestone); rerun PASS.
- Goal 47's M8 (the robots recording on GTK) first failed on "the screen is being rebuilt: ask again" (a link made just as a
  row's video card opened); the agent host now asks again (D-7330). After that it passed once outright (0 SLOW) and failed
  on single SLOW stalls in other runs; the base, run in turns with it, shows the same stalls under load and the same
  distributions (median frame paint 11.8 vs 11.7 ms, canvas draw 1.04 vs 1.04 ms): docs/goals/73/m8-compare.md with every
  run, raw logs under build/g73/m4/. So 73-check M4 is not green on its last run; every part of it has passed on this
  branch (goal 68 M0–M5, M6's components / messages / seek lint, goal 70's lints, goal 47 M0–M7, and M8 in run 1), and
  scenario robots exits 0 (docs/goals/73/m4.py).
- Already failing before this goal (checked on cc33c9d7): tests/test_theme's graphite accent assertion; goal 54's M1 width
  check (board 1066 → 927 for a 160-point narrower window, the check wants ≥ 150).

## Not done / unverified
- AppKit and iPhone not run (chips are plain Buttons; AppKit's test steps still find a field by hint only).
- No autoscroll while dragging near the window's edge; the Board doesn't shorten when a card closes (drag the bottom card up).
- A grown Board's height isn't saved: a document reopens re-tiled to the window (the tiling was never saved; no .omx format
  change; no old .omx file was opened in a proof).
- Completions split the draft at its last space, so a card whose name has a space (a document folder "My docs") completes
  its columns badly; non-ASCII card names whose lower case changes length may slice wrongly (review nits, not fixed).
- The agent host's "ask again" retry (D-7330) is the client honouring the GTK host's own protocol (its input lines and jobs
  already wait for the next idle turn the same way); the rebuild it waits out is real and short.
- The ribbon (next, after the launch posts).
