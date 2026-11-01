# omxcode launch kit · Nov 1–8, 2026

One story everywhere: **why did the robot drop it?** Real robot data (DROID), opened in **omxplorer**, built on
**omxcode**. Your job is to record and publish; every word here is copy-paste ready.

**Order:** Modular forum first (Mojo developers see it before anyone else), then X, then YouTube. Product Hunt later in
the week, once `[clip: robots-45s]` is recorded and omxlabs.tech is live with a way to try omxplorer.

**Shot list:** [shot-list.md](shot-list.md): every `[clip: …]` and `[shot: …]` named in the kit, what's on screen,
and the 10-minute check before recording (the featured drop is F00118; the clip and shots already exist).

**Per product:** [products.md](products.md): the posting plan per channel (Modular forum, X, YouTube, Product Hunt,
No Excuses Fund) with one row per product: omxcode, omxcore, omxconsole, omxplorer, omxlabs. The talks to record are in
[talks/](talks/): a Reveal.js deck per product (omxplorer in 3 parts, omxcode, omxcore and omxconsole in 2, omxqua in 1),
speaker notes on every slide (press `S`), and a README per product with YouTube titles, thumbnail text and chapters.
Edit `talks/_src/*.html`, then `pixi run python docs/launch/kit/talks/build.py`; check with `talks/shoot.py`.

**Claims:** [sources.md](sources.md): every number and where it comes from, the claims that depend on tonight's build,
and what we must not say. Lines marked *(drop line)* change to "why did it fail?" if your episode isn't a drop.

## Calendar

| Day | Channel | What to post | File | Media |
|---|---|---|---|---|
| **Sun Nov 1**, evening | Modular forum | The first post (Community Showcase) | [modular-forum/post.md](modular-forum/post.md) | `[clip: robots-45s]`, `[shot: failure-cursor]`, `[shot: mac-linux]` |
| Sun Nov 1, 1 h later | X | The launch thread, 7 posts | [x/thread.md](x/thread.md) | one per post, named in the file |
| Sun Nov 1 | (record) | Talk: the launch | [talking-points.md](talking-points.md) § Sun | — |
| Sun Nov 1 → all week | Modular forum | Replies | [modular-forum/replies.md](modular-forum/replies.md) | — |
| **Mon Nov 2** | X | Daily: the data is real | [x/daily.md](x/daily.md) § Mon | `[shot: fleet-sheet]` |
| Mon Nov 2 | YouTube | 1 · Why did the robot drop it? | [youtube/01-why-did-the-robot-drop-it.md](youtube/01-why-did-the-robot-drop-it.md) | `[clip: robots-45s]` and the full take |
| **Tue Nov 3** | X | Daily: never freezes | [x/daily.md](x/daily.md) § Tue | `[shot: slow-terminal]` |
| Tue Nov 3 | YouTube | 2 · The UI thread never freezes | [youtube/02-the-ui-thread-never-freezes.md](youtube/02-the-ui-thread-never-freezes.md) | `[clip: never-freeze]`, `[clip: slow-line]` |
| **Wed Nov 4** | X | Daily: one cursor | [x/daily.md](x/daily.md) § Wed | `[clip: robots-15s]` |
| Wed Nov 4 | YouTube | 3 · One Mojo codebase → Linux + Mac | [youtube/03-one-mojo-file-linux-and-mac.md](youtube/03-one-mojo-file-linux-and-mac.md) | `[clip: linux-run]`, `[clip: mac-run]` |
| **Thu Nov 5** | X | Daily: explicit links | [x/daily.md](x/daily.md) § Thu | `[shot: linked-doc]` |
| Thu Nov 5 | YouTube | 4 · Video + chart + documents, linked | [youtube/04-video-chart-documents-linked.md](youtube/04-video-chart-documents-linked.md) | `[clip: scrub-cursor]`, `[clip: ask-join-linked]` |
| Thu Nov 5 *(if ready)* | Product Hunt | omxplorer launch, 12:01 am PT | [product-hunt/](product-hunt/listing.md) | gallery of 9 shots, YouTube 1 |
| **Fri Nov 6** | X | Daily: agents | [x/daily.md](x/daily.md) § Fri | `[clip: agent-drives]` |
| Fri Nov 6 | YouTube | 5 · Agents drive the app | [youtube/05-agents-drive-the-app.md](youtube/05-agents-drive-the-app.md) | `[clip: agent-drives]`, `[clip: agui-chat]` |
| **Sat Nov 7** | X | Daily: one codebase, two GPUs | [x/daily.md](x/daily.md) § Sat | `[shot: mac-linux]` |
| **Sun Nov 8** | X | Daily: where it's going | [x/daily.md](x/daily.md) § Sun | `[shot: code-file]` |
| Tue Nov 10 *(fallback)* | Product Hunt | If Thu Nov 5 wasn't ready | [product-hunt/launch-day.md](product-hunt/launch-day.md) | — |
| Once omxlabs.tech is live | X, LinkedIn | The No Excuses Fund entry | [no-excuses-fund/announce.md](no-excuses-fund/announce.md) | `[clip: robots-15s]` |
| By **Dec 15** | noexcuses.get.tech | Submission | [no-excuses-fund/submission.md](no-excuses-fund/submission.md), [live-checklist.md](no-excuses-fund/live-checklist.md) | — |

Each day's talk (Sun–Sat) is in [talking-points.md](talking-points.md): record it as a short, or as that day's
YouTube intro.

## Recording order (one sitting)

Record the five videos back to back on Sunday or Monday: 1 → 4 (same app state, the robot data loaded), then 2 (turn
on `MOJOUI_BUDGET_MS`), then 5 (connect Claude Code), then 3 last (it needs the MacBook). Grab the shots as you pass
each screen. About 25 minutes of finished video.

## The deck

[deck/index.html](deck/index.html): 12 slides, Reveal.js from a CDN, Liquid dark, speaker notes on every slide (press
`S`). Open it in a browser; arrow keys to move. Slide 5's app picture is a drawing: play `[clip: robots-15s]` over it
when presenting. Screenshots: `build/kit/shots/` (not committed).

## Before each post

- The clip shows what the text says (sources.md, "claims that depend on tonight's build").
- Links: until omxlabs.tech is live, use `abhisheksreesaila.github.io/omxcode`; afterwards, swap to `omxlabs.tech`.
- Mac lines say "checked on GitHub's virtual Macs". If you record the Metal build on your MacBook, you may replace that with what its GPU line shows.

## After the week

Write down what happened (views, stars, comments, PH result) here; the No Excuses Fund's traction answer needs it.
