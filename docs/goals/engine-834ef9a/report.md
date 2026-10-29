# omxcore 834ef9a in omxcode (2026-10-29)

Branch `engine-834ef9a` from `release-2026-10-29`. The engine is vendored as `vendor/omxcore.mojoc` (built from a clean
`git archive 834ef9a` with this repo's Mojo 1.1), `vendor/OMXCORE_COMMIT` names it, and every module and test writes
`from omxcore import` (D-770). Stables taken in: 2585dc9, 8017543, 5053a44, 5e4cdb1, 834ef9a.

## What changed in the app
| What | Why |
|---|---|
| `mxframe.mojoc` → `omxcore.mojoc`, `MXFRAME_COMMIT` → `OMXCORE_COMMIT`, needs files, build.sh, mxbuild.sh, engine_lineage.py, gpu_audit.py, goal 19's check | 834ef9a is the last stable that still builds the old name (D-770) |
| Formula columns undo through the package's own log (mojoui/sheet.mojo) | 2585dc9 logs formula steps itself; with the sheet's own log too, an undone formula could come back on the next Undo (D-771, tests/test_streamed.mojo) |
| gpu_audit reads a launch-sized kernel's named bound for Apple | omxcore#19 named the per-target limits; 3d2455d still fails the audit, 834ef9a passes (D-772) |
| `.pixi` untracked | a fresh clone's `pixi install` failed on the committed symlink (D-773) |
| README's Try it starts with `git clone` | a stranger starts there |

## Proof
| Check | Result |
|---|---|
| Engine tests (tests/ that import omxcore or the sheet: 15 run, the dump tools need arguments and run inside goals 29/30) | PASS |
| omxplorer builds: Linux, web, Mac (cross); every example for every platform it lists | PASS |
| Apple objects' undefined symbols vs goal 5's ALLOWED (omxplorer, maccheck, kit mac+ios) | nothing new |
| omxplorer, 1M sample (GTK headless through scripts/omxplorer.sh, and web): Sum, far rows, sum by carrier, median by product largest first, median by region over 100 vs pyarrow (`1m-*.png`) | equal |
| omxplorer, 100M parquet (GTK and web): streamed, status-bar Sum 475,055,797,946.39 (pyarrow: the same), chart by region (`100m-*.png`) | equal |
| Goal 20 M1, M2 (100M streamed vs pyarrow, peak 0.37 GB) | PASS |
| Goal 29 M0–M4 (1M: 0.5 / 6.4 / 5.8 ms; 100M in memory 45.9 / 680.8 / 485.2 ms, as on 3d2455d) | PASS |
| Goal 30 M0–M4 (100M on GTK, the window keeps drawing) | PASS |
| Goal 32 M6 | see EXPERIMENTS.md (needs the Mac run's GPU probe) |
| Fresh clone (~/.cache/fresh-clone): README's pixi install, scripts/omxplorer.sh (headless), scripts/omxplorer.sh web | opens, computes (`fresh-clone-*.png`) |
