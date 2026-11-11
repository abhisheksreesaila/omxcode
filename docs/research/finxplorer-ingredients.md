# Finxplorer on omxcode: ingredient inventory

Date: 2026-11-11. Read-only research. Sources:
- Finxplorer: `/home/abhisheksreesaila/Projects/repo-finxplorer-2026` (HEAD aed1a8a, BL-003).
  `../finxplorer-stability` adds nothing new (its webhook hardening is merged into main). `../finxplorer-live-charts`
  holds one unmerged branch, `feature/live-analytics-chart-options` (chart options on the old analytics page). Later
  SQ/SL work replaced that page, so the branch adds no capability to rebuild.
- omxcode: `/home/abhisheksreesaila/Projects/mxapp/mojo-ui-m60` (f0268d58 = origin/main).

No secrets were read. Environment variables are named only. `appsettings.json` was opened only far enough to see its
type.

## 0. Bottom line

1. **The SaaS backend is mostly ready.** omxcode's SaaS modules (accounts, billing, mail, jobs, migrate, log, sqlite,
   serve) cover almost everything Finxplorer gets from fh-saas: Google sign-in, one SQLite file per tenant, invites,
   Stripe subscriptions with trial, portal and webhooks, SMTP, durable jobs, and JSON logs. Goal 60's checker passes
   M0 to M12, and goal 60's bench measured 4 to 25 times fh-saas's throughput. Not yet proven: anything against the
   real Google, Stripe or a real SMTP provider (goal 57 M5 is BLOCKED until the owner's keys exist).
2. **Most of the work is Finxplorer's own logic.** Quiltt (REST session, GraphQL sync, HMAC webhooks, connection
   lifecycle) has no omxcode counterpart. About 122 HTTP routes (`routes.py` 95, `public/routes.py` 16, plans 5, plan
   tags 3, tax 2, trip 1) and 17 tenant tables need porting.
3. **The front end is the big decision.** Finxplorer's UI is a client-side JavaScript SPA: `index.html` with about
   19.9k lines of plain JS (charts are hand-drawn SVG), talking to `/api/fx/*` JSON. omxcode's web host is a different
   model:
   - `mojoui/hosts/web.py` is **still Python FastHTML + HTMX**.
   - Every browser tab is a live Mojo app session held in server memory: 200 by default, 6 in public mode.
   - It is not wired to `mojoui.accounts`.
   - It isn't crawlable for SEO.

   There are two options:
   - **A.** Port only the backend to `mojoui.serve` and keep the JS/HTML front end almost unchanged. Smallest; the
     site can switch over endpoint by endpoint.
   - **B.** Rewrite the UI as a mojoui app on the web, GTK, Mac and iPhone hosts. Large: Sankey and donut charts and the
     Money·Ledger skin are missing, the web host would need sign-in and scaling work, and the native hosts are unproven
     on Mac and iPhone hardware.

---

## 1. What Finxplorer uses (grouped, one line each, with the proving file)

### Auth and accounts
- Google OAuth only, through fh-saas `utils_auth`: `/auth/google/start`, `/login`, `/auth/callback`, `/logout`.
  Signing in creates the tenant, starts the trial and sends a welcome email. No passkeys and no password. (`routes.py`
  1257–1403)
- Sessions use fh-saas middleware with a session cache (300 s TTL) and a list of skip paths. (`routes.py` ~1030–1050)
- A host-admin role comes from an env list of admin emails and promotes operator accounts. (`host_admin.py`
  `host_admin_emails`, `is_host_admin`, `ensure_host_admins_promoted`)
- Household: invite another person (Google `@gmail.com` addresses only) into the tenant; the invite is claimed at
  sign-in. (`routes.py` 3762–3889, `email_service.send_household_invite_email`)
- Consent capture: `/api/fx/consent` GET/POST and the `AppConsent` table, plus a `/welcome` onboarding page.
  (`routes.py` 1497, 1576–1600, `app_schema.py`)

### Tenancy and data
- fh-saas host database (`HostDatabase`, `HostAuditLog`, `PricingPlan`) and one SQLite file per tenant
  (`get_or_create_tenant_db`). Postgres was removed in DB-001; data lives on the Railway volume (`DATA_DIR`).
  (`runtime_env.py`, `main.py`, `services.py`, `docs/plan.md` DB-001)
