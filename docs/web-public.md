# The public web copy (goal 62)

Any omxcode web app can run on the public internet with one switch, `MOJOUI_PUBLIC=1`. omxplorer's hosted copy
(`Dockerfile.web`, started by `scripts/web-start`, deployed by `scripts/deploy-railway`) is the first. Proof:
`docs/goals/62-check.py`; decisions D-6201 onwards in `docs/decisions.md`.

## What public mode changes (mojoui/hosts/web.py)

| | Local (`scripts/omxplorer.sh web`) | Public (`MOJOUI_PUBLIC=1`) |
|---|---|---|
| Agent link, `/dev` routes | as configured | off, whatever the environment says |
| Sessions | one per page load; the oldest closes past 200 | one per page load, holding a place from the moment it's made; past `MOJOUI_MAX_SESSIONS` (6, D-6230) a busy page; an address (`X-Real-IP`, an IPv6 one by its /48, an IPv4-mapped one as IPv4, one that doesn't parse a shared "unknown") holds `MOJOUI_PER_IP` (2) places at most, at all times; new sessions at most `MOJOUI_NEW_PER_S` (2) a second on the server (bursts of 6) and `MOJOUI_IP_NEW_PER_S` (0.5) from an address (bursts of 3);  a visit ends after `MOJOUI_SESSION_MAX_S` (an hour), and the page says so; only input keeps a tab alive (`MOJOUI_IDLE_S`, 5 minutes), and a page that never comes back frees its place in 25 s |
| Idle tabs | stay | end after `MOJOUI_IDLE_S` (900 s) without input (a `/resize` isn't input); the page says so; their files go |
| Plain GETs (crawlers, link previews, health checks) | no session (both modes: only a browser's page load makes one) | same |
| File controls (pickers, savers, drop targets) | the page may send a path | only paths the host made (an upload, a save) reach the app |
| Uploads | 32 GB a file | `OMXCODE_UPLOAD_MAX` (200 MB) a file, `OMXCODE_VISITOR_MAX` (500 MB) a visitor, 2 in flight, each reserving its length (an upload must say it), every visitor's in flight together `MOJOUI_UPLOADS_IN_FLIGHT_MB` (512); an upload for no open page is refused before its body is read, and a refused one's body is read and dropped first, so the page shows why; read first in a process of its own (`validate`, held by `prlimit` to 4 GB and 60 s of CPU, first for the out-of-memory killer): a table past `MOJOUI_TABLE_MB` (256) once read, or a visitor's tables past `MOJOUI_VISITOR_TABLES_MB` (384) together, is refused |
| Questions | anything the engine takes | an answer up to `MOJOUI_ANSWER_MB` (64 MB, its real size once built, strings included; a question that builds strings is refused before it runs when its worst case could pass that; one REPLACE a question), counted with the visitor's tables in `MOJOUI_VISITOR_TABLES_MB`, `MOJOUI_ANSWERS` (8) answers kept; one SELECT (no WITH, UNION, INTERSECT or EXCEPT, no script statements); answers up to `MOJOUI_QUERY_ROWS` (1M); `MOJOUI_QUERY_S` (20 s), then stopped, still counting until the engine ends it; one at a time a visitor, `MOJOUI_QUESTIONS` (2) on the server; `MOJOUI_QUERY_THREADS` (2) cores and `MOJOUI_SORT_BYTES` (256 MB) of sort a question; `MOJOUI_JOIN_BYTES` (512 MB) a join |
| Files a visitor makes (Save, Export CSV, Export pack) | in their documents folder | in the tab's own folder, then sent as a download (a folder as one zip) and removed |
| Recent files | `OMX_CONFIG/recent.txt`, with paths | in the tab only, names only |
| Server paths in answers | as the app shows them | cut from every text answer (logged as `SCRUB:` so the source can be fixed) |
| Documents' Read | OCR model or PDF text | PDF text only (no model on a shared server) |
| Listening | 127.0.0.1:5001; any other `HOST` refuses to start | `HOST`, `PORT` (the image: 0.0.0.0:$PORT); proxy headers aren't trusted for the scheme or host (`proxy_headers=False`); `X-Real-IP` is read only for the per-address limits (Railway's proxy sets it; elsewhere it can be forged, so those limits are soft) |
| Start | | `MOJOUI_PUBLIC` other than 1 or 0, or no `prlimit` on PATH: the server doesn't start |

Both modes: `GET /health` answers `{"ok", "sessions", "max"}`; a page keeps one `/wait` open and the server answers it
only with changes or a gone tab (`MOJOUI_WAIT_S` caps the hold: 240 s in the image, as Railway closes a request after 5
minutes without data); a canvas picture already on the page isn't sent again (its digest); a page that goes away ends
its session (a beacon to `/bye`).

## The starter

`OMX_STARTER` names a folder with a `story.json` (mojoui.starter): omxplorer's Start screen offers it, and one click
plays its set-up. Its tables are read once per process (`mojoui.csvio.share_file` from `App.init_shared`) and every
visitor reads the same columns: each further tab that plays the whole robot story adds 25–40 MB, not 2.5 GB.
`scripts/starter.py --from <goal 47's full set> --to build/starter/robot` makes the robot starter (1.15 GB: the
tables, the paper and all 3,546 clips re-encoded to 480 px).

## Run it

    OMX_STARTER=$PWD/build/starter/robot HOST=127.0.0.1 PORT=8080 MOJOUI_PYTHON=$(pixi run which python) scripts/web-start

Limits that remain (see docs/goals/62-report.md): one process (scale up, not out); sessions are told apart by a 128-bit
id in their URLs, not by sign-in; a crash in the app ends every session (the platform restarts it: set Railway's
restart policy to Always).

### A shared address (an office, a school, a phone carrier)

Everyone behind one address counts as one visitor for the per-address limits: together they hold at most 2 tabs at once,
and new tabs open 3 at once, then about one every 2 seconds. Anyone past that sees the busy page and can try again in a
minute. A visit ends after an hour whatever happens (the page says so, and a reload starts a new one); a tab with no input
for 5 minutes ends sooner. Each session's blocking requests in flight (frames, events) are at most 6, so one tab can't
hold the server's worker threads; `/health` doesn't need one.

### Connections

A request's headers must arrive within 10 seconds and its body at 16 KB/s or more after 10 seconds, with no gap past
15 seconds; an idle connection is kept 20 seconds after an answer. Requests for a session that doesn't exist are answered
"gone" before anything is read. One address has 48 requests in flight at most; with no proxy in front, one peer holds 64
connections (`MOJOUI_BEHIND_PROXY=1`, which scripts/web-start sets for Railway, turns that off: there every connection
comes from the proxy, so the limits read `X-Real-IP`).
