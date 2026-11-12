# GOAL 66: everything a Finxplorer-class SaaS needs, on the server side

**End goal (owner, 2026-11-11):** "Set up to build Finxplorer.com, meaning all the ingredients should be there… don't
move [Finxplorer] ever… we just [want] a capability… to provide the framework… nothing to do with Finxplorer."
Finxplorer (a live personal-finance SaaS on FastHTML + fh-saas) is the yardstick only: never read its data, never
change it. Its inventory against omxcode is docs/research/finxplorer-ingredients.md. Goals 57 and 60 gave sign-in,
tenants, billing, mail, jobs, migrations and logs; this goal adds the generic server-side pieces still missing, each
a `mojoui` module with its own test, and ends with a small finance sample that uses all of them together. The UI
ingredients (a signed-in multi-user web host, Sankey/donut/calendar charts, a bottom sheet, the Money·Ledger family)
are goal 67 (docs/goals/67-draft.md).

Base: origin/main f0268d58. Worktree ../mojo-ui-g66, branch goal-66-saas-ingredients. Decisions D-66xx (D-65xx were
used by the omxconsole work after goal 64).

## Milestones
| # | Milestone | Proof (`docs/goals/66-check.py`; PASS, FAIL or BLOCKED each) |
|---|---|---|
| M0 | Static files | `mojoui.serve` serves a folder: content types, ETag + 304, a content-hashed URL cached a year, gzip when asked, Range for media; `..`, absolute paths, symlinks out of the folder and dotfiles refused (404); a test, and a served page loads its JS/CSS/font in headless Chromium |
| M1 | Webhooks from anyone | `mojoui.webhooks`: a receiver for signed third-party events (HMAC-SHA256 schemes: Stripe-style `t=,v1=`, a plain hex/base64 header, Svix/Standard Webhooks), a time window, an event log in host.db applied once (id unique), processing handed to `mojoui.jobs` with retries; bad signature 401, old 400, replay 200 without effect, a 1 MB cap; `mojoui.billing`'s Stripe path keeps passing goal 60 |
| M2 | Talking to other APIs | `mojoui.http` gains a JSON API client: bearer/basic auth, a token cache that refreshes before expiry, GraphQL over POST with cursor paging, retries with backoff on 429/5xx honouring Retry-After, a per-call timeout; proven against a local stand-in server (pagination over 3 pages, a 429 then success, an expired token refreshed once) |
| M3 | Schedules | `mojoui.schedule`: recurring jobs from a cron expression or "every Monday 08:00", per-tenant time zone (IANA, DST-safe: a 02:30 job on a spring-forward day runs once, an autumn 01:30 once), at most once per slot across restarts (a kill -9 mid-run neither loses nor doubles it), missed slots after downtime caught up once |
| M4 | Data in bulk | `mojoui.sqlite` gains bulk upsert (by a key, keeping the columns a user edited, in one transaction, 100k rows in < 2 s) and `Reply.csv` (streamed, RFC 4180 quoting, formula-injection guard on `=+-@`) |
| M5 | Public pages | crawlable server-rendered pages from `mojoui.serve`: templates with escaping, a sitemap.xml and robots.txt, a contact form (CSRF token, rate limit, honeypot, sent through `mojoui.mail`), a PWA manifest and service worker served with the right headers; a page's HTML has its text with JS off |
| M6 | The operator | a site-wide operator role (`SAAS_OPERATORS`, emails), and an operator API: tenants with plan and last activity, a tail of the JSON log with filters, a tenant's SQLite snapshot as a download (consistent: `VACUUM INTO`), audit rows for every operator action; nobody else reaches it (403), not even a tenant admin |
| M7 | Leaving fh-saas | `scripts/fhsaas_import.py` (or Mojo) moves an fh-saas host database (users, tenants, memberships, roles, subscriptions, trial ends, Stripe ids) into omxcode's host.db and copies tenant databases, dry-run first, idempotent; proven on a host database made by fh-saas itself (pixi env `fhsaas`), never a real one; a signed-in user keeps their tenant, role and plan |
| M8 | Shipping it | a Dockerfile and `scripts/saas_image.sh` build an image for a `mojoui.serve` SaaS server (one process, a volume for host.db and tenants, health check); the image runs locally and passes /health and a sign-in against the stand-ins; nothing deployed |
| M9 | A finance sample | `examples/finance_min`: sign-in, a stand-in bank aggregator (its API through M2, its webhooks through M1) synced by a job into the tenant's transactions with bulk upsert (M4), a spending-by-category query, a weekly digest email on a schedule (M3), a CSV export, a static JS front end (M0), a public landing page (M5); driven end to end in headless Chromium |
| M10 | Nothing regressed | goal 60's check (M0–M12), goal 57's (as before: M2/M8 at the replaced invite, M5 BLOCKED without keys), goal 64's (M5 BLOCKED without MAX) |

## Done means
66-check PASS for M0–M10 (BLOCKED only where named above); the reviewer and the security auditor pass M1, M5, M6
and M7; docs/saas.md gains each module's API and its known limits; `docs/goals/66-report.md`, EXPERIMENTS.md;
merged into main and pushed only after the owner's yes.

## Out of bounds
Finxplorer's repo, data, keys and services (read-only reference, and only its code); real Quiltt, Stripe, Google,
SMTP or Railway calls (stand-ins only); deploying; pip; the frozen ../mojo-ui-apple-test and other worktrees;
lowering a proof or deleting a test.

## Assumptions (taken instead of asking)
- Generic modules, no vendor names in `mojoui/` (no "quiltt"); the sample's aggregator is a made-up stand-in.
- Server side only; the UI ingredients are goal 67.
- Python stays allowed only where goals 57/60 allowed it (checks, stand-ins, the import script); the server is Mojo.

## Budget
120 turns.
