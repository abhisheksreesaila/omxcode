# YouTube 2 · The UI thread never freezes

**Length:** about 4 min · **Record:** omxplorer + a terminal; `examples/slowcheck`; the editor · **Post:** Tue Nov 3

## Titles (≤ 60 characters)
1. Keeping the UI thread free: how my Mojo framework does it
2. Scrub video while a query runs: no frozen window
3. One rule that keeps every app smooth

**Thumbnail:** the grid mid-scroll beside `[shot: slow-terminal]`; big text **0 SLOW FRAMES**; small: `video · query · export`.

## Script

| Time | On screen | Say |
|---|---|---|
| 0:00 | A frozen window (any app with a spinner) | "You click, and the window freezes. Every app has done it to you. Here's how mine is built to avoid it." |
| 0:15 | Diagram: one UI thread, 16 ms per frame (draw it, or a slide from the deck) | "Every platform draws on one thread. At 60 frames a second that thread has 16 milliseconds. Anything longer, a query, a file, a video seek, and the window stops." |
| 0:45 | `[shot: code-file]`, highlight `update()` and `view()` | "So omxcode splits every app in two. update and view run on the UI thread and only decide. They change state and describe the screen." |
| 1:15 | The `start_ui_job` snippet from docs/ui-threads.md | "Anything slow is a job. It runs on its own thread with its own copy of the data, and its answer comes back to update as an ordinary event. Your state is only touched on the UI thread, so there are no locks in your app." |
| 1:50 | `[clip: never-freeze]`: start an import, scroll, scrub | "Here it is in the robot app. I start a big query and keep scrubbing the video. The video has its own decoder thread: opening takes about 40 microseconds, a seek about 6, and the newest seek wins." |
| 2:30 | Terminal with `MOJOUI_BUDGET_MS` | "How do I know? A watchdog. Set a budget and anything over it prints a SLOW line, naming the message. My checks run video, query and export sessions at a 50 ms budget, headless with CPU drawing. Zero lines. One honest edge: a median over 100 million rows in memory still makes the window wait, about 0.7 s. Moving that off the UI thread is on the list." |
| 2:55 | `[clip: slow-line]` | "And here's what it looks like when an app breaks the rule. You see it before your users do." |
| 3:15 | The Mac numbers (slide) | "On the Mac, jobs used to run on the main thread. During a one-and-a-half second job, the window went a full 1.5 seconds without a frame. With threads, the longest gap is 71 to 83 milliseconds, on GitHub's virtual Macs. Real hardware is next." |
| 3:40 | Repo, docs/ui-threads.md | "Five rules, written down in the repo. Follow them and your app doesn't freeze. Link below." |

## Description

```
Every platform draws on one thread, with about 16 ms per frame. omxcode, my UI framework in Mojo, is built to keep it free: update() and view() only decide, slow work runs as jobs on their own threads, and a watchdog prints a SLOW: line for anything over budget. Shown in omxplorer, scrubbing robot video while a query runs.

The rules: https://github.com/abhisheksreesaila/omxcode/blob/main/docs/ui-threads.md
Code: https://github.com/abhisheksreesaila/omxcode
Site: https://abhisheksreesaila.github.io/omxcode/

Chapters
0:00 The frozen window
0:15 One thread, 16 ms
0:45 update() and view() only decide
1:15 Slow work is a job
1:50 Scrubbing video during a query
2:30 The watchdog
2:55 Catching a slow update
3:15 The Mac
3:40 The rules
```

**Tags:** UI thread, responsive UI, concurrency, threads, Mojo, Mojo language, GTK, AppKit, app framework, GPU, video player, omxcode, omxplorer, performance

*Sources: S5, S6, S7, S8; the 16 ms frame and the rules from docs/ui-threads.md.*
