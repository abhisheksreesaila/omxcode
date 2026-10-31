# Audit: could omxcode build finxplorer 2026?

App: `/home/abhisheksreesaila/Projects/repo-finxplorer-2026`. Personal-finance web app: bank data via Quiltt, spending analytics, budgets and plans, reports, email, admin; FastHTML + JS, omxqua Ledger, phone and laptop. Audited 2026-10-31 against omxcode main (716198c).

## Verdict

**Partly, not today.** Not today: most screens (lists, budgets, plans, analytics tables) map to tested mojoui pieces on Linux and web, but sign-in, per-tenant data, HTTPS, the Flow chart, drawers and real phone builds are missing.

Of 36 features a user would name: **15 have (42%) · 17 partial (47%) · 4 missing (11%)**.

What that means in plain words:
- **The screens are mostly there, on Linux and the web.** Transactions (DataGrid, search with FTS5), budgets and goals (meters), the 13 planning calculators (fields, sliders, line and bar charts), Shift and Month by month (pivots and month/quarter group-bys on the MX frame), settings, the omxqua Ledger skin in light and dark. Each is a mojoui component with its own test.
- **What stops a faithful rebuild is the plumbing, not the widgets.** No sign-in, no per-user tenant data in the web host (every tab is a session in one process with no identity), and plain HTTP only (`mojoui/http.mojo`: `TLS_NEEDED`), so a native app can't reach the real API.
- **Four finance pieces are missing or partial:** the Flow (Sankey) chart, a donut, a calendar chart, and charts that filter each other.
- **Phones:** the app is half phone. omxcode's rich components are ❌ on Android and have never run on an iPhone; the web host on a phone browser is the only phone path today, and it hasn't been checked on a real phone either.
- **Mac:** every row is 🔨 (builds, never run by a check).

**Where the server side sits.** Accounts, Google sign-in, Stripe, Quiltt webhooks, sync jobs, email and one SQLite per tenant are **fh-saas's job, alongside omxcode**, not omxcode's. omxcode's job is the client, plus one bridge: mount the web host inside an fh-saas app so a page's session knows its user and tenant, and give native apps HTTPS and OAuth so they can call that same fh-saas API. The landing, pricing and legal pages stay plain FastHTML (docs/probes.md: marketing sites are not where omxcode competes).

## Features

Hosts: Linux · web · Android · Mac · iPhone. ✅ run by a check · 🔨 built, never run · ❌ missing.

