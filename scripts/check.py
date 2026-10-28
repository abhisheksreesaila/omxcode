"""Milestone checker for GOAL.md (goal 38: 100M rows, four stacks). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M7)
Each milestone's proof was written before its work started, from GOAL.md's words (never weaker). M1-M6 are todo
until their work starts; M7 runs goal 36's M0 and M5 and goal 35's M2 through their archived checks.
"""

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
DATA = ROOT / "showcase-data"
REGIONS = ["US East", "US West", "Canada", "Brazil", "UK", "Germany", "India", "Japan"]


def run(cmd, timeout=1800):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def reference():
    sys.path.insert(0, str(DATA))
    import reference as ref
    return ref


def sha256(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while b := f.read(1 << 24):
            h.update(b)
    return h.hexdigest()


# ---------------------------------------------------------------------------------------------------------------------
# M0: data, steps, reference
# ---------------------------------------------------------------------------------------------------------------------

def m0_data():
    lock = json.loads((DATA / "data.lock").read_text())["files"]
    with tempfile.TemporaryDirectory() as d:
        files = []
        for k in range(2):
            p = Path(d) / f"o{k}.parquet"
            r = run([sys.executable, "showcase-data/make_data.py", "--rows", "10M", "--out", str(p)], 900)
            if r.returncode != 0 or not p.exists():
                return f"make_data.py failed: {(r.stdout + r.stderr)[-500:]}"
            files.append(p)
        if files[0].read_bytes() != files[1].read_bytes():
            return "two make_data.py runs at 10M differ"
        if (files[0].stat().st_size, sha256(files[0])) != (lock["orders-10M.parquet"]["bytes"], lock["orders-10M.parquet"]["sha256"]):
            return "make_data.py's 10M bytes are not data.lock's"
    import pyarrow.parquet as pq
    for name, rows in (("orders-10M.parquet", 10_000_000), ("orders-100M.parquet", 100_000_000)):
        p = ROOT / "data" / name
        if not p.exists() or p.stat().st_size != lock[name]["bytes"] or sha256(p) != lock[name]["sha256"]:
            return f"data/{name} missing or not data.lock's bytes (run showcase-data/make_data.py)"
        meta = pq.ParquetFile(p).metadata
        if meta.num_rows != rows or [meta.schema.column(i).name for i in range(meta.num_columns)] != \
                ["id", "day", "region", "product", "amount", "cost", "paid"]:
            return f"data/{name}: {meta.num_rows} rows, columns not the SPEC's"
    return None


def m0_steps(answers):
    s = json.loads((DATA / "steps.json").read_text())
    states = [s["opening"], *s["steps"]]
    if not 25 <= len(s["steps"]) <= 40:
        return f"{len(s['steps'])} steps, want 25–40"
    keys = ("from", "to", "min_amount", "region")
    for k, st in enumerate(states):
        if st.get("step") != k or any(x not in st for x in keys):
            return f"state {k} incomplete or misnumbered"
        if not ("2024-01-01" <= st["from"] <= st["to"] <= "2025-12-31") or not 1 <= st["min_amount"] <= 5000 \
                or st["region"] not in REGIONS + ["all"]:
            return f"state {k} out of range: {st}"
        if k and sum(st[x] != states[k - 1][x] for x in keys) != 1:
            return f"step {k} doesn't change exactly one control"
        if k and st["change"] not in keys or (k and st[st["change"]] == states[k - 1][st["change"]]):
            return f"step {k}'s change field doesn't name the control that moved"
    run_, best = 0, 0
    for k in range(1, len(states)):
        small = states[k]["change"] == "min_amount" and abs(states[k]["min_amount"] - states[k - 1]["min_amount"]) <= 100
        run_ = run_ + 1 if small else 0
        best = max(best, run_)
    if best < 4:
        return f"the longest run of small slider moves is {best}, want ≥ 4"
    if sum(states[k]["change"] == "region" for k in range(1, len(states))) < 3:
        return "fewer than 3 region switches"
    for total, ans in answers.items():
        a, name = ans["steps"], f"{total // 1_000_000}M"
        if len(a) != len(states):
            return f"answers-{name}.json has {len(a)} answers for {len(states)} states"
        if not any(x["rows"] == total for x in a[1:]):
            return f"no step matches every row at {name}"
        if sum(x["rows"] < total * 1e-4 for x in a) < 2:
            return f"fewer than two steps match < 0.01 % of rows at {name}"
    return None


def m0_compare(ref, want):
    if ref.compare(want, want):
        return f"compare(reference, reference) finds problems: {ref.compare(want, want)[:2]}"
    k = next(i for i, x in enumerate(want["steps"]) if len(x["ids"]) == 50 and x["rows"] > 1000)
    bad = {}
    g = copy.deepcopy(want); g["steps"][k]["ids"][7] += 1; bad["a wrong id"] = g
    g = copy.deepcopy(want); g["steps"][k]["sum_amount"] *= 1 + 1e-5; bad["a sum off by 1e-5"] = g
    g = copy.deepcopy(want); g["steps"][k]["top"][3][1] *= 1 - 1e-5; bad["a product's sum off by 1e-5"] = g
    g = copy.deepcopy(want); g["steps"][k]["rows"] += 1; bad["a wrong row count"] = g
    g = copy.deepcopy(want); g["steps"][k]["avg_margin"] *= 1 + 1e-5; bad["a margin off by 1e-5"] = g
    g = copy.deepcopy(want); del g["steps"][-1]; bad["a missing step"] = g
    g = copy.deepcopy(want); t = g["steps"][k]["top"]; t[0][0], t[1][0] = t[1][0], t[0][0]; bad["two products swapped"] = g
    for why, g in bad.items():
        if not ref.compare(g, want):
            return f"compare accepts {why}"
    g = copy.deepcopy(want)
    for x in g["steps"]:
        x["sum_amount"] *= 1 + 1e-9
        x["top"] = [[p, s * (1 - 1e-9)] for p, s in x["top"]]
    if ref.compare(g, want):
        return f"compare rejects a 1e-9 change: {ref.compare(g, want)[:2]}"
    if ref.compare({"steps": want["steps"][:6]}, want, steps=5):
        return "compare rejects a 5-step run"
    return None


def m0():
    """GOAL.md M0: data reproducible and locked, steps fixed and shaped as stated, reference answers for every state,
    re-made and cross-checked by a second engine, compare's own behaviour, SPEC pinned."""
    t0 = time.time()
    why = m0_data()
    if why:
        return False, why
    t_data = time.time() - t0
    lock = json.loads((DATA / "data.lock").read_text())["files"]
    answers = {}
    for name in ("10M", "100M"):
        p = DATA / f"answers-{name}.json"
        if not p.exists():
            return False, f"{p.name} missing"
        answers[name] = json.loads(p.read_text())
        if answers[name]["sha256"] != lock[f"orders-{name}.parquet"]["sha256"]:
            return False, f"{p.name} was made from other bytes than data.lock's"
    why = m0_steps({10_000_000: answers["10M"], 100_000_000: answers["100M"]})
    if why:
        return False, why
    ref = reference()
    for name, total in (("10M", 10_000_000), ("100M", 100_000_000)):
        if answers[name]["steps"][0]["rows"] != total:
            return False, f"the opening state doesn't match every row at {name}"
    with tempfile.TemporaryDirectory() as d:
        for engine in ("duckdb", "numpy"):
            out = Path(d) / f"{engine}.json"
            r = run([sys.executable, "showcase-data/reference.py", "10M", "--engine", engine, "--out", str(out)], 900)
            if r.returncode != 0:
                return False, f"reference.py --engine {engine} failed: {(r.stdout + r.stderr)[-500:]}"
            problems = ref.compare(json.loads(out.read_text()), answers["10M"])
            if problems:
                return False, f"{engine} at 10M disagrees with answers-10M.json: {problems[:3]}"
    why = m0_compare(ref, answers["10M"]) or m0_compare(ref, answers["100M"])
    if why:
        return False, why
    spec = (DATA / "SPEC.md").read_text()
    for word in ("`id` int64", "Parquet DATE", "`id` ascending", "product name ascending", "`(amount − cost) / amount`",
                 "answers.json", "data.lock", "reference.compare"):
        if word not in spec:
            return False, f"SPEC.md doesn't pin {word!r}"
    ms = answers["100M"]["step_ms"]
    return True, (f"10M twice byte-equal ({lock['orders-10M.parquet']['bytes']:,} B, {lock['orders-10M.parquet']['sha256'][:12]}), "
                  f"100M locked ({lock['orders-100M.parquet']['bytes']:,} B, {lock['orders-100M.parquet']['sha256'][:12]}) "
                  f"[{t_data:.0f} s]; {len(answers['10M']['steps']) - 1} steps; DuckDB and NumPy agree at 10M; "
                  f"compare rejects 7 faults, accepts 1e-9; DuckDB 100M per step median {sorted(ms)[len(ms) // 2]:.0f} ms")


# ---------------------------------------------------------------------------------------------------------------------
# M1-M6: todo until their work starts (their proofs are GOAL.md's words)
# ---------------------------------------------------------------------------------------------------------------------

def todo(name):
    return lambda: (False, f"todo: {name} not started")


# ---------------------------------------------------------------------------------------------------------------------
# M7: regression
# ---------------------------------------------------------------------------------------------------------------------

def m7():
    """Goal 36's M0 and M5, goal 35's M2, through their archived checks."""
    g36 = load("goal36", "docs/goals/36-check.py")
    g35 = load("goal35", "docs/goals/35-check.py")
    out, ok = [], True
    for label, fn in (("36 M0", g36.m0), ("36 M5", g36.m5), ("35 M2", g35.m2)):
        good, msg = fn()
        ok &= bool(good)
        out.append(f"{label} {'PASS' if good else 'FAIL'}: {msg[:200]}")
    return ok, " | ".join(out)


MILESTONES = [("M0", m0), ("M1", todo("A · JS + DuckDB-WASM")), ("M2", todo("B · JS + FastAPI + Polars")),
              ("M3", todo("C · Rust + Polars + egui")), ("M4", todo("D · omxcode + omxcore")),
              ("M5", todo("the measure")), ("M6", todo("the page")), ("M7", m7)]


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
