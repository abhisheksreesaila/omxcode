"""Goal 70 M2's similarity column: the app's way today (mojoui/plugin_py.py's similar(): numpy, `v @ v[row]` over the
embeddings a text model gave) timed on made-up unit vectors, written as Parquet for the engine's way
(tests/bench_robotics.mojo: one SQL query, a 384-term dot product), then both answers compared.

    pixi run python -I docs/goals/70/similarity.py write OUT [ROWS]     OUT/emb.parquet, OUT/similarity_numpy.json
    pixi run python -I docs/goals/70/similarity.py compare OUT          after bench_robotics: prints "SAME similarity yes|no …"
"""
import json
import statistics
import sys
import time
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

DIMS = 384  # (e5-small, bge-small: the text models goal 68 adds)


def write(out: Path, rows: int):
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(0)
    v = rng.standard_normal((rows, DIMS))
    v /= np.linalg.norm(v, axis=1, keepdims=True)
    cols = {"row": pa.array(np.arange(rows, dtype=np.int64))}
    for d in range(DIMS):
        cols[f"e{d}"] = pa.array(v[:, d])
    pq.write_table(pa.table(cols), out / "emb.parquet")
    times = {}
    for name, m in (("numpy_f32", v.astype(np.float32)), ("numpy_f64", v)):
        all_t, top_t = [], []
        for _ in range(5):
            t0 = time.perf_counter()
            s = list((m @ m[0]).astype(float).tolist())  # (plugin_py.similar: every row's cosine to row 0, as floats)
            all_t.append((time.perf_counter() - t0) * 1e3)
            t0 = time.perf_counter()
            sims = m @ m[0]
            k = np.argpartition(-sims, 10)[:10]
            k = k[np.argsort(-sims[k], kind="stable")]
            top_t.append((time.perf_counter() - t0) * 1e3)
        times[name] = {"all_ms": statistics.median(all_t), "top10_ms": statistics.median(top_t), "all": all_t, "top": top_t}
    sims = v @ v[0]
    top = np.argsort(-sims, kind="stable")[:10]
    (out / "similarity_numpy.json").write_text(json.dumps({"rows": rows, "times": times, "top10": [[int(i), float(sims[i])] for i in top],
                                                           "all": sims.tolist()}))
    for name, t in times.items():
        print(f"TIME similarity_all {name} median={t['all_ms']:.3f}")
        print(f"TIME similarity_top10 {name} median={t['top10_ms']:.3f}")


def compare(out: Path):
    want = json.loads((out / "similarity_numpy.json").read_text())
    top = [l.split("\t") for l in (out / "similarity_top10_engine.txt").read_text().splitlines() if l]
    got_all = [float(x) for x in (out / "similarity_all_engine.txt").read_text().split()]
    same_top = [int(r) for r, _ in top] == [i for i, _ in want["top10"]] and all(abs(float(s) - w) < 1e-9 for (_, s), (_, w) in zip(top, want["top10"]))
    worst = max(abs(a - b) for a, b in zip(got_all, want["all"])) if len(got_all) == len(want["all"]) else float("inf")
    ok = same_top and worst < 1e-9
    print(f"SAME similarity {'yes' if ok else 'no'} top 10 rows {'equal' if same_top else 'differ'}; every row's cosine within {worst:.2e} of numpy's float64")
    return ok


if __name__ == "__main__":
    if sys.argv[1] == "write":
        write(Path(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 100_000)
    else:
        sys.exit(0 if compare(Path(sys.argv[2])) else 1)
