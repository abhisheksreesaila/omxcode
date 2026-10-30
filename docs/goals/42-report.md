# Goal 42 report: Jot, omxcode keeps your data

## M6, the race: PASS (omxcode wins)
1,000,000 notes, the same fixed-seed text, Jot's schema, triggers and search SQL, SQLite 3.53.4 on both sides
(`scripts/jot_race.py` → `docs/goals/42/race.json`, commit becba61). A = `mojoui.sqlite` in a native process; B = the
official `@sqlite.org/sqlite-wasm` 3.53.4-build2 in a module Worker on OPFS, headless Chromium 152, served from
localhost with COOP/COEP. Median of 3 runs after one warm-up per side (min–max in brackets). Ryzen 9 5900X, 24 threads,
load 1.6–2.1 throughout, page cache warm on both.

| | A native | B opfs-sahpool (raced) | B opfs |
|---|---|---|---|
| search p95, 200 prefixes | **64.6 ms** (64.5–68.5) | 165.8 ms (163.9–167.0) | 167.5 ms |
| search p50 | 14.1 ms (13.9–14.9) | 37.4 ms (36.4–37.6) | 38.1 ms |
| cold open → first answer | **65.8 ms** (65.7–70.6) | 435.3 ms (428.5–448.5) | 448.1 ms |
| build: 1M inserts + FTS5 | 35.9 s | 56.6 s | 122.5 s |
| on disk | 528.3 MB | 519.2 MB | 519.2 MB |

