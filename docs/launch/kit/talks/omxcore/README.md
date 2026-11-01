# omxcore talks: SQL on your CPU and your GPU

Two decks, each complete with its own intro and outro. Open `part1/index.html` or `part2/index.html` in a browser, press
`S` for speaker notes, arrow keys to move. Built from `../_src/omxcore-part*.html` by `../build.py`.

| Part | Deck | Slides | Length (notes at 150 wpm) |
|---|---|---|---|
| 1 | [part1/](part1/index.html) · what it is and how a query runs | 13 | about 4 min |
| 2 | [part2/](part2/index.html) · the code, TPC-H, the honest edges | 13 | about 3.5 min |

Record part 1 if you record only one. Both run on their own; part 2's intro mentions part 1 in one line.

**Before recording:** slide 6 of part 1 is a real `mx sql` run (2026-11-01). If you want to run it live instead:
`cd ~/Projects/mxframe/data/tpch_sf1 && ~/Projects/mxframe/build/mx sql "SELECT l_returnflag, sum(l_extendedprice) AS revenue, count(*) AS n FROM 'lineitem.parquet' WHERE l_quantity < 24 GROUP BY l_returnflag ORDER BY l_returnflag"`.
The TPC-H 3.15 s is a **CPU** run of the Python package 0.6.0 (Python only plans) over 22 **simplified** queries (not TPC-certified, shared machine, indicative); say "simplified" and "on the CPU" every time you say it.

## Part 1 · SQL on your CPU and your GPU

**Titles (≤ 60 characters)**
1. A SQL engine written entirely in Mojo, on CPU and GPU (53)
2. omxcore: SQL over your Parquet files, no Python inside (54)
3. How a Mojo SQL engine runs a query, kernel and all (50)

**Thumbnail:** the `mx sql` notes on the right, big text **SQL IN MOJO. CPU + GPU.**, small mono line `3 of 16 columns read · 9 instructions a row`.

**Description**
```
omxcore is a SQL engine written top to bottom in Mojo, with no Python inside. Point it at the CSV and Parquet files you already have and ask; it runs on your CPU or your GPU, and every answer says what the planner decided. This part covers what it is, how a query runs (from the file to one kernel program), a real mx sql run, errors an agent can fix, exact decimals, streaming files bigger than memory, how AUTO picks CPU or GPU, and the engine inside omxplorer.

Code (Apache-2.0): https://github.com/abhisheksreesaila/omxcore
Benchmarks, query by query: https://abhisheksreesaila.github.io/omxcore/benchmarks.html
omxlabs: https://omxlabs.tech

Chapters
0:00 SQL on your CPU and your GPU
0:24 Why: the GPU naps, data is in files, agents can't squint
0:44 A library, like SQLite
1:03 One language, top to bottom
1:21 A query, as it runs
1:42 A real mx sql run
2:06 Errors an agent can fix
2:22 The GPU kernel
2:41 Money is a scaled integer
3:01 Files bigger than memory
3:16 AUTO: CPU or GPU
3:32 Inside omxplorer
3:49 Try it
```

## Part 2 · The numbers, and the honest edges

**Titles (≤ 60 characters)**
1. Mojo SQL engine vs DuckDB on simplified TPC-H, honestly (55)
2. omxcore vs DuckDB on simplified TPC-H: where it loses (53)
3. What Mojo taught me building a SQL engine (41)

**Thumbnail:** the TPC-H bars, big text **3.15 s vs 5.08 s**, small line `DuckDB still wins 12 of 22`.

**Description**
```
Part 2 of omxcore, the SQL engine written in Mojo: the Python, Mojo and SQL APIs, 22 simplified TPC-H queries at scale factor 10, not TPC-certified (3.15 s through the Python package on the CPU against DuckDB 5.08 s and Polars 14.40 s on a shared machine, answers equal to DuckDB's on the same queries), why one query carries that lead, what's in the stable build, four things Mojo taught us, what it doesn't do yet, and where it's going.

Code (Apache-2.0): https://github.com/abhisheksreesaila/omxcore
Benchmarks, query by query: https://abhisheksreesaila.github.io/omxcore/benchmarks.html
omxlabs: https://omxlabs.tech

Chapters
0:00 The numbers, and the honest edges
0:19 Python: lazy, then compute
0:34 Mojo: no Python at all
0:52 SQL from Mojo
1:04 Simplified TPC-H at scale factor 10
1:19 Faster in total, not on every query
1:34 Every query, on the page
1:46 What's in the stable build
2:00 Where Mojo pushed back
2:19 What it doesn't do yet
2:37 Where it's going
2:53 The suite
3:05 Try it
```

**Tags:** Mojo, Mojo language, Modular, MAX, GPU, SQL, SQL engine, DuckDB, Polars, TPC-H, Parquet, analytics, database, omxcore, omxlabs

*Re-time the chapters to the final cut. Sources: every slide's small mono line; TPC-H from mxframe docs/bench/m2s-engine.csv.*
