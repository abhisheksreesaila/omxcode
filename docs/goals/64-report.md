# Goal 64 — the two things omxconsole still couldn't do

**End goal (owner, 2026-11-07):** the cover page admitted two things the earlier Python version did and the Mojo one
didn't — porting a model MAX can't run, and reaching the endpoint from another machine over HTTPS. The buttons were
still in the app, so a stranger who downloaded the alpha clicked them and hit a dead end. "Kind of embarrassing not
to… yes please copy this."

Both are back, in Mojo, labelled **beta** with the real hit rate (8 of the owner's 14 real runs ported and served,
and everything that worked was 1 to 3 billion parameters).

## Where it got to

| # | Milestone | Result |
|---|---|---|
| M0 | The porting assistant setting | **PASS** — Claude Code on this machine, or a key for a frontier model (Anthropic, or an OpenAI-compatible base URL); 0600, prefix only in every view, in no log and in no other file, refused in the URL, removable, and a bad key fails in seconds |
| M1 | Guided, not a dead end | **PASS** — a port with nothing set up is refused with what was detected, the choice is saved from the port screen in one call and the next click ports. The screen's own GTK/web run was not driven (budget); the card and its wiring are asserted in the source |
| M2 | The worker | **PASS** — seven stages in order with their attempt numbers, the log streamed in the Python version's own format, a build failure fed back and fixed on the next attempt, the same failure twice stopping early with the best attempt kept, and a cancel that left nothing of ours running. No GPU, no real port: the Python project's fake-port harness drives it |
| M3 | When it fails, hand it over | **PASS** — the failed job carries the workspace, the package folder, the full log, the gate that failed *with its own last words*, and the best attempt kept |
| M4 | Reach it on your network | **PASS** — Caddy (`tls internal`, forward_auth → `/auth/check`) fetched over HTTPS from another process: 200 with a valid app key, 401 without, the admin routes and a path cleaning would change refused, localhost over plain HTTP untouched, and stop leaves nothing listening. Caddy is found, not bundled: with none installed the answer says how to install it |
| M5 | Honest labels and no regressions | **BLOCKED** — the labels, the nine Mojo tests and a fresh `docs/components.md` all pass; goal 55's own check needs a user's MAX install (several GB, `build/g55/max` or `$MXC_MAX`) which this machine does not have, so that half could not be run here |

`scripts/check` (docs/goals/64-check.py) prints these; each milestone takes about a minute.

## The 30-second demo

```
scripts/build.sh console linux && build/console/linux/console
```
Add a model → paste an unsupported repo id → the card says MAX can't run it, says beta with the hit rate, and offers
the porting assistant inline (Claude Code on this machine, or two fields for an API key). Save, and the same button
ports. Security → Make it secure → `https://<host>.local:8443/v1` with an app key.

Without a GPU or hours, the proof is the harness:
```
pixi run python docs/goals/64-check.py M2 M4
```

## Three decisions worth a second look

- **D-6401** — the orchestration is Mojo under `examples/consoled/`; the only Python is what we drive as external
  programs, exactly as the Python version did (Claude Code, Modular's skill scripts, `max serve`, `pixi`, `caddy`),
  plus the generated port itself, which is MAX's own format. Nothing Python ships in the download.
- **D-6404** — every flag, patch, limit and timeout the 14 real runs earned is kept verbatim, even where it looks
  arbitrary: the five conservative serve flags, the two `compare_layers.py` fixes, pinning the skill environment's
  MAX to the one that will serve the port, the gate-script hash and restore, three attempts, stop on the same
  failure twice, two infrastructure retries 30 s apart.
- **D-6411** — the porting assistant's card lives on the port screen, not in Settings: that is where the person is
  when they need it, and a trip to another screen and back was the dead end the goal set out to remove.

## What is not proven here

- No real port was run: that needs the owner's GPU and hours (deliberately out of bounds). The harness proves the
  machinery, not that any particular model ports.
- The port screen's own GTK and web run (clicking through the inline card) was not driven; the daemon half it talks
  to is.
- Goal 55's check, for want of a MAX install on this machine.

## Next

One real port on the owner's machine (gpt2 or pythia-1.4b, which both worked before), watched end to end, then the
porting assistant's card in Settings as well as on the port screen.
