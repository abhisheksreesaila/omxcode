# GOAL 49: one script over everything on the board

**End goal (owner, 2026-11-04):** "large scale data, large scale video, AI plugins, manipulate through script, and agents
to it all at once… script always beats UI, especially in the agent world… the UI becomes a shell and the script becomes
the main driver." Robotics first: "pick a section of video and apply, it instantly gives you the answer, then you hit cut
or save or export and boom, ship it to your colleague." Story over variety (~15 clips). **Framework first:** "omxplorer is
just a byproduct… don't overfit": every piece is a `mojoui/` component with its own test; omxplorer only composes them.
Draft and its 15-clip story: docs/goals/49-draft.md.

Base: main bfacc58 (goal 47's DROID fleet in build/g47/full, goal 48's AG-UI). Worktree ../mojo-ui-g49, branch goal-49-script.

## Milestones
| # | Milestone | Proof (`docs/goals/49-check.py`) |
|---|---|---|
| M0 | The story, as beats | docs/goals/49/story.md: 15 numbered beats, each with a caption, the card to zoom, the payoff frame and the agent tool(s) that drive it (`tool:` lines); every tool named there exists in M4's tool list |
| M1 | `mojoui.script` | `mojoui/script.mojo`: a script is statements (`name = SELECT …;`, `name = fn(args);`, a bare `SELECT`), run in order over a Catalog, each named result kept as a table later statements can read; errors carry the statement's line; a function registry (name → Mojo function returning a table) so models plug in later; `tests/test_script.mojo` prints `parse: ok`, `run: ok`, `chain: ok`, `error: ok`, `fn: ok` |
| M2 | A video is a table | every video card is a table in the catalog (`frame`, `t`, cheap: from the video's info, no decode, no analysis); in omxplorer's Script window (tags `script`, `script-text`, `run-script`), one script joins the featured episode's video, telemetry and the fleet; each named result lands as a card (`table-<name>`); the row counts equal pyarrow's on build/g47/full; `SCRIPT:` lines in the trace |
| M3 | Select, Apply, Export | pick a range on a video card (`range-from`, `range-to` or the player's selection), Apply (`apply-<fn>`) writes `name = regions(video, from, to);` into the script and runs it: the GPU analyzer (videotable) over only those frames, the result a card, results streamed as a job (0 `SLOW:` at 50 ms); Export (`export-recipe`) writes a folder: the cut clip (`videoexport.cut`), each result as CSV, and `script.sql`; the clip's frame count equals the range's |
| M4 | Recipes + agents | Open recipe (`open-recipe`) re-runs a saved script on another episode (its names rebound); `scripts/scenario.py script` plays the story through agent tools only (no clicks), writes build/g49/script.json with every tool it called; its answers equal M2/M3's |
| M5 | Nothing regressed | `tests/test_asksql.mojo`, `tests/test_tablejobs.mojo`, `tests/test_videotable.mojo` pass; goal 47's check M2 and M4 pass on this tree |

## Done means
49-check PASS for M0–M5, the reviewer passes it, M2–M4's shots (build/g49/shots/, GTK, Liquid dark) were looked at.

## Out of bounds
Pushing; merging into main before the reviewer's PASS; the frozen ../mojo-ui-apple-test; pip; deleting .pixi; paid
services; secrets; lowering a proof; notebook cells (owner: compile friction).

## Assumptions (taken instead of asking)
- Models ("AI plugins") are not in this goal: YOLOX in-process packs are plan tickets F-5/F-6 and decision models F-7
  (docs/plans/omxconsole-native.md, D-4756). This goal builds the slot they plug into (M1's function registry) and proves it
  with the GPU analyzer that already exists (`regions`). Goal 50: `detect()` (YOLOX pack) and `classify()` (an open System 1
  decision model, owner: "any decision model which can give you the answer").
- Script syntax = SQL statements plus `name = fn(args)`: what agents write best, runs with no compile (the engine plans SQL).
  Custom Mojo function bodies in a script (draft M5) wait for a later goal.
- The script's joins are written out, so they stay explicit: the "nothing joins until a link exists" rule holds (the script
  is the link). `JOIN LINKED` still works inside a script.
- Video ⨝ telemetry joins on episode and frame (`round(t * fps)`): DROID's video and telemetry are both 15 Hz.
- The Script window grows from omxplorer's Query dialog (TextArea); a real code editor component is later.

## Budget
80 turns.
