# Goal 62 report: omxplorer on the web, safe to share

`docs/goals/62-check.py`, Linux, CPU only (`CUDA_VISIBLE_DEVICES=""`), on a shared machine (other projects kept its load
at 7–31 on 24 cores and up to 39 GB in swap). Round 1 (2026-11-06/07), round 2 and M5 measured again at a cap of 6 (2026-11-07). Branch `t3/hosted-omxplorer-safety`
(reported earlier as `t3/7e13f4cf`), not merged yet: the round-2 reviews (reviewer and security auditor both NEEDS WORK,
every finding fixed since) haven't re-reviewed to a PASS.

| # | Result (round 2) |
|---|---|
| M0 | PASS · `tests/test_sheetjobs_wake.mojo` (red first): open, chart, column and warm-up jobs each wake the host; fleet.csv landed in 20 of 20 fresh servers' tabs with no moving canvas |
| M1 | PASS · one click on the Start screen → fleet 63,344 + telemetry 16,847,616 + four links, F00118's clip and lanes, the paper, in 0.55 s (the starter read once at start, ~2.6 GB); 3 questions in words with their SQL, regrasps 2,997 in 108 ms; each further tab that plays the whole story adds 22–50 MB (RSS + swap); 3,553 starter files hash the same; DROID (CC-BY-4.0) credited; the first public page has no Taxi trips or "Connect a database" |
| M2 | PASS · 39 probes refused with nothing opened, written or listed (inotify on a fresh /tmp folder): crafted requests from inside the page to every control as the screens changed, file names that walk out, traversals, upload caps, the agent link and /dev off, SQL naming server paths, the Script window not offered, numbers no control offers, a flood of bare page loads, a second visitor sees nothing of the first, the scrubber cut nothing during the story |
| M3 | PASS · 500 plain GETs → 0 sessions; a real tab → 1; idle past 6 s → the page says it ended and its upload is gone; past a cap of 2 → a busy page (200); Export pack → one `pack.zip` (3 PDFs, 3 clips, 4.7 MB), nothing left on the server |
| M4 | PASS · through a delaying proxy (100 ms RTT, 10/5 Mbit/s): every beat; F00118 at 15 pictures a second (pushed: round 1's pulls gave 8.2); 1.02× its new pictures' bytes; click → answer 398 and 123 ms; a still view fetched 0 bytes in 5 s; screenshots looked at |
| M5 | image half BLOCKED, the rest PASS · `scripts/web-start` held to Hobby's caps (8 GB, 8 vCPU), visitors only clicking. At the cap of 6 (D-6230), three runs in a row with the machine at load 9.7–17.9: video 14.6–15.0, 13.5–14.1 and 14.8–15.1 pictures a second each, p95 click → answer 238, 302 and 250 ms. Earlier, 8 at once passed three runs (13.6–15.1, p95 322–482 ms) and dipped to 10.8–11.5 in a fourth (load ~11 from other projects); 10 at once passed once and dipped to 11.5–11.8 twice. Docker: `sg` isn't installed and the socket refuses this user |
| M6 | 29 PASS, 55 SAME, 1 FAIL fixed · `docs/goals/62/regress.py`: goal 47's GTK robot story M0–M3, the web host's tests and 75 archived web milestones in 24 checks; 55 fail on 882155b too (builds, data and machines this fresh worktree lacks), so they aren't this goal's; the one regression, test_web_files.py (an upload's own folder in every mode), was fixed (public mode only) and passes; docs/components.md fresh |
| M7 | PASS · while another visitor plays every beat: a question past the time budget stops in 1.4 s, one past the row cap in 0.5 s, a join past the memory budget in ~3 s, each in plain words; WITH and script statements are refused (one SELECT at a time); malformed CSV, Parquet and MP4 uploads are refused in plain words and valid ones open; a refused upload leaves an accepted one of the same name alone; 40 push streams on one tab leave /health quick; D-6218's suspected sequences leave the server up |

## Round 3 (2026-11-07): the round-3 review's findings

Both reviews said NEEDS WORK: the availability half (M7) and M6's proof didn't hold. Each fix has a test written for it
(tests/test_public_rules.mojo, tests/test_web_public.py) and, where the review asked, a proof on the running server.

- **Uploads that decode huge** (D-6231, D-6232): the upload check measures what its read took; a table past 256 MB once
  read, or a visitor's tables past 384 MB together, is refused in plain words before the server reads it. M7: the
  review's case (516 KB of Parquet → 120M rows, 918 MB) uploaded three times is refused, the server 2,891 → 2,891 MB.
  The check is first for the out-of-memory killer and runs under an anyio CapacityLimiter.
- **Questions the engine can't stop** (D-6233, D-6234): a stopped question counts until the engine ends it, for its
  visitor and for the server (2 places, waited on up to 10 s); 2 cores and a 256 MB sort a question; WITH anywhere,
  UNION, INTERSECT and EXCEPT are refused. M7 proves it by resources: the server sampled every 0.25 s from Run, at most
  2 cores while the stopped question ran, CPU and memory back at baseline seconds later.
  **Root cause, for an omxcore change (nothing filed, omxcore untouched):** at 834ef9a the engine calls `cancelled()`
  only in group-by (`query.mojo`), window and CSV loops; its joins (`join`/`joincore`), set operations (`setops`),
  subqueries (`subq`) and sorts have no stop checks, so a stopped question runs on to its end.
- **M6** (D-6238): goals 03–05's archived checkers looked for `docs/build/…` (their root one folder too high) and built
  nothing; regress.py now builds what each goal reads in both trees, runs a failure on the base, and calls SAME only a
  row that ran on both sides. Result: 59 PASS, 24 SAME, 3 NOT RUN (Mac-only, one missing data file), 0 FAIL; every
  row the owner named ran (docs/goals/62/runs/m6-progress.txt). Files the re-runs regenerated (22 under docs/) were put back.
- **Fails closed** (D-6237): a non-loopback HOST without MOJOUI_PUBLIC=1, MOJOUI_PUBLIC other than 1 or 0, or public
  mode without prlimit: the server doesn't start.
- **Sessions** (D-6235): every session holds a place from the start (bare loads can't overshoot the cap); near the cap
  one address (X-Real-IP) can't take the last places; new sessions are rate-limited; a visit lasts an hour at most;
  /resize isn't input. The checks' simulated visitors each have their own address.
- **Uploads in flight** (D-6236): an upload must say its length; 2 in flight a visitor, each reserving its length.
- **Smaller ones:** a leading parenthesis no longer hides a WITH; story.py exits 1 on a failed beat; the image keeps
  only what the server runs (not built here: Docker is still blocked); M5's $PORT test reads the start command, not a
  comment; the phone notice spans the window above the columns; Insert ▸ Documents isn't offered on the public copy and
  its handler opens nothing there; BodyLimit lets a handler's errors through and answers a chunked body past its limit
  with 413; docs/web-public.md says cap 6 and that proxy headers aren't trusted; the M4 and three M5 runs below are kept
  in docs/goals/62/runs/.

## A 30-second demo

    pixi run python scripts/starter.py --from <goal 47's full set> --to build/starter/robot   # once: 1.15 GB
    scripts/build.sh omxplorer web && scripts/mxbuild.sh hosts/validate_main.mojo -o build/omxplorer/web/validate
    OMX_STARTER=$PWD/build/starter/robot HOST=127.0.0.1 PORT=8080 MOJOUI_PYTHON=$(pixi run which python) scripts/web-start
    # → http://127.0.0.1:8080/ : "Start the robot story", then Pivot, Play, and Run on each question

Pictures: `build/g62/m1-start.png` (the Start screen with the story card and the credit), `build/g62/m1/tab1/shots/`
(each beat), `build/g62/m4-desktop-story.png` and `build/g62/m4-phone-start.png` (1440×900 and 390×844 through the proxy).

## Three decisions worth a second look

1. **D-6209 · the starter is shared through `mojoui.csvio.read_table`** (a process-wide registry filled by
   `App.init_shared`): every omxcode app gets it, and a tab costs 22–50 MB instead of 2.5 GB. A public copy whose
   starter fails to load stops at start.
2. **D-6223/D-6224 · the speed fixes.** Paint, frame events and job wakes run without Python's lock, so tabs draw on
   every core; playing canvases' pictures are pushed in one stream per page (`GET /push`), painted on the server's clock,
   so a slow link pays no round trip a picture. Push is on for the public copy only: local apps keep pulling at the
   display's rate.
3. **D-6228 · the public copy asks one SELECT at a time.** The Script window isn't offered there (its statements ran
   outside every budget) and WITH is refused (it builds its whole answer before a cap can stop it); the time budget is
   cooperative (the engine checks it between blocks: its joins, set operations and subqueries have no checks yet), and the
   join budget is the engine's. One crash seen once in round 1 (D-6218) was never reproduced.

## Visitors per server, memory per visitor

- **Memory:** the shared starter, ~2.6 GB from the start; each visitor who plays the whole story adds **22–50 MB**.
- **Visitors:** **6 at once** on Hobby's 8 GB / 8 vCPU (the session cap, D-6230), every beat, video 13.5–15.1 pictures a second each;
  8 at once passed three runs of four and 10 one of three, dipping just under 12 when other projects loaded the machine.

## What Railway costs at that size

Hobby ($5 a month, which counts toward usage; a replica up to 8 GB / 8 vCPU), billed on what the service uses:
$10 per GB-month of memory, $20 per vCPU-month, $0.05 per GB out (docs/research/railway.md, from docs.railway.com,
read 2026-11-06). At rest the server holds ~2.7 GB and almost no CPU: about **$27 + $2 ≈ $29 a month** always on.
Eight visitors at once add ~0.4 GB and a few vCPU while they play (cents an hour). A visitor's story moves about
10–20 MB (pushed pictures, the page, a pack), so 1,000 visitors ≈ 15 GB ≈ $0.75.

## The owner's steps to go live

1. If you want the image checked here first: `sudo usermod -aG docker $USER && newgrp docker`, then `scripts/image-check`.
2. `scripts/deploy-railway` (a wizard): `railway whoami`, the starter and the build folder (`scripts/stage-web`), the
   project and service, variables (cap 6), then in the dashboard **Healthcheck Path `/health`** and **Restart Policy
   Always**, `railway up`, the story against the railway.app address, `railway domain app.omxlabs.tech` (a CNAME and a
   TXT at your DNS host), and the story again on https://app.omxlabs.tech.
