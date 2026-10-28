# LiteLLM supply-chain incidents and omxconsole's exposure

Researched 2026-10-27. Read-only: nothing in `~/Projects/mxstudio` was installed, run, imported or changed.

## Verdict

- **The rumour is true, and it happened twice.** Attackers published malicious LiteLLM releases on PyPI in **March 2026** (1.82.7, 1.82.8) and again on **21 October 2026** (1.107.0, plus Docker tags).
- **omxconsole is not affected.** Its gateway environment has **litellm 1.103.2**, installed 2026-10-01. That version is outside both affected ranges. The lock file has only ever held 1.103.2, and no indicator of compromise was found on this machine.
- **Urgency: low.** No keys need rotating because of this. The real risk is the loose `>=1.80` in `pixi.toml`: one `pixi update` at the wrong moment would pull whatever release is newest.

## Incident 1: March 2026 (1.82.7 and 1.82.8)

- **What:** two releases containing credential-harvesting malware were uploaded straight to PyPI, bypassing LiteLLM's CI/CD. [LiteLLM blog](https://docs.litellm.ai/blog/security-update-march-2026), [GitHub issue #24518](https://github.com/BerriAI/litellm/issues/24518)
- **When:** 24 March 2026, live from 10:39 UTC. PyPI quarantined the packages about 40 minutes later. LiteLLM gives 10:39 to 16:00 UTC as the window in which an install could have picked them up. [LiteLLM blog](https://docs.litellm.ai/blog/security-update-march-2026)
- **Cause:** a stolen PyPI publishing credential, linked to the compromised Trivy security scanner (the TeamPCP campaign). [OSV PYSEC-2026-2](https://osv.dev/vulnerability/PYSEC-2026-2), [GitHub issue #24518](https://github.com/BerriAI/litellm/issues/24518), [Wiz](https://www.wiz.io/blog/teampcp-attack-kics-github-action)
- **How each version triggered:**
  - 1.82.7 hid its payload in `litellm/proxy/proxy_server.py`. [PyPI inspector](https://inspector.pypi.io/project/litellm/1.82.7/packages/79/5f/b6998d42c6ccd32d36e12661f2734602e72a576d52a51f4245aef0b20b4d/litellm-1.82.7-py3-none-any.whl/litellm/proxy/proxy_server.py#line.130)
  - 1.82.8 also added `litellm_init.pth`, which runs on every Python start. [PyPI inspector](https://inspector.pypi.io/project/litellm/1.82.8/packages/f6/2c/731b614e6cee0bca1e010a36fd381fba69ee836fe3cb6753ba23ef2b9601/litellm-1.82.8.tar.gz/litellm-1.82.8/litellm_init.pth#line.1)
- **What it stole:** environment variables, SSH keys, Git and Docker credentials, `.env` files, cloud tokens (AWS, GCP, Azure, metadata servers, AWS Secrets Manager), Kubernetes tokens, database passwords, shell history and crypto wallets. It encrypted the data and POSTed it to `models.litellm[.]cloud`. For persistence it installed a systemd "System Telemetry Service", which contacts `checkmarx[.]zone`. [OSV PYSEC-2026-2](https://osv.dev/vulnerability/PYSEC-2026-2), [LiteLLM blog](https://docs.litellm.ai/blog/security-update-march-2026)
- **Not affected:** the official `ghcr.io/berriai/litellm` Docker image, LiteLLM Cloud, and installs from GitHub source. [LiteLLM blog](https://docs.litellm.ai/blog/security-update-march-2026)
- **Clean versions:** 1.82.6 and earlier; LiteLLM audited 1.78.0 to 1.82.6. 1.83.0 (30 March) was the first release from the rebuilt pipeline. [LiteLLM blog](https://docs.litellm.ai/blog/security-update-march-2026), [CI/CD v2](https://docs.litellm.ai/blog/ci-cd-v2-improvements)
- **Advisory IDs:** [GHSA-5mg7-485q-xm76](https://osv.dev/vulnerability/GHSA-5mg7-485q-xm76), [PYSEC-2026-2 / MAL-2026-2144](https://osv.dev/vulnerability/PYSEC-2026-2).
- **What users were told to do:** rotate every secret on the affected host, look for `litellm_init.pth` in site-packages, audit CI and Docker builds for 1.82.7 or 1.82.8, and pin versions. [LiteLLM blog](https://docs.litellm.ai/blog/security-update-march-2026)

## Incident 2: 21 October 2026 (1.107.0)

- **What:** LiteLLM's own release pipeline was hijacked. It published `litellm==1.107.0`, built from a lookalike repository `Berri-AI/litellm` at commit `20535d8f`, to PyPI, Docker Hub and GHCR. The official v1.107.0 source tag is clean. [Incident post](https://docs.litellm.ai/blog/security-incident-oct-21-2026)
- **How the attacker got in:** an Agent Platform master key was committed to a public repository in May and never revoked. On 10 October it was used to obtain a GitHub org owner's CLI OAuth token. CI workflows then exfiltrated other maintainers' tokens, which were used to approve the release. [Attack-chain post](https://docs.litellm.ai/blog/security-incident-oct-21-2026-attack-chain)
- **Live windows (UTC, 21 Oct):** [Incident post](https://docs.litellm.ai/blog/security-incident-oct-21-2026)
  - PyPI: 7 wheels from 11:39:51 to about 13:23.
  - Docker Hub (`v1.107.0`, `latest`, `main-latest`, `main-stable`): 11:46:56 to 14:20, image index `sha256:1bbcb1443bc962e45f5aad53fe3d2c30600e0379715fb6c664cdd3ac126c339e`.
  - GHCR (`litellm`, `litellm-database`, `litellm-non_root`): until 13:51.
- **What it did:** compiled malware that steals credentials and loads remote-code-execution tools. It runs on any Python start through `cook.pth` and `sitecustomize.py`, and leaves a detached daemon holding `/tmp/remote_code_loader.lock`. LiteLLM says: "If 1.107.0 was ever installed on a host with outbound internet, assume the exfil succeeded." [Incident post](https://docs.litellm.ai/blog/security-incident-oct-21-2026)
- **Indicators of compromise:**
  - Files: `cook.pth`, `cook.py`, `sitecustomize.py`, `__pycache__/cook*.pyc`, `litellm-1.107.0.dist-info` [Incident post](https://docs.litellm.ai/blog/security-incident-oct-21-2026)
  - Attacker IPs: `69.48.229.143`, `199.91.221.39`; exfiltration to `webhook.site` [Attack-chain post](https://docs.litellm.ai/blog/security-incident-oct-21-2026-attack-chain)
- **Safe:** pin `litellm==1.106.2` or any earlier explicit version. LiteLLM says "All previous versions are safe." [Incident post](https://docs.litellm.ai/blog/security-incident-oct-21-2026)
- **What users were told to do:** don't run `pip` inside the affected environment (that starts Python, which reruns the malware). Delete the IoC files, kill the daemon, rebuild from scratch pinned to 1.106.2, and rotate everything the host could reach: cloud roles, every provider key in the proxy database, master and virtual keys, `DATABASE_URL`, and every environment secret. [Incident post](https://docs.litellm.ai/blog/security-incident-oct-21-2026)
- **No GHSA ID found** for the October incident yet; LiteLLM's blog is the primary source.

## omxconsole's exposure (checked on this machine, read-only)

| Check | Result |
|---|---|
| `pixi.toml` gateway constraint | `litellm = { version = ">=1.80", extras = ["proxy"] }` (no upper bound) |
| `pixi.lock` | litellm **1.103.2**, litellm-enterprise 0.1.69.post1, litellm-proxy-extras 0.4.100 |
| Lock history (`git log -- pixi.lock`) | only 1.103.2 has ever been locked, first in `2c2a3d8` (2026-10-01, F-007); unchanged since 2026-10-11 |
| linux-64 wheel sha256 in lock | `a9d54a0e…55cb`, the same as [PyPI's published hash](https://pypi.org/pypi/litellm/1.103.2/json) for that wheel (uploaded 2026-10-01 06:21 UTC; not yanked; no vulnerabilities listed) |
| Installed dist-info | `.pixi/envs/gateway/.../litellm-1.103.2.dist-info`, installed 2026-10-01 23:15 local, by uv-pixi |
| IoC files in site-packages | none: no `*.pth` at all, no `litellm_init.pth`, `cook.*`, `sitecustomize*` |
| IoC strings in installed code | no `models.litellm.cloud`, `checkmarx.zone`, `litellm_init` (one hit was a false positive: a variable `_litellm_initialize`) |
| Rest of the home directory | no `litellm-1.82.7/8`, `litellm-1.107.0`, `litellm_init.pth` or `cook.pth` anywhere; the only other litellm is 1.103.2 in the rattler uv cache |
| Running processes, lock file | no `/tmp/remote_code_loader.lock`; no suspicious process |
| Docker | couldn't list images (no permission on the socket); omxconsole doesn't use the LiteLLM Docker image anyway |

**Verdict: not affected.** 1.103.2 was published 1 October, three weeks before the 21 October release. LiteLLM says all versions before 1.107.0 are safe, and 1.103.2 is well past the March range. There's one caveat that applies to any package: the attacker held a GitHub org owner's token from 10 October ([attack chain](https://docs.litellm.ai/blog/security-incident-oct-21-2026-attack-chain)), but the 1.103.2 wheel was uploaded on 1 October, before that.

## What omxconsole actually uses LiteLLM for

From `mxconsole/expose.py`, `gateway.py` and `cli.py`:

- **The request path:** client → Caddy (TLS, `forward_auth` against the daemon's `/auth/check`) → LiteLLM on 127.0.0.1 → daemon → `max serve`.
- **What LiteLLM does there:**
  - one route per local model, `openai/<name>`, all pointing at the daemon's `/v1`;
  - a master key, which Caddy injects itself;
  - `drop_params: true`.
- **What it doesn't do:** no external providers, no fallbacks, no spend tracking, no virtual keys.
- **The daemon already covers it:** it serves `/v1/models`, `/v1/chat/completions`, `/v1/completions` and `/v1/embeddings` itself, with app-key checks (`gateway.py`).
- **A bypass already exists:** `mxc expose --no-litellm` points Caddy straight at the daemon.

So LiteLLM is a pass-through hop that adds a large, frequently attacked dependency (the `proxy` extra pulls in hundreds of packages) and one extra key.

## Options

1. **Drop LiteLLM: make `--no-litellm` the default and delete the `gateway` environment** (recommended; Subtract Before You Add).
   - Pros: removes the whole supply-chain surface and a process to supervise; the code path already exists and is tested by `--no-litellm`.
   - Cons: you lose `drop_params` (unknown OpenAI parameters would reach `max serve`; check how it responds, and strip them in `gateway.py` if needed). You also lose any future LiteLLM features (external providers, fallbacks, budgets).
2. **Keep LiteLLM but pin it exactly, with hashes:** `litellm = { version = "==1.103.2", extras = ["proxy"] }`, keep the lock committed, and never run a blanket `pixi update` on the gateway environment.
   - Pros: no code change; the lock already records sha256 for every wheel.
   - Cons: the hundreds of transitive dependencies of `litellm[proxy]` are still a surface. Every upgrade needs a manual check against LiteLLM's security blog. LiteLLM itself only supports the four newest stable lines ([version support](https://docs.litellm.ai/blog/version-support)).
3. **Vendor a minimal router into the daemon:** if routing to several backends is ever needed, a model-name → upstream table in `gateway.py`, using the httpx forwarding it already has.
   - Pros: tens of lines, all your own code.
   - Cons: you maintain it, and adding providers like Anthropic or Bedrock means writing translation code yourself.
4. **Other gateways** (Envoy AI Gateway, Portkey, etc.): no advantage for a local single-backend LAN gateway, and each is another dependency to watch. Not recommended.

## What the owner must do personally

- **Nothing urgent:** no key rotation is needed for these incidents, because no affected version was installed.
- **Optional hygiene:** if LiteLLM ever ran with real secrets in its environment, regenerating `~/.mxc/expose/litellm_master_key` is cheap but not needed.
- **If you choose option 2:** don't run `pixi update` on the gateway environment without first checking [LiteLLM's security posts](https://docs.litellm.ai/blog/tags/security).