- 17 tenant tables, created idempotently by `register_tables`: AppConnection, AppAccountBalanceSnapshot,
  AppTransaction, AppBudget, AppGoal, AppPlan, AppConsent, AppGoalProgress, AppRecurringObligation, AppCategory,
  AppConnectionEvent, AppConnectionMigration, AppNotification, AppDashboard, AppRule, AppReport, AppReportTransaction.
  There are also plan-report/tag tables and startup UPDATEs. Money is stored in integer cents. (`app_schema.py`,
  `db_compat.py`)
- A 627-row FinGoal category taxonomy is seeded from CSV. (`assets/data/FinGoalCategories.csv`, `app_schema.py` 646+)
- Repair and migration scripts. (`scripts/migrate_to_sqlite.py`, `repair_tenant_db_urls.py`,
  `refresh_fingoal_categories.py`, `refresh_transaction_amounts.py`)

### Bank data (Quiltt)
- Session: REST `auth.quiltt.io/v1` (profile by email, session token per profile), with a token cache to avoid 429s.
  Env: `QUILTT_APITOKEN`, `QUILTT_UNIFIEDCONNECTORID`. (`quiltt/api.py`, `quiltt/session.py`, `services.py`
  `get_or_create_quiltt_session`)
- Connect widget: `https://cdn.quiltt.io/v1/connector.js` plus `/assets/js/quiltt-launch.js` in the SPA, with
  `/api/quiltt/session`, `/connection-result` and `/connection-migrated`. (`public/finxplorer/index.html` 2389,
  `routes.py` 1899–1934)
- Sync: Quiltt GraphQL (`QUILTT_GRAPHQLENDPOINT`), paged transactions per account, account masks, connections and
  balances. Rows are mapped to cents and upserted in bulk with polars `map_and_upsert`. User-owned columns are carried
  forward across re-syncs (BUG-001), along with card-payment detection, auto-hide of transfers, rollback and an account
  id repair. (`quiltt/sync.py`, `quiltt/queries.py`, `quiltt/mappers.py`)
- Webhooks: `/api/webhooks/quiltt` and `/webhook/connections`, verified by HMAC-SHA256 (base64) over the version,
  timestamp and payload, with a 5-minute window. Each event is logged idempotently and claimed for processing, with
  stale-claim recovery. Handlers cover created, synced (successful and errored), repairable error (creates a
  notification), disconnected and connection migration. Workflows run through fh-saas `utils_workflow`.
  (`quiltt/webhooks.py`, `docs/WEBHOOK-OPERATIONS.md`)
- Jobs: manual refresh and webhooks submit a sync to fh-saas `BackgroundTaskManager`, which runs an in-process
  `asyncio.create_task` with retries. `/api/fx/jobs/status` and `/recent` report progress, and the SPA's beacon shows
  sync status. (`job_tasks.py`, `routes.py` 4134–4275, `js/beacon.js`)
- Connection management: list, delete (also disconnects at Quiltt), check status and refresh all. (`routes.py`
  3939–4206)

### Domain features (server side)
- Transactions: list, hide, tax-deductible flag, "returning" (UI-005), split and unsplit, update (category, memo,
  tags). (`routes.py` 2214–2668)
- Spending sentence query: the page's filter spec becomes SQL on the tenant DB, kept row-for-row equal to the browser
  engine (SQ-012). (`spending_query.py`, `/api/fx/spending/query`)
- Budgets: CRUD, budget transactions and budget insights. Goals: CRUD and progress. Recurring obligations, categories
  and category stats. (`routes.py` 2670–3650, 4324)
- Rules: CRUD and apply. The rules engine runs on sync. (`routes.py` 3651–3760, `services.apply_rules_for_user`)
- Settings, notification preferences, and in-app alerts from `AppNotification`. (`routes.py` 4411–4690)
- Reports: CRUD, report transactions, a hidden default report. Two kinds: a personal scrapbook (up to 4 photos stored
  as data URIs) and a business invoice. (`routes.py` 4693–5145, `docs/briefs/reports-two-kinds.md`)
- Plans (PL-001): saved plans CRUD. (`plans.py`)
- Vacation plan tags (PL-003): tags charges to a trip. (`plan_tags.py`)
- Trip report (PL-004): a report plus one email, sent once. (`trip_report.py`)
- Tax evidence pack (PL-006): a yearly report and a CSV download. (`tax_report.py`)
- Admin diagnostics: amount diagnostic, fix amounts, apply auto-hide. (`routes.py` 5147–5296)

