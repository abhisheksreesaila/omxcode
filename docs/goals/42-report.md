# Goal 42 report: Jot, omxcode keeps your data

**Done:** the checker prints PASS for M0–M5 (output at the end). Branch `goal-42-jot`, commits `Goal 42 M0`…`M5`. The reviewer hasn't seen it yet.

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
- Goal 30's checker after the `gaps:` change.

## Next step
Fix the GTK host's swallowed second change (queue it instead of dropping it while busy), then run `build/jot/mac/JotMojo.app` on the owner's Mac and add NSSavePanel/NSOpenPanel.

## Final checker run
```
M0 PASS: tests/test_sqlite.mojo: sqlite open: ok, sqlite bind: ok, sqlite tx: ok, sqlite error: ok, sqlite fts5: ok
M1 PASS: 9 steps as expected (JOT: notes=2 results=2 open="Trip plan: flights to Lisbon in May"); the file holds both notes and FTS5 finds them
M2 PASS: 10,000 notes seeded with the window painting (479 frames, longest gap 33.3 ms); 50 searches p95 0.248759 ms, counts equal FTS5
M3 PASS: imported, exported byte for byte, and a dropped file became a note (GTK and the web)
M4 PASS: typing then quit: saved by the quit hook, there after a relaunch
M5 PASS: gallery Database section, matrix, llms.txt, EXPERIMENTS; web and mac built
```
