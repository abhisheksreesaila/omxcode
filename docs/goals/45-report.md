# Goal 45 report: Keeper, still working when the window is closed

**Verdict: PASS, M0–M4** (`pixi run python docs/goals/45-check.py`, final run on branch `goal-45-keeper`). Native does all five
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