### Domain features (client side, all plain JS, no framework)
- Home: Safe to spend, Needs you, month pace chart, accounts tile. (`js/home.js`, 1150 lines)
- Spending Live and Shift: Position, Rhythm (calendar), Where it went (flow), merchants, recurring, compare months.
  (`spend-sentence.js`, `flow.js`, `position.js`, `focus.js`, `analytics-*.js`)
- Sentence engine: typed words become a query; this is not AI. (`sentence.js`, `sentence-parts.js`, `sentence-bar.js`)
- Transactions: list grouped by day, detail sheet, bulk edit, search and filter. (`transactions.js`, 1712 lines,
  `drawer.js`, `fx-select.js`)
- Plan: goals, budgets, "Or just say it". Planning utilities: rent vs buy, runway, debt payoff, can I afford, mortgage
  and refinance, car lease vs buy, bonus, home value, vacation, tax. (`*-ui.js` pairs, about 4k lines)
- Reports page, report document, printing through the browser (`window.print`, `@media print`). (`reports.js`,
  `report-doc.js`, `css/reports.css`)
- Charts, all hand-drawn SVG with no chart library: bars, line, flow (Sankey-like), calendar, donut, sparkline/pace,
  table/list. (`sentence.js` kinds `'bars' 'line' 'flow' 'calendar' 'donut' 'table' 'list'`)
- Sample workspace (preview mode with sample data, no sign-in). (`public/preview_data.py`, `public/routes.py`
  `/preview*`, `js/preview-sandbox.js`)

### Billing (Stripe)
- fh-saas `register_billing_routes` and `attach_billing_auth_hooks`: `/pricing`, `/checkout/plan`,
  `/checkout/success`, `/billing-portal`, `/stripe/webhook`, `/settings/billing`, `/account-suspended`.
  (`routes.py` 1063–1250)
- $9.99 monthly or $99.99 yearly. A 14-day trial with no card, never two trials (BL-003). One subscription per
  household; a live subscription goes to the portal instead of a new checkout; the signup trial's end becomes Stripe's
  `trial_end` (BL-002). (`billing_checkout.py`, `plans.py` is unrelated, `seed_pricing_plans.py`)
- Webhook safety middleware keeps failed deliveries retryable, a retryable subscription store, a 3-day grace period, and
  the paywall is skipped in dev or when `ENFORCE_BILLING=false`. Trial and payment banners appear in the UI (PK-027).
  Stripe is pinned below 12. (`routes.py`, `requirements.txt`)

### Email
- fh-saas `utils_email` over SMTP (env-configured). Markdown templates: welcome, household invite, trip report, admin
  notification. (`email_service.py`, `templates/email/*.md`)
- Defined but never called: budget alert, unusual spending, weekly summary, low balance, monthly report.
  (`email_service.dispatch_*`)
- Draft brief: a weekly digest of saved sentences, sent by a scheduler that doesn't exist yet. It plans to run
  `sentence.js` under node on the server. (`docs/briefs/sentence-alerts.md`, Status: draft)

### Background jobs and schedules
- In-process asyncio jobs with retries, recorded in the tenant `tenant_jobs` table. (`job_tasks.py`)
- **No schedules or cron today** (the sentence-alerts brief says so explicitly).

### Admin and host tools
- `/admin` console page (`admin.html`, 574 lines): tenant overview with database probes, host health, per-tenant jobs,
  app log tail, filtered log export jobs, log download, and SQLite snapshot download for the host and each tenant.
  (`host_admin.py`, `routes.py` 1675–1850)
- Maintenance scripts. (`scripts/smoke_qa.py`, `wizard-keys-and-stripe.sh`, `tools/*` for landing extraction)

### AI / LLM
- **None in the product.** `openai` is a dependency in `pixi.toml` and `requirements.txt` but no code imports it. The
  sentence engine says "Not AI". `llms/` holds context files for development only (fh-matui, fh-saas, quiltt-apis docs).

### File export
- Tax-year CSV. (`tax_report.py` `/api/fx/reports/{id}/csv`)
- Reports print to PDF through the browser's print dialog; there is no server-side PDF.
- Admin SQLite and log downloads. (`host_admin.py`)

