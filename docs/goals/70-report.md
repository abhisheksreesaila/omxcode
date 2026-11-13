# Goal 70: the newest omxcore engine under omxplorer (2026-11-13)

Branch `goal-70-omxcore-engine` (worktree ../mojo-ui-g70) off main 9e3e9d0f. The owner's ask: "check with omxcore to see
if you can pull the engine and snap it to your backend for fast compute." Checker: `docs/goals/70-check.py`
(`scripts/check` runs it). Decisions D-7001..D-7007.

## In one paragraph
The app now runs on omxcore **a9a3c37** (the owner's local main: F-216..F-223 are **not on GitHub yet**; origin/main is
f8dbf9e, and the same patch applies there). The Mojo 1.2 patch needed no change but its line offsets. On the app's own
query paths all 47 answers are byte-equal between main (834ef9a) and this branch. Over the steps of 10 ms or more, the
branch is 2.4× faster than main (geometric mean) and the engine alone 1.7×; TPC-H SF1 through the app is up to 14.9×
faster, goal 47's charts and pivots 1.1–1.3×. The new engine had one real regression for this app: a sheet is a
Frame, and since F-158 a Frame is streamed through a join before its filter is counted, so goal 47's "fleet ⨝ 16.8M
telemetry rows" questions ran 5–12× slower. The app now puts an untouched sheet in a query as a plain table (D-7006),
which leaves them 3.5× (Q1) and 1.5× (Q2) slower than main; the rest of that gap is inside the engine and is an ask
below. None of goal 68's robotics computations moved to the engine: on the same data with equal answers, the app's own
Mojo loops (and numpy for similarity) are 2–76× faster, and omxcore lacks the operations that would make it a win
(asks below).

## M0: the re-vendor
- `vendor/omxcore.mojoc`: `git archive a9a3c37` + `vendor/patches/omxcore-a9a3c37-mojo12.patch`, built by this repo's
  Mojo 1.2 (`vendor/OMXCORE_COMMIT` has the rebuild line); `scripts/engine_lineage.py` proves it (a9a3c37 added at the end
  of its lineage, D-7001).
- **The patch** (D-7002): the same 29 hunks as 834ef9a's, identical changed lines, new offsets only. Kept as small as it
  can be: without it a9a3c37 doesn't build on Mojo 1.2; with only its accelerator hunks the engine builds but
  tests/test_engine_flare doesn't link ("existing function with conflicting signature" on `read`); every other symbol it
  looks up has a second declarer in the app's binaries.

| File | Hunks | Why |
|---|---:|---|
| kernels_aot/kernels_aot_gpu.mojo | 2 | Mojo 1.2's `std.sys` has `default_accelerator().is_apple_gpu()`, not `has_apple_gpu_accelerator()` (the build fails without it) |
| kernels_aot/pipeline_gpu.mojo | 2 | the same accelerator query |
| mojo/omxcore/gpu.mojo | 1 | the same accelerator query (`HAS_GPU`) |
| mojo/omxcore/_libc.mojo | 1 (new file) | dlsym lookups for read, write, mmap, munmap, unlink, strtod, pthread_create/join/detach, each called through a typed pointer: an engine declaration of any of them clashes with Mojo 1.2's stdlib, Flare (vendor/flare: pthread_*, read, write, mmap, munmap, unlink), vendor json (strtod) or mojoui (watch: pthread_create; libc: write, unlink) |
| mojo/omxcore/csv.mojo | 5 | strtod (json declares it), read (stdlib and Flare), mmap and munmap (Flare) through _libc |
| mojo/omxcore/fan.mojo | 3 | pthread_create and pthread_join (Flare, mojoui.watch) through _libc |
| mojo/omxcore/job.mojo | 4 | pthread_create, pthread_join, pthread_detach (Flare) through _libc |
| mojo/omxcore/mapped.mojo | 3 | mmap and munmap (Flare) through _libc |
| mojo/omxcore/parquet.mojo | 4 | unlink (Flare, mojoui.libc) and read (stdlib, Flare) through _libc |
| mojo/omxcore/sortspill.mojo | 4 | write, read and unlink (stdlib, Flare, mojoui.libc) through _libc |

