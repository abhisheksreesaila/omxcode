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

robots (goal 47): the DROID fleet (scripts/robot_data.py's folder): fleet.csv as the sheet, a chart and a pivot by lab;
telemetry.parquet as a card; the paper folder; four links (episode keys, the clip file, the time link, the paper by its
source); the featured failure picked (its video plays beside its telemetry lanes, three seeks with the cursor); the paper's
fields read from its text; two questions in words (JOIN LINKED); the picked failures packed. Leaves <out>/robots.json,
<out>/pack/*.pdf.

drone: for each flight, open drone_<k>.mp4 → Insert > Table… telemetry_<k>.csv (a log: it lands as a table card and a
chart + map card in step with the video) → Analyze (Assets & defects, the inspection preset: georeferenced with the log)
→ Query the defects → Export CSV; then Insert > Compare inspections… (earlier: flight a, later: flight b) → Export the
worse table → Flight plan (waypoints.csv); then seek flight a's video three times, drawing its telemetry chart each time
(its cursor prints CURSOR: t=, the video PLAYER: t=). Leaves <out>/defects_a.csv, defects_b.csv, worse.csv, waypoints.csv.
"""

import argparse
import os
import re
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


ROBOT_LINKS = ("fleet.episode = telemetry.episode", "fleet.clip = episode.file", "telemetry.t ~ episode.t +0", "fleet.source = paper.file")
ROBOT_CHART = "average success_pct by lab, largest first"
ROBOT_VERBS = "average success_pct by verb, largest first"
ROBOT_Q1 = "failures where the gripper closed, let go and closed again"
ROBOT_SQL1 = ("SELECT fleet.episode AS episode, fleet.lab AS lab, fleet.task AS task, fleet.clip AS clip, fleet.source AS source, "
              "COUNT(*) AS closes FROM fleet JOIN LINKED WHERE fleet.success = 0 AND telemetry.gripper_event = 'close' "
              "GROUP BY fleet.episode, fleet.lab, fleet.task, fleet.clip, fleet.source HAVING COUNT(*) >= 2 ORDER BY closes DESC, episode")
ROBOT_Q2 = "episodes within 30% of the arm's joint speed limit"
ROBOT_SQL2 = ("SELECT fleet.episode AS episode, fleet.lab AS lab, fleet.outcome AS outcome, MAX(telemetry.speed) AS peak "
              "FROM fleet JOIN LINKED WHERE telemetry.speed > 1.5225 GROUP BY fleet.episode, fleet.lab, fleet.outcome ORDER BY peak DESC")
ROBOT_PICKED = ("F00118", "F00119", "F00124")  # the featured drop and two failures beside it on the same bench (same robot, same day)
ROBOT_SQL3 = ("SELECT fleet.episode AS episode, fleet.lab AS lab, fleet.date AS date, fleet.task AS task, fleet.duration_s AS duration_s, "
              "fleet.grasps AS grasps, fleet.peak_speed AS peak_speed, fleet.clip AS clip, fleet.source AS source FROM fleet WHERE fleet.episode IN ("
              + ", ".join(f"'{e}'" for e in ROBOT_PICKED) + ") ORDER BY episode")
ROBOT_FIELDS = "recorded at, frequency of, Franka"


def robots(media, out):
    """Why did the robot drop it? (goal 47) The DROID fleet: the sheet, a pivot and a chart by lab; the featured failure's
    video beside its telemetry lanes (one cursor, through links); two questions in words (JOIN LINKED over 17M telemetry
    rows); the paper, linked by key; a pack of the picked failures. Only omxplorer's own tools."""
    import csv
    import json
    import re
    docs = out / "documents"
    for d in (docs, out / "config"):
        d.mkdir(parents=True, exist_ok=True)
    if (docs / "pack").exists():
        for f in (docs / "pack").iterdir():
            f.unlink()
    truth = json.loads((media / "truth.json").read_text())
    rows = list(csv.DictReader(open(media / "fleet.csv")))
    hero_row = [r["episode"] for r in rows].index(truth["hero"]) + 1
    env = {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(out / "config"), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": os.environ.get("MOJOUI_BUDGET_MS", "50"),
           "CUDA_VISIBLE_DEVICES": os.environ.get("CUDA_VISIBLE_DEVICES", "0")}
    s = Session(env)
    said = {}

    def until(tool, timeout=300):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if tool in s.c.names():
                return
            time.sleep(0.2)
        raise SystemExit(f"{tool} never appeared")

    def traced(prefix, mark, timeout=8):
        t0 = time.time()
        while time.time() - t0 < timeout:
            got = [l for l in s.log[mark:] if l.startswith(prefix)]
            if got:
                return got[-1]
            time.sleep(0.05)
        return ""

    try:
        print("# Why did the robot drop it? 63,000 real robot episodes from 13 labs (DROID), their telemetry, video and paper,")
        print("# joined only by links a person (or an agent) makes. Only omxplorer's own tools.")
        # 1. the fleet
        s.call("open-file", path=str((media / "fleet.csv").resolve()))
        until("create-table")
        s.call("create-table")
        until("chart")
        s.call("chart")
        s.call("ask", text=ROBOT_CHART, submit=True)
        said["chart"] = s.call("read", name="chart-1")
        before = set(s.c.names())
        s.call("pivot")
        time.sleep(1.0)
        drops = [t["name"] for t in s.c.tools() if t["name"] not in before and t.get("description", "").startswith("Dropdown")]
        if len(drops) < 3:
            raise SystemExit(f"the pivot's three dropdowns aren't on screen: {drops}")
        for name, option in zip(drops[:3], ("n", "lab", "outcome")):  # (value, rows, columns: named by their options)
            s.call(name, option=option)
            time.sleep(0.5)
        piv = [n for n in s.c.names() if n.startswith("pivot-") or n == "pivot-2"]
        said["pivot"] = s.call("read", name="pivot-2") if "pivot-2" in s.c.names() else s.call("screen", quiet=True)
        before = set(s.c.names())  # a second chart: success by the task's verb
        s.call("chart")
        time.sleep(0.6)
        ask2 = [t["name"] for t in s.c.tools() if t["name"].startswith("ask")][-1:]  # (the new chart's field: the last one on screen)
        chart2 = [n for n in s.c.names() if n.startswith("chart-") and n not in before]
        if ask2 and chart2:
            s.call(ask2[0], text=ROBOT_VERBS, submit=True)
            said["verbs"] = s.call("read", name=chart2[0])
        # 2. a failure opens: its video and its telemetry, one cursor
        s.call("insert-table")
        s.call("choose-table", path=str((media / "telemetry.parquet").resolve()))
        until("table-telemetry")
        s.call("links")
        for l in ROBOT_LINKS:
            s.call("link", text=l, submit=True)
        mark = len(s.log)
        s.call("grid", value=float(hero_row))
        said["open"] = traced("OPEN: ", mark)
        said["slice"] = traced("SLICE: ", mark)
        until("telemetry-chart")
        s.call("read", name="video")
        seeks = []
        for t in (4.0, 12.4, 13.3):  # (before; the shirt over the box; the shirt fallen on the box's wall)
            mark = len(s.log)
            s.call("seek", value=t)
            s.call("render", quiet=True, name="telemetry-chart")
            p, c = traced("PLAYER: t=", mark), traced("CURSOR: t=", mark)
            seeks.append((t, p, c))
        said["lanes"] = s.call("read", name="telemetry-chart")
        # 4. the paper, linked by key (read before the questions: its fields are a table the links reach)
        s.call("insert-documents", path=str((media / "paper").resolve()))
        until("fields")
        s.call("reader", option="PDF text")
        s.call("fields", text=ROBOT_FIELDS)
        s.call("read-documents")
        until("table-paper-fields", 120)
        s.call("read", name="table-paper-fields", count=3)
        s.call("highlight-field", option="recorded at")
        mark = len(s.log)
        s.call("grid", value=float(hero_row + 1))
        s.call("grid", value=float(hero_row))
        said["document"] = traced("DOCUMENT: ", mark)
        # 3. asked in words: JOIN LINKED over fleet ⨝ telemetry
        def ask_field():  # (the query dialog's "Ask in words": "ask-2" while a chart's own ask field is on screen)
            return [n for n in s.c.names() if n.startswith("ask") and n not in before_query][0]

        for q, sql, name in ((ROBOT_Q1, ROBOT_SQL1, "regrasped"), (ROBOT_Q2, ROBOT_SQL2, "fastest")):
            before_query = set(s.c.names())
            s.call("query")
            s.call(ask_field(), text=q)
            s.call("sql", text=sql)
            s.call("query-name", text=name)
            s.call("run-query")
            until(f"table-{name}", 600)
            said[name] = s.call("read", name=f"table-{name}", count=12)
        # 5. a pack of the picked failures
        before_query = set(s.c.names())
        s.call("query")
        s.call(ask_field(), text="the failures I picked")
        s.call("sql", text=ROBOT_SQL3)
        s.call("query-name", text="picked")
        s.call("run-query")
        until("table-picked", 120)
        said["picked"] = s.call("read", name="table-picked", count=5)
        s.call("table-picked", value=1.0)  # (the featured drop, F00118: its video, lanes and the paper follow from the answer's row)
        s.call("export-picked")
        pack = [t["name"] for t in s.c.tools() if t["name"].startswith("export-pack") and "picked" in t.get("description", "")]
        s.call(pack[0] if pack else "export-pack")
        t0 = time.time()
        while time.time() - t0 < 120 and len(list((docs / "pack").glob("*.pdf")) if (docs / "pack").exists() else []) < len(ROBOT_PICKED):
            time.sleep(0.5)
        time.sleep(2)
    finally:
        s.close()
    for line in s.log:
        if line.startswith(("JOB: ", "QUERY: ", "ASK: ", "LINK: ", "SELECT: ", "OPEN: ", "SLICE: ", "FOLLOW: ", "DOCUMENT: ", "PACK: ", "SLOW: ", "DOCUMENTS: ")):
            print(line[:400])
    print("\n# at each seek: the video's time and the telemetry lanes' cursor")
    for t, p, c in seeks:
        print(f"seek {t:>5.1f} s:  {p}   {c}")
    made = sorted((docs / "pack").glob("*")) if (docs / "pack").exists() else []
    (out / "pack").mkdir(exist_ok=True)
    for f in made:
        shutil.copyfile(f, out / "pack" / f.name)
    slow = [l for l in s.log if l.startswith("SLOW: ")]
    keep = ("JOB: ", "QUERY: ", "ASK: ", "LINK: ", "SELECT: ", "OPEN: ", "SLICE: ", "DOCUMENT: ", "PACK: ", "SLOW: ")
    summary = {"seeks": seeks, "said": said, "pack": [f.name for f in made], "slow": slow, "hero": truth["hero"], "hero_row": hero_row,
               "log": [l for l in s.log if l.startswith(keep)]}
    (out / "robots.json").write_text(json.dumps(summary, indent=1))
    print(f"pack: {[f.name for f in made]}; SLOW lines: {len(slow)}; summary {out / 'robots.json'}")


SCRIPT_M2 = """-- goal 49: the featured episode's video, its telemetry and the fleet, in one script
frames = SELECT * FROM episode;
tele = SELECT CAST(t * 15 AS INT) AS frame, gripper, speed, gripper_event FROM telemetry WHERE episode = '${episode}';
joined = SELECT '${episode}' AS episode, f.frame, f.t, tele.gripper, tele.speed FROM frames f JOIN tele ON tele.frame = f.frame;
with_fleet = SELECT j.episode, j.frame, j.gripper, fleet.lab, fleet.task FROM joined j JOIN fleet ON fleet.episode = j.episode;
"""


SECTION = (3.0, 8.0)  # the seconds of the featured episode Apply runs on
OTHER = "F00119"  # a colleague's episode for the reopened recipe (same bench, same day as the featured drop; has a clip)


def card_facts(text):
    """A table card's read: its rows (from "name (N rows · M columns)") and its first row's cells by column."""
    lines = text.splitlines()
    m = re.search(r"\(([0-9,]+) rows?", lines[0]) if lines else None
    rows = int(m.group(1).replace(",", "")) if m else -1
    cells = dict(zip(lines[1].split("\t"), lines[2].split("\t"))) if len(lines) > 2 else {}
    return {"rows": rows, "cells": cells}


def script(media, out):
    """One script over everything on the board (goal 49): the fleet sheet, its telemetry, the featured episode's video;
    a script joins them, each result a card. Only omxplorer's own tools."""
    import csv
    import json
    docs = out / "documents"
    for d in (docs, out / "config"):
        d.mkdir(parents=True, exist_ok=True)
    truth = json.loads((media / "truth.json").read_text())
    hero = truth["hero"]
    rows = list(csv.DictReader(open(media / "fleet.csv")))
    hero_row = [r["episode"] for r in rows].index(hero) + 1
    env = {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(out / "config"), "MOJOUI_TRACE": "1", "MOJOUI_BUDGET_MS": os.environ.get("MOJOUI_BUDGET_MS", "50"),
           "CUDA_VISIBLE_DEVICES": os.environ.get("CUDA_VISIBLE_DEVICES", "0")}
    s = Session(env)
    called = []
    cards = {}
    reopened = {}
    export = ""

    def call(tool, **args):
        called.append(tool)
        return s.call(tool, **args)

    def until(tool, timeout=300):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if tool in s.c.names():
                return
            time.sleep(0.2)
        raise SystemExit(f"{tool} never appeared; the app said: {[l for l in s.log if l.startswith(('SCRIPT:', 'JOB:'))][-6:]}")

    def run_script(text, names, timeout=600, answers=None, tool="run-script", **args):
        mark = len(s.log)
        if text is not None:
            call("script-text", text=text)
        for k, v in (answers or {}).items():  # (a recipe's ${questions}: their fields appear once the text asks them)
            until(f"recipe-{k}", 30)
            call(f"recipe-{k}", text=v)
        call(tool, **args)
        t0 = time.time()
        while time.time() - t0 < timeout:
            if any(l.startswith(("SCRIPT: problem", "JOB: script")) for l in s.log[mark:]):
                break
            time.sleep(0.2)
        problem = [l for l in s.log[mark:] if l.startswith("SCRIPT: problem")]
        if problem:
            raise SystemExit(problem[0])
        got = {}
        for n in names:  # (a card's tool is table-<its name>, "_" read as "-")
            tool = "table-" + n.replace("_", "-")
            until(tool, 60)
            got[f"table-{n}"] = card_facts(call("read", name=tool, count=1))
        return got

    available = []
    try:
        print("# One script over everything on the board: video, telemetry and the fleet. Only omxplorer's own tools.")
        call("open-file", path=str((media / "fleet.csv").resolve()))
        until("create-table")
        call("create-table")
        call("insert-table")
        call("choose-table", path=str((media / "telemetry.parquet").resolve()))
        until("table-telemetry")
        call("links")
        for l in ROBOT_LINKS[:3]:
            call("link", text=l, submit=True)
        call("grid", value=float(hero_row))  # (the featured episode's row: its clip opens as the video card "episode")
        until("video", 120)
        call("script")
        cards.update(run_script(SCRIPT_M2, ["frames", "joined", "with_fleet"], answers={"episode": hero}))
        # M3: a section of the video, Apply, Export
        call("range-from", text=str(SECTION[0]))
        call("range-to", text=str(SECTION[1]))
        cards.update(run_script(None, ["apply_1"], tool="apply-regions"))
        mark = len(s.log)
        call("export-recipe")
        t0 = time.time()
        while time.time() - t0 < 300 and not any(l.startswith("RECIPE: ") for l in s.log[mark:]):
            time.sleep(0.2)
        said = [l for l in s.log[mark:] if l.startswith("RECIPE: ")]
        if not said or not said[0].startswith("RECIPE: exported "):
            raise SystemExit(f"export: {said}")
        export = said[0].split(" ")[2]
        # M4: a colleague's episode: its row opens its clip in the same video card; the recipe reopened, asked anew
        other_row = [r["episode"] for r in rows].index(OTHER) + 1
        call("script-close")
        call("grid", value=float(other_row))
        time.sleep(2.0)
        call("script")
        call("script-text", text="")
        call("recipe-path", text=export)
        call("open-recipe")
        reopened.update(run_script(None, ["frames", "joined", "apply_1"], answers={"episode": OTHER}))
        available = s.c.names()
    finally:
        s.close()
    trace = [l for l in s.log if l.startswith(("SCRIPT:", "QUERY:", "JOB:", "SLOW:"))]
    summary = {"cards": cards, "trace": trace, "tools_called": called, "tools_available": available, "hero": hero,
               "export": export, "range": list(SECTION), "other": OTHER, "reopened": reopened}
    out.mkdir(parents=True, exist_ok=True)
    (out / "script.json").write_text(json.dumps(summary, indent=1))
    for l in trace:
        print(l[:300])
    print(f"summary {out / 'script.json'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", choices=["warehouse", "drone", "claims", "robots", "script"])
    ap.add_argument("--media", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    {"warehouse": warehouse, "drone": drone, "claims": claims, "robots": robots, "script": script}[a.name](Path(a.media).resolve(), out)


if __name__ == "__main__":
    main()
