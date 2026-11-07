# Goal 60 report: the whole SaaS backend in Mojo (fh-saas out of the equation)

**Goal (owner, 2026-11-06):** email, background jobs, migrations, logging, invites you accept, many tenants per person,
billing parity and hardening as generic `mojoui` modules; then the owner's bar (D-6006): "speed, modular, best
implementation… not a compromise". So: M10, faster than fh-saas and measured, and M11, modular drop-in.

## Checker output (docs/goals/60-check.py, branch goal-60-backend, round 3)
The final tree's full run: docs/goals/60/check.txt (every milestone in one `scripts/check`, the Mac's included).

| | result | |
|---|---|---|
| M0 | PASS | own env, Mojo 1.2; goal 57 M1, M3, M4 PASS, M2 fails only at the silent invite (replaced by M5, D-6004) |
| M1 | PASS | JSON request lines with rids, no secrets in either log, audit rows; test_log's new `secrets` (locked, capped) |
| M2 | PASS | 002 reached both tenants on restart; a broken 003 and an edited 002 refused; test_migrate's new `race` |
| M3 | PASS | 20 × /api/me < 300 ms while Stripe and Google each sat 8 s; a job resumed after kill -9 (rows found by user id, D-6022) |
| M4 | PASS | implicit TLS + AUTH, 3rd-attempt delivery, dead with the 451, no header injection, STARTTLS delivers; test_mail's new `deadline` |
| M5 | PASS | invite by email, no silent join, same-origin accept, 403 others, 410 used/expired, switching without leaks |
| M6 | PASS | trial, Stripe trial days, portal, cancel at period end, past_due after grace |
| M7 | PASS | 429 + Retry-After, sliding sessions; **new:** behind a trusted proxy a client per X-Forwarded-For, IPv6 per /64, an untrusted peer's header ignored, a bad proxy list refuses to start (D-6025) |
| M8 | PASS | parity rows, the wizard asks for SMTP, GTK shot looked at (ada on "Plan: Trial · 14 days left", Manage billing), M1/M3/M5/M6 pass on the owner's Mac |
| M9 | PASS | goal 57's M6–M8 (D-6013), test_crypto/accounts/billing/ui_thread/served and, new, test_handler, test_ratelimit, test_queue, test_clientip, test_pool under `ulimit -n 256`; libc and decision lints |
| M10 | PASS | faster on p50, p99 and req/s for every flow at 64 clients, on equal durability now (closest 3.8×) |
| M11 | PASS | saas_min: 62 lines on accounts + mail + jobs, billing not linked |

## Round 3: the round-2 reviews' findings, fixed at the root (D-6017 – D-6026)
- **Log secrets** (R1): no per-request `log.secret(access)`; `secret()` locked and capped at 64; "Basic " masked only as an
  Authorization value; invitation tokens masked in request lines.
- **Descriptors** (R2): the SQLite pool keeps a process-wide descriptor budget (SQLite's own accounting: kept .db
  descriptors counted), idle LRU connections closed across threads; 500 tenants × 8 threads pass under `ulimit -n 256`.
- **Clients behind proxies** (R3): `mojoui.clientip` + `serve(proxies=)` → `req.client`; SAAS_TRUSTED_PROXIES.
- **Tests in the checker** (R4–R6): test_handler asserts the offloaded reply in main; test_ratelimit's 90 % assertion
  found ties at the cut staying (fixed, and the cut is a quickselect now: slowest hit 5–15 ms); tests/test_queue.mojo.
- **Durability, said and equal** (R7, R8): "durable" = WAL + synchronous=NORMAL, survives a killed process, not a power
  cut; the fh-saas baseline now runs WAL + NORMAL too.
- **Lost emails** (R10, R11): sign-up and invite jobs written in the same transaction (an outbox); without SMTP the jobs
  wait pending instead of being marked done.
- **Security lows**: identity by (provider, sub) (S-L1); `__Host-` cookies and duplicate cookies refused (S-L2); early
  Stripe subscription events held and applied with their checkout (S-L3); SMTP connect/handshake deadlines (S-L4);
  offloaded CR/LF headers → 500 (S-L5); job retention, id-only payloads, masked invite paths (S-L6); expiry indexes, a
  tick sweep and a pending sign-in cap (S-L7); Flare limits 1 MB / 30 s for Handlers; Referrer-Policy on the callback
  and invites; migrate re-reads under the lock, SMTP 5xx dead at once.

## The benchmark (docs/goals/60-bench.md, the full run's own measurement; 24 CPUs)
Both sides on WAL + synchronous=NORMAL now (D-6026), so the write margins shrank to what's real. 64 clients, omxcode vs
fh-saas req/s: `me` 60,228 vs 11,103 (5.4×); `entries_get` 41,659 vs 1,338 (31×, fh-saas 295 errors); `entries_post`
12,220 vs 1,469 (8.3×; round 2 said 1,100× against fh-saas's fsyncs); `webhook` 5,884 vs 1,555 (3.8×); `callback` 935
vs none answered. Honest caveats: runs vary a lot on this loaded machine (fh-saas's `me` at 64 clients was 1,802 req/s
in an M10 run an hour earlier, 11,103 here); at **one** client the callback is no faster (p50 85 vs 81 ms, p99 492 vs
197 ms, 12 req/s each: the provider stand-in dominates, and M10's bar is 64 clients); entries_post and webhook p99 at
64 clients (48–62 ms) are writer-lock convoys on one file.

## 30-second demo
```
scripts/saas.sh run                                   # server on :8000 (keys from scripts/saas_keys.sh)
scripts/build.sh saas linux && SAAS_SERVER=http://127.0.0.1:8000 build/saas/linux/saas
pixi run python scripts/saas_bench.py                 # omxcode vs fh-saas, writes docs/goals/60-bench.md
```

## Three decisions worth a second look
1. **D-6008: the Flare offload patch** (vendor/patches/flare-0.13-offload.patch): a fork of Flare to send upstream;
   each offload makes a thread and fresh SQLite connections (a fixed pool is next).
2. **D-6018: the pool's descriptor model** mirrors SQLite's unix VFS (a closed connection's .db descriptor kept while
   others hold the file). If SQLite changes that, the count drifts; tests/test_pool.mojo compares it with /proc.
3. **D-6021: identity by sub** refuses a sign-in whose Google account differs from the one that first used an address:
   right against takeover, but a person who deletes and recreates a Google account with the same address is locked
   out until an admin clears `users.sub`.

## Next step
A fixed offload thread pool; synchronous=FULL as a per-file Pool option; the desktop sign-in confirm page; the
reviewer's and auditor's round-3 notes, if any.
