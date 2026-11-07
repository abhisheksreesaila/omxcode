# Goal 60 report: the whole SaaS backend in Mojo (fh-saas out of the equation)

**Goal (owner, 2026-11-06):** email, background jobs, migrations, logging, invites you accept, many tenants per person,
billing parity and hardening as generic `mojoui` modules; then the owner's bar (D-6006): "speed, modular, best
implementation… not a compromise". So: M10, faster than fh-saas and measured, and M11, modular drop-in.

## Checker output (docs/goals/60-check.py, branch goal-60-backend)
Full run 1 (build/g60/full-1.txt) and the final-tree reruns after the review fixes (build/g60/full-2.txt):

| | result | |
|---|---|---|
| M0 | PASS | own env, Mojo 1.2; goal 57 M1, M3, M4 PASS, M2 fails only at the silent invite (replaced by M5, D-6004) |
| M1 | PASS (final tree) | JSON request lines with rids, no secrets in either log, audit sign_up/sign_in/invite/plan_change |
| M2 | PASS | 002 reached both tenants on restart; a broken 003 and an edited 002 each refused, files unchanged |
| M3 | PASS (final tree) | 20 × /api/me < 300 ms while Stripe and Google each sat 8 s; a job resumed after kill -9 |
| M4 | PASS | implicit TLS + AUTH, text + HTML, RFC 2047, 3rd-attempt delivery, dead with the 451, no header injection; **STARTTLS delivers** |
| M5 | PASS (final tree) | invite by email, no silent join, same-origin accept only, 403 for others, 410 used/expired, switching without leaks |
| M6 | PASS | trial, Stripe trial days, customer portal, cancel at period end, past_due after grace |
| M7 | PASS | 429 + Retry-After per IP, sliding sessions |
| M8 | PASS | parity rows ✅, the wizard asks for SMTP, GTK shot looked at, M1/M3/M5/M6 pass on the owner's Mac |
| M9 | **FAIL** | goal 57's M6–M8 and the lints pass (with D-6013), but `tests/test_accounts.mojo` (goal 57's) no longer compiles: it calls the old `Accounts` API (one tenant per person, `user_for` returning an id). Blocker: that test must be ported to the new API (`user_for` → (uid, tenant), `start_session(uid, tenant)`), which the budget didn't leave room for |
| M10 | PASS (final tree) | faster than fh-saas on p50, p99 and req/s for every flow at 64 clients (closest 7.1× the throughput) |
| M11 | PASS | saas_min: 50 lines on accounts + mail + jobs, billing not linked, sign-in + tenant + welcome email |

Reviews: reviewer NEEDS WORK → its must-fixes fixed (writer lock can't leak on a raise or a nested begin, rollbacks in
Queue.add and audit(), offload socket timeouts, test_handler asserts the offloaded reply, inert template values).
Security auditor NEEDS WORK (1 High, 3 Medium) → the High and two Mediums fixed (D-6014: offload only on HTTP/1, slots
handed back on TLS/HTTP/2; invites limited per admin; strict SMTP_TLS). **Neither was re-run on the fixed tree.**

## The benchmark (docs/goals/60-bench.md, the checker's own run; 24 CPUs)
64 clients: `me` 69,006 vs 9,736 req/s; `entries_get` 54,935 vs 1,118 (fh-saas 230 errors); `entries_post` 10,997 vs
10; `webhook` 5,286 vs 18; `callback` 728 vs 0 (fh-saas answered none of 64 concurrent callbacks: its host-DB
connection is shared across uvicorn's threadpool). p50 and p99 lower everywhere. omxcode had zero errors on every flow.
Honest caveats: the callback numbers swing run to run (p50 at 1 client 1–143 ms across runs on a loaded machine) and
entries_post/webhook p99 at 64 clients (35–75 ms) are writer-lock convoys on one file; both are next-step work.

## 30-second demo
```
scripts/saas.sh run                                   # server on :8000 (keys from scripts/saas_keys.sh)
scripts/build.sh saas linux && SAAS_SERVER=http://127.0.0.1:8000 build/saas/linux/saas
pixi run python scripts/saas_bench.py                 # omxcode vs fh-saas, writes docs/goals/60-bench.md
```
Sign in → "Plan: Trial · 14 days left" + Manage billing; invite someone from /api/invites → they get a link, see
"Join <tenant>, invited by <name>?", accept, and switch tenants.

## Three decisions worth a second look
1. **D-6008: the Flare offload patch** (vendor/patches/flare-0.13-offload.patch). Blocking requests leave the reactor on
   a thread of their own with `Connection: close`. It's the root-cause fix for slow providers, but it is a fork of
   Flare to send upstream, and each offload makes a thread and fresh SQLite connections (a fixed pool is next).
2. **D-6010: mojoui.jobs became the server queue, the UI's moved to mojoui.uijobs.** A mechanical rename across ~20
   files so a server doesn't link the UI hosts; merging other branches must grep for `mojoui.jobs`.
3. **D-6012: the fh-saas baseline.** uvicorn with 8 workers (stronger than the docs' single process) and fh-saas's own
   webhook route with one fix. fh-saas bugs found for its author: that route crashes on stripe-python's Event,
   `handle_webhook_request` never awaits `process_webhook`, the host DB connection is shared across threads.

## Next step
Port tests/test_accounts.mojo to the new Accounts API (M9), re-run the reviewer and auditor on the fixed tree, then
the auditor's open items: rate-limit table eviction under a flood, saas_min getting body caps and security headers
from the framework, subscription events that arrive before the checkout, and a fixed offload thread pool.
