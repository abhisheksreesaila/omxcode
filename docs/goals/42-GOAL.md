# GOAL 42: Jot, omxcode keeps your data

**End goal (owner, 2026-10-30):** the second probe after Sketch: "this framework supports database, this is the app".
Keep the scope very small; what it forces goes back into the library; it becomes a gallery showcase. The yardstick is
Personal Note's storage (SQLite + FTS5, search as you type, import/export, nothing lost): families 3–5 of
`~/Projects/personalnotev2/docs/research/omxcode-gap-audit.md`.

Framework first (CLAUDE.md "Components first"): `mojoui/` gains what any app needs, each with its own test;
`examples/jot` only composes. Slow work follows docs/ui-threads.md (jobs, never on the UI thread). Look: Liquid.

## Milestones
| # | Milestone | Proof (`pixi run python docs/goals/42-check.py`) |
|---|---|---|
| M0 | SQLite in the library (`mojoui/sqlite.mojo`) | `tests/test_sqlite.mojo` prints `sqlite open: ok`, `sqlite bind: ok` (text with quotes, emoji and NUL-free UTF-8, ints, floats, NULL round-trip through prepared statements), `sqlite tx: ok` (a rolled-back transaction leaves nothing; a committed one stays), `sqlite error: ok` (bad SQL raises with SQLite's message, the connection stays usable), `sqlite fts5: ok` (an FTS5 table finds a prefix query) |
| M1 | examples/jot: notes that persist | one Mojo file: a notes list, an editor (title = first line), New, Delete, a search field. Data in `$JOT_DB` (default: the app's config dir): table `notes(id INTEGER PRIMARY KEY, title TEXT, body TEXT, updated INTEGER)` and FTS5 table `notes_fts` kept in step. The checker's SESSION on headless GTK prints `JOT:` lines with the expected values in order; afterwards Python's sqlite3 reads the expected rows from the file, and an FTS5 MATCH on it finds them |
| M2 | Search as you type, never freezing | with `JOT_SEED=10000` the app seeds 10,000 notes through a job (`start_ui_job`) while the window keeps painting: the host's `gaps:` step reports the longest gap ≤ 100 ms during the seed; then 50 typed queries each print `JOT SEARCH: q=… results=N ms=X`; p95 of X ≤ 16 ms and N equals Python's FTS5 count for the same query on the same file |
| M3 | Files in and out | import a `.md`/`.txt` through the existing FilePicker (`pick:` step); export the open note through a new generic save dialog (`mojoui` FileSaver, GtkFileDialog save on GTK, a download on the web, NSSavePanel on the Mac, built) driven by a new `save:Title=/path` step, the file's bytes equal the note; a file dropped from the file manager onto the list (a generic external-file drop on DropTarget, GTK's GdkFileList, driven by a new `dropfile:Tag=/path` step) becomes a note |
| M4 | Nothing lost on quit | a new generic `quit` step closes the window as the window manager does; the app's typing is saved through a generic quit hook (App learns about closing; a pending save finishes before exit); relaunched on the same `$JOT_DB`, the last edit is there (the checker reads the file and the relaunched app's `JOT:` line) |
| M5 | In the gallery, back in the library | `docs/gallery/index.html` has a Database section with `img/jot-gtk.png` and `img/jot-web.png` (exist, not blank; a deliberate scene: real-looking notes, a search with highlighted results); `scripts/components.py --check` passes and docs/components.md lists SQLite, the save dialog, the file drop and the quit hook; `docs/llms.txt` names `mojoui.sqlite`; EXPERIMENTS.md's newest entry is goal 42; `scripts/build.sh jot web` and `scripts/build.sh jot mac` succeed (the Mac links the system's libsqlite3; built, not run) |
| M6 | The race (added 2026-10-30, the owner: a probe must beat the web or not bother) | `scripts/jot_race.py` writes `docs/goals/42/race.json` (fresh: its commit's mojoui/sqlite.mojo and the script equal HEAD's): the same 1,000,000 notes (generated deterministically, identical text on both sides), the same schema and the same SQL; A = `mojoui.sqlite` in a native process (a file on disk); B = the browser's best: the official SQLite build for WebAssembly (`@sqlite.org/sqlite-wasm`, pinned) in a Worker with OPFS persistence (`opfs-sahpool` or `opfs`, whichever is faster: both tried, stated) in headless Chromium. Per side: build (1M inserts + the FTS5 index), cold open (process or page start → the first query on the existing 1M database answered), 200 search-as-you-type prefix queries (the same list; p50/p95, query only, same SQL), on-disk size. **Pass:** for every query both sides return the same count; A's search p95 ≤ half of B's and A's cold open ≤ half of B's. If B can't hold 1M notes (quota, memory), race.json records the error and B's largest size, and A wins only with that written down. A loss is a FAIL |

## Done means
The checker prints PASS for M0–M6 and the reviewer passes it. The Mac is built, not run.

## Out of bounds
Pushing; the frozen `../mojo-ui-apple-test`; `GOAL.md` and `scripts/check.py` (other goals own them); windows on the
owner's desktop (everything headless); new dependencies beyond the pixi env and the system's libsqlite3.

## Assumptions (instead of asking)
- Branch `goal-42-jot` from local `main` at 49cbd8d (Sketch merged); worktree `../mojo-ui-g42`. Goal 41 belongs to another thread.
- Decision numbers D-1300 onward.
- SQLite through `external_call` to the C library (the system's on Linux and the Mac, pixi's in tests), not a Python bridge: the framework stays one language.
- The editor is the existing plain TextArea; rich text is a later probe (Writer).
- The web host keeps the database on the server (one per process), as it keeps app state today.

## Budget
80 turns.
