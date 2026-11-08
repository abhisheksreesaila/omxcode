# GOAL 62: omxplorer on the web, safe to share

**End goal (owner, 2026-11-06: "start the fixes – always good to host a working copy… we can deploy to railway and reduce load if we have to… nothing like touching the app on the web without installs"):** anyone with the link opens omxplorer in a browser, installs nothing, and plays the whole robot story on a hosted copy: the 63,344 DROID runs, the pivot by lab, F00118's video with its sensor lanes, and the question that finds the 2,997 regrasps. The web host is safe on the public internet, serves several visitors at once from one CPU-only server, and is packaged for Railway, so going live at app.omxlabs.tech is one step the owner takes.

Today (the browser check, 2026-11-06; results in ~/.abode/home/worktrees/mojo-ui/t3-4d3cae42/build/webcheck/): every beat works in headless Chromium on localhost, and a CPU-only server does as well as a GPU one. It isn't safe to share:
- a crafted POST /e/{sid} makes the app open any server path;
- the Start screen's Recent list shows other visitors' files, with their server paths;
- Export pack writes PDFs and clips into the server's documents folder;
- every GET / makes an app session (cap 200, no idle timeout);
- each tab loads its own copy of the data, about 3 GB per visitor (omxplorer's init_shared loads nothing);
- visitors can only open files by uploading them, and the story's questions need an agent to write their SQL;
- open, chart and column jobs never wake the page when they finish, so a tab with no moving canvas can hang;
- a canvas fetches one picture at a time and fetches unchanged ones again (the video panel pulled 580 KB/s for 90 KB/s of new pictures); nothing was measured over a network;
- the Board's layout at 1440×900 is on the check's polish list.

Base: origin/main 882155b (goal 59).

## Milestones
| # | Milestone | Proof (`docs/goals/62-check.py`) |
|---|---|---|
| M0 | Jobs wake the page | 20 fresh web servers, each opening fleet.csv in a tab with no moving canvas: the table lands in all 20 within 10 s; a test per background job kind in mojoui/sheetjobs.mojo shows the host is woken when the job ends |
| M1 | The robot starter, shared | CPU-only server (CUDA_VISIBLE_DEVICES=""): a visitor starts the robot story from the Start screen with one click, with no upload and no agent link, and gets the fleet (63,344 rows) linked to its telemetry (16,847,616 rows), clips and paper. The story's questions are there in words, each run with one click (2,997 regrasps; the 4 fastest), with their SQL shown. The starter loads once per server and read-only: each further tab that plays the whole story adds under 300 MB at rest, and the starter's files hash the same before and after the check. The Start screen credits DROID (CC-BY-4.0) |
| M2 | Nothing on the server is reachable | in public mode, a probe suite, each refused with nothing opened, written or listed: crafted requests naming a server path to every route that takes text (/e, /w, /save, /upload, /dropfile, /reply, …) for pickers, savers and other controls; reading a server path from the Script window and from SQL; path traversal on /static, /assets and /static/fonts; uploads over the per-file and per-visitor caps; the agent link and /dev routes are off. A second visitor's Start screen shows nothing from the first, and no response any visitor gets during the story contains a server path |
| M3 | Visitors' sessions end | 500 plain GET / (no browser) make no app session; a real tab makes one; a tab idle past the timeout (shortened for the check) closes, says so, and its files are gone; past the cap a new visitor gets a busy page, not an error; Export pack arrives in the browser as one download and leaves nothing on the server |
| M4 | Over a real network | through a delaying proxy in front of the server (every connection the page uses, WebSockets included) adding 100 ms of round trip, 10 Mbit/s down and 5 up: the story passes, F00118 plays at ≥ 12 pictures a second, and a click to the answer takes ≤ 600 ms; a still view fetches nothing once drawn (0 bytes in 5 s); the playing video uses ≤ 1.5× the bytes of its new pictures; screenshots at 1440×900 and 390×844 (phone), looked at |
| M5 | Packaged for Railway | an image with the web version and the starter: non-root, app and data read-only, listens on $PORT, a health check, logs on stdout; the image builds and the story passes against it (BLOCKED, not FAIL, while this user can't reach Docker). With the same start command held to the memory and CPU of the Railway plan chosen (docs/research/railway.md; for example systemd-run --user -p MemoryMax=… -p CPUQuota=…), driven through the page only, as a visitor would: N visitors play the story at once, every beat passing in each, video ≥ 12 pictures a second, click-to-answer p95 ≤ 1 s; N ≥ 5 (target 10), and the server's session cap is the measured N. scripts/deploy-railway (a wizard) takes the owner from `railway login` to app.omxlabs.tech and ends by running the story against the live URL |
| M6 | Nothing regressed | the robot story on GTK (goal 47's scenario), the web host's own tests, every goal check that drives web.py (find them by grep), and a fresh docs/components.md |
| M7 | A visitor can't stall or crash the server for the others (added in round 2, from the security audit: D-6222) | while another visitor plays the story and every beat passes: a question past the time budget (shortened for the check), an answer past the row cap and a join past the memory budget each stop with a plain message; malformed CSV, Parquet and MP4 uploads (random bytes, a truncated file, wrong bytes behind the right name) are refused in plain words with the server up; D-6218's suspected sequences (a pivot or a far column, then another table) replayed with real clicks, the server up |

## Done means
62-check PASS for M0–M4, M6 and M7; M5 PASS, or only its image half BLOCKED on Docker access; the reviewer and the security auditor pass the diff; the screenshots were looked at.

## Out of bounds
Deploying, pushing images, uploading data anywhere, Railway commands that create, link or deploy, sign-ups and paid services (the owner runs scripts/deploy-railway); sudo; secrets (none are needed); the frozen ../mojo-ui-apple-test; other sessions' worktrees (read-only use of the check's results and the robot data is fine); pip; deleting anything outside this goal's scratch folders; lowering a proof; WebAssembly (parked by the owner); app-only fixes for what belongs in the web host or the framework.

## Assumptions (taken instead of asking)
- One server process, scaled up rather than out: the starter is shared in memory and per-visitor state stays small. Several processes would each need the data and sticky sessions.
- Public mode is a switch the image turns on (for example MOJOUI_PUBLIC=1); local `scripts/omxplorer.sh web` keeps working as today.
- No AI on the public copy: the story's questions come written, with their SQL. An LLM there would need keys and a budget, which is a later decision.
- The starter is goal 47's full set. Its clips are re-encoded to the size the page shows if they fit the plan's volume; otherwise it carries the story's clips plus a sample, and other runs say their video isn't in the web sample.
- Visitors can still upload their own CSV, Parquet or MP4 (capped): "send me your robot data" is the YouTube series' ask. An upload lives only in its visitor's session.
- The phone gets a look, not a new layout: if the story can't be followed at 390×844, the Start screen says it's best on a laptop. A phone layout is a later goal.
- Railway's limits, volume sizes and prices come from docs.railway.com (cited), not memory. The owner is already logged in to the Railway CLI on this machine.

## Budget
150 turns.
