"""Writes the dashboard's orders file (showcase-data/SPEC.md "Data"), deterministically.

Run: pixi run python showcase-data/make_data.py              (both files into data/, then data.lock)
     pixi run python showcase-data/make_data.py --rows 10M --out /tmp/x.parquet   (one file, no lock)

Rows are made in chunks of 1,000,000, chunk k from its own generator (numpy PCG64, seed [42, k]) and written as one
Parquet row group, so memory stays about one chunk and the 10M file is exactly the first 10M rows of the 100M file
(id = row number). Same numpy + pyarrow versions (pinned in data.lock) → the same bytes.
"""

import argparse
import datetime as dt
import hashlib
import json
import sys
import time
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DATA = ROOT / "data"
LOCK = HERE / "data.lock"
SEED = 42
CHUNK = 1_000_000
FIRST = dt.date(2024, 1, 1)
DAYS = 731  # 2024-01-01 … 2025-12-31 (2024 is a leap year)
EPOCH_DAY = (FIRST - dt.date(1970, 1, 1)).days

REGIONS = ["US East", "US West", "Canada", "Brazil", "UK", "Germany", "India", "Japan"]
REGION_W = [0.22, 0.18, 0.06, 0.07, 0.12, 0.13, 0.10, 0.12]

# (name, typical unit price, cost as a share of the price); popularity is Zipf-like by POPULAR's order below.
PRODUCTS = [
    ("Laptop", 1400, 0.78), ("Phone", 900, 0.72), ("Tablet", 550, 0.70), ("Monitor", 320, 0.68),
    ("Headphones", 180, 0.45), ("Earbuds", 120, 0.40), ("Smartwatch", 300, 0.55), ("Camera", 850, 0.70),
    ("Keyboard", 90, 0.42), ("Mouse", 45, 0.38), ("Webcam", 80, 0.45), ("Speaker", 150, 0.50),
    ("Router", 130, 0.55), ("SSD", 110, 0.65), ("Hard Drive", 85, 0.62), ("USB Hub", 30, 0.35),
    ("Charger", 35, 0.30), ("Cable", 15, 0.20), ("Power Bank", 50, 0.40), ("Printer", 240, 0.66),
    ("Ink", 40, 0.25), ("Desk Lamp", 55, 0.40), ("Office Chair", 380, 0.58), ("Standing Desk", 650, 0.60),
    ("Microphone", 140, 0.48), ("Game Console", 500, 0.80), ("Controller", 65, 0.50), ("VR Headset", 450, 0.66),
    ("E-Reader", 140, 0.60), ("Drone", 700, 0.64), ("Projector", 600, 0.62), ("TV", 1100, 0.74),
    ("Soundbar", 280, 0.52), ("Smart Bulb", 20, 0.35), ("Thermostat", 200, 0.50), ("Doorbell Cam", 170, 0.52),
    ("Backpack", 75, 0.36), ("Laptop Sleeve", 30, 0.28), ("Screen Protector", 12, 0.15), ("Phone Case", 25, 0.22),
]
POPULAR = [39, 17, 16, 1, 5, 38, 9, 33, 18, 0, 4, 8, 2, 26, 6, 13, 11, 21, 36, 15,
           3, 31, 10, 20, 37, 12, 25, 24, 7, 32, 14, 34, 35, 28, 19, 22, 27, 30, 23, 29]  # product indices, most sold first


def day_weights():
    """Orders per day: weekly rhythm, a December peak, the Black Friday → Christmas rush, quiet New Year, 15 % growth."""
    w = np.empty(DAYS)
    week = [0.92, 0.90, 0.94, 1.00, 1.08, 1.22, 1.14]  # Mon … Sun
    for i in range(DAYS):
        d = FIRST + dt.timedelta(days=i)
        doy = d.timetuple().tm_yday
        x = week[d.weekday()] * (1 + 0.18 * np.cos(2 * np.pi * (doy - 350) / 365)) * (1 + 0.15 * i / (DAYS - 1))
        if (d.month == 11 and d.day >= 24) or (d.month == 12 and d.day <= 23):
            x *= 1.45
        if d.month == 1 and d.day <= 2:
            x *= 0.6
        w[i] = x
    return w / w.sum()


