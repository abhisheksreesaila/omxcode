# Goal 62 report: omxplorer on the web, safe to share

`docs/goals/62-check.py`, Linux, CPU only (`CUDA_VISIBLE_DEVICES=""`), on a shared machine (other projects kept its load
at 7–31 on 24 cores and up to 39 GB in swap). Round 1 (2026-11-06/07), rounds 2–6 (2026-11-07). Branch `t3/hosted-omxplorer-safety`, not merged: round 6 fixed the
final review's two blocking finds and its should-fixes (both NEEDS WORK) and ran no reviewer, as asked; the owner's next review comes next.

| # | Result (round 3; the outputs kept in docs/goals/62/runs/) |
|---|---|
| M0 | PASS · `tests/test_sheetjobs_wake.mojo` (red first): open, chart, column and warm-up jobs each wake the host; fleet.csv landed in 20 of 20 fresh servers' tabs with no moving canvas |
| M1 | PASS · one click on the Start screen → fleet 63,344 + telemetry 16,847,616 + four links, F00118's clip and lanes, the paper, in 0.55 s (the starter read once at start, ~2.6 GB); 3 questions in words with their SQL, regrasps 2,997 in 108 ms; each further tab that plays the whole story adds 22–50 MB (RSS + swap); 3,553 starter files hash the same; DROID (CC-BY-4.0) credited; the first public page has no Taxi trips or "Connect a database" |
| M2 | PASS · 39 probes refused with nothing opened, written or listed (inotify on a fresh /tmp folder): crafted requests from inside the page to every control as the screens changed, file names that walk out, traversals, upload caps, the agent link and /dev off, SQL naming server paths, the Script window not offered, numbers no control offers, a flood of bare page loads, a second visitor sees nothing of the first, the scrubber cut nothing during the story |
| M3 | PASS · 500 plain GETs → 0 sessions; a real tab → 1; idle past 6 s → the page says it ended and its upload is gone; past a cap of 2 → a busy page (200); Export pack → one `pack.zip` (3 PDFs, 3 clips, 4.7 MB), nothing left on the server |
| M4 | PASS · through a delaying proxy (100 ms RTT, 10/5 Mbit/s): every beat; F00118 at 15 pictures a second (pushed: round 1's pulls gave 8.2); 1.02× its new pictures' bytes; click → answer 319 and 114 ms; a still view fetched 0 bytes in 5 s; screenshots looked at, the phone's notice now reads in full above the columns (runs/m4-final) |
| M5 | image half BLOCKED, the rest PASS · `scripts/web-start` held to Hobby's caps (8 GB, 8 vCPU), visitors only clicking, each from its own address. At the cap of 6 (D-6230), three runs in a row (load 3.7–9.8): video 15.0–15.2, 14.8–15.0 and 15.0–15.1 pictures a second each, p95 click → answer 270, 277 and 398 ms (runs/m5-run1–3). Docker: the socket still refuses this user |
| M6 | PASS · round 4's full run: 58 PASS, 18 SAME, 3 NOT RUN, and 7 rows looked at again: goal 34b M1 failed once and passed on its rerun, and the 6 CHANGED rows (goals 08, 14, 33) proved to fail the same way on both sides once read in full (runs/m6-progress.txt, runs/m6-recheck.txt: 0 CHANGED, 0 FAIL). With the rows looked at: 59 PASS, 24 SAME, 3 NOT RUN (two need a Mac run, one a data file this machine lacks), 0 FAIL; every row the owner named ran; regenerated files under docs/ put back; docs/components.md fresh |
| M7 | PASS · while another visitor plays every beat: a question past the time budget stops in 1.4 s, one past the row cap in 0.4 s, a join past the memory budget in ~3 s, each in plain words; WITH (also behind a parenthesis), UNION ALL and script statements are refused; malformed CSV, Parquet and MP4 uploads refused in plain words, valid ones open; the 516 KB decode bomb refused three times with the server's memory unchanged; a stopped sort over every telemetry row: at most 2 cores while it ran, CPU and memory back at baseline seconds after; 40 push streams leave /health quick; D-6218's sequences leave the server up |

## Round 6 (2026-11-07): the final review's blocking finds

Each in M7, read from the server:
- **One question killing the server** (D-6249): strings built from two large word lists are refused before they run (the
  engine makes a word per combination of dictionary words, whatever the rows). `w || v` over two 1,023-word lists of
  7 KB words: refused, the server 2,952 → at most 2,953 MB.
- **Export pack writing outside its folder** (D-6250): every export names its file through one seam, a safe name only
  directly inside its folder. A row named `../../../g62escaped`: the pack holds `g62escaped.pdf`, nothing outside.
- **Video paths from cells** (D-6251): only the starter and the visitor's own folders. A cell naming a real clip outside
  them: inotify saw it opened 0 times, and no clip was packed.
- **Should-fixes** (D-6252): NaN, inf and huge numbers in an event are no event; X-Real-IP read only behind the proxy;
  a drop is 20 files at most and counts as it goes; two pack PDFs print at once at most; docs say 300 s idle.

## Round 5 (2026-11-07): the round-5 review's findings

Each exploit is in M7, read from the server:
- **Answers by their real size** (D-6245): measured once built, strings included, refused past 64 MB; kept answers count by
  that size. Questions that build strings are bounded before they run, since the engine computes a built string for every
  row before an outer LIMIT (plain projections do stop there). 400 columns, 40 behind a subquery, and a 500-character
  string a row over 1M rows: each refused, the server within +8 MB. The kept-answers test now fails when the counting line
  is removed (checked by removing it).
- **Slow and idle connections** (D-6246): header and body deadlines with a byte-rate floor, keep-alive 20 s,
  limit_concurrency 2048, 64 connections a peer with no proxy in front, 48 requests in flight an address. 600 idle and
  100 half-header sockets from one address: the server held 64, another address's /health and / answered in 25 ms, and 14 s
  later none were left. 50 slow POSTs to a made-up session were answered "gone" before their bodies.
- **Uploads that outlive their session** (D-6247): end_session drops the session's uploads in flight and the server stops
  reading them; uploads keep the body rate floor. A slow 40 MB upload was cut 10 s after its session ended, and another
  visitor's 30 MB upload then fit the 50 MB budget; trickling under the floor, it was cut after 19 s.
- **Smaller ones** (D-6248): a request cap on every session route but an exempt list; events answered "retry" are sent
  again; idle 5 minutes on the public copy, only input counts; untouched 25 s; IPv4-mapped addresses as IPv4, IPv6 by /48,
  an unparsable X-Real-IP a shared "unknown", and the wizard fails on a private or proxy address; a running byte total per
  visitor instead of folder walks; Chromium with --disable-dev-shm-usage; regress.py's EXPLAINED keyed by the failure's
  words; the made-up-session log line said once every 10 s; docs/goals/34b/m1-chart-gtk.png back to 882155b.

## Round 4 (2026-11-07): the round-4 review's findings

Each exploit the review found is in M7 now, proven by the server's own memory, threads and latency:
- **One question filling 8 GB** (D-6239): an answer may take 64 MB (columns × rows), its rows capped from its width before
  it runs; kept answers count with the visitor's tables (384 MB); 8 answers at most. The review's 400 columns over a 1M-row
  upload is refused; the server went 2,876 → at most 2,881 MB meanwhile.
- **Uploads for no session** (D-6240): refused before the body is read; every upload in flight together is held to 512 MB.
  Three slow 200 MB uploads for a made-up session were answered after 64 KB each, the server's memory unchanged.
- **One session stalling everyone** (D-6241): a session's blocking requests in flight are capped at 6, answered "retry"
  without a worker thread; /health is async; uvicorn's limit_concurrency 512, keep-alive 75 s. 300 open /frame requests
  at 3840×2400 from one session: /health median 1 ms, worst 179 ms (the review: 7.9 s median).
- **The image** (D-6242): Playwright's Chromium (with its headless shell) is installed for Export pack's PDFs, and
  scripts/image-check fails unless the pack arrives from the container. Not built: Docker still refuses this user.
- **Smaller ones:** X-Real-IP keys parse as addresses (45 characters, IPv6 by /64), the table bounded, and the wizard checks
  what the live server records for a made-up one; 2 places per address at all times; an untouched session frees its place
  in 10 s and says why truthfully; the "being made" count and the session list change under one lock; the page's frame and
  drop fetches retry after a network error (the M4 "Failed to fetch" flake); a refused upload's body is read and dropped so
  Chromium shows the notice (proven in M7 with a 60 MB upload past a 50 MB cap); BodyLimit's answers carry the security
  headers; regress.py calls a row SAME only for the same reason (goal 27's change was mine: a comment in
  mojoui/starter.mojo said "paper"; reworded); docs/web-public.md says how a shared address is treated.

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