| Area | Feature | omxcode piece | Hosts | Status | Gap (size, ETA) |
|---|---|---|---|---|---|
| Shell & look | Laptop shell: top islands, collapsible sidebar, nav (`public/finxplorer/js/nav-more.js:1`) | mojoui.shell (AppBar, NavLink) · mojoui.sidebar · Overlay islands | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Shell & look | Phone shell: floating tab bar, touch-size targets (`public/finxplorer/css/pocket.css:1`) | Overlay(...).pin + shell.is_compact · NavBar | ✅ ✅ ❌ 🔨 🔨 | partial | No bottom-tab island component for the compact shell; Overlay never run on a phone (S, Nov 2026) **blocks** |
| Shell & look | omxqua Money · Ledger skin, light and dark (`public/finxplorer/css/pocket.css:1`) | themes/omxqua.mojo · themes/skins.mojo (Ledger) · App.appearance(dark) | ✅ ✅ ❌ 🔨 ❌ | have | — |
| Shell & look | Liquid motion: card grows into a focus view, drawers slide, press feedback (`public/finxplorer/js/focus.js:13`) | mojoui.spring (Canvas on_frame only) | ✅ ✅ 🔨 🔨 🔨 | partial | Springs drive canvas drawing only; native views have no slide/morph transitions (a Transition modifier the hosts animate) (M, Dec 2026) |
| Shell & look | Beacon while a bank sync runs (`public/finxplorer/js/beacon.js:6`) | mojoui.beacon | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Home | Bento: Safe to spend, Needs you, accounts, upcoming bills, where the month's money went (`public/finxplorer/js/home.js:111`) | mojoui.panel (stat tiles) · KpiView · mojoui.meter · mojoui.lists | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Home | Pace line chart and category donut (`public/finxplorer/js/home.js:456`) | ChartView (line/bars) · mojoui.charts | ✅ ✅ 🔨 🔨 🔨 | partial | No donut/pie mark (S, Nov 2026) **blocks** |
| Home | Phone gestures: drag a sheet down to close, swipe rows and view strips (`public/finxplorer/js/pocket-gestures.js:19`) | Canvas on_gesture PAN (canvas only) | ✅ ✅ 🔨 🔨 🔨 | partial | Swipe and drag only on a Canvas; no .on_swipe for native views, no bottom Sheet (M, Dec 2026) **blocks** |
| Transactions | Dense list (laptop) and lean rows (phone), search, category dropdown (`public/finxplorer/js/transactions.js:206`) | DataGrid · LazyList · mojoui.fields (search box) · mojoui.sqlite FTS5 · Dropdown | ✅ ✅ ❌ ❌ ❌ | have | — |
| Transactions | Detail drawer: edit, hide, deductible, returning, split, notes (`routes.py:2254`) | TextField, Toggle, Dropdown, Dialog · mojoui.sqlite | ✅ ✅ ❌ 🔨 🔨 | partial | No side drawer (laptop) / bottom sheet (phone) component; Dialog is the nearest (M, Nov 2026) **blocks** |
| Transactions | Drill-in: tap any chart part to open its transactions in a drawer (`public/finxplorer/js/drawer.js:26`) | ChartView hit/select + Drawer (missing) | ✅ ✅ 🔨 🔨 🔨 | partial | Needs the same Drawer component (M, Nov 2026) **blocks** |
| Transactions | Rules: auto-categorize, create, delete, apply to history (`routes.py:3566`) | Forms + mojoui.lists + mojoui.sqlite | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Spending | Live: Position, Rhythm (month calendar), Where it went (`public/finxplorer/js/rhythm.js:10`) | ChartView bars/lines/Heatmap · Sparkline · sheetpage month/weekday group-bys | ✅ ✅ 🔨 🔨 🔨 | partial | No calendar chart (days in a month grid, tap a day); Heatmap only approximates it (S, Nov 2026) **blocks** |
| Spending | Flow: category → merchant bands, dive in, play the months (`public/finxplorer/js/flow.js:538`) | — | ❌ ❌ ❌ ❌ ❌ | missing | A Flow (Sankey) chart in mojoui.charts with hit-test and Spring animation (M, Dec 2026) **blocks** |
| Spending | Cross-filter: category × merchant × time linked (`public/finxplorer/js/analytics-state.js:1`) | sheetpage compute() group-bys · ChartView selection · mojoui.links | ✅ ✅ 🔨 🔨 🔨 | partial | A generic CrossFilter: a selection on any chart filters the page's other charts (on the MX frame) (M, Dec 2026) **blocks** |
| Spending | Shift and Month by month: a period vs the prior one, category table (`public/finxplorer/js/months.js:2`) | PivotTable · MX frame group-bys (month/quarter) · ChartView | ✅ ✅ ❌ ❌ ❌ | have | — |
| Spending | Merchants, Subscriptions, Recurring lenses (`routes.py:3434`) | frame group-bys + mojoui.lists + Chip | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Spending | Shared filters, pills, themed dropdowns (`public/finxplorer/js/fx-select.js:1`) | Segmented · Dropdown · mojoui.fields filter chips · mojoui.header pill tabs | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Plan | Budgets with progress, insights, icon picker (`routes.py:2554`) | mojoui.meter · ProgressBar · Dropdown · Icon | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Plan | Goals and recurring obligations (`routes.py:3202`) | Forms + Meter + mojoui.sqlite | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Plan | Planning shelf: 13 calculators (rent vs buy, runway, debt, afford, mortgage, car, bonus, home value) with charts (`public/finxplorer/js/plan.js:1`) | TextField · Slider · Segmented · ChartView line/area/bars | ✅ ✅ 🔨 🔨 🔨 | have | — |
| Plan | Vacation trip tags + emailed trip report; tax evidence pack, year report, CSV (`trip_report.py:178`) | mojoui.csvio · FileSaver · mojoui.http (to the server that emails) | ✅ ✅ ❌ 🔨 ❌ | partial | Email stays server-side (fh-saas); the client needs HTTPS to reach it (M, Dec 2026) **blocks** |
| Reports | Personal (scrapbook) and Business (invoice) reports, same on screen and in print, up to 4 photos (`public/finxplorer/js/reports.js:474`) | mojoui.packpdf (Chromium prints HTML) · Picture · FilePicker | ✅ ✅ ❌ 🔨 🔨 | partial | No print/PDF of a view tree (browser print, GTK print, NSPrintOperation); packpdf is a separate HTML path (M, Dec 2026) **blocks** |
| Accounts & bank | Connect a bank with the Quiltt Connector (`quiltt/session.py:1`) | WebComponent (JS widget in a web view) | ✅ ✅ ❌ 🔨 ❌ | partial | Wrap a third-party JS SDK (Quiltt) with its HTTPS origin and popups; native Quiltt SDKs on phones (M, Dec 2026) **blocks** |
| Accounts & bank | Accounts, connections, refresh, status, net-worth history (`routes.py:3775`) | mojoui.lists · ChartView line · mojoui.http + Timers | ✅ ✅ ❌ 🔨 ❌ | partial | HTTPS in mojoui.http (TLS backend, needs Mojo ≥ 1.2 / flare) (M, Dec 2026) **blocks** |
| Accounts & bank | Bank sync jobs and Quiltt webhooks, job status (`quiltt/webhooks.py:18`) | fh-saas (server) · client: mojoui.http + Timers poll /api/fx/jobs/status | ✅ ✅ ❌ 🔨 ❌ | partial | Server side is fh-saas's job, not omxcode's; the client side needs HTTPS (M, Dec 2026) **blocks** |
| Sign-in & tenants | Google sign-in, sessions, logout (`routes.py:1196`) | — | ❌ ❌ ❌ ❌ ❌ | missing | Auth bridge: the web host mounted inside fh-saas (session → signed-in user); native OAuth (system browser + PKCE, token in the keychain) (L, Dec 2026) **blocks** |
| Sign-in & tenants | One SQLite per tenant, household members and invites (`routes.py:3646`) | — | ❌ ❌ ❌ ❌ ❌ | missing | Per-session tenant context in the web host (user → tenant DB path) and fh-saas as the data API for native clients (L, Dec 2026) **blocks** |
| Sign-in & tenants | Stripe pricing, checkout, billing portal, trial and payment banners (`routes.py:1075`) | fh-saas (server) · mojoui.feedback banners | ✅ ✅ ❌ 🔨 🔨 | partial | An open_url effect (system browser / new tab) to hand off to Stripe Checkout (S, this week) **blocks** |
| Notifications | Email: welcome, invites, budget and low-balance alerts, weekly summary (`email_service.py:88`) | fh-saas (server) · settings form in mojoui | ✅ ✅ ❌ 🔨 🔨 | partial | Stays in fh-saas by design; nothing for omxcode to add (S, this week) |
| Notifications | Install as an app (manifest, service worker), phone push (`public/finxplorer/service-worker.js:1`) | mojoui.notify (Linux only) | ✅ ❌ ❌ 🔨 ❌ | missing | PWA manifest + service worker from the web host; notify() on iOS/Android (M, 2027) |
| Onboarding | Welcome flow and a sample workspace you try without signing in (`public/routes.py:260`) | app state with sample data (mojoui.sample / contoso pattern) | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Onboarding | Sign-in page with an animated money scene (`public/finxplorer/js/login-scenes.js:1`) | Canvas on_frame + mojoui.draw | ✅ ✅ 🔨 🔨 🔨 | have | — |
| Onboarding | Landing, pricing, security, privacy, terms, about, contact pages (`public/routes.py:253`) | mojoui.markdown could render the legal pages | ✅ ✅ ❌ 🔨 🔨 | partial | Out of scope by design: these stay plain FastHTML (SEO, first paint) |
| Settings | One scrolling Settings page: notifications, household, billing link (`public/finxplorer/js/settings.js:1`) | Scroll · Toggle · mojoui.panel · mojoui.fields | ✅ ✅ ❌ 🔨 🔨 | have | — |
| Admin | Host console: tenants, logs, exports, SQLite downloads, amount diagnostics (`routes.py:1643`) | DataGrid · LogView · FileSaver · mojoui.http | ✅ ✅ ❌ ❌ ❌ | partial | Needs the auth bridge (admin role) and HTTPS; the screens themselves exist (M, Dec 2026) **blocks** |

