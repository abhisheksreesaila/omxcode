"""The dashboard's correct answers for every step (showcase-data/SPEC.md "Correctness"), and the compare every build's
check uses.

Run: pixi run python showcase-data/reference.py 10M            → showcase-data/answers-10M.json (DuckDB)
     pixi run python showcase-data/reference.py 100M
     pixi run python showcase-data/reference.py 10M --engine numpy --out /tmp/a.json   (a second engine, for M0)

In a build's check:
    sys.path.insert(0, "showcase-data"); import reference
    problems = reference.compare(json.load(open("answers.json")), reference.expected("10M"))   # [] when right
"""

import argparse
import hashlib
import json
import math
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REL = 1e-6
TOP, IDS = 20, 50


def data_file(rows, check_lock=True):
    """data/orders-<rows>.parquet, after checking its size and SHA-256 against data.lock."""
    path = ROOT / "data" / f"orders-{rows}.parquet"
    if check_lock:
        want = json.loads((HERE / "data.lock").read_text())["files"][path.name]
        if not path.exists() or path.stat().st_size != want["bytes"]:
            raise SystemExit(f"{path} missing or not data.lock's size: run showcase-data/make_data.py")
        h = hashlib.sha256()
        with open(path, "rb") as f:
            while b := f.read(1 << 24):
                h.update(b)
        if h.hexdigest() != want["sha256"]:
            raise SystemExit(f"{path} is not data.lock's bytes")
    return path


def states():
    """The opening state (step 0) and every step's full state, from steps.json."""
    s = json.loads((HERE / "steps.json").read_text())
    return [s["opening"], *s["steps"]]


def expected(rows):
    return json.loads((HERE / f"answers-{rows}.json").read_text())


# ---------------------------------------------------------------------------------------------------------------------
# DuckDB
# ---------------------------------------------------------------------------------------------------------------------

def duckdb_answers(path):
    import duckdb
    con = duckdb.connect()
    t0 = time.perf_counter()
    con.execute(f"CREATE TABLE o AS SELECT * FROM read_parquet('{path}')")
    load_ms = (time.perf_counter() - t0) * 1000
    steps, ms = [], []
    for st in states():
        where = "day BETWEEN CAST($f AS DATE) AND CAST($t AS DATE) AND amount >= $m"
        args = {"f": st["from"], "t": st["to"], "m": st["min_amount"]}
        if st["region"] != "all":
            where += " AND region = $r"
            args["r"] = st["region"]
        t0 = time.perf_counter()
        rows, total, margin = con.execute(
            f"SELECT count(*), coalesce(sum(amount), 0), avg((amount - cost) / amount) FROM o WHERE {where}", args).fetchone()
        top = con.execute(f"SELECT product, sum(amount) AS s FROM o WHERE {where} GROUP BY product "
                          f"ORDER BY s DESC, product ASC LIMIT {TOP + 1}", args).fetchall()
        ids = [r[0] for r in con.execute(f"SELECT id FROM o WHERE {where} ORDER BY day DESC, id ASC LIMIT {IDS}", args).fetchall()]
        ms.append((time.perf_counter() - t0) * 1000)
        steps.append({"step": st["step"], "rows": rows, "sum_amount": float(total),
                      "avg_margin": None if margin is None else float(margin),
                      "top": [[p, float(s)] for p, s in top[:TOP]],
                      "next": [top[TOP][0], float(top[TOP][1])] if len(top) > TOP else None, "ids": ids})
    meta = {"engine": f"duckdb {duckdb.__version__}", "threads": con.execute("SELECT current_setting('threads')").fetchone()[0],
            "load_ms": round(load_ms, 1), "step_ms": [round(x, 2) for x in ms]}
    return steps, meta


# ---------------------------------------------------------------------------------------------------------------------
# NumPy (a second, independent engine: M0 checks the two agree)
# ---------------------------------------------------------------------------------------------------------------------

