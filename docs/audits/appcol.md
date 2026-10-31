# Audit: could omxcode build appcol?

appcol (`~/Projects/appcol`) is one personal web app on the owner's iPhone home screen, with three mini-apps: **Shlokas** (learn a shloka stanza by stanza from a PDF and a recording), **House** (what I walk away with if I sell) and **What-if** (stay vs move). Built with FastHTML and plain JS, about 2,600 lines. Audited 2026-10-31 against omxcode main (716198c). Shipped features only (F-001 to F-009); F-010 to F-012 are still todo.

## Verdict

**Could we build it today? Partly, and not on the iPhone.**

- **House and What-if:** yes on Linux and the web, today. Every piece exists (rows, sliders, dialogs, number formats, charts, SQLite). The feel drops: no bottom sheet, no drag-to-scrub, and on the web every slider move is a server round-trip.
- **Shlokas:** no. omxcode can't **play sound** on any platform. Looping a stanza, slowing it down and keeping it going with the phone locked are the whole app.
- **The iPhone, where appcol is used:** no. The UIKit host builds and signs but **has never run on a phone**, and it lacks SQLite, HTTP, timers and light/dark. The web host can't be added to the home screen (no manifest) and has no passcode gate.

Of 44 features: **15 have (34%) · 22 partial (50%) · 7 missing (16%)**. Hosts: ✅ run by a check · 🔨 built, never run · ❌ missing, in the order Linux, web, Mac, iPhone, Android.

## Features

