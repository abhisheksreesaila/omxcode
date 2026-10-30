# GOAL 38 (draft, 2026-10-28): our home turf — 100M rows, four stacks

**Why (owner, 2026-10-28):** "my goal is to prove Mojo is superior… if it doesn't, we have to see why." The particle
showcase (goal 36) is pure GPU work where every stack uses the same hardware: omxcode ties the best. Data + UI + GPU in
one process is where omxcode's design should win decisively; this measures it, fairly. Spec: showcase-data/SPEC.md.

## The contenders (each the idiomatic way to build this today)
- **A · JS + DuckDB-WASM:** all in the browser (the "no server" web answer).
- **B · JS UI + Python server (FastAPI + Polars):** the common web stack: a page, an API, a dataframe server.
- **C · Rust native (Polars + egui):** the "go native with Rust" answer, one binary.
- **D · omxcode + omxcore:** one Mojo program, the data on the GPU, native UI.

## Milestones
| # | Milestone | Proof |
|---|---|---|
| M0 | Data, steps, reference | make_data.py reproducible (two runs byte-equal at 10M); steps.json fixed; reference.py answers for every step |
| M1–M4 | A, B, C, D | each built blind by its own agent from its stack's docs; each matches the reference on every step at 10M and 100M |
| M5 | The measure | one protocol, quiet gate, real desktop: per step input-to-pixels latency (median, p95, worst), compute time where separable, cold start to first dashboard, peak memory (PSS) incl. any server, data load time, lines/files/languages/build steps counted by script; fairness review of every build first |
| M6 | The page | docs/data.html (or a chapter of why.html): what a user feels (smooth vs waiting per change), the numbers, the code, the stack, every loss stated |

## Fair play
As goal 36: blind builds, a performance review of each before measuring, the same chance for every build, losses
stated. Specific risks to state: B's network hop is real but local; A is limited by the browser's memory (wasm 4 GB);
D needs an NVIDIA GPU today (Apple via Metal later); C and D are native, A and B are web.
