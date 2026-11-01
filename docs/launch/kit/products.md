# Posting plan per product · Nov 1–8, 2026

One table per channel. Rows run omxcode, omxcore, omxconsole, omxplorer, then omxlabs as the umbrella. The week's
order is: **omxplorer opens it on Sunday** (the robot story), then one product every other day: omxcode on Tuesday, omxcore
on Thursday, omxconsole on Saturday. The talk decks are in [talks/](talks/): open a deck's `index.html`, press `S` for
the speaker notes, record yourself talking through it. Each talk folder's README has the YouTube titles, thumbnail
text, description and chapters.

Placeholders to swap before posting: `[YouTube: <product> part N]` → the uploaded video's link; `LINK-TO-SUNDAY-POST`
(in omxcode.md) → Sunday's forum post URL. Every number in these posts is sourced in the file's footnote or in
[sources.md](sources.md).

## Talks to record (Sunday morning, one sitting)

| Talk | Parts · slides · minutes | Deck |
|---|---|---|
| omxplorer | part 1 · 14 · 4.8 · Why did the robot drop it?<br>part 2 · 14 · 5.1 · Not a replay. An investigation.<br>part 3 · 12 · 4.5 · Beyond robots, and what's next | [talks/omxplorer/](talks/omxplorer/README.md) |
| omxcode | part 1 · 13 · 4.3 · One Mojo app, every screen<br>part 2 · 14 · 4.6 · Never freezes, and agents drive it | [talks/omxcode/](talks/omxcode/README.md) |
| omxcore | part 1 · 13 · 4.2 · SQL on your CPU and your GPU<br>part 2 · 13 · 3.4 · The numbers, and the honest edges | [talks/omxcore/](talks/omxcore/README.md) |
| omxconsole | part 1 · 13 · 4.3 · Your GPU as a private model server<br>part 2 · 14 · 4.4 · Porting with Claude Code, and a console in Mojo | [talks/omxconsole/](talks/omxconsole/README.md) |
| omxqua *(optional)* | one part · 14 · 5.1 · Google's surfaces, Apple's springs | [talks/omxqua/](talks/omxqua/README.md) |

Minutes are the speaker notes read at 150 words a minute (`talks/build.py` prints them). If you only have an hour:
omxplorer 1 and 2, then omxcode 1, omxcore 1, omxconsole 1.

## Modular forum (forum.modular.com)

| Day | Product | What to post (title · first line) | Full text | Media | Talk to record |
|---|---|---|---|---|---|
| **Tue Nov 3** | omxcode | *omxcode: writing native apps in Mojo, how it works under the hood* · "On Sunday I showed omxplorer, a robot-data app. Today is the framework under it, omxcode, for anyone who wants to write apps in Mojo themselves." | [modular-forum/omxcode.md](modular-forum/omxcode.md) | `[YouTube: omxcode part 1]`, shots named in the file | omxcode part 1 (part 2 linked in a reply) |
| **Thu Nov 5** | omxcore | *omxcore: a SQL engine written top to bottom in Mojo, on CPU and GPU* · "On Sunday I showed omxplorer, a data app in Mojo. Today it's the engine underneath it: omxcore." | [modular-forum/omxcore.md](modular-forum/omxcore.md) | TPC-H bars (omxcore part 2) or `omxcore-bench.png` | omxcore part 1 (part 2 for the numbers) |
| **Sat Nov 7** | omxconsole | *omxconsole: every model behind one local URL on MAX, asleep until called* · "Last of my posts this week: omxconsole, a small model server on top of MAX." | [modular-forum/omxconsole.md](modular-forum/omxconsole.md) | `[YouTube: omxconsole part 1]`, a console screenshot | omxconsole part 1 (part 2 for porting) |
| **Sun Nov 1**, evening | omxplorer | *Why did the robot drop it? A data app written entirely in Mojo, on the GPU* · "Hi all. I've been building a UI framework in Mojo, called omxcode, and I'd like to show you what it can do now." | [modular-forum/post.md](modular-forum/post.md) | `[clip: robots-45s]`, `[shot: failure-cursor]`, `[shot: mac-linux]` | omxplorer part 1 (link part 2 in the first reply) |
| all week | omxlabs | No post of its own. Each post ends with omxlabs.tech; replies from [modular-forum/replies.md](modular-forum/replies.md) | — | — | — |

## X

