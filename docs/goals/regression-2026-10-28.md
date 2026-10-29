# Night regression, 2026-10-28 → 29

Branch `regression-2026-10-28` (from origin/main b233357), worktree `~/.abode/home/worktrees/mojo-ui/t3-b5fb6548`, its own
pixi env. Three full passes: a baseline on main, a pass after the first fixes, and a final pass on e31866b's parent
(c9a7bdb, see "Particles" below). Mac runs on GitHub's Macs: 40829521876 (baseline), 40836799290, 40872704059 (final,
fresh for the final sources). Each archived milestone ran once per pass; the "nothing regressed" milestones that only
re-run others (35 M4, 34 M4, 34b M3) were covered by running their parts. Not run: Mojo 1.2 / flare (goal 37).

## Final result (c9a7bdb, Mac run 40872704059)

| Check | Result |
|---|---|
| Goal 36 (current GOAL) M0–M3, M6b, M6c | PASS |
| Goal 36 M4, M6, M7 | FAIL: stale measurements (owner) |
| Goal 36 M5, M8 | PASS on main's particles source; FAIL with D-767's particles change (see "Particles") |
| Goal 35 M0–M3 | PASS |
| Goal 34 M0–M3 | PASS |
| Goal 34b M0, M1, M1b, M1c, M2 (Mac) | PASS |
| Goal 33 M0–M7 (M7: web ≥ 99 % on all 20 shots, GTK 0 of 1425 and Mac 0 of 1268 boxes off) | PASS |
| Goal 33 M8: gallery, goal 32 M0–M2 and M7, goal 30 M0–M5 with goals 3–29 inside | PASS (6378 s) |
| Goal 32 M3, M4, M5 | FAIL: never passed (goal 32 was set aside for goal 33 with these open) |
| Goal 32 M6 | FAIL: an MX frame engine kernel (owner / omxcore) |

## Baseline failures and their causes

| Where | Cause | Fix |
|---|---|---|
| 36 M4, M6, M7 | results.json, results-desktop.json and present-desktop.json were measured at 12:29; 197040f (12:31, review round 2) changed a docstring in mojoui/app.mojo, so the source hashes differ | none: needs the desktop and the quiet gate (owner) |
| engine_lineage, gpu_audit | assumed the MX frame checkout at ../../mxframe | `$MXFRAME_REPO` (D-755) |
| 34b M1b, 33 M4 | docs/components.md stale since goal 35's review: agentchat builds GenUi through mojoui.agentui | the matrix follows an app's mojoui imports to real calls (D-758) |
| 33 M0, then 33 M7 (gateway 90–94 %, security 96 %) | mxstudio's F-063 (2026-10-28 10:58) changed the original console (no LiteLLM, asks /admin/caddy/log); M0 re-shot orig/ from it | goal 33 reads the original it measured, 798ef8c (D-760) |
| 32 M1 (in a fixes worktree) | the web drag flaked: 3 of 12 runs lost moves; the web golden itself held a lost-moves run (2×2, GTK 3×3) | web host fix + golden re-taken (D-761) |
| 33 M8, 32 M3–M5 (crash) | no check builds maccheck for Linux/web | goal 32's shoot builds it (D-762) |
| 33 M8 (crash) | goal 30 M2 saved into build/g30 before anything made it | D-763 |
| 33 M8 (crash) | goal 27 M1 parsed web.py's inline CSS; goal 34 M3 (5b28808) moved it to mojoui/hosts/static/mojoui.css | read it there, no other .css allowed (D-764) |
| goal 14 M1 (in 33 M8) | the matrix read only web.py, so three web rows went ❌ when the CSS moved (toolbar button, Toolbar · FormulaBar · StatusBar, phone-width list) | the web host's source includes the sheet it serves (D-765) |
| 30 M1/M3/M4, 29 M4 | the 100M parquet and the 1M CSV live in other checkouts | copied from mojo-ui-console's build/; 29 M4 looks in build/ too (D-766) |
| goal 5 M9 / goal 3 M6 (in 33 M8) | agentchat and particles import std.os / std.sys (goals 35, 36) | mojoui.shared arguments(), exit_with() (D-767) |
| goal 14 M4 (in 33 M8, once) | load flake: passed twice alone, and inside the final pass | none (recorded; it flaked once in goal 33 too) |
| 32 M6 | gpu_audit can't size `external_memory` in MX frame 3d2455d's pipeline_kernel and group_shared_kernel; group_shared_kernel can launch with up to 48 KB (SHARED_MAX_GROUPS 12288 × 4) with no Apple guard, over Metal's 32 KB. Failing since 3d2455d was vendored (2026-10-25); goal 33's M8 never re-ran 32 M6 | none: an engine (omxcore) matter, not patched here |

## The owner's list
- **D-579** done (D-759): GTK toolbar icon buttons take the Look's icon_w, 32 (were 34; now measured 32 like the web
  and the Mac); goal 32's GTK goldens re-taken (they were 0.45–0.93 % off; two re-shoots after: 0.000 %); goal 27's
  kit-web and kit-graphite-web re-taken into docs/goals/27/golden (+ golden2 for noise) and compared at HEAD, the
  exemption dropped. Before/after: `golden32-*-before-after.jpg`, `golden27-*-before-after.jpg` here.
- **Goal 33 round 2** should-fixes: an env header's value with a control character (D-756); goal 6 M7's Mac clock
  proven by behaviour: maccheck's input-free page changes with a rising canvas version on GitHub's Mac (D-757).

## Particles
D-767 moved particles' `argv`, `exit` and `getenv` onto mojoui.shared. With it, goal 33 M8's whole chain passes (goal
36 M3 still "C: ok"), but goal 36 M6 proves the measured app unchanged beyond its GPU-canvas line, and M5/M8 print its
code from the file. So the particles change waits on branch `regression-particles-imports` for the owner's
re-measure, and this branch keeps the measured source. Until then goal 5 M9 / goal 3 M6 fail on particles alone,
and so does goal 33 M8.

**2026-10-29:** landed on branch `particles-remeasure` with the owner's re-measure (D-768): goal 36 M0–M8 PASS on
fresh results, goal 5 M9 and goal 3 M6 PASS. JS + Rust/wasm's desktop row came back capped at one refresh (D-769).

## Reviewer
Round 1 NEEDS WORK (a stale Mac run after look.mojo; the matrix counted definitions) → fixed; round 2 PASS (three
small should-fixes, done); round 3 PASS (two wording nits, done).

## Commits
1d7f247 97bc2d2 1b089ec 3f792ed 14ed4e4 ed1fd14 01d96b3 78dcb7a 8a10efa 21c8be2 8471fb4 9adccc6 412c393 c9a7bdb e31866b
(D-755 – D-767).
