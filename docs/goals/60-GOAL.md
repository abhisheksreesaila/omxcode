# GOAL 60: the whole SaaS backend in Mojo (fh-saas out of the equation)

**End goal (owner, 2026-11-06):** "can you do email, background jobs, database [migrations], logging… why can't you go and
do it… remove fh-saas out of the equation… a Mojo backend is the easiest thing you can have… just punch through."
Goal 57 built sign-in, sessions, tenants and Stripe as `mojoui` modules; its `docs/saas.md` left email, jobs, migrations,
logging, the audit log, multiple tenants per person, the customer portal, trials and rate limits ❌ or 🟡, and the
security auditor left one Medium (invites join without asking). Close them, framework first: each a generic `mojoui`
module with its own test; `examples/saas` only composes. Real Google, Stripe and SMTP keys come later from the owner.

Base: goal-57-saas 14392f0 (on merge-50-52). Worktree ../mojo-ui-g60, branch goal-60-backend, its own .pixi. 58 and 59
are other sessions' goals. Decisions D-6001 on.

## Milestones
| # | Milestone | Proof (`docs/goals/60-check.py`; stand-ins for Google, Stripe and SMTP live in the checker; truth is the SQLite files, the log file and what the stand-ins received) |
|---|---|---|
| M0 | Its own env, goal 57 still green | `.pixi` a directory; Mojo 1.2; goal 57's checker M1–M4 pass on this tree, except M2's silent-invite step, which M5 replaces on purpose (it must fail only there, at "the invited viewer") |
| M1 | `mojoui.log` + the audit log | tests/test_log.mojo `json: ok`, `redact: ok`, `rotate: ok`. The server writes JSON lines to `$SAAS_LOG`: one per request (ts, level, rid, method, path without the query, status, ms) and the reply's `X-Request-Id` is that rid; after a sign-in, an entry, an invite, a checkout and a webhook, no line holds the cookie, an access token, a code, a state, the client secret, the Stripe key or the SMTP password; host.db's `audit` has sign_in, invite, invite_accept and plan_change rows with tenant and actor |
| M2 | `mojoui.migrate` | tests/test_migrate.mojo `apply`, `idempotent`, `broken`, `checksum`, `down`. The server applies `$SAAS_MIGRATIONS/tenant/NNN_name.sql` (`-- up` / `-- down`) to every tenant's SQLite at start and to new tenants: two tenants made under 001, the server stopped, 002 (a new column) added, restarted: both files have the column and `schema_migrations` lists 1 and 2 with checksums; a broken 003 → the server refuses to start and both files stay at 2, unchanged; an applied file edited → refuses to start |
| M3 | `mojoui.jobs` on the server, slow providers off the lock | a durable queue in host.db (status, attempts, run_at, error), workers off `mojoui.serve`'s lock, retries with backoff, `dead` after max attempts, pending jobs resume after a `kill -9` and restart. While Stripe's stand-in takes 8 s to answer a checkout and Google's 8 s to answer a token, 20 `/api/me` calls from another person each answer in < 300 ms. `GET /api/jobs` (admin) lists the tenant's jobs |
| M4 | `mojoui.mail` | tests/test_mail.mojo `dotstuff`, `header_inject`, `encode`, `multipart`. SMTP with AUTH, markdown templates → text + HTML parts, UTF-8 subjects encoded; sent as jobs. Against the checker's SMTP stand-in: a welcome email on first sign-in; implicit TLS (`SMTP_TLS=implicit`, the checker's own CA in `SMTP_CA_FILE`) delivers; STARTTLS reported (PASS or ❌ in docs/saas.md, honest); the stand-in refusing twice (4xx) → delivered on the 3rd attempt, `attempts` 3; refusing always → `dead` with the reason; a name with CR/LF adds no header |
| M5 | Invites you accept, many tenants per person | an admin's invite emails a link (sealed, expiring, single use); the invited person signing in is **not** joined; the link signed in as the invited address shows "Join <tenant>, invited by <name>?" and only a same-origin POST accept joins them, with the invited role; another person on the link → 403; the link again → 410; an expired one → 410. A person in two tenants lists both (`GET /api/tenants`) and switches (`POST /api/switch`); rows follow the switch, never leak |
| M6 | Billing parity | `/billing/portal` creates a Stripe customer-portal session (stand-in checks the form) and answers its URL; `SAAS_TRIAL_DAYS` gives a new tenant a trial (`/api/pro` 200) that expires (→ 402); `STRIPE_TRIAL_DAYS` puts `subscription_data[trial_period_days]` on checkout; `customer.subscription.updated` with `cancel_at_period_end` keeps Pro and shows when it ends; status `past_due` → 402 after `SAAS_GRACE_DAYS` |
| M7 | Hardening | per-IP limits on `/login`, `/auth/callback`, `/api/token`: over `SAAS_RATE` a minute → 429 with `Retry-After`; sliding sessions: idle past `SAAS_SESSION_IDLE` → 401, use extends it; the security auditor's goal-57 notes in docs/saas.md "Known limits" closed or still listed, honestly |
| M8 | Parity, demo, keys, the Mac | docs/saas.md: every fh-saas row ✅ except blog/SEO, GraphQL and AI (out of scope, said so); `scripts/saas_keys.sh` also asks for SMTP; the native demo shows the trial, the portal button and an invite accepted (GTK shot, looked at); on the owner's Mac (~/omxcode-g60 only) the server builds and M1, M3, M5 and M6 pass against it |
| M9 | Nothing regressed | goal 57's M6–M8 and tests/test_crypto, test_accounts, test_billing, test_ui_thread, test_served pass; libc and decision lints |
| M10 | Faster than fh-saas, measured (owner, D-6006) | scripts/saas_bench.py runs the same flows against build/saas/server and a baseline app on fh-saas itself, used as its docs say (bench/fhsaas/, its own pixi feature and env `fhsaas`, so the Mojo server stays Python-free), same data, same machine: a signed-in GET /api/me, GET and POST /api/entries on the tenant's SQLite, a signed Stripe webhook's verify, and the sign-in callback against the same OAuth stand-in. p50, p99 and requests/s at 1 and 64 concurrent clients, peak RSS and cold start for both, in docs/goals/60-bench.md as measured. Pass: omxcode faster on p50, p99 and throughput for every flow at 64 concurrent, from a run the checker does itself. Generic framework techniques only (no global lock, per-thread connections, prepared statements), never special-casing the bench |
| M11 | Modular: drop in (owner, D-6006) | examples/saas_min uses only mojoui.accounts + mojoui.mail + mojoui.jobs (no billing): Google sign-in, tenants and a welcome email in ≤ 80 lines of app code, built and checked against the stand-ins; each module's public API in docs/saas.md with a snippet; no module imports one it doesn't need (the checker reads the imports: billing isn't linked into saas_min) |
| M12 | Hardening (2026-11-11, after the goal: docs/saas.md's known limits) | desktop sign-in confirm page: no code on a GET, only a same-origin POST releases it (D-6029); the pending sign-in a sealed cookie: a /48 flood writes no row and locks nobody out, bound to the browser, single use (D-6031); blocking requests on a fixed offload pool, 503 + Retry-After past it, no thread per request (D-6033) |

## Done means
60-check PASS for M0–M11; the reviewer and the security auditor pass it; M8's shot looked at; `docs/report.md`.

## Out of bounds
Pushing; deploying; merging into main or goal-57-saas; real keys (the owner gives them later); reading or printing
secrets; sign-ups or paid services; the frozen ../mojo-ui-apple-test and other sessions' worktrees (g50–g59); other
folders on the owner's Mac; pip; another worktree's .pixi; lowering a proof; Python in the server; new looks; the GPU.

## Assumptions (taken instead of asking)
- No new product name: the pieces are `mojoui.*` modules, "omxcode SaaS" in docs; a brand ("omxsaas"?) is the owner's call.
- SMTP, as fh-saas does (any provider speaks it); an HTTP mail API is a later adapter.
- Jobs are at-least-once (an email may go twice after a crash, never zero times); said so in docs/saas.md.
- Migrations are forward-first; `down` exists and is tested, but the server never runs it on its own.

## Budget
150 turns.