### UI shell and components
- Design: omxqua, Money·Ledger family. Top islands on a laptop, a floating tab bar on a phone, a collapsible sidebar,
  drawers and sheets, a focus view (a card grows into a page), themed dropdowns, segmented pills, a filter strip,
  bento cards, light and dark, spring press feedback. (`css/pocket.css`, `js/omxqua.js`, `nav-more.js`,
  `pocket-gestures.js`, `docs/briefs/omxqua-reskin.md`)
- Pages: landing, sign-in (with "scenes"), welcome/consent, Home, Spending (Live, Shift, Months), Transactions, Plan
  (and its utilities), Reports, Accounts/connections, Rules, Settings (profile, notifications, subscription, household,
  danger zone), pricing, account suspended, error, admin; public about, privacy, terms, security and contact (with a
  contact form).
- PWA: `manifest.json`, `service-worker.js`.

### Deployment and observability
- Railway QA and prod environments, one replica, a volume at `/app/data`. CI runs in Azure Pipelines (and GitHub
  Actions): tests, deploy to Railway QA plus smoke checks, a manual production promote. Old Azure Web App variables
  remain. (`azure-pipelines.yml`, `docs/QA-RAILWAY-DEPLOYMENT.md`, `.railwayignore`)
- Logging: `./logs/app.log` through fh-saas `configure_logging`, request-timing middleware, `/health`,
  `/api/host/health`, and a log tail in the admin console. No external APM.

---

## 2. Gap table

Legend: ✅ have (proving check) · 🟡 partial · ❌ missing. Gap: S (≤1 day) · M (a few days) · L (a week or more).

