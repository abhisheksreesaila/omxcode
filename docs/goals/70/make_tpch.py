"""Goal 70 M1's TPC-H SF1: DuckDB's dbgen (the tpch extension) written as Parquet into build/tpch_sf1 (DATE and DECIMAL
columns, as TPC-H defines them; omxcore's own data/tpch_sf1 stores int32 days and float32 prices, which the app's SQL
refuses to compare with dates). Skipped when the files are there.
    pixi run python -I docs/goals/70/make_tpch.py"""
from pathlib import Path

import duckdb

OUT = Path(__file__).resolve().parents[3] / "build/tpch_sf1"
TABLES = ["lineitem", "orders", "customer", "part", "partsupp", "supplier", "nation", "region"]
if not all((OUT / f"{t}.parquet").exists() for t in TABLES):
    OUT.mkdir(parents=True, exist_ok=True)
    c = duckdb.connect()
    c.execute("INSTALL tpch")
    c.execute("LOAD tpch")
    c.execute("CALL dbgen(sf=1)")
    for t in TABLES:
        c.execute(f"COPY {t} TO '{OUT / t}.parquet' (FORMAT parquet)")
print(f"tpch sf1: {OUT}")
