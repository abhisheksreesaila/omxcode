# The UI thread: why apps don't hang, and the rules that keep it that way

An app built on omxcode should never freeze, on any platform, without its author thinking about threads. This page
says how the framework makes that true, the few rules an app (or an agent writing one) follows, what each platform
does today, and how it's checked. The evidence for each claim is in [component-practices.md](component-practices.md)
§1–§2 and the decisions it names.

## The idea in one paragraph

Every platform (GTK, AppKit, UIKit, Android, the browser) draws on **one thread**, the UI thread, and lets nothing
else touch its widgets. At 60 frames a second that thread has about **16 ms per frame** (8 ms at 120 Hz). Anything
that takes longer, like a network call, opening a file or a big query, freezes the window if it runs there. So omxcode
splits every app in two: `update()` and `view()` run on the UI thread and must be quick; **slow work runs on worker
threads, and its answer comes back to `update()` as an ordinary event**. The app's state is only ever touched on the
UI thread, so there are no locks, no races and no "which thread am I on?" in app code.

## What the framework guarantees (you get these for free)

| Guarantee | How | Where |
|---|---|---|
| Widgets are only touched on the UI thread | the platform runs the loop and calls into Mojo; Mojo never runs a loop of its own | every host |
| Network requests never block the screen | `Http.get(...)` queues a request; it runs on a worker thread; the reply arrives as an `Event` | `mojoui/effects.mojo`, goal 33 |
| Timers never block | `App.every()` lists `Every(ms, msg)`; ticks arrive as events | `mojoui/effects.mojo` |
| Data work never blocks | `start_ui_job(...)` runs a query, import or sort on its own thread; when it ends, `App.jobs_message()` reaches `update()` | `mojoui/jobs.mojo`, D-771, D-792 |
| A finished job shows at once, not a frame later | the job's end wakes the main loop (a pipe on Linux and the web, `performSelectorOnMainThread` on the Mac) | D-771 |
| Cancelling never blocks | cancelling marks the job; checking whether its thread stopped doesn't wait (Linux, Mac) | `mojoui/sheetjobs.mojo` |
| Clicking a button that changes the screen never crashes | rebuilds wait until the click has finished; re-entrant signals are swallowed | every host |
| Big lists don't build big trees | `LazyList` and the data grid draw only what's on screen | D-252 |
| An idle app uses no CPU | canvases tick only while something moves; the web pulls a frame only after the last arrived | D-64, D-57 |

## The rules for an app (and for an agent writing one)

1. **`update()` and `view()` only decide.** They change state and describe the screen. Nothing in them should take
   more than a few milliseconds.
2. **Anything slow is a request, a timer or a job:**

   ```mojo
   # a network call: queue it; the reply comes back to update() as Event(FETCHED, ...)
   self.http.get(FETCHED, "http://localhost:8000/api/orders")

   # data work (a query, an import, a sort): a job; update() hears LANDED when it ends
   self.running = start_ui_job(StepJob(self.orders.value(), self.filters))
   def jobs_message(self) -> Int: return LANDED
   ```

3. **A job owns its inputs.** Hand it a snapshot or a copy (`sheet.snapshot()`), never a reference to the app's
   state; read its result back with `poll()` / `result()` in `update()`.
4. **Draw big things on a canvas, list big things lazily.** Don't build a widget per row.
5. **Never sleep or wait in `update()`.** Use `App.every()` for "later".

Follow these and the app runs without freezing on every platform below. Break rule 1 or 2 and no framework can save
it: SwiftUI, Jetpack Compose and React all share that limit (see "What's next" for how omxcode will catch it).

## Where each platform stands (measured)

| Platform | Requests and timers | Data jobs on their own thread | Finished job wakes the screen | Evidence |
|---|---|---|---|---|
| Linux (GTK) | ✅ | ✅ | ✅ 0.02–0.05 ms median | `examples/jobwake`: a 1.5 s job, 90 frames while it ran, longest gap 17 ms |
| Web | ✅ | ✅ | ✅ | goal 33, D-771 |
| Mac (AppKit) | ✅ | ✅ (D-792) | ✅ ~35 ms median on GitHub's virtual Macs | a 1.5 s job: longest frame gap 1516–1527 ms before → 71–83 ms after, macOS 15 and 26 |
| iPhone (UIKit) | builds, never run | ❌ jobs still run on the main thread | ❌ frame poll only | needs the Mac's fix plus a UIKit wake |
| Android | not checked | threaded build, not measured | frame poll; cancelling a job waits for its thread | runs on the emulator; none of this measured there |

The Mac numbers are from GitHub's virtual Macs (no GPU, ~20 frames a second), with the CPU build. The Mac's GPU
(Metal) build has the same switch but hasn't run with it yet; real-hardware numbers need the owner's MacBook.

## How it's checked

- `examples/jobwake` measures it: 40 short jobs (how fast a finished job reaches `update()`), then one 1.5 s job and
  the longest time the window went without a frame. It prints **PASS** under 500 ms and **FAIL (the window froze)**
  above, and exits 1 on Linux when it fails. On the Mac it runs on GitHub's runners (`scripts/mac-ci jobwake`).
- Building the Mac app the old way (`MOJOUI_SERIAL_JOBS=1 scripts/build.sh jobwake mac`) shows the freeze it
  prevents: 1 frame in 1.5 s.

## Known edges

- **Deliberate waits, every platform:** replacing a document waits for its cancelled jobs to stop (they may still be
  reading its data). A cancel lands within a block of rows (the engine's claim; not measured here).
- **The Mac's "has the thread stopped?" check reads an engine internal** (the job's reference count, `W_REFS`): the
  engine has no non-blocking `ended()` and Apple has no `pthread_tryjoin_np`. Asked of the engine as request #26
  ([mxframe-needs.md](mxframe-needs.md)); until then an engine change to that order would break it quietly.
- **The Mac's wake is ~35 ms** on GitHub's Macs against 0.05 ms on Linux; unmeasured on real hardware.

- **Python in a job** (goal 41, D-1146): CPython's lock stays with the UI thread, which never lets go on its own. A job
  that calls Python takes the lock with `mojoui.pygil.python_enter()`/`python_exit()`, and whoever starts it lends the
  lock (`python_lend()`, then `python_reclaim()` when the result is taken; mojoui.documentjobs does both). While it is
  lent, Python on the UI thread must go through `python_enter()` too (pdfsource and ocrmodel do; visionmodel doesn't yet).

## What's next, so it's "drop in a component and it just works"

1. **Catch a slow `update()`**: a debug build that names any `update()` or `view()` over one frame (16 ms) with the
   event that caused it, so an app author or an agent sees the freeze before a user does.
2. **The iPhone**: the Mac's job threads plus a UIKit wake, checked on the owner's iPhone.
3. **The Mac's GPU build** run with job threads (a job's Metal queries from its own thread), on the owner's MacBook.