def numpy_answers(path):
    import numpy as np
    import pyarrow as pa
    import pyarrow.parquet as pq
    t0 = time.perf_counter()
    t = pq.read_table(path, read_dictionary=["region", "product"]).unify_dictionaries().combine_chunks()
    col = lambda name: t.column(name).chunk(0)
    ids = col("id").to_numpy()
    day = col("day").cast(pa.int32()).to_numpy()
    amount, cost = col("amount").to_numpy(), col("cost").to_numpy()
    reg, prod = col("region"), col("product")
    reg_names, reg_code = reg.dictionary.to_pylist(), reg.indices.to_numpy()
    prod_names, prod_code = prod.dictionary.to_pylist(), prod.indices.to_numpy()
    load_ms = (time.perf_counter() - t0) * 1000
    epoch = lambda s: (np.datetime64(s, "D") - np.datetime64("1970-01-01", "D")).astype(int)
    steps, ms = [], []
    for st in states():
        t0 = time.perf_counter()
        m = (day >= epoch(st["from"])) & (day <= epoch(st["to"])) & (amount >= st["min_amount"])
        if st["region"] != "all":
            m &= reg_code == (reg_names.index(st["region"]) if st["region"] in reg_names else -1)
        a, c = amount[m], cost[m]
        n = int(m.sum())
        sums = np.bincount(prod_code[m], weights=a, minlength=len(prod_names))
        counts = np.bincount(prod_code[m], minlength=len(prod_names))
        ranked = sorted(((prod_names[k], float(sums[k])) for k in range(len(prod_names)) if counts[k]),
                        key=lambda x: (-x[1], x[0]))
        mi = np.nonzero(m)[0]
        order = np.lexsort((ids[mi], -day[mi].astype(np.int64)))[:IDS]
        ms.append((time.perf_counter() - t0) * 1000)
        steps.append({"step": st["step"], "rows": n, "sum_amount": float(a.sum()),
                      "avg_margin": float(((a - c) / a).mean()) if n else None,
                      "top": [list(x) for x in ranked[:TOP]], "next": list(ranked[TOP]) if len(ranked) > TOP else None,
                      "ids": [int(x) for x in ids[mi][order]]})
    return steps, {"engine": f"numpy {np.__version__}", "load_ms": round(load_ms, 1), "step_ms": [round(x, 2) for x in ms]}


# ---------------------------------------------------------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------------------------------------------------------

def close(a, b):
    return abs(a - b) <= REL * max(abs(a), abs(b)) + 1e-9


def compare(got, want, steps=None):
    """Problems (empty when right) between a build's answers.json and the reference's (SPEC "Correctness"):
    rows exact; sum of amount and average margin within 1e-6 relative (both null when nothing matches); the top 20's
    sums position by position within 1e-6, its names exact except where the reference's sum ties a neighbour's (incl.
    the 21st) within that tolerance; the 50 ids exact and in order. `steps`: how many steps the build ran (default all)."""
    g, w = got["steps"], want["steps"]
    n = len(w) - 1 if steps is None else steps
    problems = []
    if len(g) != n + 1:
        problems.append(f"{len(g)} answers, want {n + 1} (the opening state + {n} steps)")
    for a, b in zip(g, w[:n + 1]):
        k = b["step"]
        p = lambda msg: problems.append(f"step {k}: {msg}")
        if a.get("step") != k:
            p(f"answer labelled step {a.get('step')}")
        if a.get("rows") != b["rows"]:
            p(f"rows {a.get('rows')}, want {b['rows']}")
        if not isinstance(a.get("sum_amount"), (int, float)) or not close(a["sum_amount"], b["sum_amount"]):
            p(f"sum_amount {a.get('sum_amount')}, want {b['sum_amount']}")
        am, bm = a.get("avg_margin"), b["avg_margin"]
        if (am is None) != (bm is None) or (bm is not None and not (isinstance(am, (int, float)) and close(am, bm))):
            p(f"avg_margin {am}, want {bm}")
        top, wt = a.get("top") or [], b["top"]
        if len(top) != len(wt):
            p(f"{len(top)} products in the top, want {len(wt)}")
        ws = [s for _, s in wt] + ([b["next"][1]] if b.get("next") else [])
        for i, ((name, s), (wname, wsum)) in enumerate(zip(top, wt)):
            if not close(s, wsum):
                p(f"top #{i + 1} sum {s}, want {wsum}")
            tied = any(0 <= j < len(ws) and close(ws[j], wsum) for j in (i - 1, i + 1))
            if name != wname and not tied:
                p(f"top #{i + 1} is {name!r}, want {wname!r}")
        if len({name for name, _ in top}) != len(top):
            p("a product appears twice in the top")
        if a.get("ids") != b["ids"]:
            p(f"ids differ (first difference at #{next((i for i, (x, y) in enumerate(zip(a.get('ids') or [], b['ids'])) if x != y), min(len(a.get('ids') or []), len(b['ids'])))})")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rows", choices=["10M", "100M"])
    ap.add_argument("--engine", choices=["duckdb", "numpy"], default="duckdb")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    path = data_file(a.rows)
    steps, meta = (duckdb_answers if a.engine == "duckdb" else numpy_answers)(path)
    lock = json.loads((HERE / "data.lock").read_text())["files"][path.name]
    out = a.out or HERE / f"answers-{a.rows}.json"
    out.write_text(json.dumps({"file": path.name, "sha256": lock["sha256"], **meta, "steps": steps}, indent=1) + "\n")
    ms = meta["step_ms"]
    print(f"{out.name}: {meta['engine']}, {len(steps)} states, load {meta['load_ms'] / 1000:.1f} s, per step median "
          f"{statistics.median(ms):.1f} ms, p95 {sorted(ms)[math.ceil(0.95 * len(ms)) - 1]:.1f} ms, worst {max(ms):.1f} ms")


if __name__ == "__main__":
    sys.exit(main())
