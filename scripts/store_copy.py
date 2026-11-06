"""A consistent copy of a consoled/mxc store (SQLite's backup API, the source opened read-only): WAL included.
    pixi run python scripts/store_copy.py [SRC] DEST_DIR      # SRC default ~/.mxc/mst.db"""
import sqlite3
import sys
from pathlib import Path

args = sys.argv[1:]
src = Path(args[0]) if len(args) > 1 else Path.home() / ".mxc" / "mst.db"
dest = Path(args[-1])
dest.mkdir(parents=True, exist_ok=True)
for f in dest.glob("mst.db*"):
    f.unlink()
a = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
b = sqlite3.connect(dest / "mst.db")
a.backup(b)
a.close()
b.close()
print(dest / "mst.db")
