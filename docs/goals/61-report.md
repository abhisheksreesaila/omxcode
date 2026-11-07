# Goal 61 report: fresh videos for the omxplorer page, in the tiled shell

`scripts/check` (docs/goals/61-check.py): M0–M5 PASS (2026-11-06), Linux, RTX 3090, takes at 2× (3840×2160, GDK_SCALE=2).

| # | Result |
|---|---|
| M0 | scripts/director.py: cards, captions, cameras (any card shape lifted onto a stage above the caption), split views, encoding; robotclip and clipshots use it; no clicks by position, no fixed card sizes |
| M1 | the robot story, re-shot: 57 s + a 16 s cut; every scene's rectangles in the window, video and chart on their cards; video and telemetry side by side at the freeze (12.7 s); captions from the take: 63,344 runs, 16,847,616 rows, 2,997 answers in 77.2 ms |
| M2 | the island: 30 s; the open filmed from the call to its landing; "median by region" 1,945.2 ms and "by month, as a line" 4,901.6 ms, each its own job's time |
| M3 | the sentence: 21.5 s; three asks typed with real keys, the sentence strip held while typing, then the bars; captions = the time under the chart's sentence (0.8, 0.7, 5.7 ms) |
| M4 | your own model: 22 s; the Script window offers scene beside regions and detect; Apply writes `apply_1 = scene(episode, 3.0, 8.0)`; 75 labels in 3,777 ms with the model's load; the agent's tool named; on docs/models.html |
| M5 | omxplorer, index, gallery and models pages use the four clips with posters and descriptions; every video loads in Chromium; each under 12 MB (the robot story 10 MB) |

Found on the way (fixed): at 1× a tile was 300–600 px, soft when pushed in to 1080p (→ 2× takes); the tiled chart is nearly square (→ the split goes side by side); two cards are called telemetry (→ the one holding the chart); a narrow tile cropped to 16:9 dragged in its neighbours (→ cards lifted); chart answers aren't traced (→ read through the agent); the status bar's time was stale and the first island take credited the default chart's 51 ms to "median by region" (→ each answer's own job line); the island's open is too quick to film after a wait (→ filmed from the call).

Reviewer: round 1 NEEDS WORK (the pages' 0.77 s, "22 s", "~40 ms" contradicted the clips; unproven "on the GPU"), round 2 one fix (a device word), round 3 PASS.

Open: the recorded times are slower than goals 30 and 47 measured (median by region 1.9 s vs 0.77 s; the robot question 77 ms vs 37–42 ms), also on an idle GPU. Whether the 2× recording (a 4K screen grab, cairo at 2×) costs it or the engine slowed is not known; the pages cite both with their sources. Frames are looked at by a person (the contact sheets); 61-check reads the takes' logs and files. No Mac clip (the owner's Mac was not used).
