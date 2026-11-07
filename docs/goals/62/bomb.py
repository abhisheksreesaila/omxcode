"""A decode bomb for M7 (goal 62 round 3, the review's case): a Parquet file of a few hundred KB whose one column decodes
to 120 million rows, about 0.9 GB once read. Before round 3 the public copy's check passed it (its 4 GB limit) and the
server then read it in its own process, +0.93 GB a file.

    pixi run python docs/goals/62/bomb.py OUT.parquet [rows]"""

import sys

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq


def write(path, rows=120_000_000, group=10_000_000):
    schema = pa.schema([("reading", pa.int64())])
    with pq.ParquetWriter(path, schema, compression="zstd", use_dictionary=True) as w:
        left = rows
        while left > 0:
            n = min(group, left)
            w.write_table(pa.table({"reading": pa.array(np.zeros(n, dtype=np.int64))}, schema=schema), row_group_size=n)
            left -= n
    return path


if __name__ == "__main__":
    write(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 120_000_000)