| Day | Product | What to post (first line) | Full text | Media | Talk to record |
|---|---|---|---|---|---|
| **Tue Nov 3** | omxcode | 5-post thread · "The framework under omxplorer: omxcode." | [x/omxcode.md](x/omxcode.md) | named under each post | omxcode part 1 |
| **Thu Nov 5** | omxcore | 5-post thread · "The engine under omxplorer is a SQL engine written top to bottom in Mojo. No Python inside." | [x/omxcore.md](x/omxcore.md) | named under each post | omxcore part 1 |
| **Sat Nov 7** | omxconsole | 5-post thread · "Your GPU, as a private model server." | [x/omxconsole.md](x/omxconsole.md) | named under each post | omxconsole part 1 |
| **Sun Nov 1**, 1 h after the forum | omxplorer | 7-post launch thread · "Why did the robot drop it?" | [x/thread.md](x/thread.md) | `[clip: robots-45s]` and one per post | omxplorer part 1 |
| Mon Nov 2 → Sun Nov 8, mornings | omxlabs | one post a day on the omxplorer story (the data is real, never freezes, one cursor, links, agents, two GPUs, where it's going) | [x/daily.md](x/daily.md) | named per day | — |

On Tue, Thu and Sat the product thread goes out in the evening, so it doesn't sit on top of that morning's daily post.
All X posts are ≤ 280 characters: `pixi run python docs/launch/kit/x/check_lengths.py`.

## YouTube

| Day | Product | What to post (title) | Full text | Media | Talk to record |
|---|---|---|---|---|---|
| **Tue Nov 3** | omxcode | part 1 · *One Mojo app, every screen: GTK, web, Mac, Android* | [talks/omxcode/README.md](talks/omxcode/README.md) | the recorded talk | omxcode part 1 |
| Wed Nov 4 | omxcode | part 2 · *The UI thread never freezes: how omxcode does it in Mojo* | same | the recorded talk | omxcode part 2 |
| **Thu Nov 5** | omxcore | part 1 · *A SQL engine written entirely in Mojo, on CPU and GPU* | [talks/omxcore/README.md](talks/omxcore/README.md) | the recorded talk | omxcore part 1 |
| Fri Nov 6 | omxcore | part 2 · *Mojo SQL engine vs DuckDB on simplified TPC-H, honestly* | same | the recorded talk | omxcore part 2 |
| **Sat Nov 7** | omxconsole | part 1 · *Your GPU as a private OpenAI-compatible server, on MAX* | [talks/omxconsole/README.md](talks/omxconsole/README.md) | the recorded talk | omxconsole part 1 |
| Sun Nov 8 | omxconsole | part 2 · *MAX can't run your model? Claude Code ports it* | same | the recorded talk | omxconsole part 2 |
| **Sun Nov 1** | omxplorer | part 1 · *Why did the robot drop it? Real robot data, one GPU app* | [talks/omxplorer/README.md](talks/omxplorer/README.md) | the recorded talk | omxplorer part 1 |
| Mon Nov 2 | omxplorer | part 2 · *Not a replay. An investigation.* | same | the recorded talk | omxplorer part 2 |
| Thu Nov 5 | omxplorer | part 3 · *Beyond robots: sheets, video and paperwork on one GPU* | same | the recorded talk | omxplorer part 3 |
| any day after | omxlabs | omxqua · *omxqua: Google's surfaces, Apple's springs, three files* (optional) | [talks/omxqua/README.md](talks/omxqua/README.md) | the recorded talk | omxqua |

The talks are separate from the five screen-recorded videos in [youtube/](youtube/) (scripts for Mon–Fri in the
README calendar). If time is short, the talks win: they're ready to record from a deck; the screen videos need the app.
Make a playlist per product, and one "omxlabs" playlist with every part.

## Product Hunt

| Day | Product | What to post | Full text | Media | Talk to record |
|---|---|---|---|---|---|
| Thu Nov 5 | omxcode | mentioned in the maker comment (the open-source framework under it) | [product-hunt/first-comment.md](product-hunt/first-comment.md) | — | — |
| Thu Nov 5 | omxcore | mentioned in the maker comment (the engine) | same | — | — |
| Thu Nov 5 | omxconsole | mentioned in the maker comment (local AI on the same GPU) | same | — | — |
| **Thu Nov 5**, 12:01 am PT *(fallback Tue Nov 10)* | omxplorer | **The launch.** *omxplorer · Sheets, video and documents on your own GPU, agent-ready* | [product-hunt/listing.md](product-hunt/listing.md), [launch-day.md](product-hunt/launch-day.md) | gallery of 9 shots; video: omxplorer part 1 or YouTube 1 | omxplorer part 1 |
| Thu Nov 5 | omxlabs | the maker profile and the link (omxlabs.tech) | — | — | — |

Launch only when omxlabs.tech is live with a way to try omxplorer ([no-excuses-fund/live-checklist.md](no-excuses-fund/live-checklist.md)).

## No Excuses Fund (noexcuses.get.tech, by Dec 15)

| Day | Product | What to post | Full text | Media | Talk to record |
|---|---|---|---|---|---|
| — | omxcode | one line in the submission: the framework under omxplorer | [no-excuses-fund/submission.md](no-excuses-fund/submission.md) | — | — |
| — | omxcore | one line in the submission: the engine | same | — | — |
| — | omxconsole | one line in the submission: local AI beside it | same | — | — |
| by **Dec 15** | omxplorer | **The main submission**, told through the robot story ("why did the robot drop it?") | same, plus [live-checklist.md](no-excuses-fund/live-checklist.md) | `[clip: robots-45s]`; omxplorer part 1 as the video | omxplorer part 1 |
| once omxlabs.tech is live | omxlabs | the entrant (the umbrella); the announcement on X and LinkedIn | [no-excuses-fund/announce.md](no-excuses-fund/announce.md) | `[clip: robots-15s]` | — |
