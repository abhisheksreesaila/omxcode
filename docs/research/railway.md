# Railway for omxplorer: plans, limits, HTTP, config, CLI

Researched 2026-11-06. Every fact was read that day from docs.railway.com (each page's `.md` source) or
railway.com/pricing, and each one links to its page. CLI help was read locally from **railway 5.68.0**
(`--help` only; nothing was created, linked or deployed). **UNCONFIRMED** = not found in those sources.

## Read this first

1. **`railway.json` / `railway.toml` are deprecated.** "New services cannot opt into Config as Code." Existing
   files stop being read on **2026-12-01**, two weeks before the 2026-12-15 fund deadline. [cac](https://docs.railway.com/config-as-code)
2. **No sticky sessions.** Replicas get requests at random, and replicas cannot be used with volumes. If a
   visitor's long-poll state lives in process memory, run one replica. [scaling](https://docs.railway.com/deployments/scaling) [volref](https://docs.railway.com/volumes/reference)
3. **Long-polls:** an HTTP request is closed after 5 minutes with no data, and can never run past 15 minutes.
   WebSockets have no duration or idle limit. [specs](https://docs.railway.com/networking/public-networking/specs-and-limits)

## 1. Plans and prices

| Plan | Fee | Included usage | Source |
|---|---|---|---|
| Trial | $0 | "one-time grant of $5", up to 30 days; then it becomes Free | [trial](https://docs.railway.com/pricing/free-trial) |
| Free | $0 / month | "$1 of free credit per month" | [plans](https://docs.railway.com/pricing/plans) |
| Hobby | $5 / month | "$5 of resource usage per month" | [plans](https://docs.railway.com/pricing/plans) |
| Pro | $20 / month | "$20 of resource usage per month" | [plans](https://docs.railway.com/pricing/plans) |
| Enterprise | Custom | Custom | [plans](https://docs.railway.com/pricing/plans) |

- The fee counts toward usage. Above it: "you will be charged the delta". Included usage "does not accumulate
  over time". So **bill = max(fee, usage)**: $8 of usage on Hobby is an $8 bill. [plans](https://docs.railway.com/pricing/plans) [bill](https://docs.railway.com/pricing/understanding-your-bill)
- Builds are free: no charge for "build CPU, memory, base-image downloads, image exports, or image storage". [plans](https://docs.railway.com/pricing/plans)
- You pay for what the process uses, not for its limits: "generous limits cost nothing on their own". [rightsize](https://docs.railway.com/guides/right-size-cpu-memory)

Resource prices, exactly as each page states them:

| Resource | railway.com/pricing [pricing](https://railway.com/pricing) | docs pricing/plans [plans](https://docs.railway.com/pricing/plans) |
|---|---|---|
| RAM | $0.00000386 per GB / sec | $10 / GB / month ($0.000231 / GB / minute) |
| CPU | $0.00000772 per vCPU / sec | $20 / vCPU / month ($0.000463 / vCPU / minute) |
| Volume | $0.00000006 per GB / sec | $0.15 / GB / month ($0.000003472222222 / GB / minute) |
| Egress | $0.05 per GB, for services | $0.05 / GB ($0.000000047683716 / KB) |
| Object storage | $0.015 per GB-month, free egress | (not listed) |

The pricing page says billing is "by the second"; the docs say "billed by the minute". The monthly figures
match either way (per-second × 30 days = $10.005 / GB and $20.01 / vCPU). [pricing](https://railway.com/pricing) [d-pricing](https://docs.railway.com/pricing)

## 2. Per-plan limits

| Limit | Trial | Free | Hobby | Pro | Source |
|---|---|---|---|---|---|
| RAM / vCPU per replica | 1 GB, shared vCPU | - | 8 GB / 8 vCPU | 24 GB / 24 vCPU | [trial](https://docs.railway.com/pricing/free-trial) [slow](https://docs.railway.com/deployments/troubleshooting/slow-deployments) [pricing](https://railway.com/pricing) |
| RAM / vCPU per service, all replicas | 1 GB / 2 vCPU | 0.5 GB / 1 vCPU | 48 GB / 48 vCPU | 1 TB / 1,000 vCPU | [plans](https://docs.railway.com/pricing/plans) |
| Replicas per service | 2 | 1 | 6 (pricing card says 5) | 42 | [plans](https://docs.railway.com/pricing/plans) [pricing](https://railway.com/pricing) |
| Max volume | 0.5 GB | 0.5 GB | 5 GB | 1 TB (50 GB default) | [plans](https://docs.railway.com/pricing/plans) [volref](https://docs.railway.com/volumes/reference) |
| Volumes per project | 3 | 1 | 10 | 20 | [volref](https://docs.railway.com/volumes/reference) |
| Image size | 4 GB | 4 GB | 100 GB | Unlimited | [plans](https://docs.railway.com/pricing/plans) |
| Ephemeral disk | 1 GB | 1 GB | 100 GB | 100 GB | [plans](https://docs.railway.com/pricing/plans) [deploys](https://docs.railway.com/deployments/reference) |
| Build timeout (pricing page only) | 20 min | 10 min | 40 min | 90 min | [pricing](https://railway.com/pricing) |
| Custom domains (per service) | 1 | 0 | 2 | 20 | [domains](https://docs.railway.com/networking/domains/working-with-domains) [pricing](https://railway.com/pricing) |
| Log history | 7 days | 3 days | 7 days | 30 days | [pricing](https://railway.com/pricing) |
| Availability target | - | - | 99.9% | 99.99% | [pricing](https://railway.com/pricing) |

- `railway scale --help` (5.68.0) adds "Maximum: 50 total replicas across regions". Free and Trial cannot use
  the `Always` restart policy, and `On Failure` is capped at 10 restarts. [restart](https://docs.railway.com/deployments/restart-policy)
- Railway "may temporarily suspend resource allocation, including builds, to Free, and more rarely Hobby"
  ("Pro tier customers are not affected"). On "Trial or Hobby, you may be pre-emptively moved to a different
  host", which is a redeploy and drops open connections. [deploys](https://docs.railway.com/deployments/reference)

## 3. HTTP at the edge

| Item | What the docs say | Source |
|---|---|---|
| Request duration | "up to 15 minutes if data keeps transferring", "closed after 5 minutes with no data transferred" | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| Upload time | "Request bodies must finish uploading within 5 minutes" (100 MB needs about 2.7 Mbit/s) | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| Max body size | **UNCONFIRMED**: no size limit is documented | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| Idle keep-alive | HTTP/1.1 idle connections closed "after 60 seconds between requests"; not HTTP/2 or WebSockets | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| WebSockets | "Support for websockets over HTTP/1.1"; "exempt from these duration and inactivity limits, and can stay open indefinitely, even while idle" | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| Client to edge | HTTP/1.1 and HTTP/2; TLS 1.2 and 1.3; SNI required; HTTP GET on port 80 gets a 301 to HTTPS | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| Edge to container | **UNCONFIRMED**. The HTTP log example shows `"upstreamProto": "HTTP/1.1"` with `"downstreamProto": "HTTP/2"` | [logs](https://docs.railway.com/cli/logs) |
| Headers added | `X-Real-IP`, `X-Forwarded-Proto` ("always indicates `https`"), `X-Forwarded-Host`, `X-Railway-Edge`, `X-Request-Start`, `X-Railway-Request-Id` | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| X-Forwarded-For | **UNCONFIRMED**: not listed on any docs page. Read the client IP from `X-Real-IP` | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| Header size | "Max 32 KB combined header size" | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| Rate limits | 10,000 concurrent connections; about 11,000 requests/sec per domain; 10,000 requests per connection | [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) |
| Replicas | "randomly distribute public traffic"; "does not support sticky sessions" | [scaling](https://docs.railway.com/deployments/scaling) |
| Redeploys | The old deploy gets SIGTERM, then SIGKILL after `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` (default 0). `RAILWAY_DEPLOYMENT_OVERLAP_SECONDS` defaults to 0 | [deploys](https://docs.railway.com/deployments/reference) [vars](https://docs.railway.com/variables/reference) |
| CDN | Free on all plans and off by default; caches `image/*` by default; "A cache hit never reaches your service" and incurs no egress. It is a Priority Boarding (beta) feature | [cdn](https://docs.railway.com/networking/cdn) [pb](https://docs.railway.com/platform/priority-boarding) |

## 4. `$PORT` and bind host

- "Your web server should bind to the host `0.0.0.0` and listen on the port specified by the `PORT`
  environment variable, which Railway automatically injects". uvicorn: `uvicorn main:app --host 0.0.0.0 --port $PORT`. [afr](https://docs.railway.com/networking/troubleshooting/application-failed-to-respond)
- The injected value of `PORT` is **UNCONFIRMED** (not documented). You may set `PORT` yourself, and
  health checks use it. [health](https://docs.railway.com/deployments/healthchecks)
- On a Dockerfile service, a start command set in Railway runs in exec form, which does not expand variables.
  Wrap it: `/bin/sh -c "exec uvicorn app:app --host 0.0.0.0 --port $PORT"`. With no start command set, the
  Dockerfile's `ENTRYPOINT`/`CMD` is used. [start](https://docs.railway.com/deployments/start-command)
- `::` appears only in the FastAPI Dockerfile example (`hypercorn main:app --bind ::`). [fastapi](https://docs.railway.com/guides/fastapi) It matters for
  the private network: environments created after 2025-10-16 resolve to IPv4 and IPv6, older ones to IPv6 only. [pnet](https://docs.railway.com/networking/private-networking/how-it-works)
- Each domain has a target port: `railway domain app.omxlabs.tech --port 8000`. [domains](https://docs.railway.com/networking/domains/working-with-domains) [cli-domain](https://docs.railway.com/cli/domain)

## 5. Health checks and restarts

- Set the path in service settings, as `healthcheckPath` (Config as Code) or as `healthcheck` (IaC). Any `2xx` passes. [health](https://docs.railway.com/deployments/healthchecks) [iacref](https://docs.railway.com/infrastructure-as-code/reference)
- Default timeout is 300 s. Change it in settings, with `healthcheckTimeout`, or with `RAILWAY_HEALTHCHECK_TIMEOUT_SEC`. [health](https://docs.railway.com/deployments/healthchecks) [vars](https://docs.railway.com/variables/reference)
- **Deploy time only:** "Railway does not monitor the healthcheck endpoint after the deployment has gone live." [health](https://docs.railway.com/deployments/healthchecks)
- Probes come from host `healthcheck.railway.app`; allow it if the app checks `Host`. [health](https://docs.railway.com/deployments/healthchecks)
- With a volume attached, every redeploy has "a small amount of downtime", even with a health check. [health](https://docs.railway.com/deployments/healthchecks)
- Restart policies: `ON_FAILURE` (the default, max 10 restarts), `ALWAYS`, `NEVER`; set the limit with
  `restartPolicyMaxRetries`. A crash restarts only that replica. [restart](https://docs.railway.com/deployments/restart-policy) [cacref](https://docs.railway.com/config-as-code/reference)

## 6. Config as code (deprecated) and its replacement

Schema: <https://railway.com/railway.schema.json>. Only services that already use it can keep it, and only until 2026-12-01. [cac](https://docs.railway.com/config-as-code) [schema](https://railway.com/railway.schema.json)

| Key | Values (from the schema) |
|---|---|
| `build.builder` | `"DOCKERFILE"` ("Force usage of a Dockerfile"), `"RAILPACK"`, `"NIXPACKS"`; `HEROKU`/`PAKETO` deprecated |
| `build.dockerfilePath` | string, "Location of non-standard Dockerfile" |
| `deploy.startCommand` | string |
| `deploy.healthcheckPath` / `deploy.healthcheckTimeout` | string / number (seconds) |
| `deploy.restartPolicyType` / `restartPolicyMaxRetries` | `ON_FAILURE`, `ALWAYS`, `NEVER` / number ≥ 1 |
| `deploy.numReplicas` | integer 1 to 200 |
| `deploy.sleepApplication` | boolean ("Should application be stopped when inactive") |
| `deploy.overlapSeconds` / `drainingSeconds` | number ≥ 0 |
| `deploy.limitOverride.containers` | `cpu`, `memoryBytes`, `diskBytes` |

- **Replacement:** Infrastructure as Code in `.railway/railway.ts` (TypeScript is GA, `npm install railway`) or
  `.railway/railway.py` (beta, `railway-sdk` on PyPI; in pixi that is `pixi add --pypi railway-sdk`). Run
  `railway config init`, then `plan`, then `apply`. Railway does not read `.railway/` during deploys. [iac](https://docs.railway.com/infrastructure-as-code)
- Documented IaC service fields: `source` (`github(...)` or `image(...)`), `build`, `start`, `healthcheck`,
  `healthcheckTimeout`, `preDeploy`, `replicas`, `env`, `volumeMounts`, `domains`. Restart policy, serverless and
  replica limits are **UNCONFIRMED** in IaC (not in the reference). [iacref](https://docs.railway.com/infrastructure-as-code/reference)
- Without either file: a root `Dockerfile` is "automatically" used, `RAILWAY_DOCKERFILE_PATH` picks another one,
  and timeout, draining and overlap can all be set as variables. [docker](https://docs.railway.com/builds/dockerfiles) [vars](https://docs.railway.com/variables/reference)

```ts
// .railway/railway.ts: every field below is documented in the IaC reference linked above
import { defineRailway, github, project, service } from "railway/iac";
export default defineRailway(() => {
  const web = service("web", {
    source: github("OWNER/REPO", { branch: "main" }),
    healthcheck: "/health", healthcheckTimeout: 300, replicas: 1,
    domains: [{ domain: "app.omxlabs.tech", port: 8000 }],
    env: { PORT: "8000", RAILWAY_DEPLOYMENT_DRAINING_SECONDS: "30" },
  });
  return project("omxplorer", { resources: [web] });
});
```

## 7. Volumes, and image vs volume for 1 to 2 GB of read-only data

- **Attach (dashboard):** open the Command Palette (⌘K) or right-click the canvas, pick the service, then set the mount path. [vol](https://docs.railway.com/volumes)
- **Attach (CLI):** `railway volume add --service web --mount-path /data` (the 5.68.0 help example). There is no
  size flag; IaC has `volume(name, { sizeMB })`. [cli-vol](https://docs.railway.com/cli/volume) [iacref](https://docs.railway.com/infrastructure-as-code/reference)
- Volumes mount when the container starts, not at build or pre-deploy time. Railway sets `RAILWAY_VOLUME_MOUNT_PATH`. [vol](https://docs.railway.com/volumes)
- Upload data with `railway volume files upload ./data.tar /data.tar`. [vol](https://docs.railway.com/volumes)
- **Read-only mount: UNCONFIRMED.** No read-only option in the docs or the CLI.
- Volumes mount as `root`. A non-root image needs `RAILWAY_RUN_UID=0`. [vol](https://docs.railway.com/volumes)
- Rules: one volume per service, "Replicas cannot be used with volumes", downtime on each redeploy, no shrinking.
  3,000 read and 3,000 write IOPS. You pay for used storage, and filesystem metadata takes about 2 to 3%. [volref](https://docs.railway.com/volumes/reference)
- **Verdict: bake the data into the image.** The image limit is 100 GB on Hobby and unlimited on Pro, and image
  storage is free. [plans](https://docs.railway.com/pricing/plans) Baking keeps zero-downtime overlapping deploys and the option of replicas; a volume
  rules both out. [volref](https://docs.railway.com/volumes/reference) The cost: "Large images take longer to pull, especially on first deployment to a new
  compute node" [slow](https://docs.railway.com/deployments/troubleshooting/slow-deployments), and build cache "is not guaranteed". [buildcfg](https://docs.railway.com/builds/build-configuration)
- `railway up` follows `.gitignore` and `.railwayignore`. If the data folder is git-ignored, it is left out.
  `railway up ./staging --path-as-root` uploads one curated folder. The upload size limit is **UNCONFIRMED**. [cli-up](https://docs.railway.com/cli/up)

## 8. Custom domain `app.omxlabs.tech`

1. CLI: `railway domain app.omxlabs.tech --port 8000 --service web` prints the DNS records to add. Dashboard:
   Settings → Public Networking → `+ Custom Domain`. [cli-domain](https://docs.railway.com/cli/domain) [domains](https://docs.railway.com/networking/domains/working-with-domains)
2. DNS: add a `CNAME` for `app` pointing at the value shown (for example `g05ns7.up.railway.app`), **and** the
   `TXT` record shown. "Both records are required"; without the TXT the domain returns `404`. [domains](https://docs.railway.com/networking/domains/working-with-domains)
3. Check with `railway domain status app.omxlabs.tech`. If it stalls, use `railway domain certificate retry app.omxlabs.tech`. [cli-domain](https://docs.railway.com/cli/domain)
- TLS: Let's Encrypt certificates with ECDSA keys, "expected to be issued within an hour", attempted "for up to
  72 hours". They last 90 days and renew when 30 days remain. [specs](https://docs.railway.com/networking/public-networking/specs-and-limits)
- Don't delete and re-add the domain: Let's Encrypt allows 5 duplicate certificates a week, and going over blocks
  issuance for 7 days. Any CAA record must allow `letsencrypt.org`. [ssl](https://docs.railway.com/networking/troubleshooting/ssl)
- **Cloudflare (orange cloud):** set SSL/TLS to **Full**, not Full (Strict). Railway "may not always be able to
  issue a certificate", but Cloudflare-to-Railway traffic uses the `*.up.railway.app` certificate. If issuance
  is stuck, turn the proxy off until the certificate issues. `app.` is a first-level subdomain, so no Advanced
  Certificate Manager is needed. [domains](https://docs.railway.com/networking/domains/working-with-domains) [ssl](https://docs.railway.com/networking/troubleshooting/ssl) Cloudflare's own proxy limits are not on Railway's pages (**UNCONFIRMED**).

## 9. CLI commands (railway 5.68.0, local `--help`)

| Task | Command |
|---|---|
| Log in / check | `railway login` (`--browserless` for a device code); `railway whoami --json` |
| Create a project | `railway init --name omxplorer [--workspace W] [--json]` (also links this directory) |
| Link | `railway link --project P --environment production --service web` |
| Add a service | `railway add --service web`; or from GitHub: `railway add --repo owner/repo --branch main --service web` |
| Deploy local dir | `railway up --service web` (`-d/--detach` returns once the build is queued; `--ci`, `-m`, `--json`) |
| Wait for a deploy | `railway deployment list --json` (watch `.status`) |
| Variables | `railway variable set PORT=8000 KEY2=V --service web [--skip-deploys]`. `railway variables --set K=V` still works but is legacy [cli-var](https://docs.railway.com/cli/variable) |
| Domain | `railway domain app.omxlabs.tech --port 8000 --service web`; `railway domain status <domain>` |
| Volume | `railway volume add --service web --mount-path /data`; `railway volume list --json` |
| Logs | `railway logs --service web [--build/--deployment/--http] [--lines 100] [--since 1h] [--latest]` |
| Status | `railway status [--json]`; `railway metrics --cpu --memory` |
| Redeploy / restart | `railway redeploy --service web --yes [--from-source]`; `railway restart --service web --yes` |
| Replicas | `railway scale --service web us-west=1` (regions: us-west, us-east, eu-west, southeast-asia) |
| Spend cap | `railway usage limit set --target workspace --soft 100 --hard 250` (the hard limit is at least $10 [cost](https://docs.railway.com/pricing/cost-control)) |
| IaC | `railway config init / plan / apply` |

- No dedicated flag exists for the health check path, restart policy, Replica Limits (Settings → Deploy → Replica
  Limits) or Serverless; set them in the dashboard. [cost](https://docs.railway.com/pricing/cost-control) `railway environment edit --service-config web <dot.path> <value>`
  sets service settings by path, but the docs only show `deploy.startCommand`, `build.buildCommand`,
  `source.rootDirectory` and `variables.<KEY>.value`. Whether `deploy.healthcheckPath` works is **UNCONFIRMED**. [cli-env](https://docs.railway.com/cli/environment)
- One guide shows `railway service <name> set --memory-limit`; 5.68.0 has no such subcommand (**UNCONFIRMED**). [scaling-guide](https://docs.railway.com/guides/scaling-your-application)

## 10. Serverless (scale to zero, formerly App Sleeping)

- Railway watches *outbound* packets. It sleeps a service "somewhere between 5 and 10 minutes after its last
  outbound traffic". Responses count, so visitors keep it awake. [serverless](https://docs.railway.com/deployments/serverless)
- It wakes on the first request from the internet or the private network. "The first request sent to a slept
  service may return a 502 Bad Gateway". The cold-boot time is **UNCONFIRMED** (described only as "a small delay"). [serverless](https://docs.railway.com/deployments/serverless)
- Turn it on in Settings → Deploy → Serverless. It takes effect at the next deploy and applies to all replicas.
  A slept service is de-prioritized and "in remote cases, may require a rebuild". [cost](https://docs.railway.com/pricing/cost-control) [serverless](https://docs.railway.com/deployments/serverless)
- **For a burst demo:** keep it off while people might visit. A large image with Mojo start-up makes the first
  visitor's 502 or slow load likely. Turn it on only for weeks with no traffic.

## 11. Non-root and read-only root filesystem

- No rule requires non-root. `RAILWAY_RUN_UID` sets "the UID of the user which should run the main process"
  ("Set to `0` to explicitly run as root"). [vars](https://docs.railway.com/variables/reference)
- Non-root images run into permission errors on volumes (which mount as root); use `RAILWAY_RUN_UID=0`. [volref](https://docs.railway.com/volumes/reference)
- **Read-only root filesystem: UNCONFIRMED.** No setting is documented. Files outside a volume are on the
  "ephemeral filesystem and don't persist across deployments". [services](https://docs.railway.com/services)

## Recommendation for omxplorer

- **Plan: Pro.** Because bill = max(fee, usage), Pro costs the same as Hobby once usage reaches $20 a month,
  and every size below gets there. Pro also gives 24 GB / 24 vCPU per replica (Hobby: 8 / 8), 90-minute builds
  (Hobby: 40), no build pausing, a 99.99% availability target, and 20 custom domains. Hobby saves money only
  if usage stays under $20. [plans](https://docs.railway.com/pricing/plans) [pricing](https://railway.com/pricing) [deploys](https://docs.railway.com/deployments/reference)
- **One replica**, sized vertically: there are no sticky sessions. [scaling](https://docs.railway.com/deployments/scaling) Set **Replica Limits** at 1.5 to 2
  times the measured peak memory (Railway's rule). [rightsize](https://docs.railway.com/guides/right-size-cpu-memory) Add a workspace usage limit with a soft alert and
  a hard cap. [cost](https://docs.railway.com/pricing/cost-control)
- **Data in the image**, not a volume (section 7). Serve `/health` quickly, set `PORT`, and bind to `0.0.0.0`.
- **Long-poll:** return within about 60 s, well under the 5-minute no-data cutoff. WebSockets have no limit.
  Clients must reconnect after deploys; set `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=30`. [specs](https://docs.railway.com/networking/public-networking/specs-and-limits) [vars](https://docs.railway.com/variables/reference)
- **Measure before you resize:** run it for a week, then read `railway metrics` and the Usage page. [d-faqs](https://docs.railway.com/pricing/faqs)

**Formula** (monthly rates; RAM and CPU are *averages of real use*, per replica, times the replica count): [rightsize](https://docs.railway.com/guides/right-size-cpu-memory) [plans](https://docs.railway.com/pricing/plans)

`usage = RAM_GB × $10 + vCPU × $20 + volume_GB × $0.15 + egress_GB × $0.05`, and `bill = max($20, usage)` on Pro.

| Case (egress 50 GB = $2.50) | RAM | CPU | Usage = Pro bill | Hobby bill |
|---|---|---|---|---|
| 4 GB + 2 vCPU, busy all month | $40.00 | $40.00 | **$82.50** | $82.50 |
| 8 GB + 4 vCPU, busy all month | $80.00 | $80.00 | **$162.50** | $162.50 (8 GB is the Hobby cap) |
| 4 GB held, 0.25 vCPU average | $40.00 | $5.00 | **$47.50** | $47.50 |

At per-second prices over a 30-day month the first two rows are $82.54 and $162.58; a 31-day month adds about
3%. A 2 GB volume would add $0.30. CDN cache hits would lower egress. [pricing](https://railway.com/pricing) [cdn](https://docs.railway.com/networking/cdn)

## The plan chosen for omxplorer (goal 62, 2026-11-06)

Hobby: a replica may use up to 8 GB and 8 vCPU, billed on what it actually uses (sections 1–2 above). The server holds
the shared starter (about 2.7 GB at rest) and each visitor adds 25–40 MB, so memory is set by the starter, and CPU by
how many visitors play video and run questions at once. goal 62 M5 runs `scripts/web-start` held to these limits
(systemd-run: MemoryMax, CPUQuota) and plays the story with this many visitors at once; the server's session cap
(`MOJOUI_MAX_SESSIONS` in scripts/web-start) is that number.

PLAN: MemoryMax=8G CPUQuota=800% visitors=10
