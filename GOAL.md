# GOAL 64: the two things omxconsole still can't do

**End goal (owner, 2026-11-07):** omxconsole's cover page admits two things the earlier Python version did and the
Mojo one doesn't: **porting a model MAX can't run**, and **reaching the endpoint from another machine over HTTPS**.
Both buttons are still in the app, so a stranger who downloads the alpha clicks them and hits a dead end. "Kind of
embarrassing not to… yes please copy this." Copy the decisions of the working Python version (`~/Projects/mxstudio`,
read-only), re-expressed in Mojo: the orchestration (stage machine, gates, attempt and early-stop rules, SQLite rows,
log format, Caddyfile, process supervision) lives in `examples/consoled/`. No Python ships inside omxconsole; the only
Python is what we drive as external programs, as the old version did (Claude Code, Modular's skill scripts, `max
serve`, `pixi`, `caddy`) and the generated port itself, which is MAX's own format.

Measured on the owner's 14 real runs (`~/.mxc/ports/`, read-only): 8 ported and served (gpt2, pythia-1.4b, phi-2,
starcoder2-3b, OLMoE-1B-7B, granite-3.1-1b MoE, SmolLM3-3B), 6 failed, and everything that worked was 1–3B. So both
features ship labelled **beta**, with that real hit rate in the app, not a vague badge.

Base: origin/main 2abf5775 (after goal 62).

## Milestones
| # | Milestone | Proof (`docs/goals/64-check.py`; PASS, FAIL or BLOCKED each) |
|---|---|---|
| M0 | The porting assistant setting | A Settings card: Claude Code on this machine (detected, no key), or an API key for a frontier model (Anthropic, or an OpenAI-compatible base URL). Frontier models only; the user's own small local model is never offered as the porter. The key is stored for omxconsole only, mode 0600, never logged, never shown in full (prefix only), never in a URL, and removable. Proved against a stand-in server, never a real key: POST/GET/DELETE the setting, the file's mode is 0600, the plaintext appears in no log, no response and no stored row but its own file, and a wrong key fails the small test call in seconds |
| M1 | Guided, not a dead end | Clicking "Port it" with nothing configured opens that card **inline on the port screen**, not a bounce to Settings: it says what was detected, takes the choice, saves it, and the button becomes "Port it". The daemon's small test call happens first, so a bad key fails in seconds. GTK step run with screenshots, looked at, plus the web host |
| M2 | The worker | `POST /admin/ports` runs the pipeline and writes stages and the log where `ports_json` and the existing screen already read them; `GET /admin/ports/<id>`; cancel really stops the agent and its children. Proved with no GPU and no real port, with the old project's fake-port harness re-used (a fake `claude`, fake skill gates, fake `max`, and the tiny `WeirdForCausalLM` fixture): the seven stages land in order with their attempt numbers, the log streams `== stage`/`-- stage done` lines, a build failure feeds the error back and the next attempt fixes it, the same failure twice stops early, cancel leaves no process of ours running |
| M3 | When it fails, hand it over | The failed job and the screen give: the workspace folder, the full log path, the exact gate that failed, and the best attempt kept. Proved on a fake run that always fails: `GET /admin/ports/<id>` carries all four, and a GTK step run shows them on the port screen |
| M4 | Reach it on your network | `POST /admin/expose` writes a Caddyfile with `tls internal` and `forward_auth` to the daemon's `/auth/check`, runs Caddy through `mojoui.process`, and `POST /admin/expose/stop` really stops it. `/auth/check` answers 200 with `X-Mst-App` for a valid app key and 401 for none or a revoked one. Caddy is found, not bundled: when it is missing the answer says so with how to install it. Proved on this machine from a second process: `https://localhost:8443/v1/models` with a valid key works, without one is 401, a dot-segment path is 400, and localhost over plain HTTP still works; stop leaves nothing listening |
| M5 | Honest labels and no regressions | Both features marked beta in the app and on `docs/omxconsole.html`, with the 8-of-14 hit rate; the cover's honest-edges section no longer says these two are missing. Goal 55's check (the console's own milestones) and the console's Mojo tests still pass, and `docs/components.md` is fresh |

## Done means
`docs/goals/64-check.py` prints PASS for M0–M5 (BLOCKED only where this machine genuinely can't: no GPU-hours
real port run, which needs the owner's machine and hours); the `reviewer` and `security-auditor` subagents pass;
`docs/goals/64-report.md` and an `EXPERIMENTS.md` entry; merged into main and pushed only if all of that holds.

## Out of bounds
A real multi-hour porting run (the fake harness is the proof; a real one is the owner's GPU and hours → BLOCKED).
Real API keys, sign-ups, releases, deploys. `~/Projects/mxstudio` and `~/.mxc` are read-only references; the owner's
daemon on :11435 is never touched. `mojoui/hosts/web.py` belongs to another session. The frozen
`../mojo-ui-apple-test` and other worktrees are never touched. Never the words "LM Studio" in anything public.

## Assumptions (taken instead of asking)
- The porter is a frontier model only (owner's steer). Claude Code on the machine is preferred when present.
- `port_try` (the old project's agent-facing "see it run" helper, Python) becomes a subcommand of our own Mojo
  daemon binary rather than travelling as Python (D-6403).
- Arbitrary flags, patches and timeouts earned by the 14 real runs are kept verbatim and logged as kept (D-6404).

## Budget
140 turns.