| Capability | Finxplorer uses (file) | omxcode status | Gap | Notes |
|---|---|---|---|---|
| Google OAuth sign-in | routes.py 1257–1403 | ✅ `mojoui.accounts` (57 M2/M4, 60 M5/M7: PKCE, sealed state cookie, sliding sessions, POST logout) | S | Real Google not yet proven: goal 57 M5 is BLOCKED on the owner's keys. Accounts key on Google `sub`; Finxplorer's users have none until they sign in again |
| Passkeys / password | not used | ❌ (not needed) | – | – |
| Sessions, roles | fh-saas middleware | ✅ admin/member/viewer, `acc.need()` | – | – |
| Host admin (operator) role | host_admin.py | 🟡 roles are per tenant; there is no site-wide operator flag | S | An env list of admin emails, as today |
| Household invites | routes.py 3762–3889 | ✅ invites with an accept page, single use, expiring, many tenants per person (60 M5) | S | Finxplorer's `@gmail.com`-only rule is an app check |
| Consent / onboarding | routes.py 1497–1600 | ❌ app-level | S | One table and a page |
| One SQLite per tenant | services.py, fh-saas db_tenant | ✅ `Accounts.tenant_db` (57 M2, 60 M2/M5); pool tested at 500 tenants (tests/test_pool.mojo) | – | – |
| Tenant schema (17 tables) | app_schema.py | ✅ engine `mojoui.migrate` (60 M2) | M | Write the `NNN_*.sql` migrations by hand from the dataclasses |
| Host DB and existing data | fh-saas host tables, sqldata/ | 🟡 omxcode host.db has a different schema (users/tenants/members/billing) | M | A one-time migration script is needed for users, tenants, memberships, subscriptions, trial ends and Stripe ids |
| SQL helpers / bulk upsert | fh-saas utils_sql, polars map_and_upsert | 🟡 `mojoui.sqlite` (prepared statements, transactions, Pool); no query builder or bulk upsert | S | Write the upsert with carry-forward of user columns (BUG-001) |
| HTTP client (outbound) | fh-saas AsyncAPIClient, httpx | ✅ `mojoui.http` over Flare (HTTPS; billing uses it for Stripe; tests/test_stream.mojo) | – | – |
| GraphQL client | fh-saas utils_graphql | ❌ out of scope in saas.md | S | Plain POST of JSON plus cursor paging over `mojoui.http` |
| Quiltt session tokens | quiltt/api.py, session.py | ❌ | S | REST calls and a token cache |
| Quiltt Connect widget | index.html 2389, assets/js/quiltt-launch.js | 🟡 web: custom elements through `mojoui.webcomponent` (docs/js.md); GTK/Mac through a web view; iPhone/Android: none | S (web) / M (native) | With option A it stays as-is. Native apps would need Quiltt's mobile SDKs or a web view |
| Quiltt sync (transactions, accounts, balances) | quiltt/sync.py, mappers.py, queries.py | ❌ | L | Core domain port: paging, cents, card-payment detection, auto-hide, carry-forward, rollback, account-id repair, rules on sync |
| Quiltt webhooks | quiltt/webhooks.py | 🟡 `mojoui.crypto` has HMAC-SHA256, base64, constant-time compare; Stripe's verify/idempotency pattern in `mojoui.billing` to copy; no generic webhook receiver | M | The event log, processing claims, migration events and notifications are app logic |
| Background jobs | job_tasks.py (fh-saas, in-memory asyncio) | ✅ `mojoui.jobs`: durable queue in host.db, backoff, dead, survives `kill -9` (60 M3, tests/test_queue.mojo) | S | Better than today. At least once, so sync must be idempotent (it already is) |
| Job status for the UI | /api/fx/jobs/* | ✅ `q.list_json(tenant)` / `/api/jobs` | S | – |
| Scheduler (weekly digest, recaps) | none yet (sentence-alerts draft) | 🟡 `serve` `tick()` every N ms plus jobs' `run_at`; no cron syntax or per-tenant time zones | S–M | Only needed for the not-yet-built digest |
| Email (SMTP, templates) | email_service.py, templates/email | ✅ `mojoui.mail`: SMTP implicit TLS and STARTTLS, markdown → text + HTML, injection-safe, `welcome()` and `invitation()`, sent as jobs (60 M4) | S | Port trip-report and admin-notification templates. Real provider not yet proven (keys) |
| Stripe checkout, portal, webhooks, trial, grace, paywall | routes.py 1063–1250 | ✅ `mojoui.billing` (57 M3, 60 M6) | S | Real Stripe not yet proven (keys) |
| Finxplorer billing rules (BL-002/BL-003) | billing_checkout.py | 🟡 own trial (`SAAS_TRIAL_DAYS`) and Stripe trial exist; "no second trial", "signup trial end → `trial_end`", "live subscription → portal" don't | S–M | Small changes inside `mojoui.billing` or the app |
| Pricing, suspended and billing settings pages | routes.py 1131–1250 | ❌ pages (the API exists) | S | – |
| Rules engine | services.apply_rules_for_user | ❌ | M | Pure logic, testable |
| Server-side spending query | spending_query.py | ✅ engine (`mojoui.sqlite`); ❌ port | M | Must stay row-for-row equal to `sentence.js` (SQ-012 tests). omxcode's own `mojoui.sentence` is the tappable-words UI (goal 28), not this engine |
| Transactions, budgets, goals, recurring, returns, reports, plans: CRUD API | routes.py, plans.py, plan_tags.py | ❌ (`serve` gives routing primitives only: `Req.matches`, `Reply.json`) | L | About 122 routes in total; mechanical but large |
| Trip report email | trip_report.py | ✅ mail and jobs, ❌ port | S | – |
| Tax CSV download | tax_report.py | 🟡 CSV writers exist (tablecard Export CSV); `Reply` can set headers | S | – |
| Report print / PDF | reports.js window.print | 🟡 `mojoui.packpdf` (HTML → PDF through Chromium) exists; option A keeps browser print | S (A) / M (B) | – |
| Static assets (JS, CSS, fonts, cache-busting, gzip) | routes.py 2153–2191 | 🟡 `serve` has `Reply.html`, `Reply.text` and `Reply.stream` but no static-file handler and no gzip | S | Needed for option A |
| Public marketing pages, SEO, contact form | public/routes.py, landing.html | ❌ (utils_seo/blog out of scope; the web host's HTMX session pages aren't crawlable) | S–M | Serve the existing static HTML from `serve` |
| Sample workspace (preview) | public/preview_data.py, preview-sandbox.js | ❌ | S–M | – |
| PWA manifest and service worker | public/finxplorer/manifest.json | ❌ in the web host; plain files in option A | S | – |
| Admin / ops console | host_admin.py, admin.html | 🟡 JSON logs, audit and `/api/jobs` exist; no tenant overview, log tail/export or SQLite snapshot download | M | Could be a GTK/desktop omxcode app over an admin API |
| Logging and observability | fh-saas utils_log, RequestTimingMiddleware | ✅ `mojoui.log`: JSON lines, request id, ms, secrets masked, rotation, audit (60 M1) | S | Add `/health` to the server (the web host has it) |
| Rate limits, proxy awareness | none | ✅ `ratelimit`, `clientip`, `SAAS_TRUSTED_PROXIES` | – | Set it to Railway's proxy, or all clients share one limit (saas.md) |
| TLS | Railway terminates it | 🟡 `serve` speaks cleartext only; terminate TLS in front | – | Railway already does this |
| Deploy (Railway, CI) | azure-pipelines.yml, QA-RAILWAY-DEPLOYMENT.md | 🟡 `Dockerfile.web` and `scripts/deploy-railway` exist for omxplorer's web host (goal 62); no image or deploy for a `serve.mojo` SaaS server | M | One process; scale up, not out |
| UI: omxqua look | css/pocket.css (Money·Ledger) | 🟡 `themes/omxqua.mojo` is the Developer "Graphite" family only | S | (option B only) |
| UI: shell (sidebar, top islands, phone tab bar) | nav-more.js, pocket.css | 🟡 Sidebar, header and NavBar ✅ on GTK and web; no floating tab bar; Android ❌; Mac and iPhone 🔨 (never run) | M | (option B only) |
| UI: lists, sheets, dropdowns, segmented, dialogs, toasts | transactions.js, drawer.js, fx-select.js | 🟡 LazyList, Dropdown, Segmented, Dialog, Toast, Overlay ✅ on GTK and web; no bottom-sheet/drawer component | M | (option B only) |
| UI: charts | sentence.js kinds: bars, line, flow, calendar, donut, sparkline | 🟡 Flint Bar, Line, Area, KPI, Bar Table, Heatmap, Sparkline, TimeSeries ✅ on GTK and web; no Sankey/flow, no donut; calendar only through Heatmap | L | (option B only) Sankey is the big one |
| UI: tappable sentence words | sentence-bar.js | ✅ `mojoui.sentence` (goal 28) | – | (option B only) A good fit |
| Planning calculators (9 tools) | `*.js` / `*-ui.js` | ❌ in Mojo | L | (option B only) Pure maths; port with their tests |
| Web host for signed-in users at scale | n/a | 🟡 `web.py` is FastHTML + HTMX (Python), one in-memory Mojo session per tab (200 by default, 6 public), sessions by URL id, not sign-in | L | (option B only) Blocks a public multi-user web app on the web host |
| Native apps (iPhone, Android, Mac) | none today (web + PWA) | 🟡 Android ✅ on the emulator; Mac and iPhone 🔨 build but never run on hardware | L | New scope, not parity |
| AI / LLM | none (openai unused) | ✅ `mojoui.agui` / AgentChat (goal 48) | – | An opportunity, not a gap |

---

## 3. Gaps that block a first useful vertical slice

Slice: **sign in → connect a bank through Quiltt → see this month's spending**, on Railway QA. The order assumes option
A (Mojo `serve` backend, existing JS front end).

1. **Keys and real-provider proof (owner).** Run `scripts/saas_keys.sh` and unblock goal 57 M5, so sign-in is proven
   against real Google. Quiltt sandbox keys too. Blocks everything that goes live.
2. **Server skeleton and static assets (S).** A `serve` Handler built from accounts, jobs and log, a static file
   handler (MIME, path safety, cache headers), `/health`, and serving `index.html`, `js/` and `css/`.
3. **Tenant migrations for the slice (S–M).** connections, accounts/balances, transactions, categories (plus the
   FinGoal seed) and rules as `migrations/tenant/NNN_*.sql`.
4. **Quiltt session and Connect (S).** `/api/quiltt/session`, `/api/quiltt/connection-result`, the token cache, and
   the existing connector JS.
5. **Quiltt sync as a `mojoui.jobs` Runner (L).** A GraphQL POST with paging, the mappers, an idempotent upsert that
   carries user columns forward, card-payment and transfer auto-hide, and rules on sync. This is the largest single
   piece; port `tests/test_sync_preserves_user_edits.py` first.
6. **Quiltt webhook (M).** HMAC verify, event log with idempotency and stale claims, then enqueue a sync. Needs a public
   URL (Railway QA) and the webhook secret in Quiltt's dashboard (owner).
7. **The read endpoints the Home and Spending pages call (M).** `/api/fx/transactions`, `/api/fx/context`,
   `/api/fx/accounts`, `/api/fx/connections`, `/api/fx/categories`, `/api/fx/spending/query`, `/api/fx/jobs/status`.
8. **Deploy (M).** A Dockerfile for the Mojo server (no Python needed with option A) and a Railway service with its
   volume. TLS ends at Railway; list the proxy in `SAAS_TRUSTED_PROXIES`.

Not needed for the first slice: billing (`ENFORCE_BILLING=false` equivalent: skip the paywall), reports, plans, the
admin console, marketing pages, household and email (beyond welcome).

With option B, add before step 7: wiring the web host to accounts, the per-session scaling decision, and a Money·Ledger
theme. That takes the first slice from roughly 2–3 weeks to 6 or more (rough estimate).

## 4. What needs the owner (keys, accounts, access)

- Google OAuth client (web client with the redirect URI on the new host) → `scripts/saas_keys.sh` (goal 57 M5 BLOCKED).
- Stripe: test key, Pro monthly and yearly price ids (`STRIPE_PRICE_PRO`, `STRIPE_PRICE_PRO_YEARLY`), and a new webhook
  endpoint and secret (`STRIPE_WEBHOOK_SECRET`) pointing at `/billing/webhook` (the path differs from `/stripe/webhook`).
- SMTP provider credentials (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_TLS`).
- Quiltt: a sandbox or second environment's API token, connector id, and webhook secret, plus the new webhook URL in
  the Quiltt dashboard (or a decision to share production's).
- Railway: a new service or environment for the Mojo build, a volume, and a domain. The Azure DevOps `RAILWAY_TOKEN`
  if CI deploys it.

## 5. Decisions only the owner can make

1. **Front end: A (keep the JS SPA, port only the backend) or B (rewrite the UI in mojoui).** A is "Subtract Before You
   Add": it reuses about 20k lines of proven UI and puts all the risk on the backend, where omxcode is strongest. B is
   a showcase for omxcode but needs Sankey/donut charts, the Money·Ledger skin, a bottom-sheet component, and a web
   host that handles sign-in and many sessions (today it is Python plus per-tab server state).
2. **Web only, or native apps too** (iPhone, Android, Mac)? Native means Quiltt's mobile SDKs or web views, and Mac and
   iPhone running on real hardware first.
3. **Keep the Python site live during the rebuild?** Recommended: yes. Build on a separate Railway service and QA
   domain, and move users only when the data migration is proven. Decide whether the two may ever share Quiltt and
   Stripe webhooks; sharing means double processing.
4. **Data migration from existing tenants.**
   - Do the tenant SQLite files move as they are? The tables are compatible if the migrations recreate the same
     schema; `mojoui.migrate` then needs an "already at version N" baseline.
   - Host database: fh-saas users, tenants, memberships and subscriptions need converting into omxcode's host.db.
   - Google `sub` is unknown for current users until their first sign-in; omxcode's rules cover this.
   - Stripe customer and subscription ids must carry over.
5. **Webhook and URL paths:** keep fh-saas's (`/stripe/webhook`, `/api/webhooks/quiltt`) or move to omxcode's
   (`/billing/webhook`)? Keeping them avoids reconfiguring Stripe and Quiltt during the cutover.
6. **Billing parity:** whether BL-002/BL-003 behaviour (no second trial, one subscription per household, the signup
   trial carried into Stripe) belongs in `mojoui.billing` (generic) or in the app.
7. **Scope cuts:** whether the unused `dispatch_*` alert emails, the admin "fix amounts" endpoints, and the `openai`
   dependency are dropped instead of ported. Recommended: drop them.
8. **Where the sentence engine lives on the server.** Today it is JS in the browser plus a Python SQL twin. Options: a
   Mojo twin, or run the JS. The digest brief already assumes node on the server.
9. **Admin console:** a web page as today, or an omxcode desktop app over an admin API (a natural omxcode showcase).

## 6. Risk notes
- Finxplorer is `Risk: high` territory (bank data, money, sign-in). omxcode's SaaS modules have had a security audit
  round (2026-11-11), but new Quiltt and webhook code needs its own security review.
- `serve` is one process with in-process locks; that matches Finxplorer's single replica today.
- Jobs are at least once: a crash can resend an email. The trip report already guards with a database row.
