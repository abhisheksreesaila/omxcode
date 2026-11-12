# Goal 66 report: the server-side ingredients of a Finxplorer-class SaaS

Worktree ../mojo-ui-g66, branch goal-66-saas-ingredients (base origin/main f0268d58). Stand-ins only: goal 60's
Google, Stripe and SMTP, plus a made-up bank aggregator in docs/goals/66-check.py. Not merged, not pushed.

## Milestones (`scripts/check`, 2026-11-11)
| # | Result | Commit | Proof |
|---|---|---|---|
| M0 Static files | PASS | c3d26c15 | mojoui.static: types, ETag 304, `app.<hash>.js` a year immutable (a wrong hash 404), gzip with Vary, Range 206/416, 11 escapes 404 (.., %2e%2e, dotfile, symlink out, absolute, NUL); Chromium loads JS, CSS, a woff2 font |
| M1 Webhooks | PASS | 6f25f9eb | mojoui.webhooks: Stripe-style, hex, base64, Standard Webhooks (its published vector); good 200 → one job; replay 200 no effect; bad/other-secret/changed body 401; ±10 min 400; retried once; > 1 MB 413 |
| M2 API client | PASS | 8d50ce58 | mojoui.apiclient: bearer, basic, client credentials (one token for 3 GraphQL pages, refreshed before expiry and once on a 401), 429 + Retry-After 1 s honoured, 503s backed off, a GraphQL error, a 300 ms timeout |
| M3 Schedules | PASS | 85346ec9 | mojoui.schedule: cron and words, 9 zone offsets equal Python's zoneinfo, New York's 02:30 spring and 01:30 autumn once each, every-30-minutes 8 times across the autumn change; a process on a fake clock: kill -9 mid-run finished after restart, no slot queued twice, 5 missed slots caught up once |
| M4 Bulk data | PASS | a9d3ed68 | bulk_upsert 100k rows in ~0.14 s, an edited category kept, a bad row rolls back the batch; Reply.csv streamed (chunked), Python's csv reads quotes, commas, newlines and the =+-@ guard |
| M5 Public pages | PASS | 9d589a8b | mojoui.pages: landing, sitemap, robots, manifest, sw.js with their headers; contact: forged / cookieless / cross-site 403, delivered by mojoui.mail, honeypot silent, burst 429; JS off reads the text; the service worker registers |
| M6 Operator | PASS | 84d45fa5 | mojoui.operator: tenants with plan and last activity, the log filtered by path and level, a VACUUM INTO snapshot (integrity ok); anonymous 401, tenant admins 403; audit rows |
| M7 Leaving fh-saas | PASS | bb1a11ca (+ d5d8329d, 20b5936f) | an fh-saas 0.9.14 host db made by fh-saas; dry run writes nothing; twice = same host.db; a re-run keeps a removed membership removed; 4 people sign in to their tenant, role and plan; an address bound to another Google sign-in left out (403) |
| M8 The image | BLOCKED | a5bf1135 | Docker's socket refuses this user. The image's folder (what the Dockerfile copies) runs with no pixi library: /health 200, `server --health` exits 0, a sign-in |
| M9 Finance sample | PASS | c68e2a2d (code in 9d589a8b, d5d8329d) | Chromium: landing → Sign in → /app; bank link by one-time token; a signed webhook → job → API client (429, 3 pages, token refresh) → bulk upsert keeping the edit; spending; CSV download; a digest email on a schedule |
| M10 Nothing regressed | PASS | (rerun after a parser fix) | goal 60 M1–M12 PASS; goal 57 M1, M3, M4 PASS, M2 and M8 FAIL only at the replaced invite, M5 BLOCKED (no keys); goal 64 M0–M4 PASS, M5 BLOCKED (no MAX) |

Reviews: code reviewer FAIL → PASS (round 2), security auditor FAIL → PASS (round 2), on M1, M5, M6, M7 and the sample
(D-6630–D-6633).

## The 30-second demo (examples/finance_min)
```
scripts/mojo_flare.sh build examples/finance_min/server.mojo -o build/finance_min/server
pixi run python docs/goals/66-check.py M9      # starts Google, SMTP and the bank stand-ins, drives it in headless Chromium
```
By hand: run `build/finance_min/server` with goal 60's env (docs/saas.md) plus BANK_* and SAAS_CONTACT_TO, open
http://127.0.0.1:8000/ (the landing page, readable with JS off), Sign in, /app shows spending by category and an
Export CSV button; the bank's webhook at /webhooks/bank fills it; a digest email goes out every Monday 08:00
(FIN_DIGEST, SAAS_TIMEZONE).

## Three decisions worth a second look
1. **D-6613/D-6615: schedules are at most once queued, at least once run.** A slot can't be queued twice, but a run
   killed mid-way runs again; runners must be idempotent by `slot` (the digest records digests_sent after sending, so
   a crash between send and record can send twice).
2. **D-6631: bank linking by one-time token.** The security audit showed any tenant could claim a connection id; the
   sample now trades the aggregator's link token server to server. A real aggregator's link screen (goal 67's UI) has
   to supply that token.
3. **D-6629: M8 BLOCKED rather than proven.** The image was never built or run in Docker here. The bundle runs without
   pixi on this host, but glibc/libstdc++ inside debian:trixie-slim is untested.

## What's left
- M8: `sudo usermod -aG docker $USER`, log in again, `scripts/check M8`.
- Review NITs left open: operator 500s aren't logged; a hand-built `Source` could still name an unsigned id header.
- Limits in docs/saas.md: static files read per request, snapshots in memory (512 MB cap), API client token cache per
  client, the contact limit per process.
- Merge to main and push only after the owner's yes.