## Where omxcode would be better

- **Every screen is an agent's tool set for free: 'what did I spend on dining in October', 'hide this transaction', 'make a trip report' through MCP, with no per-app work (finxplorer has no agent features).** Evidence: docs/agent.md; mojoui/hosts/agent.py; tests/test_agui.mojo, tests/test_genui.mojo.
- **Questions in words become SQL over the transactions (Ask → SQL), answered in place.** Evidence: mojoui/asksql.mojo, tests/test_asksql.mojo (omxplorer's tables, not finance data yet).
- **Local-first native app: the tenant's SQLite in process opens and searches faster than the web can.** Evidence: docs/probes.md Jot: cold open 6.6×, search p95 2.6× vs SQLite-wasm on OPFS (Linux; phones unproven).
- **GPU group-bys behind Shift, Month by month and cross-filter.** Evidence: unproven at this scale: omxplorer groups 1M rows on the GPU, but a household has ~10–50k transactions, which JS handles today; a win only for multi-year business books or the admin console across tenants.
- **Charts drawn by Mojo look and animate the same on every host (no ECharts plus hand-written SVG mix).** Evidence: mojoui/chartview.mojo, tests/test_chartmove.mojo (Linux/web ✅; phones 🔨).
- **The 13 calculators' maths and their screens in one language and one file each, instead of a pure-JS file plus a UI file.** Evidence: unproven (not ported).

The honest one: GPU speed isn't a reason to rebuild finxplorer. A household's transactions fit in JavaScript. The reasons are the agent tools, a local-first native app, and one language.

## Gaps, in order

| # | Gap | Generic piece | Size | ETA | Unblocks |
|---|---|---|---|---|---|
| 1 | Sign-in and tenants: the web host inside fh-saas, session → user → tenant DB; native OAuth with keychain | mojoui/hosts/web.py auth bridge + mojoui.auth | L | Dec 2026 | Google sign-in, sessions, logout; One SQLite per tenant, household members and invites; Host console; Stripe pricing, checkout, billing portal |
| 2 | HTTPS in mojoui.http, so native apps reach the finxplorer API | mojoui.http TLS transport (flare, Mojo ≥ 1.2) | M | Dec 2026 | Accounts, connections, refresh, status, net-worth history; Bank sync jobs and Quiltt webhooks, job status; Vacation trip tags + emailed trip report |
| 3 | Drawer / bottom Sheet and swipe on native views | mojoui.overlays Drawer + .on_swipe modifier | M | Nov 2026 | Detail drawer; Drill-in; Phone gestures |
| 4 | Finance charts: Flow (Sankey), donut, calendar, and a CrossFilter between charts | mojoui.charts Flow/Donut/Calendar + mojoui.crossfilter | M | Dec 2026 | Flow; Cross-filter; Live; Pace line chart and category donut |
| 5 | Phones for real: bottom-tab island, and DataGrid/Pivot/Overlay run on iOS and Android (today ❌ or never run) | mojoui.shell BottomTabs + uikit/android host coverage | L | 2027 | Phone shell; Dense list; Shift and Month by month |
| 6 | Print/PDF of a view, same on screen and paper | host print (browser print, GTK print, NSPrintOperation) | M | Dec 2026 | Personal and Business reports |
| 7 | Third-party JS SDK inside a WebComponent (Quiltt Connector) | mojoui.webcomponent: HTTPS origin, popups | M | Dec 2026 | Connect a bank |
| 8 | Transitions for native views (slide, morph from source) | Transition modifier animated by each host | M | Dec 2026 | Liquid motion |
| 9 | Open a URL in the system browser | open_url effect | S | this week | Stripe checkout hand-off |
| 10 | Installable web app and phone push | web host manifest + service worker; notify on phones | M | 2027 | Install as an app, phone push |

Good demo videos once closed: the Flow chart playing the months, charts filtering each other, the phone shell with its floating tab bar and sheets, and an agent driving finxplorer over MCP ("hide every Uber ride in October").

ETAs are estimates, not commitments; HTTPS depends on Mojo 1.2's TLS. Sizes: S ≤ 1 day, M ≤ 1 week, L > 1 week.
