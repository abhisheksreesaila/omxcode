# GOAL 45: Keeper, still working when the window is closed

**End goal (owner, 2026-10-30):** the fifth probe, and the first of the "the web can't do this at all" kind. The owner's
question: the JS crowd will say "I have WebGPU, I'll keep JS". The answer that lasts is reach, not only speed: a native app
keeps working with its window closed, watches your folders, sits in the tray and tells you things. A web page can't read a
folder without a click, and once its tab is closed none of its code runs. Yardstick: Personal Note's reminders thread
(`reminders.py`: fires through `system_notify`, counts what came due while closed) and its background indexer.

Framework first: the folder watcher, background mode, the tray item and notifications are `mojoui` components with their
own tests; `examples/keeper` composes them with `mojoui.sqlite` (goal 42). Slow work off the UI thread (docs/ui-threads.md).
Look: Liquid.

## Milestones
| # | Milestone | Proof (`pixi run python docs/goals/45-check.py`) |
|---|---|---|
| M0 | The folder watcher (`mojoui/watch.mojo`) | `tests/test_watch.mojo` watches `$MOJOUI_WATCH_DIR` recursively (Linux inotify on its own thread, new subfolders followed); the checker creates, modifies, renames and deletes 1,000 files across new subfolders while it runs; the test prints one `WATCH EVENT: <kind> <path> ms=<lag>` per change (lag = the file's close or rename → the event in Mojo, on one clock); every change is reported, none twice for one write, p95 lag ≤ 50 ms |
| M1 | Alive without a window | App learns a background mode: closing the window (the `quit` step) leaves the process running when the app asks for it; a tray item (StatusNotifierItem over D-Bus: `org.kde.StatusNotifierItem-<pid>-1`, `/StatusNotifierItem`) whose Activate opens the window again; notifications through `org.freedesktop.Notifications`. All on a private session bus the checker starts (`dbus-run-session`), never the owner's: the checker sees the item's bus name with `gdbus`, calls Activate and sees the app print that its window is open, and sees a `Notify` call with the app's text on `dbus-monitor` |
| M2 | examples/keeper | one Mojo file: watches `$KEEPER_DIR` (text and Markdown files), keeps a SQLite FTS5 index of them in `$KEEPER_DB`, a search field, a list of what changed lately. (a) A first scan of 100,000 files runs as a job with the window painting (`gaps:` ≥ 20 frames, longest ≤ 100 ms, the scan inside the window). (b) With the window closed (background mode), the checker writes 200 files; each prints `KEEPER INDEXED: <path> ms=<lag>` (file closed → searchable), p95 ≤ 100 ms, and Python's sqlite3 finds every one by a word in it; files containing `$KEEPER_ALERT`'s word raise a notification naming the file (seen on the bus). (c) Activate reopens the window and a typed search shows the new files; screenshot `docs/goals/45/keeper-gtk.png` |
| M3 | What the web can do, measured | `scripts/keeper_web.py` writes `docs/goals/45/web.json` (fresh: its commit's mojoui/watch.mojo and the script equal HEAD's) from headless Chromium trying the web's best for each thing Keeper does: read a folder (File System Access `showDirectoryPicker`; without a user gesture, and with one granted through the DevTools protocol), notice a change in it (`FileSystemObserver` if offered, else polling, each tried), run code with the tab closed (a service worker with Background Sync and Periodic Background Sync registered: does it run when a file changes or a minute passes after the tab closes?), show a notification with the tab closed, a tray item. Each entry: `can` true/false, the evidence (the error, the observation, the timings), never a guess. **Pass:** native does all five (M0–M2 passed); every web entry has evidence; where the web can do a thing, native's p95 lag is ≤ half the web's. A loss is a FAIL |
| M4 | In the gallery, back in the library | a "Works when closed" section in `docs/gallery/index.html` with `img/keeper-gtk.png` and web.json's results (each web entry with its evidence, wins and losses); a short "Why not just WebGPU?" note in the gallery drawing the Dictate, Jot (and Recall, if merged) race numbers from their race.json files; `scripts/components.py --check` passes and components.md lists the folder watcher, background mode, the tray item and notifications (honest per host: GTK ✅ if run; the Mac's FSEvents/NSStatusItem/UNUserNotificationCenter 🔨 with notes if built only); `docs/llms.txt` names `mojoui.watch`; EXPERIMENTS.md's newest entry is goal 45; `scripts/build.sh keeper mac` succeeds (built, not run) |

## Done means
The checker prints PASS for M0–M4 and the reviewer passes it.

## Out of bounds
Pushing; the frozen `../mojo-ui-apple-test`; `GOAL.md` and `scripts/check.py`; windows on the owner's desktop (headless
only); the owner's session bus, tray and notifications (a private bus only); the owner's files (temp folders only);
installing system packages; paid services.

## Assumptions (instead of asking)
- Branch `goal-45-keeper` from local `main` at 7d747de (Sketch, Jot and Dictate merged); worktree `../mojo-ui-g45`; decisions D-1600 onward. Goal 44 (Recall) runs in parallel in `../mojo-ui-g44` and owns the GPU; this goal doesn't need one.
- The checker (`docs/goals/45-check.py`) is written first, from this file's words, as the first commit, and baseline-FAILs every milestone; it may only gain additions afterwards.
- D-Bus through libdbus or GIO's GDBus (already linked by the GTK host), not a Python bridge.
- No compositor-level global hotkey here (it needs a Wayland compositor the checker can run headless, which isn't installed); that is a later probe.

## Budget
80 turns.