| Area | Feature | Status | L W M i A | omxcode piece → what closes it |
|---|---|---|---|---|
| Shell | Installs to the iPhone home screen (manifest, apple meta tags, icon, standalone) | missing | ❌ ❌ 🔨 🔨 ✅ | none (web host serves no manifest); native UIKit app instead → Web host emits a manifest, icons and apple meta from App metadata; or a signed UIKit build run on the owner's iPhone (S, Nov 2026) |
| Shell | Tab bar: bottom bar on the phone, top islands on the computer, sliding thumb | partial | ✅ ✅ 🔨 🔨 ✅ | Tabs + Overlay islands (mojoui/view.mojo) → TabBar shell piece: bottom bar under compact width (UITabBar on iPhone), top pill on wide screens, spring thumb (M, Nov 2026) |
| Shell | Auto / Light / Dark button, remembered, follows the phone, no white flash | partial | ✅ ✅ 🔨 ❌ ❌ | App.appearance(dark) + Theme → UIKit traitCollection change → App.appearance; a per-app override setting (S, Nov 2026) |
| Shell | Remembers small settings (last tab, repeats, speed) across launches | partial | ✅ ✅ 🔨 ❌ ❌ | mojoui.sqlite (no key-value prefs API) → mojoui.prefs: a tiny per-app key-value store (file / localStorage / NSUserDefaults / SharedPreferences) (S, Nov 2026) |
| Shell | Deep links open a stanza (#/s/<id>/practise/<n>), back button works | partial | ✅ ✅ 🔨 ❌ ❌ | Route (mojoui/route.mojo) → Route on UIKit and Android (URL schemes / universal links into the same messages) (M, Dec 2026) |
| Shell | Toasts ('Not saved…', 'Every stanza learned') | have | ✅ ✅ 🔨 🔨 ❌ | Toast |
| Shell | Bottom sheets with scrim and grab handle (every value edit, add, menus) | partial | ✅ ✅ 🔨 🔨 ❌ | Dialog / Popover (UIKit presents adaptively) → Sheet component: UISheetPresentationController with detents on iPhone, a bottom sheet that drags to dismiss on web/GTK/Android, Liquid settle (M, Nov 2026) |
| Shell | Sliders a finger can tap or drag anywhere on the band (not just the thumb) | partial | ✅ ✅ 🔨 🔨 ✅ | Slider → Slider(track_taps=True): a tap or drag on the track moves the thumb on every host (S, Nov 2026) |
| Shell | Passcode gate online (one sign-in page, 400-day cookie, lockout after 10 tries) | missing | ❌ ❌ ❌ ❌ ❌ | none → Web host auth hook (passcode or fh-saas sign-in in front of every session) (S, Nov 2026) |
| Shell | Saves each app's state to SQLite a moment after the last change; survives restart | partial | ✅ ✅ 🔨 ❌ ❌ | mojoui.sqlite + Timers (App.every) → mojoui.sqlite and Timers on UIKit (libsqlite3 ships with iOS; NSTimer) (S, Nov 2026) |
| Shell | Same data on the phone and the computer (mark on the Mac, practise on the phone) | partial | ✅ ✅ 🔨 ❌ ❌ | Web host sessions over one server database; mojoui.http for a native client → HTTP on UIKit (NSURLSession) so a native phone app syncs with the server (M, Nov 2026) |
| Shell | Runs online away from home Wi-Fi (Railway, a /data volume) | partial | ❌ 🔨 ❌ ❌ ❌ | Web host (FastHTML, Python) → A deploy recipe for the web host and a latency check over a phone network (S, Nov 2026) |
| Shlokas | Library: Learning / Saved / Done / Archived, progress per shloka, 'continue' card | have | ✅ ✅ 🔨 🔨 ✅ | Segmented, Card, ProgressBar, LazyList, Lists |
| Shlokas | Add: paste a PDF link and an mp3 or YouTube link | have | ✅ ✅ 🔨 🔨 ❌ | TextField + Dialog |
| Shlokas | Server downloads the PDF and audio (yt-dlp for YouTube) in the background; library polls 'preparing' | partial | ✅ ✅ 🔨 ❌ ❌ | mojoui.jobs (start_ui_job) + mojoui.http + Python interop → Http.download(url, path) with progress on a job thread (S, Nov 2026) |
| Shlokas | PDF pages as images; stanza bands found from the bold stanza numbers | partial | ✅ ✅ 🔨 🔨 🔨 | PdfSource (mojoui/pdfsource.mojo) → PdfSource words with font, size and bold (S, this week) |
| Shlokas | Pause detection, waveform peaks and 'Suggest' markers from a 2-hour recording | missing | ❌ ❌ ❌ ❌ ❌ | mojoui.audio.load_wav only (no decoder for mp3) → AudioSource: any audio file to PCM (ffmpeg pipe now, libav later), plus pauses/peaks on the GPU (M, Nov 2026) |
| Shlokas | Plays one stanza on a tight loop, ×1–×10 or ∞, with a breath between repeats | missing | ❌ ❌ ❌ ❌ ❌ | none → mojoui.sound: Sound(path) play/pause/seek/time/loop(segment) — PipeWire on Linux, <audio> on web, AVAudioPlayer on Mac/iPhone, MediaPlayer on Android (L, Dec 2026) |
| Shlokas | Speed 0.5×–1× without chipmunk pitch, ramping up to 1× over the repeats | missing | ❌ ❌ ❌ ❌ ❌ | none → Sound.rate with pitch kept (AVAudioUnitTimePitch, browser preservesPitch, WSOLA in Mojo on Linux) (M, Dec 2026) |
| Shlokas | Keeps looping with the phone locked or the app in the background | missing | ❌ ❌ ❌ ❌ ❌ | none → iOS audio session + UIBackgroundModes audio, lock-screen Now Playing controls (M, 2027) |
| Shlokas | Practise page: the PDF page with the stanza's band lit | partial | ✅ ✅ ❌ ❌ ❌ | Document card (mojoui/documentcard.mojo) + Picture → DocumentView: the document card without Board chrome, on the Apple canvas and Android (M, Nov 2026) |
| Shlokas | Double-tap the page to zoom into the band, again to go back (spring) | partial | ✅ ✅ 🔨 🔨 ❌ | Canvas DOUBLE + Spring → zoom_to(box) with a spring inside DocumentView (S, Nov 2026) |
| Shlokas | Swipe left/right for the next or previous stanza | partial | ✅ ✅ 🔨 🔨 ✅ | Canvas PAN → Pager: swipe between pages with a spring, on any view (S, Nov 2026) |
| Shlokas | Strip of stanza numbers, current one scrolled into view, learned ones ticked | partial | ✅ ✅ 🔨 🔨 ✅ | Scroll + Button (Board has reveal; Scroll doesn't) → Scroll(reveal=index) on every host (S, Nov 2026) |
| Shlokas | Playback sheet: repeats slider (×1–×10, ∞), speed slider, 'Speed up' toggle | have | ✅ ✅ 🔨 🔨 ✅ | Slider + Toggle + Dialog |
| Shlokas | ✓ marks a stanza learned (tap again to undo); all learned → done | have | ✅ ✅ 🔨 🔨 ❌ | Button(style=ICON_ON) |
| Shlokas | Mark tool timeline: waveform, playhead, scrub, wheel and pinch zoom, tap a band | partial | ✅ ✅ 🔨 🔨 ❌ | Canvas (PAN, ZOOM, TAP, WHEEL) + MediaTimeline / Time lane → Waveform lane for MediaTimeline once AudioSource exists (S, Dec 2026) |
| Shlokas | Big Start N / End N button; Space, P, Z, arrows on the keyboard; Undo | partial | ✅ ✅ ❌ ❌ ❌ | Canvas KEY + Item(shortcut=) → App-level shortcuts without a menu (App.shortcuts()), on every host (S, Nov 2026) |
| Shlokas | Stanza list beside the page (click a row or ↑/↓ to fix one) | have | ✅ ✅ 🔨 🔨 ❌ | Lists + LazyList |
| Shlokas | Mark tool only on wide screens; phone gets Practise | have | ✅ ✅ 🔨 🔨 ❌ | App.window_size() |
| Shlokas | Markers saved on every tap, merged atomically with the server's preparation | have | ✅ ✅ 🔨 ❌ ❌ | mojoui.sqlite begin/commit |
| House | Hero number, money as $1,234,567 / −$… / $1.6M | have | ✅ ✅ 🔨 🔨 🔨 | mojoui.numformat (CURRENCY, COMPACT) |
| House | Sale price ruler: a slider over a $600k window with $ ticks | partial | ✅ ✅ 🔨 🔨 ✅ | Slider (+ Canvas for ticks) → Slider ticks and labels (S, Nov 2026) |
| House | Value rows: tap → sheet with slider, presets and keypad; or scrub the value sideways | partial | ✅ ✅ 🔨 🔨 ❌ | Button rows + Dialog + Slider + Segmented; drag only on Canvas/Draggable → Scrubber: a value you drag sideways to change, on every host (S, Nov 2026) |
| House | Proceeds waterfall (a bar per cost, sized to the sale) | have | ✅ ✅ 🔨 🔨 ❌ | Meter (chart rows) / ChartView bars |
| House | + chips add extra costs; remove a row; location picks the transfer tax | have | ✅ ✅ 🔨 🔨 ❌ | Chip, Dropdown / Menu |
| House | Sale maths (commission, transfer tax, escrow, exclusion, fed + NIIT + CA) and the insight line | have | ✅ ✅ 🔨 🔨 ✅ | plain Mojo in update() |
| What-if | Stay and Move ledgers; add my own credit/debit lines (months, growth, one-off) | have | ✅ ✅ 🔨 🔨 ❌ | Lists, TextField, Segmented, Toggle |
| What-if | Running-gap line chart, Stay vs Move, redrawn while I drag | partial | ✅ ✅ 🔨 🔨 🔨 | ChartView.line → ChartView.lines(series…): any number of series on one axis (S, Nov 2026) |
| What-if | Verdict, break-even rent, 24/48-month toggle | have | ✅ ✅ 🔨 🔨 ✅ | Card + Segmented |
| What-if | Edit sheet with an amount slider; typing after a slide starts a new number | have | ✅ ✅ 🔨 🔨 ❌ | Dialog + Slider + TextField |
| Look | omxqua look: tonal surfaces, one soft shadow, violet Money and amber Shlokas accents | partial | ✅ ✅ 🔨 🔨 ❌ | themes/omxqua.mojo → omxqua families (money, amber…) as theme options (S, this week) |
| Look | Liquid motion: springs, sheets that settle, the tab thumb that slides | partial | ✅ ✅ 🔨 🔨 ❌ | mojoui/spring.mojo (Canvas only) → Springs on native views (sheet settle, tab thumb, press) (M, Dec 2026) |
| Look | Every touch target ≥ 48 px, checked by a test | missing | ❌ ❌ ❌ ❌ ❌ | none (mojoui/a11y.mojo has no size rule) → A check that fails a tappable view under 44–48 pt on every host (S, Nov 2026) |

## Where omxcode would win

- **Audio analysis in the app itself.** Pause detection and waveform peaks for a 2-hour class run in the same Mojo program, on the GPU when there is one, instead of a numpy step on the server. *Unproven:* no AudioSource yet. The same idea is proven for video (`mojoui/videotable.mojo`, goal 41).
- **Agent-native for free.** "Mark stanza 12 learned" or "set the sale price to $1.7M" become MCP tools with no per-app code (`docs/agent.md`). appcol has nothing like it.
- **Native on each screen.** One app gives the computer its mark tool and the phone its practise page, each with native controls, instead of one responsive web page. *Unproven on the phone.*
- **Offline.** A native phone app could keep the PDFs and audio on the device. appcol needs its server for every screen. *Unproven:* needs SQLite, Sound and HTTP on UIKit.
- **The maths as typed Mojo.** The sale and stay-vs-move maths become plain Mojo, tested with `mojo test` and shared by every host.

## Gaps, in order

1. **Sound** (`mojoui.sound`: play, pause, seek, loop a segment, rate with pitch kept; PipeWire, `<audio>`, AVAudioPlayer, MediaPlayer). L, Dec 2026. Blocks Shlokas. Good demo: one stanza looping at 0.8× → 1× on Linux, web and the phone.
2. **The iPhone host for real**: run it on the owner's iPhone, then add SQLite, HTTP, timers and appearance on UIKit. L, Dec 2026. Blocks every mini-app on the phone.
3. **AudioSource + GPU pauses/peaks** (file → PCM via ffmpeg, like `VideoSource`). M, Nov 2026. Blocks Suggest and the waveform. Good demo: Suggest on a 2-hour class against the numpy version.
4. **Sheet** (detents, drag to dismiss, Liquid settle, on every host). M, Nov 2026. Blocks the faithful feel of every edit. Good demo.
5. **DocumentView** (the document card without Board chrome, on the Apple canvas and Android, plus `zoom_to(box)` and a swipe Pager). M, Nov 2026. Blocks the practise page on the phone.
6. **Web host as a home-screen app** (manifest, icons, apple meta) **and an auth hook** (passcode or fh-saas). S, Nov 2026. Blocks the "use the web host on the phone today" route.
7. **Background audio on the iPhone** (audio session, background mode, Now Playing). M, 2027.
8. Small ones, S each, this week to Nov 2026: bold text in `PdfSource` words, omxqua Money/amber families, `mojoui.prefs`, `Scroll(reveal=)`, Slider track taps and ticks, a Scrubber, `ChartView.lines`, app-level shortcuts, `Http.download`, a 48 pt touch-target check, Route and appearance on UIKit.