def tables():
    pop = np.empty(len(PRODUCTS))
    for rank, p in enumerate(POPULAR):
        pop[p] = 1 / (rank + 1) ** 1.05
    return (np.cumsum(day_weights()), np.cumsum(REGION_W) / sum(REGION_W), np.cumsum(pop / pop.sum()),
            np.array([p[1] for p in PRODUCTS], float), np.array([p[2] for p in PRODUCTS], float))


SCHEMA = pa.schema([("id", pa.int64()), ("day", pa.date32()), ("region", pa.string()), ("product", pa.string()),
                    ("amount", pa.float64()), ("cost", pa.float64()), ("paid", pa.bool_())])


def chunk(k, n, t):
    day_cdf, reg_cdf, prod_cdf, price, cost_share = t
    rng = np.random.default_rng([SEED, k])
    day = np.minimum(np.searchsorted(day_cdf, rng.random(n), side="right"), DAYS - 1).astype(np.int32)
    region = np.minimum(np.searchsorted(reg_cdf, rng.random(n), side="right"), len(REGIONS) - 1).astype(np.int32)
    product = np.minimum(np.searchsorted(prod_cdf, rng.random(n), side="right"), len(PRODUCTS) - 1).astype(np.int32)
    qty = rng.geometric(0.62, n)
    amount = price[product] * qty * rng.lognormal(0.0, 0.32, n)
    over = amount > 5000
    amount[over] = rng.uniform(1000, 5000, int(over.sum()))  # big baskets spread out, no pile at the cap
    amount = np.round(np.maximum(amount, 1.0), 2)
    share = np.clip(cost_share[product] + rng.normal(0, 0.06, n), 0.08, 0.97)
    cost = np.round(amount * share, 2)
    recent = day >= DAYS - 14  # the last two weeks are still being paid
    paid = rng.random(n) < np.where(recent, 0.62, 0.97)
    ids = np.arange(k * CHUNK, k * CHUNK + n, dtype=np.int64)
    return pa.table([
        pa.array(ids),
        pa.array(day + EPOCH_DAY, type=pa.int32()).cast(pa.date32()),
        pa.DictionaryArray.from_arrays(pa.array(region), pa.array(REGIONS)).cast(pa.string()),
        pa.DictionaryArray.from_arrays(pa.array(product), pa.array([p[0] for p in PRODUCTS])).cast(pa.string()),
        pa.array(amount), pa.array(cost), pa.array(paid),
    ], schema=SCHEMA)


def write(rows, path):
    t = tables()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".parquet.part")
    with pq.ParquetWriter(tmp, SCHEMA, compression="snappy", write_statistics=True) as w:
        for k in range((rows + CHUNK - 1) // CHUNK):
            w.write_table(chunk(k, min(CHUNK, rows - k * CHUNK), t), row_group_size=CHUNK)
    tmp.replace(path)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while b := f.read(1 << 24):
            h.update(b)
    return h.hexdigest()


def rows_arg(s):
    s = s.upper()
    return int(float(s[:-1]) * 1_000_000) if s.endswith("M") else int(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=rows_arg)
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    if a.rows:
        t0 = time.time()
        out = a.out or DATA / f"orders-{a.rows // 1_000_000}M.parquet"
        write(a.rows, out)
        print(f"{out}: {a.rows:,} rows, {out.stat().st_size:,} bytes, {time.time() - t0:.1f} s, sha256 {sha256(out)}")
        return
    files = {}
    for rows in (10_000_000, 100_000_000):
        out = DATA / f"orders-{rows // 1_000_000}M.parquet"
        t0 = time.time()
        write(rows, out)
        secs = time.time() - t0
        files[out.name] = {"rows": rows, "bytes": out.stat().st_size, "sha256": sha256(out), "seconds": round(secs, 1)}
        print(out.name, files[out.name], flush=True)
    LOCK.write_text(json.dumps({
        "generator": "showcase-data/make_data.py", "seed": SEED, "row_group": CHUNK,
        "numpy": np.__version__, "pyarrow": pa.__version__, "python": sys.version.split()[0],
        "files": files}, indent=2) + "\n")


if __name__ == "__main__":
    main()
