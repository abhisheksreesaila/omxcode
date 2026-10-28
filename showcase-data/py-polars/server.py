"""Build B's API: FastAPI + Polars over the orders Parquet file (showcase-data/SPEC.md).

Run: pixi run python showcase-data/py-polars/server.py --rows 10M [--port 8738] [--out DIR]

How it works
- At startup (the lifespan hook, before uvicorn accepts a connection) the whole file is read into memory once:
  `region` and `product` become Polars Enums (values read from the file), and the rows are sorted by `day`
  descending, stable, so `id` stays ascending within a day (the file is in id order). Measured at 100M: ~3.5 s
  to load and sort, ~3 GB.
- Each filter change is one GET /api/query. The date range becomes a contiguous slice of the sorted frame
  (two binary searches), then the amount and region filters run inside it. Two Polars queries over that slice:
  a group-by product (count, sum of amount, sum of margin) from which the KPIs and the top 20 both come, and the
  first 50 matching rows (already in table order). Nothing is cached between requests; every request scans the
  rows it needs.
- The compute time is sent back in a `Server-Timing` header (and `X-Compute-Ms`), so the page can separate it
  from the HTTP hop and its own drawing.
- One uvicorn process, one worker: the data lives in this process's memory, so more workers would mean more
  copies of it. Requests are handled in FastAPI's thread pool; Polars runs each query on all cores.
"""

import argparse
import datetime as dt
import json
import math
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path

import polars as pl
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
TOP, ROWS_SHOWN = 20, 50

DATA = {}  # filled once at startup: frame, day column, regions, products, load time


def load(path):
    t0 = time.perf_counter()
    lf = pl.scan_parquet(path)
    regions = sorted(lf.select(pl.col("region").unique()).collect().to_series().to_list())
    products = sorted(lf.select(pl.col("product").unique()).collect().to_series().to_list())
    df = (lf.with_columns(pl.col("region").cast(pl.Enum(regions)), pl.col("product").cast(pl.Enum(products)))
            .sort("day", descending=True, maintain_order=True)
            .collect())
    DATA.update(df=df, day=df["day"], regions=regions, products=products, file=path.name,
                load_ms=(time.perf_counter() - t0) * 1000,
                first_day=str(df["day"].min()), last_day=str(df["day"].max()))


@asynccontextmanager
async def lifespan(app):
    load(Path(os.environ["B_DATA"]))
    print(f"B: {DATA['file']} loaded, {DATA['df'].height:,} rows in {DATA['load_ms'] / 1000:.1f} s", flush=True)
    yield


app = FastAPI(lifespan=lifespan)


def query(day_from, day_to, min_amount, region):
    df, day = DATA["df"], DATA["day"]
    # The frame is sorted by day descending: rows with day in [from, to] are one slice.
    lo = day.search_sorted(day_to, side="left", descending=True)
    hi = day.search_sorted(day_from, side="right", descending=True)
    cond = pl.col("amount") >= min_amount
    if region != "all":
        cond = cond & (pl.col("region") == region)
    matched = df.slice(lo, max(hi - lo, 0)).lazy().filter(cond)
    groups = (matched.group_by("product")
                     .agg(pl.len().alias("n"), pl.col("amount").sum().alias("s"),
                          ((pl.col("amount") - pl.col("cost")) / pl.col("amount")).sum().alias("m"))
                     .collect())
    table = matched.head(ROWS_SHOWN).collect()
    rows = int(groups["n"].sum()) if groups.height else 0
    total = float(groups["s"].sum()) if groups.height else 0.0
    margin = float(groups["m"].sum()) / rows if rows else None
    top = groups.sort(["s", "product"], descending=[True, False]).head(TOP)
    return {
        "rows": rows, "sum_amount": total, "avg_margin": margin,
        "top": [[p, s] for p, s in zip(top["product"].cast(pl.String).to_list(), top["s"].to_list())],
        "table": {"columns": table.columns,
                  "rows": table.with_columns(pl.col("day").cast(pl.String), pl.col("region").cast(pl.String),
                                             pl.col("product").cast(pl.String)).rows()},
    }


def parse_day(s):
    try:
        return dt.date.fromisoformat(s)
    except ValueError:
        raise HTTPException(400, f"bad date {s!r}")


@app.get("/api/meta")
def meta():
    return {"file": DATA["file"], "rows": DATA["df"].height, "load_ms": DATA["load_ms"], "regions": DATA["regions"],
            "first_day": DATA["first_day"], "last_day": DATA["last_day"]}


@app.get("/api/query")
def api_query(day_from: str, day_to: str, min_amount: float, region: str = "all"):
    if region != "all" and region not in DATA["regions"]:
        raise HTTPException(400, f"unknown region {region!r}")
    if not math.isfinite(min_amount):
        raise HTTPException(400, "bad min_amount")
    t0 = time.perf_counter()
    result = query(parse_day(day_from), parse_day(day_to), min_amount, region)
    ms = (time.perf_counter() - t0) * 1000
    return JSONResponse(result, headers={"Server-Timing": f"compute;dur={ms:.3f}", "X-Compute-Ms": f"{ms:.3f}",
                                         "Cache-Control": "no-store"})


@app.post("/api/results")
async def results(request: Request):
    """Scripted mode: the page posts answers.json and timings.json here; they're written to --out."""
    out = os.environ.get("B_OUT")
    if not out:
        raise HTTPException(403, "no --out given")
    body = await request.json()
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "answers.json").write_text(json.dumps(body["answers"]) + "\n")
    (out / "timings.json").write_text(json.dumps({"load_ms": DATA["load_ms"], **body["timings"]}, indent=1) + "\n")
    (out / "done").write_text("ok\n")
    return Response(status_code=204)


@app.get("/steps.json")
def steps():
    return FileResponse(HERE.parent / "steps.json")


app.mount("/", StaticFiles(directory=HERE / "web", html=True), name="web")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", choices=["10M", "100M"], default="10M")
    ap.add_argument("--port", type=int, default=8738)
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    os.environ["B_DATA"] = str(ROOT / "data" / f"orders-{a.rows}.parquet")
    if a.out:
        os.environ["B_OUT"] = str(a.out.resolve())
    # One process, one worker: the data is in this process's memory (see the module docstring).
    uvicorn.run(app, host="127.0.0.1", port=a.port, workers=1, log_level="warning")


if __name__ == "__main__":
    main()
