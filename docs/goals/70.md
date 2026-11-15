# GOAL 70: the newest omxcore engine under omxplorer, and goal 68's robotics compute on it where it wins

**End goal (owner, 2026-11-13):** "check with omxcore to see if you can pull the engine and snap it to your backend for
fast compute." The app vendors omxcore 834ef9a (2026-10-29). omxcore has ~200 commits since (F-201..F-223: faster joins,
COUNT(DISTINCT), GROUP BY over ordered runs, presence-bitmap joins, every core on the Mac, arm64 NEON). Its local main
a9a3c37 is ahead of origin/main f8dbf9e (F-216..F-223 not pushed): vendor a9a3c37, say so, fall back to f8dbf9e only if
a9a3c37 doesn't build.

Base: main 9e3e9d0f (goal 68 in). Worktree ../mojo-ui-g70, branch goal-70-omxcore-engine. Decisions D-70xx. Goal 68's
contract is archived as docs/goals/68.md. omxcore (~/Projects/mxframe) is read-only: sources come out with
`git archive <sha>` only.

## Milestones
| # | Milestone | Proof (`docs/goals/70-check.py`; PASS, FAIL or BLOCKED each) |
|---|---|---|
| M0 | Re-vendor | vendor/OMXCORE_COMMIT names a9a3c37 (not on GitHub yet, said) and how to rebuild it; the Mojo 1.2 patch is rebased as vendor/patches/omxcore-a9a3c37-mojo12.patch with each patched file's reason in the report, and an engine without its libc hunks still clashes with Flare (so they stay); scripts/engine_lineage.py proves vendor/omxcore.mojoc is a build of a9a3c37's archive + the patch; omxplorer and every example whose `needs` says omxcore build for Linux; tests/test_engine_flare (the engine beside Flare) and the engine/frame/SQL tests pass; every Mac app that uses the engine (jobwake, jot, keeper, omxplorer) cross-builds with no undefined symbol that main's objects don't need, and links where main's does (D-7004: main's own omxplorer Mac link has failed since goal 68; goal 5's ALLOWED list is behind main) |
| M1 | Same answers, measured faster | tests/bench_engine_paths.mojo (the app's own query paths: omxplorer's SQL, joins, pivots / group-by, the chart queries) built against the old engine (834ef9a) and the new one, run on goal 68's fleet tables, goal 47's fleet (made by scripts/robot_data.py when the DROID data is on disk) and TPC-H SF1 (DuckDB's dbgen into build/tpch_sf1, D-7005; the 22 queries as omxcore writes them): every answer's text is equal between the two; a timing table (median of 2 interleaved rounds of 5 runs, same machine, same run) in docs/goals/70-bench.md, slower cases kept |
| M2 | Robotics compute on the engine where it wins | each of goal 68's paths (the fleet's every-topic time join at 10 Hz, stops, the Learn tree's row reads, the embedding similarity column with top-k) measured old vs engine on the same data in tests/bench_robotics.mojo; a path moves only if the engine is faster with equal results (mojoui.fleet's tables and Learn's tree equal before vs after); the paths that stay and the operations omxcore lacks are written as asks (operation, shape, size) in the report |
| M3 | Nothing regressed | goal 68's 68-check.py (M0–M6, through docs/goals/68/regress.py: it starts the headless display an archived checker needs), goal 47's check (inside 68's M6), the component matrix, decisions lint, libc and seek lints |

## Done means
70-check PASS for M0–M3 (a BLOCKED says exactly what is missing); a fresh reviewer subagent passes it; vendor/OMXCORE_COMMIT
says how to rebuild; docs/goals/70-report.md with the before/after table, what moved and what stayed, the asks for
omxcore; EXPERIMENTS.md. Committed after each passing milestone; never pushed or merged.

## Out of bounds
Editing, committing, branching or pushing in ~/Projects/mxframe; the other worktrees (../mojo-ui-g69,
../mojo-ui-apple-test, ../mojo-ui-omxcode); pushing; merging; pip (pixi only); lowering a proof or deleting a test; a
faster path with different answers.

## Assumptions (taken instead of asking)
- "The engine/frame/SQL tests" are the tests/ programs that import omxcore and run without arguments or downloads
  (as in the 834ef9a re-vendor: docs/goals/engine-834ef9a/report.md).
- The Mac is cross-built here (link + undefined-symbol audit); running it needs GitHub's Macs or the owner's: unverified.
- TPC-H SF1 is generated here (DuckDB dbgen, DATE and DECIMAL columns); omxcore's data/tpch_sf1 stores int32 days and
  float32 prices, which the app's SQL refuses to compare with dates (D-7005). Its queries are read from omxcore's
  scripts/tpch_sql/queries.py at a9a3c37 (read only, no bytecode written).
