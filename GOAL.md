# GOAL 57: SaaS building blocks in omxcode, Mojo only

**End goal (owner, 2026-11-06):** "SaaS building blocks (sign-in, accounts, payments)" from the roadmap, as omxcode
components. "fh-saas is phased out and this becomes Mojo only… enabling Google for real… Stripe yes… CPU mode, which is
more common: you will match CPU, that's ok, this is more of a feature-parity request than a perf request; you are
contributing to the omxcode app framework, that's the point." Plus a tiny, focused demo for the gallery.

So: fh-saas's jobs (Google sign-in, sessions, users / tenants / roles, one SQLite per tenant, Stripe checkout, webhooks,
paywall) become `mojoui` modules on `mojoui.serve` (Flare), each with its own test; a tiny native app signs in and pays
through them. No Python in the server.

Base: branch merge-50-52 d010952 (goals 50 + 52: Mojo 1.2, `mojoui.serve`, HTTPS in `mojoui.http`, `mojoui.hash`; not on
main yet). Worktree ../mojo-ui-g57, branch goal-57-saas, its own .pixi. Decisions D-5701 on.

## Milestones
| # | Milestone | Proof (`docs/goals/57-check.py`; Google and Stripe stand-ins live in the checker; truth is the SQLite files) |
|---|---|---|
| M0 | Its own env | `.pixi` is a directory here; `mojo --version` 1.2; tests/test_serve, test_https and test_hash pass on this tree |
| M1 | `mojoui.crypto` | tests/test_crypto.mojo: `hmac: ok` (RFC 4231 vectors), `random: ok` (getrandom tokens, never repeat), `base64url: ok` (RFC 4648 vectors, round trip), `compare: ok` (constant time), `seal: ok` (a signed, expiring value: tampered, wrong key or expired → refused) |
| M2 | `mojoui.accounts`: Google sign-in, sessions, tenants, roles | `build/saas/server` (examples/saas/server.mojo, nothing but mojoui) against the checker's OAuth stand-in: `/login` redirects with state + PKCE S256; a wrong state is refused; the callback makes the user, their tenant and its SQLite (`tenants/<id>.db`), and sets a sealed cookie; `/api/*` without it → 401, with a tampered one → 401; ada never sees ben's rows (`?tenant=`, a forged id: nothing); `/logout` ends the session server-side (the old cookie → 401); an admin's invite lets a second person join as viewer, and a viewer's write → 403 |
| M3 | `mojoui.billing`: Stripe | against the checker's Stripe stand-in: `/billing/checkout` creates a subscription Checkout Session (form fields as Stripe's API takes them, the tenant as `client_reference_id`) and answers its URL; `/billing/webhook` checks `Stripe-Signature` (signed by the checker's own HMAC): a bad signature → 400, a 6-minute-old one → 400, the same event twice → applied once; `checkout.session.completed` makes ada Pro, ben stays free; a Pro-only route → 402 for ben; `customer.subscription.deleted` → free again |
| M4 | The demo app, signed in and paying | examples/saas (GTK, headless, `MOJOUI_TEST`), a native client of the M2 server: "Sign in with Google" opens the system browser (`open_url`; the checker reads `$MOJOUI_OPENER` and plays the browser), the app gets its session through a loopback redirect (RFC 8252, PKCE); it shows `Signed in as ada@example.com`; an entry added in the app lands in ada's SQLite on the server; "Upgrade" opens checkout, the webhook arrives, the app shows `Pro`. `open_url` is a generic effect with its own test |
| M5 | Live keys (owner-keyed) | with `~/.config/omxcode/saas.env` (names only: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, STRIPE_SECRET_KEY, STRIPE_PRICE_PRO; never printed): Google's real authorize URL from `/login` answers a consent page, not an error; Google's token endpoint answers `invalid_grant` (not `invalid_client`) to a made-up code; a real test-mode Checkout Session (`cs_test_…`) made by the server over Mojo HTTPS, paid with 4242 in headless Chromium, and `/billing/return` reading it back from Stripe makes the tenant Pro. No file → `BLOCKED` naming `scripts/saas_keys.sh` (a wizard for the owner) |
| M6 | Parity and the gallery | docs/saas.md: fh-saas's modules → the mojoui piece, ✅/❌, honest (email, jobs, migrations may be ❌); docs/components.md lists the new modules (`scripts/components.py` not stale); a gallery card with a shot of ada (Pro) and ben (free) side by side, looked at; `scripts/package.sh saas linux` makes the Linux download |
| M7 | Nothing regressed | tests/test_ui_thread.mojo and test_served.mojo pass here; scripts/libc_lint.py and scripts/decisions_lint.py pass |

## Done means
57-check PASS for M0–M4, M6, M7, and M5 PASS or BLOCKED only for the owner's keys; the reviewer and the security
auditor (sign-in, sessions, tenants, payments, webhooks) pass it; M4's and M6's shots looked at. `docs/report.md`.

## Out of bounds
Pushing; deploying; real keys anywhere but the env file the owner writes; reading or printing secrets; sign-ups or paid
services; merging into main (merge-50-52 isn't there yet); the frozen ../mojo-ui-apple-test and other sessions'
worktrees; pip; another worktree's .pixi; lowering a proof; Python in the server (fixtures and the checker are fine);
new looks (Liquid light/dark as it is); the GPU (CPU only; owner: a parity goal, not a speed one).

## Assumptions (taken instead of asking)
- The client is native (gallery = downloads), the server is a Mojo program; the web host's own sign-in comes later.
- Desktop sign-in is RFC 8252: the system browser plus a loopback redirect to the app, PKCE; tokens are sealed values.
- Stripe: webhooks in the stand-in; for the live run, reading the session back on return (no tunnel to localhost).
- Email, background jobs and migrations are listed in docs/saas.md, built only if time is left.
- The Mac run (scripts/mac-ci) is next, not this goal.

## Budget
120 turns (owner's spare credit this week; more than autopilot's default 80, the scope is wider).
