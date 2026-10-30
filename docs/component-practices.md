# How omxcode's components are built: the best practices, and the proof

This page shows that the component layer (`mojoui/`) was designed on purpose. Every claim links to its code, the
decision behind it (D-nn in [decisions.md](decisions.md)), and the check that proves it. The gaps are listed too.
Audited 2026-10-30 against `main` (a818aa8), plus the accessibility work on branch `components-practices`.

## On one slide

> **Native widgets, one UI thread, data flowing one way, slow work on worker threads, names for every screen reader:
> the same rules SwiftUI, Jetpack Compose and React follow, applied to five platforms from one Mojo file, and checked by
> running them.**

| Practice | Status |
|---|---|
| Only the UI thread touches widgets; the platform owns the loop | ✅ by construction |
| Slow work runs on worker threads and comes back as an event | ✅ HTTP, timers, data jobs (Apple: jobs still on the main thread) |
| Data flows one way: state → `view()` → diff → patches | ✅ |
| No closures on widgets (no leaks, no stale captures) | ✅ D-19 |
| A widget is never destroyed inside its own event | ✅ |
| Keyed diffing keeps focus, cursor and scroll position | ✅ |
| Lists and grids draw only what's on screen | ✅ 1M rows, 0.8 ms p95 a scroll frame |
| Idle apps don't wake the CPU; slow networks get fewer frames, not lag | ✅ D-64, D-57 |
| Native controls: typing, spell-check, keyboard and screen readers from the platform | ✅ |
| Every control has a name a screen reader can say, from one rule | ✅ GTK and web proven; Apple builds |
| Respects "reduce motion" and dark mode | ✅ GTK, web (motion); every host (dark) |
| Behaviour separate from looks (themes) | ✅ D-260 |
| Proven by running on each platform, with a public matrix | ✅ [components.md](components.md) |

## 1. One UI thread, and the platform owns the loop

**The rule.** Every UI toolkit (GTK, AppKit, UIKit, Android, the browser) lets only one thread touch its widgets.
Touching them from another thread causes random crashes that are hard to reproduce.

**What omxcode does.** The platform's own loop runs the app: GTK's main loop, `NSApplication run`,
`UIApplicationMain`, Android's Activity, the web server. It calls into Mojo; Mojo never runs a loop of its own
(ROADMAP decision 2). Every widget call happens inside one of those callbacks, so no widget can be touched from the
wrong thread. ([architecture.md](architecture.md), "The bridge")

## 2. Slow work off the UI thread, results back as events

**The rule.** The UI thread has about 16 ms per frame at 60 Hz (8 ms at 120 Hz). Anything slower, like a network call,
a file import or a big query, must run elsewhere, and its result must come back to the UI thread. Elm calls these
"commands", Compose uses coroutines, SwiftUI uses `async` tasks.

**What omxcode does.**
- **Effects** ([mojoui/effects.mojo](../mojoui/effects.mojo), goal 33, D-320–D-326): `update()` asks for HTTP requests
  and timers; requests run on worker threads; each reply comes back to `update()` as an ordinary `Event`, on the UI
  thread. Requests can be cancelled; streamed replies arrive piece by piece.
- **Data jobs** ([mojoui/jobs.mojo](../mojoui/jobs.mojo), D-771): a background job's end wakes the UI at once through
  a self-pipe the main loop watches (GTK: `g_unix_fd_add`; the web: a thread blocking on it). Measured
  ([examples/jobwake](../examples/jobwake/app.mojo)): job end → `update()` median 0.05 ms, p95 1.0–2.2 ms on GTK.
- Nothing else crosses threads: the job's result is read on the UI thread, so the app's state is never shared.

**Gap.** On the Mac and iPhone the engine runs jobs serially on the main thread (D-771), so a long job freezes the
window there. UIKit isn't wired to the wake yet; it falls back to polling at frames.

## 3. Data flows one way

**The rule.** The screen is a function of the state. You change the state; the framework works out what to redraw.
That rules out "forgot to update that label" bugs. SwiftUI, Compose, React and Elm all work this way.

**What omxcode does.** `update(event)` changes the state, `view()` describes the whole screen as data, `diff()` compares
it with the last one, and the host applies only the differences ([mojoui/app.mojo](../mojoui/app.mojo),
[mojoui/diff.mojo](../mojoui/diff.mojo)).

## 4. Messages are numbers, not closures

**The rule.** A closure stored on a widget can capture stale variables, and on Apple platforms it can keep its own view
alive forever (a retain cycle, the classic iPhone memory leak).

**What omxcode does.** A button holds a message number (`on_tap=SAVE`). When it's tapped, the host looks up the message
in the current screen (D-19). Nothing is captured, so nothing leaks, and a message can change without rewiring.

## 5. Never destroy a widget inside its own event

**The rule.** Freeing a button while it's still handling its own click is a well-known crash in GTK and AppKit.

**What omxcode does.** When a tap changes the screen's shape, the rebuild waits for the next idle moment
(`g_idle_add` on GTK), never inside the signal handler. Re-entrant signals (setting a slider from code fires
"value-changed") are swallowed by a busy flag, so the app and the widget can't bounce events back and forth.

## 6. Keyed diffing

**The rule.** When rows are added or removed, the widgets that stay should keep their state: focus, the text cursor,
the scroll position. React does this with `key`.

**What omxcode does.** The diff pairs old and new children by kind, style and tag (the longest common run) and keeps
every widget it can; only the parts that changed are rebuilt ([mojoui/diff.mojo](../mojoui/diff.mojo),
`tests/test_diff_keep.mojo`).

## 7. Draw only what's on screen

