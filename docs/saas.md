# omxcode SaaS: fh-saas's jobs as mojoui modules (goals 57, 60)

fh-saas (Python, FastHTML) is being phased out; its jobs are Mojo modules now, on `mojoui.serve` (Flare). This page maps
each fh-saas module to the mojoui piece that does its job, honestly: ✅ done and checked, 🟡 part of it, ❌ not yet.
Checked means `docs/goals/57-check.py` / `docs/goals/60-check.py` (against their Google, Stripe and SMTP stand-ins) or a
module test ran it, on Linux and on the owner's Mac. Against the real Google, Stripe and an SMTP provider it is proved
only once the owner's keys exist (`scripts/saas_keys.sh`; goal 57's M5 is BLOCKED until then): `email_verified`, the
redirect URI, Stripe's portal and a real mailbox are checked against the stand-ins, not yet against the real services.

The demo: `examples/saas/server.mojo` (routes and wiring only), `examples/saas/app.mojo` (a native GTK/AppKit client),
and `examples/saas_min/server.mojo` (sign-in, tenants and a welcome email from accounts + mail + jobs alone, no billing).

| fh-saas module | What it did | mojoui piece | State |
|---|---|---|---|
| `utils_auth` | Google OAuth with CSRF state, sessions, provisioning, roles, logout | `mojoui.accounts`: `/login` (state in a sealed cookie, bound to the browser, single use, no row + PKCE S256), `/auth/callback`, a desktop sign-in confirmed on a same-origin page before its code goes to the app (D-6029), server-side sessions in sealed HttpOnly SameSite cookies that slide (idle `SAAS_SESSION_IDLE`, 30 days at most), `POST /logout` ends them on the server (a GET only shows the button, D-6034), roles admin/member/viewer (`acc.need(req, "member")` in place of `@require_role`), desktop apps through `mojoui.signin` (RFC 8252), per-client limits on the sign-in routes (behind `SAAS_TRUSTED_PROXIES`, IPv6 by /64), people identified by Google's `sub` (a reassigned address can't take over an account), `__Host-` cookies on https | ✅ (57 M2, M4; 60 M5, M7). Google only, as fh-saas |
| `db_host` | Users, tenants, memberships, subscriptions, webhook events, audit log, jobs, pricing plans | host.db: `mojoui.accounts`' users, tenants, members (many tenants per person), invites, sessions, used sign-in states, desktop confirms and codes, audit; `mojoui.billing`'s billing and stripe_events; `mojoui.jobs`' jobs; each module's tables versioned by `mojoui.migrate` (accounts_migrations, billing_migrations) | ✅ (60 M1, M3, M5, M6). Pricing plans are configuration (`STRIPE_PRICE_PRO`, `STRIPE_PRICE_PRO_YEARLY`, `STRIPE_PRICES_ONCE`), not a table |
| `db_tenant` | One database per tenant, tenant users, permissions, settings | `Accounts.tenant_db(member)`: `tenants/<id>.db`, chosen from the session only (never a request's `?tenant=`), this thread's own connection, migrated by `mojoui.migrate` | ✅ the file per tenant, its isolation and its schema (57 M2, 60 M2, M5). Who is in a tenant and with which role lives in host.db's `members` (one source of truth) rather than fh-saas's per-tenant TenantUser/TenantPermission copies; a tenant's settings are the app's own table in its migrations |
| `utils_billing` | Billing config, access decisions, checkout return, trials, paywall hooks | `mojoui.billing`: `BillingConfig.from_env()`, `/billing/checkout` (monthly, or `{"interval": "year"}`), `/billing/return` (reads the session back), `bill.paywall(member)` → 402, our own trial for new tenants (`SAAS_TRIAL_DAYS`), past_due with a grace period (`SAAS_GRACE_DAYS`), `/api/me`'s plan, status, trial_ends, cancels_at | ✅ (57 M3; 60 M6) |
| `utils_stripe` | Stripe service: subscription and one-time checkout, portal, cancel, change plan | `mojoui.billing` over `mojoui.http` (HTTPS through Flare): subscription checkout with Stripe's trial (`STRIPE_TRIAL_DAYS`), one-time checkout (`POST /billing/purchase {price}` for a price in `STRIPE_PRICES_ONCE`, recorded in `payments`), the customer portal (`POST /billing/portal`: cards, invoices, cancel, change plan, as Stripe's portal is set up), cancel at period end | ✅ subscription checkout, Stripe's trial, the portal, cancel at period end (60 M6). The one-time checkout is built and type-checked but no proof runs it against a stand-in yet |
| `utils_webhook` | Signature check, idempotency, event log | `mojoui.billing`: Stripe-Signature (HMAC-SHA256, constant time, 5-minute window), each event applied once (stripe_events), older events never undo newer (by `created`), a paid session applied once whichever way it arrives (D-5715); `mojoui.crypto.hmac_hex_ok` for other sources' `X-Webhook-Signature`-style HMACs | ✅ (57 M3, tests/test_billing.mojo) |
| `utils_email` | Sending email (templates, providers) | `mojoui.mail`: SMTP with AUTH PLAIN over implicit TLS (`SMTP_TLS=implicit`) or STARTTLS (`SMTP_TLS=starttls`, refuses to go on in the clear if the server doesn't offer it), markdown templates → text + HTML parts, RFC 2047 subjects and names, dot-stuffing, no header injection, `welcome()` and `invitation()`; sent as jobs | ✅ (60 M4: implicit TLS delivers; **STARTTLS delivers** against the stand-in, with its own CA; tests/test_mail.mojo) |
| `utils_bgtsk` | Tenant background jobs with retries | `mojoui.jobs`: a durable queue in host.db (status, attempts, run_at, error), worker threads off every request, exponential backoff, `dead` after max attempts, resumed after a crash, `/api/jobs` per tenant | ✅ (60 M3, M4, tests/test_queue.mojo). **At least once**: a job running when the process dies runs again on restart, so an email may go twice after a crash, never zero times. Jobs made by a change (a sign-up, an invite) are written in that change's transaction (an outbox), payloads hold ids only, done jobs go after 7 days and dead after 30, an SMTP 5xx is dead at once |
| `utils_migrate` | Schema migrations per tenant | `mojoui.migrate`: `NNN_name.sql` with `-- up` / `-- down`, a checksum per applied file, every tenant verified and dry-run before any changes, each file in its own transaction; the server refuses to start on a broken or edited migration; `rollback(to)` exists but a server never runs it on its own | ✅ (60 M2, tests/test_migrate.mojo) |
| `utils_db`, `utils_sql` | Database helpers, SQL builders | `mojoui.sqlite` (prepared statements cached per connection, transactions, FTS5, `Pool`: a connection per thread, a writer lock per file) | 🟡 statements yes, no query builder |
| `utils_log` | Structured logging | `mojoui.log`: JSON lines (one per request: ts, level, rid, method, path without its query and with sealed segments such as an invitation's token masked, status, ms, the client's ip; `X-Request-Id` on the reply), secrets masked by value (configuration only, at most 64, under the log's lock) and by shape, rotation by size; `Audit` rows (sign_up, sign_in, invite, invite_accept, plan_change) | ✅ (60 M1, tests/test_log.mojo) |
| `utils_api`, `utils_graphql` | API helpers | `mojoui.serve`'s routes; `mojoui.apiclient` for calling others (auth, token cache, retries, GraphQL paging) | ✅ (66 M2) |
| `utils_seo`, `utils_blog` | Blog and SEO pages | `mojoui.pages` (templates, sitemap, robots, PWA, contact form), `mojoui.static` | ✅ SEO and public pages (66 M0, M5); no blog engine |
| `utils_ai_interface`, `utils_ai_queue`, `utils_workflow`, `utils_polars_mapper` | AI calls, queues, workflows, dataframes | elsewhere in omxcode (`mojoui.agui`, the omxcore engine) | out of scope here |

## The modules' APIs

Each is a generic `mojoui` module with its own test; an app composes them (examples/saas_min uses three). None imports
one it doesn't need: `accounts` doesn't know billing or mail (it puts `signed_up` and `invite` events on a jobs queue),
`mail`, `jobs`, `migrate` and `log` know no account.

### `mojoui.serve` (concurrent)
A `Handler`'s `answer(self, …)` runs on every worker at once: no lock. Requests its `blocking()` names (they wait on
Google or Stripe) leave the reactor for a small fixed pool of offload threads, so a slow provider stalls nobody (D-6007,
D-6008, D-6033).
```mojo
struct Api(Handler):
    var acc: Accounts
    def answer(self, mut req: Req) -> Reply: ...
    def blocking(self, req: Req) -> Bool: return self.acc.blocking(req)
    def tick(self): pass
    def stop(self): pass
var served = serve(Api(acc^), port=8000, log=Log.open("saas.log"),   # X-Request-Id + a JSON line per request
                   proxies=TrustedProxies.parse(getenv("SAAS_TRUSTED_PROXIES")),   # req.client: X-Forwarded-For from these only
                   tick_ms=60_000,                                    # tick(): the sweeps
                   offload_threads=16, offload_queue=64,              # blocking requests: 16 at once, 64 waiting, then 503
                   offload_per_client=4)                              # one client's share of them (429 past it)
```
Bodies over `max_body` (1 MB) and requests slower than `request_timeout_ms` (30 s) are refused by Flare as it reads
them; a reply header with CR, LF or NUL becomes a 500.

### `mojoui.accounts`
```mojo
var acc = Accounts(data_dir, AuthConfig.from_env(), log, events=queue)   # host.db + tenants/<id>.db, migrated
var r = acc.handle(req)            # /login /auth/callback /auth/desktop /api/token /logout (POST) /api/me /api/invites /api/tenants /api/switch /invites/<token>
if r.status != 0: return r^
var m = acc.member(req)            # Optional[Member]: user, current tenant, role
var db = acc.tenant_db(m.value())  # this thread's connection to the tenant's file
var need = acc.need(req, "member") # (Optional[Member], Reply): the reply is 401/403 when the role is short
```

### `mojoui.billing`
```mojo
var bill = Billing(data_dir, BillingConfig.from_env(), log)   # STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET STRIPE_PRICE_PRO …
var b = bill.handle(req, acc)      # GET /api/me (plan, status, trial_ends, cancels_at) /billing/checkout /billing/portal
if b.status != 0: return b^        # /billing/purchase /billing/return /billing/webhook
var wall = bill.paywall(member)    # 402 unless pro, trial, or past_due within the grace
```

### `mojoui.mail`
```mojo
var cfg = SmtpConfig.from_env()    # SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM SMTP_TLS SMTP_CA_FILE
send(cfg, welcome(email, name, "omxcode SaaS", base + "/"))   # raises with the server's reply when refused
var m = Mail.from_template(to, name, "Hi {{name}}", "# Hello {{name}}\n\n[Open]({{link}})", names, values)
```

### `mojoui.jobs`
```mojo
var q = Queue(data_dir + "/host.db", backoff_ms=2000, max_attempts=5)
_ = q.add("mail", m.to_json(), tenant=t)          # committed when it returns (see below)
db.begin(); …; _ = q.add_in(db, "invite", '{"invite": 7}', t); db.commit(); q.wake()   # an outbox: with the change
start_workers(q, MyRunner(...), threads=2)         # MyRunner(Runner).run(job) -> "" or the error (retried, then dead)
q.list_json(tenant)                                # [{id, kind, status, attempts, run_at, error}]
q.sweep()                                          # (tick) done jobs older than 7 days, dead older than 30, deleted
```
`permanent(why)` as a run's error: dead at once (mojoui.mail's 5xx replies say so themselves). **Durable** means
committed to host.db in WAL mode with `synchronous=NORMAL`: a job survives the process being killed at any point after
`add()` returns (M3's `kill -9`), but a power cut or an OS crash can lose the last transactions before the next
checkpoint. `synchronous=FULL` (an fsync of the WAL on every commit, so every write waits for the disk) isn't offered
yet: it has to be on every connection to the file to mean anything, and the pool shares host.db's connections across
modules (D-6020).

### `mojoui.migrate`
```mojo
var m = Migrations.from_dir("migrations/tenant")   # 001_entries.sql: "-- up" … "-- down" …
_ = m.apply(Database(path))                         # verify checksums, then every pending one in one transaction
_ = apply_all(m, paths)                             # every file verified and dry-run first, then each applied
```

### `mojoui.log`
```mojo
var log = Log.open(getenv("SAAS_LOG"), max_bytes=10_000_000, keep=5)   # "" → stdout
_ = log.secret(getenv("SMTP_PASSWORD"))                                # configuration only: never written, wherever it appears
log.info("checkout", Fields().str("tenant", t).int("ms", 12))
Audit.record(db, tenant, actor, "invite", detail)
```

## Goal 66: the rest of a Finxplorer-class SaaS (server side)

Each is a generic `mojoui` module with its own test (tests/test_<name>.mojo); `examples/finance_min` uses them all
together (docs/goals/66-check.py M9). fh-saas's `utils_api`, `utils_graphql`, `utils_seo` and its webhook handler for
anyone but Stripe now have a Mojo counterpart; leaving fh-saas is `scripts/fhsaas_import.py`.

### `mojoui.static` (M0)
```mojo
var files = Static("examples/finance_min/static", prefix="/static/")
var f = files.handle(req)        # status 0: not under the prefix, or not GET/HEAD
if f.status != 0: return f^
files.url("app.js")              # "/static/app.<10 hex of sha256>.js": served "public, max-age=31536000, immutable"
```
Content types by extension, an ETag from size + mtime (If-None-Match → 304; plain URLs `no-cache`), gzip for text types
when asked (Vary: Accept-Encoding), one byte Range (206, 416), a folder's index.html. Refused with 404 before the disk
is touched: `..`/`.`/empty/dot segments, NUL, backslash, an encoded `/` or `\`; then realpath must stay in the folder
(symlinks out). Limits: a file is read on every request (no cache); a hashed URL hashes the file on every request; whole
files over 64 MB are 413 (a Range still works); one range per request (several → the whole file).

### `mojoui.webhooks` (M1)
```mojo
var hooks = Webhooks(data + "/host.db", queue)
var bank = Source.standard("bank", getenv("BANK_WEBHOOK_SECRET"))   # Standard Webhooks / Svix
# Source.stripe(name, secret) · Source.hmac_hex(name, secret, "X-Hub-Signature-256") · Source.hmac_b64(name, secret, header)
if req.matches("POST", "/webhooks/bank"): return hooks.receive(req, bank)
# a Runner: job.kind == "webhook" → var ev = hooks.job_event(job.payload)   # (source, id, type, body)
```
200 accepted or a duplicate (no effect), 401 no or wrong signature, 400 a good signature outside the 5-minute window or
no event id, 413 over 1 MB. The event's row and its job are one transaction (an outbox); the job's payload holds ids
only. Limits: the hex/base64 shapes have no timestamp: a replay is stopped by the body's `id` while the log keeps it
(`sweep(keep_days=30)`); the signature is checked over the body as text (a body that isn't UTF-8 is not supported).

### `mojoui.apiclient` (M2)
```mojo
var bank = ApiClient(api, Auth.client_credentials(api + "/oauth/token", id, secret))   # or Auth.bearer / Auth.basic
var r = bank.get("/v1/accounts")              # ApiReply: status, body, error, attempts; r.ok(); r.json()
var nodes = bank.graphql_pages(QUERY, '{"connection": "c1"}', "transactions")   # every page's nodes (JSON texts)
```
Retries 429 and 503 always, other 5xx and no reply for idempotent calls, honouring Retry-After (seconds), exponential
backoff with jitter, `max_wait_ms` (30 s) at most; a 401 fetches one new token and tries once more; the token is fetched
again before it expires. Limits: blocking (call it from a job or an offloaded request); one client per thread (its token
cache is its own: a job making a client per run asks for a token per run); Retry-After as an HTTP date falls back to backoff.

### `mojoui.schedule` (M3)
```mojo
var sched = Scheduler(data + "/host.db", queue)
_ = sched.due(Schedule("digest", tenant, Cron.parse_any("every Monday 08:00"), Zone.load("Europe/London"), "digest", ""), now)
```
Cron's five fields or words ("every minute", "every 15 minutes", "every day 08:00", "every Monday 08:00", "every
weekday 09:30", "every month on the 1st 09:00"); IANA zones from the system's tz database (TZif + its POSIX rule);
DST as Vixie cron (a skipped 02:30 runs once just after the gap, a repeated 01:30 once, every-hour schedules on real
time). A slot's row and its job are one transaction: queued at most once across restarts and kill -9; after a downtime
only the latest missed slot runs (`"catchup": true, "missed": n`). Limits: running is at least once (mojoui.jobs):
make the effect idempotent by `slot`; needs /usr/share/zoneinfo (or $TZDIR); slots more than 400 days back are skipped.

### `mojoui.sqlite` bulk writes and `mojoui.csvstream` (M4)
```mojo
_ = bulk_upsert(db, "transactions", ["id"], ["id", "date", "amount", "category"], rows, keep_edited=["category"])
_ = set_edited(db, "transactions", "id", id, "category", "Coffee")     # a person's change, kept by later syncs
return stream_csv(db.path, "SELECT date, amount FROM transactions", args, header, "transactions.csv")   # Reply.csv
```
One transaction (any failure writes nothing), one prepared statement: 100k rows in ~0.14 s here. The table needs a
UNIQUE key and, for `keep_edited`, an `edited TEXT` column. CSV: RFC 4180 quoting, CRLF; text cells starting with
= + - @ tab or CR get a leading ' (numbers stored as numbers stay numbers); written by a thread into a Pipe.

### `mojoui.pages` (M5)
```mojo
public_page(render(TEMPLATE, names, values), cache="no-store")   # {{x}} escaped, {{{x}}} trusted HTML; CSP: own files only
sitemap_reply(base, paths) · robots_reply(base, disallow) · manifest_reply(manifest_json(...)) · worker_reply(service_worker_js(...))
var contact = ContactForm(key, base, to, site_name, per_minute=5, queue=jobs)    # contact.page(page) / contact.post(req, thanks)
```
The contact form: a sealed HttpOnly SameSite=Strict cookie and a hidden field (double submit), same-origin only, a
per-client limit counted before the token is checked, a honeypot that gets the same thanks, the message queued as a
`mail` job (mojoui.mail's header and markdown safety). Limits: the limit is per process; no captcha.

### `mojoui.operator` (M6)
```mojo
var op = Operator(data, getenv("SAAS_OPERATORS"), getenv("SAAS_LOG"))    # emails, comma-separated
var o = op.handle(req, acc)     # GET /operator/api/tenants  /operator/api/log?level=&path=&tenant=&rid=&limit=
if o.status != 0: return o^     # GET /operator/api/tenants/{id}/snapshot (blocking: offloaded)
```
Anyone else signed in: 403 and an `operator_refused` audit row; not signed in: 401. Every action is an audit row
(`operator_tenants`, `operator_log`, `operator_snapshot`, `operator_snapshot_failed`). Snapshots are `VACUUM INTO` a
temporary file (consistent under writes), removed after sending; leftovers are removed at start. Limits: operators are
configuration (a restart to change); a snapshot sits whole in memory while it is sent (512 MB cap); the log tail reads
the file's last 4 MB only (rotated files aren't read).

### Leaving fh-saas (M7)
`scripts/fhsaas_import.py --from <fh host .db> --tenants <folder> --to <SAAS_DATA> [--dry-run]` (start the server once
first). People keep their tenant (same id), role (editor → member) and plan (Stripe ids, status, period and trial
ends). A person whose address or Google sub is already someone else's in host.db is left out with their memberships.
Existing rows are never overwritten, so a second run changes nothing and can't roll omxcode back. SQLite fh-saas only
(a PostgreSQL fh-saas: dump to SQLite first).

### The image (M8)
`scripts/saas_image.sh build` (needs Docker) makes `omxcode-saas:g66` from debian:trixie-slim and a pixi-free bundle;
`/data` is the volume (host.db, tenants/), the server checks its own health (`server --health <url>`), a non-root
user. Not run in Docker yet on this machine (the user can't reach Docker's socket): the bundle itself is proven.

## The pieces under it
- `mojoui.crypto`: HMAC-SHA256, the OS's random bytes (getentropy), base64 and base64url, a constant-time compare,
  seals (signed, expiring values), PKCE: plain Mojo on `mojoui.hash` so every host has it (D-5709).
- `mojoui.sqlite`'s `Pool` (D-6009, D-6018): one connection per thread per file (closed when the thread ends), an
  in-process writer lock per file around `BEGIN IMMEDIATE`, statements cached per connection; its connections stay
  inside half the open-file limit (raised to the hard limit at start), idle least-recently-used ones closed first, so a
  server with thousands of tenants never hits EMFILE (tests/test_pool.mojo: 500 tenants, 8 threads, `ulimit -n 256`).
- `mojoui.clientip` (D-6019): trusted-proxy CIDRs, the client from X-Forwarded-For's rightmost untrusted hop, IPv6
  keys by /64.
- `mojoui.ratelimit`: an exact sliding-window limiter per key (a client and a route); under a flood of live keys it
  evicts the least recently seen down to 90 % of its 100,000-key cap (slowest hit 5–15 ms).
- `mojoui.browser`: open a page in the system browser as an effect (`App.opens`), GTK and AppKit (D-5718).
- `mojoui.signin`: the desktop half of sign-in: a loopback listener (libc sockets) and the PKCE verifier (D-5720).
- Flare carries two vendored patches: the streaming client's body (D-4775) and the offload of blocking requests
  (`vendor/patches/flare-0.13-offload.patch`, D-6008), to send upstream.

## Known limits (read before real users)
- Closed in goal 60: every request under one lock and the provider calls inside it (D-5714: now a concurrent Handler,
  and the calls run off the reactor); no per-IP limit on `/login`, `/auth/callback`, `/api/token` (now `SAAS_RATE` a
  minute each, 429 with Retry-After); invites that join without asking (D-5725: now an accept page, single use,
  expiring, for the invited address only); sessions that never slid; one tenant per person (D-5712).
- Closed in the hardening of 2026-11-11 (60-check M12):
  - A desktop sign-in's one-time code in the browser's address bar after a bare GET (RFC 8252 §8.12's phishing risk: a
    stranger's link with their own loopback port and verifier). The callback now answers "Sign in to <app> on this
    computer?" (`SAAS_APP_NAME`), and only a same-origin POST from that page (`/auth/desktop`: Origin is the site's, or
    Sec-Fetch-Site same-origin, or Origin "null" with Sec-Fetch-Site same-origin) makes the code and sends it to the
    loopback; cancel, or 5 minutes, and there is none (D-6029). The page is served with Referrer-Policy: same-origin, so
    a browser's form sends the real Origin (no-referrer made it "null" and every real confirm 403: D-6035, found by the
    security audit; 60-check M12 now drives the confirm, Sign out and an invitation's Join in headless Chromium).
  - Pending sign-ins as host.db rows under a global cap (`SAAS_MAX_SIGNINS`), which one IPv6 /48 could fill and make
    /login answer 503 for everyone. A pending sign-in is now the browser's sealed HttpOnly cookie (10 minutes; the PKCE
    verifier is an HMAC of the state under the server's key, never sent), so /login writes nothing; single use is a
    `signin_used` row written only once the provider has traded the code (a flood can't write one), checked before the
    provider is asked again. `SAAS_MAX_SIGNINS` and `SAAS_SIGNINS_PER_CLIENT` are gone; `SAAS_RATE` per client stays
    (D-6031, D-6032).
  - A new thread and new SQLite connections for every blocking request (up to 256 at once). A fixed pool of offload
    threads now takes them from a bounded queue (a pipe of job addresses), 503 with Retry-After past it (D-6033).
  - `GET /logout` signing people out (a link or an img on any page could). Sign-out is `POST /logout` from the site
    itself (Origin this site, or none) or with a bearer token; another site's POST gets 403 and the cookie is left
    alone; `GET /logout` shows a "Sign out?" page with the button (D-6034).
- Per-client limits key on `req.client`: the socket's peer, or, when the peer is in `SAAS_TRUSTED_PROXIES` (CIDRs:
  set it to your TLS proxy's addresses), X-Forwarded-For's rightmost hop that isn't a trusted proxy, read across every
  X-Forwarded-For line (nginx, Caddy and Envoy join the hops into one line; HAProxy's `option forwardfor` adds its own:
  both work, checked with one and two lines). Behind a proxy
  that isn't listed, every client is the proxy and shares one limit: list it. IPv6 clients are keyed by their /64.
- Durability: WAL with synchronous=NORMAL (above): a crash of the process loses nothing committed, a power cut can
  lose the last moments of writes (sessions, entries, jobs alike).
- A blocking request (the callback, checkout, portal, return, purchase) answers with `Connection: close` on one of the
  offload pool's threads (`SAAS_OFFLOAD_THREADS`, 16, made at start and kept, so their SQLite connections stay open),
  and its socket gets 30 s send and receive timeouts. At most `SAAS_OFFLOAD_QUEUE` (64) more wait for a thread; past
  that, 503 with Retry-After, and a job that waited past the 30 s request timeout is dropped with 503, never answered
  late; the queue's pipe never blocks the reactor (full: 503). One client (`req.client`, IPv6 by /64) holds at most
  `SAAS_OFFLOAD_PER_CLIENT` (4) of the slots: 429 with Retry-After past it (D-6036). Behind a reverse proxy that isn't in `SAAS_TRUSTED_PROXIES`, every visitor is the proxy and the whole site shares those 4 (as with `SAAS_RATE`): list the proxy. Counters are keyed by a hash seeded at start, so no one can choose addresses that share a victim's counter (D-6038). Sixteen providers each sitting
  20 s (the callback's timeout) fill the pool for that long: the reactor still answers every other request. The pool's
  threads aren't joined when a server stops: one server per process (they wait on the queue until the process ends).
- The demo server refuses to start on a `SAAS_*` number that isn't a whole number in range, naming it (D-6036). The offload needs a cleartext connection, and `mojoui.serve` binds
  cleartext only: terminate TLS in front of it (a TLS connection would get a 503).
- `serve()` stopped and started again in one process (tests do; the demos don't): the stopped server's loop ends on its
  own thread a little later and can close a descriptor number the new server has reused (its listener: connections
  refused). Observed in tests/test_handler.mojo with the old offload too; wait for `served.stopped()` before serving
  again. Not yet fixed in mojoui.serve / Flare.
- Bodies over 64 KB (the webhook 1 MB) get a 413 before any work; Flare itself refuses a body over 1 MB as it reads it
  and gives a request 30 s to arrive (serve()'s `max_body`, `request_timeout_ms`); `/billing/return` makes at most 30 Stripe
  read-backs a minute for the whole server, so a stranger can spend that budget and make a real return page say 429 (the
  webhook still upgrades the plan) (D-5727).
- Template values in emails are inert: a name like `[Accept](https://evil.example)` can't become a link (brackets and
  marks are replaced), and they are HTML-escaped in the HTML part.
- Jobs are at least once (above). An invitation's email is built when its job runs, from the invite's row, so the job's
  payload holds no link (only `{invite}`; a welcome's only `{user}`); a used or expired invite sends nothing. Without
  SMTP set up the demos start no mail workers: the emails wait, pending, and go after a restart with SMTP set.
- A Stripe subscription event that arrives before its checkout's completion is held (the newest per subscription, 30
  days at most) and applied when the checkout lands (D-6023).
- One pending sign-in per browser: the state is one cookie, so a second /login in another tab replaces the first's
  (that tab's callback says to start again).
- Deploying this version cancels the sign-ins in progress once: host migration 006 drops `oauth_states`, so a
  callback for a /login started before the upgrade says to start again.
- A request carrying two cookies named `saas` (or `__Host-saas`, or the state cookie) gets 400 and that cookie expired:
  a page that can set cookies for this site could sign someone out that way (an availability cost, chosen over guessing
  which copy is real). On https the `__Host-` names can't be set by a sibling subdomain or an http page. On a plain-http
  base (local runs only) the expiring Set-Cookie removes only the site's own copy: a copy planted with another Domain or
  Path survives, and could be an attacker's session: never serve real users over http.
- Identity: the first sign-in with a Google `sub` claims the account with that address; a sign-in from another `sub`
  with the same address gets 403 and an audit row (D-6021). A known `sub` signing in with a new verified address moves
  its account to it (an `email_changed` audit row; refused if another account has that address), so invitations match
  the address Google vouches for now (D-6027). Accounts made by goal 57's test hook have no `sub` until
  their first real sign-in.
- Goal 57's pending invites (made before goal 60's host migration 002) are dropped by it: they joined silently and had
  no link; send them again.
- Plans follow Stripe's events; a paid session counts only in subscription mode with a subscription (not a Payment
  Link's one-off payment), and a deleted subscription is final. Our own trial runs from the tenant's creation for
  `SAAS_TRIAL_DAYS` as the server is set now (changing it moves every tenant's trial).

## Running it
```
scripts/saas_keys.sh                 # once: Google Desktop client, Stripe test key and Pro price, SMTP → ~/.config/omxcode/saas.env
scripts/saas.sh run                  # the server on http://127.0.0.1:8000
scripts/build.sh saas linux && SAAS_SERVER=http://127.0.0.1:8000 build/saas/linux/saas
```
For Stripe webhooks on a public host: set `STRIPE_WEBHOOK_SECRET` (the endpoint's `whsec_…`) and point Stripe at
`<base>/billing/webhook`; locally, `/billing/return` reads the paid session back instead.