Pass bar: A's p95 ≤ half of B's (64.6 ≤ 82.9) and A's cold open ≤ half of B's (65.8 ≤ 217.6); counts equal on all 200
queries. Ratios: search 2.6×, cold open 6.6×. B's cold open leaves out the browser's launch (in B's favour). B runs in a
rollback journal (OPFS can't do WAL), which is why its file is smaller. A 20k-note dry run gave 2.9× and 26×: the
browser's fixed cost (wasm compile, OPFS open) counts for more on a small file, and the search gap stays at 2.5–3×.

## Review round 1: PASS with should-fixes, all fixed
- **Field changes during a rebuild (D-1321)**, framework: GTK held back nothing, it dropped the change. Now a change that
  arrives while busy is held by the field's node id and sent after the rebuild; a stale patch can't write the app's
  older value over it. `examples/fieldcheck` + `tests/test_field_queue.py`: red on the old host (5 of 6 values lost),
  green now. Jot's workaround (D-1317) removed: the highlight follows typing again.
- **M2's margin (D-1322)**, checker addition: `GAPS: start` must print before `JOT SEED: start`, and the seed must take
  ≥ 200 ms (twice the gap limit). Seeded notes are a paragraph long now (10,000 still).
- **Goal 30 (D-1324)**: after D-1309 its M1 FAILED (a 66.7 ms gap, ≤ 50 wanted). `gaps:` now forces frames only when it
  starts paint timing itself (untraced runs); under MOJOUI_TRACE it measures the app's own paints as before. Goal 30 M1
  PASS (17, 17, 17 ms). `tests/test_gaps_stall.py`: a deliberate 300 ms stall reads 316.7 ms traced and untraced.
- **Web file drop (D-1326)**: every file in one upload, handed to on_file in turn under the session lock; each upload
  in its own folder; a session's uploads and downloads removed when it ends. drive.py `dropfile:` takes several paths;
  M3 gains two files of one name dropped together on GTK and the web (addition).
- **sqlite text (D-1323)**: `sqlite3_column_bytes`, so embedded NULs come back; invalid UTF-8 reads as U+FFFD;
  `fts_prefix_query` drops NULs. `sqlite nul text: ok` added to tests/test_sqlite.mojo.
- **Jot (D-1328)**: the problem line clears after the next action that goes well; imports over 4 MB or not UTF-8 are
  refused with a message (tried by hand).
- **GTK dialogs and drops (D-1327)**: answers go by message (picker_msg, the target's on_file), not node index, and wait
  out a pending rebuild (held_events); the save dialog honours `accept`.

## What it adds to the library
- `mojoui/sqlite.mojo`: `Database(path)` with `prepare/bind/step/run`, `begin/commit/rollback`, `count`, `last_id`, SQLite's own error messages (the connection stays usable), FTS5, and `fts_prefix_query(typed)` for search as you type (every word a quoted prefix: FTS5 syntax is searched for, never run). The system's libsqlite3 is loaded at run time and called by address (D-1304, D-1311). Test: `tests/test_sqlite.mojo`.
- `FileSaver(title, on_save, suggested=)` (mojoui.view): GTK's save dialog; on the web, a path in the page's downloads folder, then a real browser download. Step `save:Title=/path` (GTK and drive.py).
- `DropTarget(view, on_drop, on_file=)` (mojoui.dragdrop): files dropped from outside, one `on_file` per path; GTK a GdkFileList target, the web the browser's file drop (uploaded first). Step `dropfile:Tag=/path`. Test: `tests/test_file_io_views.mojo`.
- `App.closing()`: told once however the app ends (GTK close-request or shutdown, the web's session end and server exit, the Mac's terminate/close: built only). Step `quit` closes the window as a window manager does.
- `gaps:` is now a freeze detector by itself (shows the test window, listens to paints, asks for a frame every frame; D-1309).

## 30-second demo
```
scripts/build.sh jot linux
JOT_DB=/tmp/demo.db JOT_SCENE=gallery build/jot/linux/jot     # twelve notes; type "lisb" in Search, open a result
JOT_DB=/tmp/big.db JOT_SEED=10000 build/jot/linux/jot         # 10,000 notes arrive while the window stays live
scripts/build.sh jot web && JOT_DB=/tmp/demo.db pixi run python mojoui/hosts/web.py build/jot/web   # Export downloads; drop a .txt on the list
```

## Screenshots
`docs/gallery/img/jot-gtk.png`, `docs/gallery/img/jot-web.png` (gallery section "Database", `docs/gallery/index.html#database`).

## Decisions most worth a second look
1. **D-1317 and the host bug it works around.** `gtk_editable_set_text` emits "" then the new text; if the "" event's screen change needs a rebuild, the GTK host swallows the second change while the rebuild is pending, so the field's text is lost. Jot avoids it (its highlight changes only when a result is opened); the host isn't fixed. A paste over a selection can hit it in any app.
2. **D-1309, `gaps:` asks for a frame every frame.** Honest for "did the UI thread freeze", but it changes what goal 30's checker measures (idle stretches no longer count as gaps); goal 30 wasn't re-run.
3. **D-1304/D-1311, SQLite by dlopen and addresses.** No link flag anywhere and `mojo run` works, but the C signatures are written by hand in mojoui/sqlite.mojo (a wrong one is a crash, not a compile error), and the library path is fixed per OS.

## Unverified
- GTK's real save dialog and a drag from a real file manager (the checks hand in the path / a real GdkFileList through the target's own signal); the web's drop is a synthetic drop event carrying a File.
- The web's quit hook runs at session eviction and server exit (tried by hand once with SIGINT); closing a tab doesn't end its session, so it isn't told then.
- The Mac: built, not run; no save dialog or file drop there (no NSOpenPanel for FilePicker either). Android and iPhone: mojoui.sqlite not built.
- Search timing (p95 0.27 ms) is the FTS5 query only, not the list's repaint. Seed timing (~150 ms) and the frame gaps are from a shared, loaded machine.
- (Explained, not a defect) Two checker runs found build/jot/linux/jot missing, or an empty web database at M3: two agents ran the checker in this worktree at the same time and each rebuilt Jot under the other. Run alone: M3 three times PASS, the full checker M0–M6 PASS.
- A real file dialog left open while the screen rebuilds (D-1327): the steps hand in the path, no dialog stays open.
- The race: cold caches (no root to drop them), other machines, a phone browser. The web side's search time is the Worker's own; the page's repaint isn't in either side's number.

## Next step
Fix the GTK host's swallowed second change (queue it instead of dropping it while busy), then run `build/jot/mac/JotMojo.app` on the owner's Mac and add NSSavePanel/NSOpenPanel.

## Final checker run (after review round 1 and M6)
```
M0 PASS: tests/test_sqlite.mojo: sqlite open: ok, sqlite bind: ok, sqlite tx: ok, sqlite error: ok, sqlite fts5: ok
M1 PASS: 9 steps as expected (JOT: notes=2 results=2 open="Trip plan: flights to Lisbon in May"); the file holds both notes and FTS5 finds them
M2 PASS: 10,000 notes seeded with the window painting (479 frames, longest gap 33.3 ms); 50 searches p95 1.050617 ms, counts equal FTS5
M3 PASS: imported, exported byte for byte, and a dropped file became a note (GTK and the web); two dropped together (one name) became two
M4 PASS: typing then quit: saved by the quit hook, there after a relaunch
M5 PASS: gallery Database section, matrix, llms.txt, EXPERIMENTS; web and mac built
M6 PASS: 1M notes: search p95 A 64.58 vs B 165.82 ms (opfs-sahpool); cold open A 65.79 vs B 435.28 ms; build A 35.94 vs B 56.64 s; disk A 528.3 vs B 519.2 MB
```
