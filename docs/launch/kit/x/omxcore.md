# X: omxcore, the engine (Thursday Nov 5)

Post 1/ first, then reply to it with each next post. Attach the media named under each post. Every post is under 280
characters (`pixi run python docs/launch/kit/x/check_lengths.py`). Copy only the text between the lines.

---
**1/** · attach the talk's part 1 slide 6 (`mx sql` with its notes)

The engine under omxplorer is a SQL engine written top to bottom in Mojo. No Python inside.

Point it at a CSV or Parquet file and ask. It runs on your CPU or your GPU, and every answer says what the planner decided. It's called omxcore. 🧵

---
**2/** · attach the TPC-H bars (part 2, slide 5)

22 simplified TPC-H queries (not certified), SF10, Python package 0.6.0 on the CPU, shared machine (indicative):

omxcore 3.15 s
DuckDB 5.08 s
Polars 14.40 s

Answers equal DuckDB's on the same queries.

---
**3/** · no media

Honestly: Q21 carries that lead. Without it, DuckDB's total is lower (2.27 s vs 2.41 s), and DuckDB is still faster on 12 of the 22, mostly joins.

Every query is on the benchmarks page, computed from the CSVs in the repo.

---
**4/** · attach the typo error (part 1, slide 7)

Built for agents: JSON out, exact decimals (money is a scaled integer), and a typo comes back with its line, its column and "did you mean l_returnflag?".

One round to fix it, no stack trace.

---
**5/** · no media

Apache-2.0. Next: SQL on the GPU through AUTO, 22 of 22 TPC-H, an MCP server.

github.com/abhisheksreesaila/omxcore

Send me a query where DuckDB wins. That's the next ticket.

---

*Sources (mxframe): README.md, docs/bench/m2s-engine.csv (SF10), docs/omxcore-mojo-api.md "The mx command line",
docs/plan.md F-191/F-192/F-169. Add the talk link to 5/ once part 1 is up.*
