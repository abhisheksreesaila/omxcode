"""Goal 39's end-to-end scenarios: the real omxplorer driven ONLY through its agent tools (the MCP host, mojoui/hosts/agent.py,
over omxplorer's web build), as an agent (or a person) would use it. The tool calls print as a transcript: it doubles as the
demo script.

  pixi run python scripts/scenario.py warehouse --media build/g39/media --out build/g39/warehouse

warehouse: open warehouse.mp4 → Analyze (Objects & codes, the warehouse preset) → the detections land as the sheet's table →
Insert > Table… shipments.csv → Query: the delivered shipments whose pallet code never shows → Export CSV → Make a reel
(damaged frames, faces blurred, the shipment burned in). Leaves <out>/reel.mp4 and <out>/missing.csv (and the documents the
app wrote in <out>/documents). Exit 1 when a tool fails.

claims: open dock.mp4, Analyze it (Objects & codes), Insert > Table… shipments.csv, Insert > Documents… the BOL folder and
read its fields (OCR, the labels given as data), link shipments.shipment_id to the video's codes and to the BOLs' shipment
numbers, ask "damaged pallets whose BOL says no exceptions" (the SQL taught beside it: FROM shipments JOIN LINKED, the joins
the links imply), Export CSV the answer, select each answer row (the video seeks, the BOL page marks its Exceptions box),
Export pack. Leaves <out>/answer.csv, <out>/selections.csv (shipment, frame, page, x, y, w, h: read back from the app's trace
lines), <out>/pack/<shipment>.pdf and .mp4. Runs in the models environment (the OCR model runs in the app's process).

drone: for each flight, open drone_<k>.mp4 → Insert > Table… telemetry_<k>.csv (a log: it lands as a table card and a
chart + map card in step with the video) → Analyze (Assets & defects, the inspection preset: georeferenced with the log)
→ Query the defects → Export CSV; then Insert > Compare inspections… (earlier: flight a, later: flight b) → Export the
worse table → Flight plan (waypoints.csv); then seek flight a's video three times, drawing its telemetry chart each time
(its cursor prints CURSOR: t=, the video PLAYER: t=). Leaves <out>/defects_a.csv, defects_b.csv, worse.csv, waypoints.csv.
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

    def __init__(self, env, python=None):
        self.c = Client(app_build("omxplorer"), env=env, python=python)
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


def defects_sql(table):
    return f"SELECT asset, lat, lon, severity FROM {table} WHERE kind = 'defect' ORDER BY asset, lat"


def drone(media, out):
    docs = out / "documents"
    for d in (docs, out / "config"):
        d.mkdir(parents=True, exist_ok=True)
    outputs = ("defects_a.csv", "defects_b.csv", "worse.csv", "waypoints.csv")
    for f in outputs:
        (out / f).unlink(missing_ok=True)
        (docs / f).unlink(missing_ok=True)
    env = {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(out / "config"), "MOJOUI_TRACE": "1",
           "CUDA_VISIBLE_DEVICES": os.environ.get("CUDA_VISIBLE_DEVICES", "0")}
    s = Session(env)
    seeks = []
    try:
        print("# The drone: two inspection flights along a power line become a table of every asset and defect, on the map;")
        print("# which assets got worse since last time, and the next flight plan. The telemetry plays beside the video.")
        for k, n in (("a", ""), ("b", "-2")):  # (the second video joins the first one's sheet: the toolbar's Open)
            s.call("open-file" if k == "a" else "open", path=str((media / f"drone_{k}.mp4").resolve()))
            s.call("insert-table")
            s.call("choose-table", path=str((media / f"telemetry_{k}.csv").resolve()))
            s.call("analyze" + n)
            s.call("analyze-assets-defects-inspection-preset")
            s.call("query")
            s.call("sql", text=defects_sql(f"drone_{k}_places"))
            s.call("query-name", text=f"defects_{k}")
            s.call("run-query")
            s.call("read", name=f"table-defects-{k}", count=12)
            s.call(f"export-defects-{k}")
        s.call("insert-compare-inspections")
        s.call("compare-earlier", option="drone_a_places")
        s.call("compare-later", option="drone_b_places")
        s.call("compare-go")
        s.call("read", name="table-worse", count=12)
        s.call("export-worse")
        s.call("flight-plan")
        s.call("read", name="table-waypoints", count=12)
        for t in (5.0, 12.5, 20.0):  # flight a's video, and its telemetry chart's cursor with it
            mark = len(s.log)
            s.call("seek", value=t)
            s.call("render", quiet=True, name="telemetry-a-chart")
            deadline = time.time() + 5
            while time.time() < deadline and not any(l.startswith("CURSOR: t=") for l in s.log[mark:]):
                time.sleep(0.05)
            got = s.log[mark:]
            p = [l for l in got if l.startswith("PLAYER: t=")]
            c = [l for l in got if l.startswith("CURSOR: t=")]
            seeks.append((t, p[-1] if p else "(no PLAYER line)", c[-1] if c else "(no CURSOR line)"))
        s.call("read", name="telemetry-a-chart")
        s.call("read", name="telemetry-a-map")
        screen = s.call("screen", quiet=True)
        print("      " + "\n      ".join(l for l in screen.splitlines() if l.lstrip().startswith(("Object [", '"drone', '"telemetry', '"worse', '"waypoints', '"defects'))))
    finally:
        s.close()
    for line in s.log:
        if line.startswith(("JOB: ", "QUERY: ", "TRACK: ")):
            print(line)
    print("\n# at each seek: the video's time and the telemetry chart's cursor")
    for t, p, c in seeks:
        print(f"seek {t:>5.1f} s:  {p}   {c}")
    for f in outputs:
        if not (docs / f).exists():
            raise SystemExit(f"the app didn't write {f} in {docs}")
        shutil.copyfile(docs / f, out / f)
        rows = (docs / f).read_text().strip().splitlines()
        print(f"{f}: {len(rows) - 1} rows ({rows[0]})")


CLAIM_FIELDS = "Shipment no., Date, Consignee, Carrier, Pallets, Exceptions, Signed by"  # the labels printed on the forms (data)
CLAIM_LINKS = ("shipments.shipment_id = dock.mp4.code", "shipments.shipment_id = bol fields.shipment_no")
CLAIM_QUESTION = "damaged pallets whose BOL says no exceptions"
CLAIM_SQL = ("SELECT DISTINCT shipments.shipment_id AS shipment FROM shipments JOIN LINKED "
             "WHERE detections.damaged = true AND bol_fields.exceptions = 'None' ORDER BY shipment")


def models_python():
    """The models environment's Python (torch + docTR), for an app that runs its OCR model in process."""
    root = Path(__file__).resolve().parent.parent
    p = root / ".pixi" / "envs" / "models" / "bin" / "python"
    return p if p.exists() else None


