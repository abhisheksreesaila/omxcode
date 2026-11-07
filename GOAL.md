# GOAL 61: fresh videos for the omxplorer page, in the tiled shell

**End goal (owner, 2026-11-06: "go, record fresh videos"; goal 59's next step):** the omxplorer page's three clips
(the 100-million-row island, the robot story, the sentence chart) still show the old floating board. They are recorded
again in today's app (the tiled shell, Liquid dark, goal 54/56) and directed as the owner asked for posts
(memory demo-clips-choreographed): a title card, one idea per scene, captions that come first, eased push-ins so one
card fills the frame, a held payoff, an end card with the URL; never a shrunk full-window recording. A new fourth clip
shows goal 59's point: your own model as a script function. Everything is re-renderable from code.

Base: main 882155b. Worktree ../mojo-ui-g61, branch goal-61-clips. (60 is another session's.)

## Milestones
| # | Milestone | Proof (`docs/goals/61-check.py`) |
|---|---|---|
| M0 | One director for every clip | the robot story's composer (scripts/robotclip.py) split into a shared library (scripts/director.py: cards, captions, push-ins, freezes, spotlight, encode) that takes its rectangles from the app at record time, no fixed screen coordinates or card sizes; the robot clip re-rendered from its old take through it |
| M1 | The robot story, re-recorded | docs/img/clip-robots.mp4 (+ -15s, .jpg) from a new take in the tiled shell: every scene's crop inside the window and on the card it names (read from the take's own bounds), the freeze lands at the drop (12.7 s ± 0.3), 1920×1080, 30 fps; contact sheet looked at |
| M2 | The island, directed | docs/img/clip-island-100m.mp4 from the 100M-row file, driven by tags (no click:x,y): opening in the background (the island counts), a chart, "median by region", "by month, as a line", each answer's time in a caption read from the app's own trace; looked at |
| M3 | The sentence, directed | docs/img/clip-sentence-gtk.mp4: a chart over 1M orders edited three times through its ask field, push-in on the chart card, its sentence readable at 1080p; looked at |
| M4 | Your own model | docs/img/clip-models.mp4: the Script window, Apply scene on a robot clip, the labels card lands, the agent's tool named; on docs/models.html; looked at |
| M5 | On the pages | docs/omxplorer.html, index.html, gallery use the new clips and posters, alt text says what each shows; every video plays in Chromium (readyState ≥ 2, no error); sizes under 12 MB each |

## Done means
61-check PASS for M0–M5, every contact sheet looked at, the reviewer passes it.

## Out of bounds
Pushing before the reviewer's PASS; other sessions' worktrees (g50, g52, g53, g55, g57, g60); the frozen
../mojo-ui-apple-test; light-mode recordings (Liquid dark, D-1241); restyling the learn deck; overlays that claim
anything the take doesn't show (every number on screen is read from the app).

## Assumptions (taken instead of asking)
- Linux GTK only (the Mac clip waits for the owner's machine to be free of other work); 1920×1080 output from a
  2560×1440 headless take, as goal 47.
- The robot story keeps its beats (goal 47's script), only re-shot and re-framed; the full 63,344-episode set.
- Silent clips (posts play muted), captions carry the story.

## Budget
150 turns.
