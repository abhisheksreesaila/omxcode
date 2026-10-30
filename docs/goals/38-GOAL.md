# GOAL 38: our home turf — 100M rows, four stacks

**End goal (owner, 2026-10-28):** "my goal is to prove Mojo is superior… if it doesn't, we have to see why." The
particle showcase (goal 36) is pure GPU work where every stack uses the same hardware: omxcode ties the best. Data + UI
+ GPU in one process is where omxcode's design should win decisively; this measures it, fairly. Draft:
docs/goals/38-draft.md. Spec, the contract for every build: showcase-data/SPEC.md. Written before the work
(2026-10-28); goal 36's contract is archived in docs/goals/36-GOAL.md and 36-check.py.

## The contenders (each the idiomatic way to build this today)
- **A · JS + DuckDB-WASM:** all in the browser (the "no server" web answer).
- **B · JS UI + Python server (FastAPI + Polars):** the common web stack: a page, an API, a dataframe server.
- **C · Rust native (Polars + egui):** the "go native with Rust" answer, one binary.
- **D · omxcode + omxcore:** one Mojo program, the data on the GPU, native UI.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | Data, steps, reference | showcase-data/make_data.py run twice at 10M writes byte-equal files, equal to data.lock's 10M size and SHA-256; data/orders-100M.parquet matches data.lock (100,000,000 rows); steps.json has the opening state and 25–40 steps, every state complete and valid (dates in range, from ≤ to, slider 1 … 5,000, a known region), with at least one step matching every row, at least two matching fewer than 0.01 % of rows, region switches, and a run of ≥ 4 small slider moves; answers-10M.json and answers-100M.json have an answer for every state, made from data.lock's bytes; DuckDB run again at 10M agrees with answers-10M.json and a second engine (NumPy) agrees too, through `reference.compare`; `compare` rejects a wrong id, a sum off by 1e-5 relative, a wrong row count and a missing step, and accepts a 1e-9 change; SPEC.md pins the id column, the date type, the tie-breaks, the margin and the answers format |
| M1 | A · JS + DuckDB-WASM | showcase-data/a-duckdb-wasm, built blind (its own agent, from DuckDB-WASM's docs, without reading the other builds): the SPEC's app in headless Chromium at 1280 × 800; its scripted mode writes answers.json and timings.json; `reference.compare` finds no problem at 10M and at 100M on every step (or the build states, with the error it hit, that 100M does not load in the browser: that is a result, not a skip) |
| M2 | B · JS + FastAPI + Polars | showcase-data/b-fastapi-polars, built blind: a page and a Python API (Polars over the Parquet file); scripted mode times change → new numbers on the page through the real HTTP hop; `compare` clean at 10M and 100M on every step |
| M3 | C · Rust + Polars + egui | showcase-data/c-rust-egui, built blind: one native binary (cargo, release); scripted mode times change → the first egui frame showing the new numbers; `compare` clean at 10M and 100M on every step |
| M4 | D · omxcode + omxcore | showcase-data/d-omxcode (or examples/…), built blind from the framework's docs: one Mojo program, the data on the GPU through MX frame, native GTK UI from generic mojoui components only (the console lint's rule); scripted mode times change → first frame; `compare` clean at 10M and 100M on every step |
| M5 | The measure | a fairness review of every build first (performance mistakes fixed, each build given the same chance); then one script, one protocol, quiet gate, the real desktop: per step input-to-pixels latency (median, p95, worst over the steps, 3 runs), compute time where separable, cold start to the first dashboard, data load time, peak memory (PSS) including any server process, and lines, files, languages and build steps counted by the script; results JSON + table written fresh for the sources, with the setup recorded |
| M6 | The page | docs/data.html (or a chapter of docs/why.html): what a user feels (smooth vs waiting per change), the numbers (generated from M5's results, every number on the page found in them), the code side by side, the stack, and every loss stated |
| M7 | Regression | goal 36's M0 (the particle reference) and M5 (the page) and goal 35's M2 (AG-UI's UI as data) still pass, through their archived checks |

## Fair play
As goal 36: blind builds, a performance review of each before measuring, the same chance for every build, losses
stated. Specific risks to state: B's network hop is real but local; A is limited by the browser's memory (wasm 4 GB);
D needs an NVIDIA GPU today (Apple via Metal later); C and D are native, A and B are web. No build may pre-aggregate,
sample, or cache results across different filter values (SPEC "The app"). DuckDB's own time per step (reference.py,
24 threads, in memory) is recorded as a baseline, not a contender.

## Out of bounds
Pushing; tuning one build after seeing another's numbers without giving the others the same chance; changing the data,
steps or reference after M1 starts (any change re-runs every build's correctness).

## Done means
`scripts/check` PASS for M0–M7; the reviewer passes it; the page previewed for the owner.