def claims(media, out):
    import csv
    import re
    docs = out / "documents"
    for d in (docs, out / "config", out / "pack"):
        d.mkdir(parents=True, exist_ok=True)
    for f in ("answer.csv", "selections.csv"):
        (out / f).unlink(missing_ok=True)
    for d in (docs / "pack", out / "pack"):
        if d.exists():
            for f in d.iterdir():
                f.unlink()
    env = {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(out / "config"), "MOJOUI_TRACE": "1",
           "CUDA_VISIBLE_DEVICES": os.environ.get("CUDA_VISIBLE_DEVICES", "0")}
    s = Session(env, python=models_python())
    picked = []
    try:
        print("# The claim: which damaged pallets does the carrier owe for? The dock camera, the shipments sheet and the")
        print("# signed bills of lading, linked by hand (two key links), asked in words, every answer shown on the video and")
        print("# the page, then a claim pack per shipment. Only omxplorer's own tools.")
        s.call("open-file", path=str((media / "dock.mp4").resolve()))
        s.call("analyze")
        s.call("analyze-objects-codes-warehouse-preset")
        s.call("insert-table")
        s.call("choose-table", path=str((media / "shipments.csv").resolve()))
        s.call("insert-documents", path=str((media / "bol").resolve()))
        s.call("fields", text=CLAIM_FIELDS)
        s.call("read-documents")
        s.call("read", name="table-bol-fields", count=20)
        s.call("highlight-field", option="Exceptions")
        s.call("links")
        for l in CLAIM_LINKS:
            s.call("link", text=l, submit=True)
        s.call("query")
        s.call("ask", text=CLAIM_QUESTION)
        s.call("sql", text=CLAIM_SQL)
        s.call("query-name", text="answer")
        s.call("run-query")
        answer = s.call("read", name="table-answer", count=50)
        s.call("export-answer")
        rows = [l for l in answer.splitlines()[2:] if l.strip()]
        for i, key in enumerate(rows):
            mark = len(s.log)
            s.call("table-answer", value=float(i + 1))
            deadline = time.time() + 5
            while time.time() < deadline and not (any(l.startswith("PLAYER: t=") for l in s.log[mark:]) and any(l.startswith("DOCUMENT: ") for l in s.log[mark:])):
                time.sleep(0.05)
            got = s.log[mark:]
            player = [l for l in got if l.startswith("PLAYER: t=")]
            doc = [l for l in got if l.startswith("DOCUMENT: ")]
            frame = re.search(r"frame=(\d+)", player[-1]).group(1) if player else ""
            box = dict(re.findall(r"(page|x|y|w|h)=([0-9.]+)", doc[-1])) if doc else {}
            said = s.call("read", name="video")  # (the player's own state: "t=5.333 s of 38.000 s, frame 160 of 1140, …")
            m = re.search(r"frame (\d+) of", said)
            if m and frame and m.group(1) != frame:
                raise SystemExit(f"the player says frame {m.group(1)}, its trace line {frame}")
            frame = frame or (m.group(1) if m else "")
            picked.append((key.split("\t")[0], frame, box.get("page", ""), box.get("x", ""), box.get("y", ""), box.get("w", ""), box.get("h", "")))
            s.call("read", name="document")
        s.call("export-pack")
        screen = s.call("screen", quiet=True)
        print("      " + "\n      ".join(l for l in screen.splitlines() if l.lstrip().startswith(("Object [", '"answer', '"bol', '"shipments'))))
    finally:
        s.close()
    for line in s.log:
        if line.startswith(("JOB: ", "QUERY: ", "ASK: ", "LINK: ", "SELECT: ", "FOLLOW: ", "DOCUMENT: ", "PACK: ", "SLOW: ", "DOCUMENTS: ", "PLAYER: ")):
            print(line)
    ans = docs / "answer.csv"
    if not ans.exists():
        raise SystemExit(f"the app didn't write answer.csv in {docs}")
    shutil.copyfile(ans, out / "answer.csv")
    with open(out / "selections.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["shipment", "frame", "page", "x", "y", "w", "h"])
        w.writerows(picked)
    made = sorted((docs / "pack").glob("*")) if (docs / "pack").exists() else []
    for f in made:
        shutil.copyfile(f, out / "pack" / f.name)
    print(f"\nanswer.csv: {ans.read_text().strip().splitlines()[1:]}; selections: {picked}; pack: {[f.name for f in made]}")
    slow = [l for l in s.log if l.startswith("SLOW: ")]
    print(f"SLOW lines: {len(slow)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", choices=["warehouse", "drone", "claims"])
    ap.add_argument("--media", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    {"warehouse": warehouse, "drone": drone, "claims": claims}[a.name](Path(a.media).resolve(), out)


if __name__ == "__main__":
    main()