**The rule.** Big lists and grids must not create a widget per row. iOS table views and Android's RecyclerView recycle
a few on-screen rows.

**What omxcode does.** `LazyList` asks the app only for visible rows (`App.row`). The data grid draws a display list
with keyed layers that each host replays on its GPU path (D-252): 1M rows scroll at 0.8 ms p95 a frame, with no cells
rebuilt while gliding (goal 26).

## 8. Frame pacing and backpressure

**The rule.** An idle app shouldn't drain the battery. A slow network should get fewer frames, not a growing backlog.

**What omxcode does.** Canvases tick only while something moves (D-64). The web pulls at most one frame per display
refresh, and only after the last one arrived (D-57, D-58).

## 9. Native widgets, not imitations

**The rule.** A real platform control brings typing in every script, spell-check, keyboard handling, the platform's
feel and its screen-reader support for free. Frameworks that draw their own controls must rebuild all of that.

**What omxcode does.** Each component is the platform's own control: `GtkButton`, `NSButton`, `UIButton`, Android's
`Button`, the browser's `<button>`. Only data-heavy content (charts, the grid, the particle field) is drawn.

## 10. Every control has a name a screen reader can say

**The rule.** VoiceOver, TalkBack, Orca and Narrator read out each control's *accessible name*. An icon-only button or
a drawn chart without one is invisible to a blind user (WCAG 4.1.2).

**What omxcode does** ([mojoui/a11y.mojo](../mojoui/a11y.mojo), branch `components-practices`):
- **One rule for every host.** The name comes from `.label()` (never shown), then `.tooltip()`, then the control's own
  words (a button's title), then a field's placeholder.
- **An audit.** `audit(view)` lists every control nothing names: `SLIDER #7 (zoom): no name`.
- **Each host hands the name to its platform:** GTK's `GtkAccessible` label, the web's `aria-label` on the control
  itself, `accessibilityLabel` on AppKit and UIKit. A drawn chart is an *image* named by its words, and the name
  follows when the words change in place.
- **Proven against the platform, not our own tree** (`scripts/check_a11y.py`): GTK's own test accessibility backend
  reads back each label (and confirms an unnamed control has none); Chromium's accessibility tree names
  `button "Delete"`, `combobox "Region"`, `textbox "Search"`, `img "Sum of amount by region, as bars"`, and after a
  change `img "Average of amount by region, as bars"`.
- **Motion and appearance.** "Reduce motion" turns animations off on GTK (`gtk-enable-animations`) and the web
  (`prefers-reduced-motion`); every host tells the app about dark mode (`App.appearance`). The iPhone follows the
  person's text size (Dynamic Type).

## 11. Behaviour separate from looks

**The rule.** The best component libraries separate what a control *does* (states, keyboard, accessibility) from how it
*looks*: Radix and React Aria on the web, control templates in Microsoft's XAML.

**What omxcode does.** Components say what they mean (`PROMINENT`, `TOKEN`, `CARD_WARN`); themes outside the framework
decide the look (D-260, [themes/](../themes)). An app switches skins without touching a component.

## 12. Proven by running, on each platform

**The rule.** "It compiles" is not "it works".

**What omxcode does.** The core has no platform code, so it's unit-tested on its own. Each host has a test mode that
drives its *real* widgets (`MOJOUI_TEST="tap:Save;type:Name=Ada"`). The web is driven in headless Chromium, Android on
the emulator with real input, the Mac on GitHub's Mac runners. [components.md](components.md) is generated from the
code and the checks: ✅ run by a check, 🔨 built but never run, ❌ missing. `scripts/check` fails when it's stale.

## Where it falls short (honest list)

| Gap | Why it matters | Next step |
|---|---|---|
| iPhone and Android tablet never run on real hardware | the iPhone column is 🔨; a build isn't proof | CI/CD on the owner's MacBook, iPhone and Android tablet |
| Mac/iPhone: data jobs run on the main thread | a long query freezes the window there | job threads in the engine's Apple build (omxcore) |
| Screen readers can name a chart, but not read its numbers | a summary isn't the data | expose `App.describe()` (already written for agents) as an accessible table |
| Android: no accessible names from `.label()` yet | its content description doubles as a test tag | separate the test tag from the description |
| Apple hosts don't apply a canvas's changing words (SET_TIP) | VoiceOver hears the first words only | apply SET_TIP on AppKit and UIKit |
| No right-to-left layout or localisation | Arabic and Hebrew users | `dir="auto"` on the web, `semanticContentAttribute` on Apple |
| The whole screen is rebuilt and compared on each event | fine today; may cost at 10k+ nodes | measure first; fine-grained tracking (SwiftUI `@Observable`, Compose scopes) if it shows |

## Why Mac controls feel flexible and Windows ones stubborn

AppKit and UIKit draw every view on a layer you can restyle, stack and animate freely. Classic Windows controls (Win32,
WinForms) came with a fixed set of properties: change more than those and you had to draw the whole control yourself.
Microsoft fixed this in XAML with control templates: replace a control's whole look and keep its behaviour. The
industry settled on that split, behaviour in one place and looks in another, and omxcode follows it: native
components for behaviour, themes for the look. The cost of native widgets is that they share only the properties every
platform has; that's why rich content (charts, the grid) is drawn instead.

## What we compared against

SwiftUI and UIKit (Apple), Jetpack Compose and the Android view system, GTK 4's accessibility model (GtkAccessible,
modelled on WAI-ARIA), WAI-ARIA and WCAG 2.2 (W3C), React's reconciliation and keys, Elm's architecture (commands and
subscriptions), React Native's new architecture (Fabric), Flutter, Zed's GPUI and Linebender's Xilem and AccessKit (Rust
UI toolkits with an accessibility tree of their own).
