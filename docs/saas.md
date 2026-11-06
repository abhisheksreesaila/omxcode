# SaaS building blocks: fh-saas → mojoui (goal 57)

fh-saas (Python, FastHTML) is being phased out; its jobs move into Mojo modules on `mojoui.serve` (Flare). This page maps
each fh-saas module to the mojoui piece that does its job now, honestly: ✅ done and checked, 🟡 part of it, ❌ not yet.
Checked means `docs/goals/57-check.py` (against its Google and Stripe stand-ins) or a module test ran it on Linux.

The demo: `examples/saas/server.mojo` (the server, routes only) and `examples/saas/app.mojo` (a native GTK client).

| fh-saas module | What it did | mojoui piece | State |
|---|---|---|---|
| `utils_auth` | Google OAuth with CSRF state, sessions, provisioning, roles, logout | `mojoui.accounts`: `/login` (state + PKCE S256), `/auth/callback`, server-side sessions in sealed HttpOnly SameSite cookies, `/logout` ends them on the server, roles admin/member/viewer, invites; desktop apps through `mojoui.signin` (RFC 8252) | ✅ (M2, M4). 🟡: no sliding expiry (sessions last 7 days), no `require_role` decorator (apps call `member.can_write()` / `is_admin()`), Google only (no password sign-in) |
| `db_host` | Users, tenants, memberships, subscriptions, webhook events, audit log, jobs, pricing plans | `mojoui.accounts`' host.db: users, tenants (plan, Stripe customer, subscription), members, invites, sessions, OAuth states, desktop codes; `mojoui.billing`'s billing.db: applied events | 🟡: no audit log, no system jobs table, no pricing-plan table (one Pro price from the environment), one membership per user (D-5712) |
| `db_tenant` | One database per tenant, tenant users, permissions, settings | `Accounts.tenant_db(member)`: `tenants/<id>.db`, chosen from the session only (never a request's `?tenant=`) | ✅ the file per tenant and its isolation (M2); ❌ the tenant-side TenantUser / TenantPermission / TenantSettings tables |
| `utils_billing` | Billing config, access decisions, checkout return, trials, paywall hooks | `mojoui.billing`: `BillingConfig.from_env()`, `/billing/checkout`, `/billing/return` (reads the session back from Stripe), `paywall(member)` → 402 | ✅ checkout, return, paywall (M3; live in M5 with the owner's keys). ❌ trials, grace periods, yearly prices |
| `utils_stripe` | Stripe service: subscription and one-time checkout, portal, cancel, change plan | `mojoui.billing` over `mojoui.http` (HTTPS through Flare) | 🟡 subscription checkout only; ❌ one-time payments, the customer portal, cancel/change from the app |
| `utils_webhook` | Signature check, idempotency, event log | `mojoui.billing`: Stripe-Signature (HMAC-SHA256, constant time, 5-minute window), each event applied once, a paid session applied once whichever way it arrives (D-5715) | ✅ (M3, tests/test_billing.mojo). 🟡 Stripe's scheme only (no generic `X-Webhook-Signature` sources) |
| `utils_email` | Sending email (templates, providers) | none | ❌ |
| `utils_bgtsk` | Tenant background jobs with retries | `mojoui.jobs` runs work off the UI thread in apps; nothing server-side with retries and status rows | ❌ |
| `utils_migrate` | Schema migrations per tenant | `CREATE TABLE IF NOT EXISTS` at open | ❌ (no versioned migrations) |
| `utils_db`, `utils_sql` | Database helpers, SQL builders | `mojoui.sqlite` (prepared statements, transactions, FTS5) | 🟡 statements yes, no query builder |
| `utils_log` | Structured logging | `print` lines (`<event id> applied …`, no secrets) | ❌ |
| `utils_api`, `utils_graphql` | API helpers | `mojoui.serve`'s `Req.matches`, `Reply.json` | 🟡 REST routes yes, no GraphQL |
| `utils_seo`, `utils_blog` | Blog and SEO pages | none (the gallery is static) | ❌ |
| `utils_ai_interface`, `utils_ai_queue`, `utils_workflow`, `utils_polars_mapper` | AI calls, queues, workflows, dataframes | elsewhere in omxcode (`mojoui.agui`, the omxcore engine) | out of scope here |

## The pieces under it
- `mojoui.crypto`: HMAC-SHA256, the OS's random bytes (getentropy), base64url, a constant-time compare, seals (signed,
  expiring values), PKCE: plain Mojo on `mojoui.hash` so every host has it (D-5709).
- `mojoui.browser`: open a page in the system browser as an effect (`App.opens`), GTK and AppKit (D-5718).
- `mojoui.signin`: the desktop half of sign-in: a loopback listener (libc sockets) and the PKCE verifier (D-5720).

## Running it
```
scripts/saas_keys.sh                 # once: Google Desktop client + Stripe test key and Pro price → ~/.config/omxcode/saas.env
scripts/saas.sh run                  # the server on http://127.0.0.1:8000
scripts/build.sh saas linux && SAAS_SERVER=http://127.0.0.1:8000 build/saas/linux/saas
```
For Stripe webhooks on a public host: set `STRIPE_WEBHOOK_SECRET` (the endpoint's `whsec_…`) and point Stripe at
`<base>/billing/webhook`; locally, `/billing/return` reads the paid session back instead.
