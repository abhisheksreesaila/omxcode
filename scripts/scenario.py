"""Goal 39's end-to-end scenarios: the real omxplorer driven ONLY through its agent tools (the MCP host, mojoui/hosts/agent.py,
over omxplorer's web build), as an agent (or a person) would use it. The tool calls print as a transcript: it doubles as the
demo script.

  pixi run python scripts/scenario.py warehouse --media build/g39/media --out build/g39/warehouse

warehouse: open warehouse.mp4 → Analyze (Objects & codes, the warehouse preset) → the detections land as the sheet's table →
Insert > Table… shipments.csv → Query: the delivered shipments whose pallet code never shows → Export CSV → Make a reel
(damaged frames, faces blurred, the shipment burned in). Leaves <out>/reel.mp4 and <out>/missing.csv (and the documents the
app wrote in <out>/documents). Exit 1 when a tool fails.
"""

import argparse
import os
import shutil
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agent_client import Client, app_build  # noqa: E402

MISSING_SQL = ("SELECT shipment FROM shipments WHERE status = 'delivered' "
               "AND pallet_code NOT IN (SELECT code FROM detections WHERE code IS NOT NULL) ORDER BY shipment")


class Session:
    """A Client with a transcript: every call printed as `→ tool {args}` and what the app said back, indented."""

    def __init__(self, env):
        self.c = Client(app_build("omxplorer"), env=env)
        self.log = []  # what the app printed (stderr): PLAYER: / JOB: / QUERY: trace lines
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()
        self.step = 0

    def _drain(self):
        for line in self.c.p.stderr:
            self.log.append(line.rstrip("\n"))

    def call(self, tool, quiet=False, **args):
        self.step += 1
        shown = ", ".join(f"{k}={v!r}" for k, v in args.items())
        print(f"\n{self.step:>2}. → {tool}({shown})", flush=True)
        t0 = time.perf_counter()
        text, _, err = self.c.call(tool, **args)
        took = time.perf_counter() - t0
        lines = [l for l in text.splitlines() if l.strip()]
        if not quiet:
            for l in lines[:14]:
                print(f"      {l}")
            if len(lines) > 14:
                print(f"      … ({len(lines) - 14} more lines)")
        print(f"      ({took:.1f} s)", flush=True)
        if err:
            raise SystemExit(f"tool {tool} failed: {text}")
        return text

    def close(self):
        try:
            self.c.p.stdin.close()
            self.c.p.wait(timeout=30)
        except Exception:
            self.c.p.kill()
        self.reader.join(timeout=5)


def warehouse(media, out):
    docs = out / "documents"
    for d in (docs, out / "config"):
        d.mkdir(parents=True, exist_ok=True)
    for f in ("reel.mp4", "missing.csv"):
        (out / f).unlink(missing_ok=True)
    (docs / "warehouse-reel.mp4").unlink(missing_ok=True)
    env = {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(out / "config"), "MOJOUI_TRACE": "1",
           "CUDA_VISIBLE_DEVICES": os.environ.get("CUDA_VISIBLE_DEVICES", "0")}
    s = Session(env)
    try:
        print("# The warehouse: a 60-second reel of every damaged pallet, faces blurred, the shipment burned in;")
        print("# and the delivered shipments whose label never appears on camera. Only omxplorer's own tools.")
        s.call("open-file", path=str((media / "warehouse.mp4").resolve()))
        s.call("analyze")
        s.call("analyze-objects-codes-warehouse-preset")
        s.call("read", name="grid", count=6)
        s.call("insert-table")
        s.call("choose-table", path=str((media / "shipments.csv").resolve()))
        s.call("query")
        s.call("sql", text=MISSING_SQL)
        s.call("query-name", text="missing")
        s.call("run-query")
        s.call("read", name="table-missing", count=20)
        s.call("export-missing")
        s.call("make-reel")
        s.call("reel-where", option="damaged")
        s.call("reel-caption", option="shipments · shipment")
        s.call("reel-blur-faces", on=True)
        s.call("reel-make")
        s.call("seek", value=6.0)  # (the source video: the moment the first damaged pallet passes)
        s.call("read", name="video", quiet=False)
        screen = s.call("screen", quiet=True)
        print("      " + "\n      ".join(l for l in screen.splitlines() if l.lstrip().startswith(("Object [", '"warehouse', '"missing', '"shipments'))))
    finally:
        s.close()
    for line in s.log:
        if line.startswith(("PLAYER: t=", "JOB: ", "QUERY: ")):
            print(line)
    reel, missing = docs / "warehouse-reel.mp4", docs / "missing.csv"
    if not reel.exists() or not missing.exists():
        raise SystemExit(f"the app didn't write {'warehouse-reel.mp4' if not reel.exists() else 'missing.csv'} in {docs}")
    shutil.copyfile(reel, out / "reel.mp4")
    shutil.copyfile(missing, out / "missing.csv")
    print(f"\nreel.mp4: {reel.stat().st_size // 1024} KB; missing.csv: {missing.read_text().strip().splitlines()[1:]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", choices=["warehouse"])
    ap.add_argument("--media", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    {"warehouse": warehouse}[a.name](Path(a.media).resolve(), out)


if __name__ == "__main__":
    main()
