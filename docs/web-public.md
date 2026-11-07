# The public web copy (goal 62)

Any omxcode web app can run on the public internet with one switch, `MOJOUI_PUBLIC=1`. omxplorer's hosted copy
(`Dockerfile.web`, started by `scripts/web-start`, deployed by `scripts/deploy-railway`) is the first. Proof:
`docs/goals/62-check.py`; decisions D-6201 onwards in `docs/decisions.md`.

## What public mode changes (mojoui/hosts/web.py)

| | Local (`scripts/omxplorer.sh web`) | Public (`MOJOUI_PUBLIC=1`) |
|---|---|---|
| Agent link, `/dev` routes | as configured | off, whatever the environment says |
| Sessions | one per page load; the oldest closes past 200 | one per page load; past `MOJOUI_MAX_SESSIONS` (default 8; the image: 10) a busy page |
| Idle tabs | stay | end after `MOJOUI_IDLE_S` (900 s) without input; the page says so; their files go |
| Plain GETs (crawlers, link previews, health checks) | no session (both modes: only a browser's page load makes one) | same |
| File controls (pickers, savers, drop targets) | the page may send a path | only paths the host made (an upload, a save) reach the app |
| Uploads | 32 GB a file | `OMXCODE_UPLOAD_MAX` (200 MB) a file, `OMXCODE_VISITOR_MAX` (500 MB) a visitor |
| Files a visitor makes (Save, Export CSV, Export pack) | in their documents folder | in the tab's own folder, then sent as a download (a folder as one zip) and removed |
| Recent files | `OMX_CONFIG/recent.txt`, with paths | in the tab only, names only |
| Server paths in answers | as the app shows them | cut from every text answer (logged as `SCRUB:` so the source can be fixed) |
| Documents' Read | OCR model or PDF text | PDF text only (no model on a shared server) |
| Listening | 127.0.0.1:5001 | `HOST`, `PORT` (the image: 0.0.0.0:$PORT), proxy headers trusted |

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