- Builds: omxplorer and every example whose `needs` says omxcore (agentchat, analytics, dashboard, jobwake, jot, keeper,
  media, omxplorer, workbook) for Linux; 34 engine tests (tests/ that import the engine or the sheet and run on their own,
  test_engine_flare, the new test_add_sheet, and test_tablejobs — the test of QueryJob/ScriptJob, which this goal changed —
  among them; goal 39's media is generated first, scripts/media_data.py, as goal 49's checker does).
- **The Mac** (D-7003, D-7004): omxcore F-210 made every core the default on macOS, which needs Mojo's async runtime
  (`AsyncRT_*`); the cross-built Mac and iPhone objects link only mojo_rt's stand-ins, so scripts/build.sh's
  apple_objects now passes `-D MXFRAME_SERIAL` (as the engine's own docs say an app without the runtime must). With it,
  jobwake, jot and keeper (the other Mac apps on the engine) cross-build and link, needing no undefined symbol their main
  builds don't, and omxplorer's Mac objects need exactly main's 88. (Goal 5's ALLOWED list is behind main: main's
  jobwake, jot and keeper already need `_pthread_attr_*` from D-792 and `_setenv`, `_fcntl`, `_time` from mojoui, which
  the Mac stub provides; so main's own objects are the reference.) **But omxplorer's Mac link already
  fails on main** (built here with the old engine): goal 68's plugin runner pulls CPython interop
  (`_KGEN_CompilerRT_GetArgV`, `_KGEN_CompilerRT_Python_SetPythonPath`) and mojoui.maxrt/listdir pull `_realpath`,
  `_opendir`, `_readdir`, `_access`, `_system`, `_asin`, `AsyncRT_Device*`… that the Mac stub doesn't provide. That is
  goal 68's follow-up, not fixed here. The native Mac GPU build (MAC_GPU) takes the engine's new default, every core:
  **unrun** (no Mac here).

## M1: same answers, measured
`docs/goals/70/bench_m1.py` builds tests/bench_engine_paths.mojo (read_table → Sheet; SQL through implied_sql +
query_table as the SQL box and the AskBook do; pivots and charts through sheetpage.compute as the cards and the chart
job do) three times, so the engine's change and the app's are told apart (reviewer, round 1): **main** (834ef9a, every
sheet a Frame), **old+sheet** (834ef9a with add_sheet, D-7006; its refuse_wide line left out, a no-op on an engine
without 128-bit columns) and **new** (a9a3c37 with add_sheet: this branch). Data: goal 68's fleet (build/g68/fleet),
goal 47's DROID fleet (63,344 episodes, 16.8M telemetry rows) and TPC-H SF1 (DuckDB dbgen, D-7005). Three interleaved
rounds of 5 runs per build, each round starting with another build; load average 3.7–5.7 on 24 cores (other sessions).
The noise floor is measured, not assumed: charts and pivots never touch the catalog, so main and old+sheet run identical
code there, and they landed up to 1.23× apart. **47 answers, 0 differ across the three builds, 0 refused.** Over steps
of 10 ms or more: the engine alone 1.70× faster, the branch vs main 2.41×. The full table: `docs/goals/70-bench.md`
(written by the run 70-check's M1 passed). The ones that matter:

| Query (the app's path) | main ms | old+sheet ms | new ms | engine | branch |
|---|---:|---:|---:|---:|---:|
| TPC-H Q20 | 232.0 | 54.1 | 15.6 | 3.5× | 14.9× |
| TPC-H Q22 | 84.8 | 113.9 | 8.4 | 13.5× | 10.1× |
| TPC-H Q18 | 362.9 | 320.6 | 46.2 | 6.9× | 7.9× |
| TPC-H Q10 | 145.1 | 79.6 | 19.0 | 4.2× | 7.6× |
| TPC-H Q17 | 66.8 | 29.6 | 11.6 | 2.6× | 5.8× |
| TPC-H Q21 | 252.0 | 262.3 | 48.0 | 5.5× | 5.3× |
| TPC-H Q5, Q7 | 93.8 / 74.3 | 37.5 / 70.2 | 22.4 / 17.9 | 1.7× / 3.9× | 4.2× / 4.2× |
| TPC-H Q8, Q16 | 87.0 / 25.3 | 27.2 / 22.4 | 29.7 / 22.5 | 0.92× / 1.00× (noise) | 2.9× / 1.1× |
| goal 47: average speed by lab, failures (fleet ⨝ telemetry) | 253.7 | 75.5 | 74.6 | 1.0× | 3.4× |
| goal 47: charts and pivots over the fleet | 0.7–19.2 | 0.7–19.7 | 0.5–16.6 | 1.2–1.3× | 1.2–1.3× |
| goal 68's fleet (920 moments): every step | 0.03–0.74 | 0.03–0.64 | 0.03–0.70 | within noise (all under 1 ms) | |
| goal 47 Q2, "within 30% of the arm's speed limit" (JOIN LINKED) | 17.6 | 11.1 | 26.0 | **0.43×** | **0.68×** |
| goal 47 Q1, "failures where the gripper closed, let go and closed again" (JOIN LINKED) | 24.2 | 29.5 | 83.7 | **0.35×** | **0.29×** |

So add_sheet alone already helps the old engine on several joins (Q20, Q10, Q2, the lab-speed join): a plain table's
filter is counted before the join on 834ef9a too. Inside goal 47's own checker (M7, the app on GTK) Q1 took 218 ms and
Q2 31 ms on this branch.

**The regression found, and what the app does about it (D-7006).** omxplorer puts every sheet in a query as a Frame
(`Catalog.add_frame`). Since F-158 (7bb63f9) the engine streams a Frame on the probe side of a join chunk by chunk and
does not count its filter first ("its rows before the filter: the side is not read to count them"). Goal 47's questions
filter 16.8M telemetry rows down to 19 (Q2) or 85k (Q1): 834ef9a built the join on those few rows; a9a3c37 built on the
63k fleet and probed all 16.8M (EXPLAIN ANALYZE: 258 ms of kernel for a COUNT(*) that took 19 ms). Before the fix, Q1
was 146 ms and Q2 207 ms. `mojoui.tablecard.add_sheet` now puts a sheet that nothing has touched (no edits, appended or
removed rows, merges, formulas; not a streamed file) in as its shared table, whose filter the engine counts (a sample of
blocks) before choosing the build side; an edited sheet still goes in as its Frame. tests/test_add_sheet proves both
(and fails with main's add_frame). What is left of Q1 is the deferred probe filter (F-161) computing the text join key
for all 16.8M rows before the filter drops 99.5% of them ("keys 190 ms"); turning fusion off fixes Q1/Q2 (18/15 ms) but
slows ten TPC-H queries up to 3.4× and changes one answer's float rounding, so the default stays and it's an ask.

## M2: goal 68's robotics compute: what moved, what stayed
`tests/bench_robotics.mojo` (+ `docs/goals/70/similarity.py` for numpy's side), same data both ways, medians of 5.
A path moves only if the engine is faster with equal answers. **Nothing moved.**

| path | data | app ms | engine ms | answers | decision |
|---|---|---:|---:|---|---|
| asof | the fleet's every-topic time join at 10 Hz: 6 bags, 21 topics, 115,890 moment cells | 1.6 | 22.2 | equal | stays |
| asof_1m | the same join, one topic of 1,000,000 messages × 3 fields, 100,000 moments | 9.2 | 305.1 | equal | stays |
| stops | stop rows (half-seconds standing still) over 1,000,000 moments | 1.3 | 94.9 | equal | stays |
| learn_reads | Learn's column reads, 100,000 rows × 5 columns | 7.9 | 16.3 | equal | stays |
| similarity_all | every row's cosine to row 0, 100,000 × 384 (app: numpy float32, as plugin_py; answers compared with float64, the engine's) | 15.5 | 62.7 | equal (1e-16) | stays |
| similarity_top10 | its top 10 | 10.0 | 67.4 | equal | stays |

The numbers are the final run 70-check's M2 passed (docs/goals/70-robotics.md, which every M2 run rewrites; the
log is build/g70/m2.log). Across runs the ratios moved (as-of 13–14×, stops 70–76×, similarity 4–6×), never the decisions.

Why each stays:
- **asof**: omxcore has no ASOF JOIN (refused by name) and no `IGNORE NULLS`; the engine way is a UNION of the topic's
  and the moments' times, a running `MAX(row) OVER (ORDER BY t, kind ROWS UNBOUNDED PRECEDING)`, then reading the values
  by that row. `topic.*` in that query is refused for a 40-field topic ("more than 48 registers"). The app's merge scan
  is O(n + m) in one pass; even the engine's query alone (no table building) is about 6× slower on the real bags.
- **stops**: a run-length state machine; the engine's gaps-and-islands (a running SUM window, ROW_NUMBER per island)
  is two sorts and two windows over a million rows.
- **learn_reads**: the engine way (Frame.bake, then Table.values) copies the whole table first; the cell-at-a-time
  reads it replaces are already cheap (8 ms for 500k cells). Kept.
- **similarity**: omxcore has no vector column, no dot product, no CROSS JOIN (to bring row 0's vector in as a table)
  and holds at most 64 distinct constants a query (48 in practice: the engine adds its own), so the 384-term dot product
  is 8 queries plus a top-10 query. numpy's BLAS matvec (the app's path today, mojoui/plugin_py.py) is 4–7× faster.

## Asks for omxcore
For the robotics brief (~/Projects/mxframe/docs/briefs/robotics.md, draft). Sizes are what this app has today; the
brief's LeRobot/DROID scale is 10–1,000× more.

1. **As-of join** (`ASOF JOIN … ON a.t >= b.t` or a `join_asof(left, right, on=t, by=run)`): left = a regular clock
   (10–30 Hz moments, 100k–10M rows), right = 20–50 topics per run, each 1k–1M rows × 3–40 number fields, sorted by time,
   partitioned by run. Output: the right's last row at or before each left time (and optionally a tolerance). Today the
   app does it in a Mojo merge scan (8–9 ms for 1M × 3 → 100k).
2. **Wide select lists**: a 40-field topic (`SELECT w.t, topic.*`) is refused ("more than 48 registers"); robot topics
   (Odometry, Imu, JointState) are 10–60 fields.
3. **Vector columns and top-k by similarity**: a FLOAT32[384–768] column (EmbeddingGemma 2 is 768 wide), `dot(a, b)` /
   `cosine`, and `ORDER BY dot(v, :q) DESC LIMIT k` as one fused matvec + top-k (on the GPU when it's there). Shape:
   100k–10M rows × 384–768. Today: numpy, 10–16 ms for 100k × 384 on the CPU. Without it, also: more than 64 constants a
   query, and CROSS JOIN (refused).
4. **Run-length / sessionization**: "stretches where a condition holds for at least N rows" (`stops`) as one pass
   (MATCH_RECOGNIZE-like, or a `runs(cond)` window). 1M moments: the app's loop takes 1 ms, the window way 78–95 ms.
5. **`IGNORE NULLS`** in `LAST_VALUE` / `LAG` (forward fill): refused by name; it is the plain-SQL as-of join.
6. **A Frame's selective filter is counted before the build side is chosen** (F-158): an in-memory Frame that probes a
   join is streamed uncounted, so a 0.0001%-selective filter on 16.8M rows made it the probe side (Q2 18 → 207 ms). The
   app works around it for untouched sheets (D-7006); an edited sheet still pays.
7. **The deferred probe filter (F-161) keys only the rows that pass**: goal 47's Q1 spends 190 ms mapping 16.8M text
   join keys of which 85k pass the filter (834ef9a: 2 ms of keys after filtering first). Q1 is 3.5× slower than main
   even as a plain table, Q2 1.5×.
8. **Text join keys on a streamed probe**: the fleet ⨝ telemetry COUNT(*) spends 8.6 ms on keys for 63k text keys
   (834ef9a: 1.3 ms).

## M3: nothing regressed
PASS: goal 68's checker M0–M6 (run M3 first: its M0 and M2 open a video its M3 writes, D-7008), whose M6 runs goal 47
M0–M8, goal 59 M1–M2, goal 62 M1, the component matrix, the message ranges and the seek lint; then the decisions and
libc lints and the matrix again. Goal 68's stopwatch on this branch: a tree file 0.1 s paste → answer, ViT 6.9 s, YOLOS
4.9 s; Learn on 100,000 rows 55 ms, relearn 57 ms.

## What is unverified
- Any Mac run: the cross-built Mac objects are checked for undefined symbols only; omxplorer's Mac link fails on main
  already (goal 68); the native Mac GPU build's every-core default is unrun.
- The iPhone: no example that uses the engine lists ios in its platforms, so no engine code reaches an iPhone build
  (CLAUDE.md's `llvm-nm -u` rule has nothing new to record); the flag is in apple_objects for when one does. Not built.
- a9a3c37 exists only in the owner's checkout; if it is rebased or lost, f8dbf9e is the fallback (the patch applies
  cleanly there; not built).
- Timings were taken beside other sessions' load (load average 5–9 on 24 cores); the builds' runs were interleaved so all saw it.
