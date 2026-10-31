# Goal 45 report: Keeper, still working when the window is closed

## Review round 1 (2026-10-30)

**Verdict: PASS, M0–M4** on the full checker after the fixes (`pixi run python docs/goals/45-check.py`, branch `goal-45-keeper`);
reviewer re-check pending. The reviewer said NEEDS WORK; every item is fixed, each code fix with a test, decisions D-1611–D-1626.

| # | Item | What changed | Proof |
|---|---|---|---|
| 1 | M3's folder read was a strawman | `keeper_web.py` lists every subfolder at once and reads 16, 64, 256 at a time on the page and over 4 and 8 Web Workers; every try kept, the fastest races | web.json: one at a time 42.1 s; 16: **18.3 s**; 64: 20.2 s; 256: 21.9 s; 4 workers 28.7 s; 8 workers 27.8 s; `<input webkitdirectory>` at 64: 117.1 s. Native 2.2 s (read + index). The checker recomputes the fastest from raw t0/t1 |
| 2 | Web claims went beyond the evidence | Wording now: no code ran for a local file change or within a minute of closing; the held Background Sync *did* run when the network came back. Web Push was tried with every host but 127.0.0.1 unresolvable: `subscribe()` gave "no answer in 20 s". It needs a push server and Chromium's FCM, so it's recorded as untried. Periodic Sync's installed-app/~12 h rule is marked "documented, not observed". Every web number in the gallery is drawn from web.json by `scripts/keeper_gallery.py`; all polling and observer tries are kept | web.json `run_closed.tries.web_push`, `background_sync.ran_when_the_network_came_back: true` |
| 3 | A folder renamed inside the tree emitted nothing | DELETED (is_dir) for the old name, CREATED for each file under the new one, waiting files re-keyed; Keeper drops and re-adds them | tests/test_watch_edges.mojo `rename` |
| 4 | Overflow / unwatchable folders were silent | On IN_Q_OVERFLOW: report what was waiting, flush the move, re-add every watch, then OVERFLOW (Keeper rescans). A refused `inotify_add_watch` makes the watcher `partial()` with `missed()` and the reason (EACCES, ENOSPC → raise max_user_watches); Keeper shows it | test_watch_edges `overflow` (20,000 events past the 16,384 queue, via a test-only `hold`), `partial` (a mode-000 folder) |
| 5 | Background mode could strand the app | Hides only while a StatusNotifierWatcher holds the item (watched by name; registers again when one appears), otherwise closing ends the app and says so; one instance per background app (a relaunch opens the running one); a com.canonical.dbusmenu with Open and Quit | tests/test_tray.mojo (appear → register, vanish, re-appear → register again; menu layout; Quit/Open clicks); M1 additions: no panel → exits, registers with a pretend panel, second launch hands over, menu Quit ends it |
| 6 | Pipe records could be forged | Length-prefixed records; non-UTF-8 names arrive with `exact=False`, lossy `path`, real `path_bytes` | test_watch_edges `names`, `bytes` |
| 7 | Drop could kill or race | Drop stops the thread and waits (≤ 2 s, emptying the pipe); SIGPIPE blocked on the watcher thread, EPIPE stops it; F_SETPIPE_SZ checked (1 MB, else 256 KB), `pipe_size` kept | test_watch_edges `drop` (pipe full, thread count back to where it was) |
| 8 | Mac FSEvents use-after-free | stop, invalidate, `dispatch_sync_f` on its queue, release stream and queue, then free | built only (`scripts/build.sh keeper mac` in M4) |
| 9 | Alert floods, lost batches | One notification per burst (0.5 s quiet or 2 s max; names the file, or "<n> files mention <word>" and the first 50); none for a same-text re-save; a failed reindex goes back to the head of the queue, shows the error, retries after 1 s | M2: 20 alert files named exactly once each in 2 notifications; with the index held past the 5 s busy wait, KEEPER RETRY and then the file indexed |
| 10 | Checker tightening (additions only) | M0: stamp before each close/rename/remove, FAIL on events before it, show events inside the call, bound the lag from the call start, ms= allowance 10 → 3. M2: once each, Python's sqlite3 polling from outside (p95 ≤ 100), locked-index retry, `KEEPER RESULTS` from the list's first row checked against sqlite. M3: recompute from raw stamps, require a parallel read and a web_push try | D-1621, D-1623–D-1626 |
| 11 | Native lag stamped before delivery; different workloads | test_watch prints `got=` (the consumer's thread); the race takes the later stamp's p95; the gallery states both workloads. The web's observer lag is the median of three rounds (1.546, 2.011, 0.176 ms): one round swung 6× between runs on a machine at load ~10 from a parallel goal | M0: delivered p95 0.026 ms; web median 1.546 ms |
| 12 | Caption | Says Activate was called with gdbus on a private bus with a pretend panel (no real panel), and mentions the menu's Quit | gallery |

### Final run (all on a private bus, headless)
- **M0** 1,000 changes, each reported once; p95 0.01 ms from the close (0.03 ms from the call's start; 7 stamped inside their own close call, none before it began); delivered to the consumer's thread p95 0.026 ms; ms= within 2 ms on 1000/1000.
- **M1** no panel → closing ends it; with a pretend panel: registered, window closed and the app kept running, Activate reopened it, Notify on the bus, a second launch opened the running one, the menu's Quit ended it; without background mode it exits.
- **M2** (a) 100,000 files in 2,227 ms as a job, 2,400 frames, longest gap 16.7 ms; (b) closed: 200 files indexed once each, p95 2.5 ms (Python's sqlite3 polling: 5.0 ms), 20 alert files in 2 notifications, each named once, locked-index retry recovered; (c) Activate, search and the list show 200.
- **M3** read: native 2,227 ms vs the web's best 18,314 ms (8.2×); notice: both sub-millisecond and noisy on a loaded machine (native delivered p95 0.026–0.064 ms in M0 runs, 0.4 ms in a reviewer's standalone M3 run; the web's per-round p95 0.18–2.0 ms, median of three 1.546 ms), so no ratio is claimed: the difference that holds is that the web notices only while its tab is open; run, notify and tray: the web can't (with evidence; Push untried).
- **M4** gallery, matrix, llms.txt, EXPERIMENTS; `keeper mac` builds.

### Review round 2 (reviewer: PASS)
- The notice result no longer headlines a ratio (it swung with load); shown as ranges next to each other.

### Open items after round 1
- Reviewer re-check of this round.
- The notice race is sub-millisecond and noisy on a loaded machine: the web's single-round p95 ranged 0.18–2.0 ms across rounds and runs. An earlier run (one round, 0.279 ms) failed M3 against a loaded native run (~0.2 ms); the median-of-three rule (D-1626) is what settles it now. Native's delivered p95 ranged 0.026–0.064 ms across M0 runs.
- Web Push untried (needs a push server and Google's FCM; not allowed here).
- A second launch builds its App object (Keeper opens its index, starts a watcher) before it hands over to the running one.
- No real panel or notification server; the Mac is built, not run (no NSStatusItem or background mode there); `file_stamp` offsets are x86-64 Linux only.

---

## Round 0 (first pass)

Verdict then: PASS, M0–M4 (`pixi run python docs/goals/45-check.py`, final run on branch `goal-45-keeper`). Native does all five
things Keeper needs; the web does two of them, only while its tab is open and only on a folder a person dropped or picked,
and loses both races by far more than 2×. Three it can't do at all, with evidence. Reviewer: not run yet (see open items).

## What native did (final checker run)
| | Result |
|---|---|
| M0 folder watcher (`mojoui/watch.mojo`) | 1,000 changes (400 creates in 10 new nested folders, 200 modifies, 200 renames, 200 deletes), each reported once, none twice; p95 lag 0.01 ms (max 21 ms), close → event on CLOCK_MONOTONIC, computed by the checker; inotify read on its own thread (tid ≠ main) |
| M1 alive without a window | traycheck: window closed by the `quit` step, the process kept running; `org.kde.StatusNotifierItem-<pid>-1` on a private bus; `Activate` reopened the window (`WINDOW: open`); `Notify` with the app's random token seen on `dbus-monitor`; without background mode it still exits |
| M2 examples/keeper | (a) 100,000 files scanned and indexed as a job in 1.9 s: 2,400 frames, longest gap 16.7 ms; (b) window closed: 200 new files searchable p95 1.9 ms, all found by Python's sqlite3, 20 alert files each named in a notification, no quiet file named; (c) Activate reopened it, typed search shows the 200; screenshot `docs/goals/45/keeper-gtk.png` |
| M3 the web, measured | web.json fresh for its commit; every entry and try has evidence; native wins both races |
| M4 gallery and library | "Works when closed" + "Why not just WebGPU?" (42's and 43's race numbers); components.md rows (GTK ✅; Mac FSEvents/UNUserNotificationCenter 🔨; NSStatusItem/background mode ❌); llms.txt names `mojoui.watch`; EXPERIMENTS newest entry; `scripts/build.sh keeper mac` builds |

## What the web could and couldn't (headless Chromium 152, `docs/goals/45/web.json`)
| Thing | Web | Evidence |
|---|---|---|
| Read a folder | only after a click | `showDirectoryPicker()` without a gesture: SecurityError. With a DevTools gesture: the picker opens (`Page.fileChooserOpened`, mode selectSingle) but intercepting it aborts it, and headless nobody can answer it; a folder dropped through `Input.dispatchDragEvent` gives a directory handle; `<input webkitdirectory>` through `DOM.setFileInputFiles` gives a File snapshot. Reading the 100k corpus: 47.4 s through the handle (input: ~116 s), against native's 1.9 s that also indexes it |
| Notice a change | only with the tab open, on that dropped folder | FileSystemObserver (on by flag) p95 1.8 ms over 199 of 200 changes (missed the first file in a new subfolder); polling every 50 ms p95 ~126 ms. Native 0.01 ms |
| Run with the tab closed | no | a service worker with Background Sync (registered while offline) and Periodic Sync (permission granted via `Browser.setPermission`, registered, tag listed): no worker event after a file change or in 75 s after the tab closed. The held sync ran when the network came back (a network event, not a file change) and then couldn't read the stored folder handle (NotAllowedError) or show a notification |
| Notify with the tab closed | no | nothing woke the worker; when the network did, `showNotification` refused ("No notification permission", even after the grant: headless) |
| Tray item | no | no tray-like API in window/navigator (`statusbar` is the window's BarProp); Badging API exists but marks an installed app's icon |

Fairness notes: the tab was closed with the browser still running (kinder to the web than quitting it); the web's folder read is
read-only while native's scan also indexes; the watch race compares M0's workload (1,000 changes, 2 ms apart) with the web's
200 creates 20 ms apart; the web's lag uses a wall-clock offset measured by round trips (RTT ~0.4 ms).

## Open items
- Reviewer subagent not run in this session.
- Mac: FSEvents watcher and UNUserNotificationCenter built, not run; no permission request (needs a block); no NSStatusItem and no background mode in the AppKit host (it still quits when its last window closes); the watcher's wake on the Mac is not wired (poll take() on a timer).
- No tray menu (com.canonical.dbusmenu), so a background Keeper is quit only by ending the process; no real panel was used (only the bus).
- FSEvents doesn't pair rename halves; the Linux `file_stamp` stat offsets are x86-64 only.
- web.json's notification permission inside the worker stayed refused in headless Chromium despite the grant.

## Unverified
- Anything on a real desktop panel/notification server (all checks on a private bus with no services).
- The Mac at run time; Linux on non-x86-64.
