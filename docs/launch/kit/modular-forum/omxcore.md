# Modular forum: omxcore, the engine (Thursday Nov 5)

**Where:** forum.modular.com → **Community Showcase** (it's a project post; the MAX/GPU people read it there too). Tags if
offered: `gpu`, `sql`, `showcase`.

**Attach:** the TPC-H bars from the talk (part 2, slide 5) or `omxcore-bench.png` under the numbers paragraph; the
`mx sql` notes screenshot (part 1, slide 6) under "shows its work".

## Title (pick one)

1. omxcore: a SQL engine written top to bottom in Mojo, on CPU and GPU
2. A Mojo SQL engine on simplified TPC-H, and where DuckDB still wins
3. What building a SQL engine in Mojo taught me (with the numbers)

*(1 for builders, 2 for clicks, 3 for the Mojo crowd.)*

## Body (copy from here)

Hi all. On Sunday I showed omxplorer, a data app in Mojo. Today it's the engine underneath it: **omxcore**, a SQL engine written top to bottom in Mojo (parser, binder, planner, CPU and GPU kernels, Parquet and CSV readers), with no Python inside. Apps link it like SQLite; agents call `mx` and get JSON back.

[YouTube: omxcore part 1]

**What it does.** Point it at a file and ask:

```sh
mx sql "SELECT region, sum(revenue) AS revenue FROM 'orders.csv' GROUP BY region"
```

The answer comes with notes: the group strategy the planner picked (dense or hashed), the columns it read ("3 of 16"), how many instructions a row the kernel ran, the device. A typo comes back as `{"error":{"message", "line", "column", "hint": "did you mean …"}}`. Money is a scaled int64, so sums match to the cent, and an overflow raises instead of wrapping. Big Parquet files stream a row group at a time (a 1.6 GB file in 72 MB of memory, informal).

**The numbers, honestly.** 22 simplified TPC-H queries at scale factor 10 (not TPC-certified: some predicates and keys are simplified, the same for every engine), run through the Python package 0.6.0 on the CPU (Python only plans; the engine executes), query time only, one fresh process per query, on a shared machine, so indicative: omxcore 3.15 s, DuckDB 5.08 s, Polars 14.40 s, every omxcore answer equal to DuckDB's on the same queries. Q13 does one step in PyArrow, and it's in that total. But Q21 carries that lead: without it DuckDB's total is lower (2.27 s vs 2.41 s), and DuckDB is faster on 12 of the 22, mostly the join-heavy ones. Every query is on the benchmarks page, computed from the CSVs in the repo.

**CPU or GPU.** In Python and the Mojo builder, AUTO prices the CPU against the GPU plus the copy and picks per query (informal, a 20M-row streamed query: 12 cores stay on the CPU; with 2 cores and a heavy plan the GPU wins 2.7×). The GPU path is validated on NVIDIA; Apple's GPU through Metal is checked on GitHub's virtual Macs.

**Where Mojo pushed back, in case it saves you a day:**
- The stdlib `Atomic` is sequentially consistent, so on NVIDIA every accumulation got fenced (~100× slower). We use `llvm.atomicrmw` with monotonic ordering for sums.
- `parallelize` runs tasks with flush-to-zero set, so threaded kernels read denormals as 0 while one thread didn't. Workers now launch through one helper.
- A `List` whose address goes into a kernel call is freed at its last use. It bit us three times; now a script fails the build.
- On Metal, a pointer made from an integer is thread-private: writes vanish with no error. Kernels name the global address space.
- `SIMD.ne` is an ordered compare (`NaN.ne(NaN)` is False). Test NaN with `~x.eq(x)`.

**What it doesn't do yet:** `mx sql` runs SQL on the CPU (`--device gpu` is accepted and the notes say so); TPC-H Q11 needs 128-bit decimal sums (so 21 of 22 through `mx` today); some joins are 3–5× slower than DuckDB (a star-aware planner is next); most engine timings are informal, from a shared machine.

Next: 22 of 22, SQL on the GPU through AUTO, a quiet-machine scoreboard, and 0.7.0 with an MCP server around `mx`.

Apache-2.0:
https://github.com/abhisheksreesaila/omxcore · benchmarks: https://abhisheksreesaila.github.io/omxcore/benchmarks.html

```sh
pip install "mxframe[runtime,sql]"   # 0.6.0 still imports as mxframe
```

If you have a query where DuckDB beats it, please send it: that's how the next ticket gets written.

---

*Sources (not for posting), all in ~/Projects/mxframe: README.md (3.15 / 5.08 / 14.40, 0.6.0), docs/bench/m2s-engine.csv
(SF10 first_ms: without Q21 2,267 vs 2,411 ms; DuckDB faster on 12 of 22; mx-cpu verdicts all ok), docs/bench/m2s-engine.md
(method, Query semantics, Hardware: shared, indicative; Q13 PyArrow F-016), docs/site/bench/engine-informal.json (72 MB, AUTO table, Q5/Q7), docs/omxcore-mojo-api.md ("The mx command
line": errors, device, exact decimals), docs/lessons.md (2026-09-29, 2026-10-16 ×2, 2026-10-19, 2026-10-25), docs/plan.md
(F-191, F-192, F-161, F-169), STABLE.md (21 of 22 through mx). Apple GPU: omxcode docs/decisions.md D-308.*
