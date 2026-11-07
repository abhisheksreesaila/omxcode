# Goal 62 report: omxplorer on the web, safe to share

`docs/goals/62-check.py` (2026-11-07), Linux, CPU only (`CUDA_VISIBLE_DEVICES=""`), on a shared machine under memory
pressure (other projects held 39 GB of swap). Branch `t3/7e13f4cf`, not merged: M4 doesn't pass (below).

| # | Result |
|---|---|
| M0 | PASS · `tests/test_sheetjobs_wake.mojo` (red first: "warm_gpu ended without waking the host"): open, chart, column and warm-up jobs each wake the host; fleet.csv landed in 20 of 20 fresh servers' tabs with no moving canvas, median 0.34 s, slowest 0.67 s |
| M1 | PASS · one click on the Start screen → fleet 63,344 + telemetry 16,847,616 + four links, F00118's clip and lanes, the paper, in 0.8 s (the starter is read once at start: 2.6 GB); 3 questions in words with their SQL, regrasps 2,997 in 194 ms; RSS + swap 2,606 → 2,683 → 2,733 → 2,763 MB: each further tab that plays the whole story adds 30–50 MB; 3,553 starter files hash the same; DROID (CC-BY-4.0) credited |
| M2 | PASS · 38 probes, each refused with nothing opened, written or listed (inotify on a probe folder): crafted requests from inside the page to every control as the screens changed (/e with second 1/2/0 and six server paths, /save), /w, /reply, /describe, /jslog, /spot, /download, /img; file names that walk out on /upload and /dropfile; 11 traversals on /static, /assets, /static/fonts; per-file and per-visitor upload caps; the agent link and /dev off; SQL and the Script window naming server paths; numbers no control offers; a flood of bare page loads; a second visitor sees nothing of the first; the scrubber cut nothing during the story (the app emits no server path) |
| M3 | PASS · 500 plain GETs → 0 sessions; a real tab → 1; idle past 6 s → the page says it ended, 0 sessions, its upload gone; past a cap of 2 → a busy page (200); Export pack → one `pack.zip` (3 PDFs, 3 clips, 4.7 MB), nothing left on the server |
| M4 | FAIL · through a delaying proxy (100 ms RTT, 10/5 Mbit/s): every beat passes, click → answer within 600 ms, a still view fetches 0 bytes in 5 s, the video uses 1.2× its new pictures' bytes; but F00118 plays at 8.2 pictures a second (≥ 12 asked). Screenshots build/g62/m4-desktop-*.png, m4-phone-*.png, looked at: the desktop story is clean; the phone shows the "best on a laptop" note and a cramped layout |
| M5 | FAIL, image half BLOCKED · `scripts/web-start` under systemd-run at Hobby's caps (MemoryMax=8G, CPUQuota=800%), visitors only clicking: every beat passes for 10 visitors at once and for 5, but the video runs 3.5–6 (10 at once) and 6.7–7.5 (5 at once) pictures a second each, under 12. Cause measured: every picture is drawn under Python's one GIL (~4 ms each), so simultaneous videos share one core. Docker: "permission denied … /var/run/docker.sock" (the owner's command below). The wizard `scripts/deploy-railway` is written (bash -n clean; not run: it deploys) |
| M6 | partial · the web host's tests and goal 47's GTK robot story (below); the 75 archived web milestones in 24 checks were not run (hours): `pixi run python docs/goals/62/regress.py` runs them, a failure re-run on 882155b to tell a regression from an old one |

Done means isn't met: M4 and M5 fail on video throughput and M6 is partial, so the branch isn't merged or pushed.
Reviewer: NEEDS WORK (15 findings; the must-fixes were fixed: starter sharing at the plan's memory, scrubbing at path
boundaries, a body-size guard, Open recipe's typed path, settings per visitor, the cap without races, the two web
tests, M2's blind spots). Security auditor: PASS WITH NOTES (2 high fixed: bare page loads holding the cap, an
unchecked number index; 3 medium left as residual risks: malformed uploads parsed in-process, unbounded query cost,
and the image's full environment).

## A 30-second demo

    pixi run python scripts/starter.py --from <goal 47's full set> --to build/starter/robot   # once: 1.15 GB
    scripts/build.sh omxplorer web
    OMX_STARTER=$PWD/build/starter/robot HOST=127.0.0.1 PORT=8080 MOJOUI_PYTHON=$(pixi run which python) scripts/web-start
    # → http://127.0.0.1:8080/ : "Start the robot story", then Pivot, Play, and Run on each question

![Start screen](../../build/g62/m1-start.png)

Pictures: `build/g62/m1-start.png` (the Start screen with the story card and the credit), `build/g62/m1/tab1/shots/`
(each beat), `build/g62/m4-desktop-story.png` and `build/g62/m4-phone-start.png` (1440×900 and 390×844 through the proxy).

## Three decisions worth a second look

1. **D-6209 · the starter is shared through `mojoui.csvio.read_table`** (a process-wide registry filled by
   `App.init_shared`): every omxcode app gets it, and a tab costs 30–50 MB instead of 2.5 GB. A public copy whose
   starter fails to load now stops at start rather than quietly loading it per visitor (the review's catch at 8 GB).
2. **D-6219 · M4 left failing.** Pipelined pulls, one shared `/pending`, kept pictures and gzip took the network video
   from 4.5 to 6–9 pictures/s. A WebSocket for pictures bought nothing and a page-wide batch broke playback: both
   taken out. The next step is a pushed picture stream for playing canvases (one connection, no round trip a
   picture), or HTTP/2 at the edge; Railway's edge speaks HTTP/2 to browsers, which lifts the six-connection limit my
   HTTP/1.1 proxy keeps (unverified).
3. **D-6218 · one crash seen once** (an omxcore `Frame.name` assert after crafted presses swapped tables while jobs
   ran; ~8,600 more crafted requests never repeated it). Any assert ends the process for every visitor: the wizard
   sets Railway's restart policy to Always, and malformed uploads are parsed in-process (the auditor's medium #3).

## Visitors per server, memory per visitor

- **Memory:** the server holds the shared starter, ~2.6 GB, from its start; each visitor who plays the whole story adds
  **30–50 MB** at rest (M1: 2,606 → 2,683 → 2,733 → 2,763 MB). Memory is not what limits visitors: 10 fit in 3 GB.
- **Visitors:** on Hobby's 8 GB / 8 vCPU, **10 visitors at once** play every beat (start, pivot, questions, answers in
  well under a second), but their videos slow to 3.5–6 pictures a second; **5 at once**, 6.7–7.5; **one** gets 15. The
  session cap is set to **5** (scripts/web-start): every beat for each, video at about half speed while all play at
  once. Releasing the GIL around the Mojo paint (mojoui.pygil already lends it to job threads) should let the 8 vCPUs
  draw in parallel: the next step for both M4 and M5.

## What Railway costs at that size

Hobby ($5 a month, which counts toward usage; a replica up to 8 GB / 8 vCPU), billed on what the service uses:
$10 per GB-month of memory, $20 per vCPU-month, $0.05 per GB out (docs/research/railway.md, from docs.railway.com,
read 2026-11-06). At rest the server holds ~2.7 GB and almost no CPU: about **$27 + $2 ≈ $29 a month** always on.
Ten visitors at once add ~0.4 GB and a few vCPU while they play (cents an hour). A visitor's story moves about 5–10 MB
(pictures, the page, a pack), so 1,000 visitors ≈ 10 GB ≈ $0.50.

## The owner's steps to go live

1. `scripts/deploy-railway` (a wizard): it checks `railway whoami`, makes the starter if needed, stages the build
   folder (`scripts/stage-web`), creates the project and service, sets variables, asks you to set **Healthcheck Path
   `/health`** and **Restart Policy Always** in the dashboard, deploys (`railway up`), plays the story against the
   railway.app address, adds `app.omxlabs.tech` (`railway domain`: a CNAME and a TXT at your DNS host), and plays the
   story again on https://app.omxlabs.tech.
2. Before that, if you want the image checked here: `sudo usermod -aG docker $USER && newgrp docker`, then
   `scripts/image-check` (builds Dockerfile.web and plays the story against the container).
