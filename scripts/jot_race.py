"""Goal 42 M6: the race. Native mojoui.sqlite (A) against the official SQLite WebAssembly build with OPFS in headless
Chromium (B), on the same 1,000,000 notes, the same schema and the same SQL. Writes docs/goals/42/race.json.

  pixi run python scripts/jot_race.py            (generates the notes once into build/race/data, ~1 GB of disk in all)
  pixi run python scripts/jot_race.py --notes 20000 --out /tmp/race.json      (a quick dry run)

- Data: deterministic (random.Random(SEED)): an 8,000-word vocabulary with Zipf frequencies; a title of 3–6 words and
  a body of 20–50 words per note; one note per line of notes.tsv (title, a tab, body). Both sides read that file.
- SQL: pragmas.sql, schema.sql (Jot's notes + notes_fts + triggers), insert.sql (10,000 per transaction), finish.sql,
  open.sql, query.sql (Jot's search: every rowid matching a prefix), written once and run verbatim by both sides.
- Queries: 200 prefixes of vocabulary words (2–4 letters), as FTS5 strings `"pre"*` (what fts_prefix_query makes).
- A: tests/bench_jot_race.mojo, built with `mojo build`. B: scripts/jot_race_web (index.html, worker.js), the npm
  package pinned in its lockfile, served from http://localhost with COOP/COEP (the `opfs` VFS needs SharedArrayBuffer).
  B tries both OPFS VFSes (opfs-sahpool, opfs) and races with the faster (by search p95); both are recorded.
- Cold open: A from just before the process is spawned to the first query answered (the program's FIRST stamp, the
  same monotonic clock); B from navigation start (performance.now() in the page) to the Worker's first answer: wasm
  fetched and compiled, OPFS opened, the query run. The browser's own launch is left out (in B's favour).
- Each side: one warm-up run, then RUNS measured runs (fresh process / fresh browser each); race.json has the median of
  each figure and its spread (min–max) across runs, the machine's load and CPUs.
"""
import argparse
import json
import os
import random
import shutil
import statistics
import subprocess
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "scripts" / "jot_race_web"
WORK = ROOT / "build" / "race"
CHROMIUM = "/usr/bin/chromium"
SEED = 42
RUNS = 3
N_QUERIES = 200
VFSES = ["opfs-sahpool", "opfs"]

PRAGMAS = "PRAGMA journal_mode=WAL;\nPRAGMA synchronous=NORMAL;\nPRAGMA cache_size=-65536;\nPRAGMA temp_store=MEMORY\n"
SCHEMA = """CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', updated INTEGER NOT NULL DEFAULT 0);
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(title, body, content='notes', content_rowid='id');
CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
  INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
  INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body); END;
CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
  INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
  INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
"""
INSERT = "INSERT INTO notes(title, body, updated) VALUES (?, ?, ?)\n"
FINISH = "PRAGMA wal_checkpoint(TRUNCATE)\n"
OPEN = "PRAGMA cache_size=-65536;\nPRAGMA temp_store=MEMORY\n"
QUERY = "SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?\n"

SYLLABLES = ("ba be bi bo bu ca ce co cu da de di do fa fe fi fo ga ge go ha he hi ho ja jo ka ke ki ko la le li lo lu "
             "ma me mi mo mu na ne ni no nu pa pe pi po ra re ri ro ru sa se si so su ta te ti to tu va ve vi vo wa we "
             "wi ya yo za ze zo bar ber bin bor can cer con dan den dor fan fer gan gor han her lan len lin lor man mer "
             "min mor nan nor pan per por ran ren rin ron san ser sin son tan ter tin ton van ver vin").split()


def vocabulary(rng):
    words = set()
    while len(words) < 8000:
        words.add("".join(rng.choice(SYLLABLES) for _ in range(rng.choice((2, 2, 3, 3, 3, 4)))))
    words = sorted(words)
    rng.shuffle(words)  # (rank order: Zipf weight 1/rank)
    return words


def generate(n, data):
    """notes.tsv and queries.txt for n notes (kept while the same n and SEED were used)."""
    stamp = data / "stamp.json"
    want = {"notes": n, "seed": SEED, "queries": N_QUERIES, "v": 1}
    if stamp.exists() and json.loads(stamp.read_text()) == want:
        return
    data.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)
    vocab = vocabulary(rng)
    cum, total = [], 0.0
    for r in range(len(vocab)):
        total += 1.0 / (r + 1)
        cum.append(total)
    with open(data / "notes.tsv", "w") as f:
        for _ in range(n):
            t = rng.choices(vocab, cum_weights=cum, k=rng.randint(3, 6))
            b = rng.choices(vocab, cum_weights=cum, k=rng.randint(20, 50))
            body = []
            for i, w in enumerate(b):  # sentences of ~8–12 words
                body.append(w.capitalize() if i == 0 or body[-1].endswith(".") else w)
                if i % rng.randint(8, 12) == 7 or i == len(b) - 1:
                    body[-1] += "."
            f.write(" ".join([t[0].capitalize()] + t[1:]) + "\t" + " ".join(body) + "\n")
    words = sorted(w for w in vocab if len(w) >= 4)
    step = len(words) / N_QUERIES
    queries = ['"' + words[int(i * step)][: 2 + i % 3] + '"*' for i in range(N_QUERIES)]
    (data / "queries.txt").write_text("\n".join(queries) + "\n")
    for name, text in (("pragmas.sql", PRAGMAS), ("schema.sql", SCHEMA), ("insert.sql", INSERT), ("finish.sql", FINISH),
                       ("open.sql", OPEN), ("query.sql", QUERY)):
        (data / name).write_text(text)
    stamp.write_text(json.dumps(want))


def disk_mb(paths):
    total = 0
    for p in paths:
        p = Path(p)
        if p.is_file():
            total += p.stat().st_blocks * 512
        elif p.is_dir():
            total += sum(f.stat().st_blocks * 512 for f in p.rglob("*") if f.is_file())
    return round(total / 1e6, 1)


def p95(xs):
    s = sorted(xs)
    return s[int(0.95 * (len(s) - 1))]


def summary(runs):
    """Median and spread of each figure across the measured runs."""
    out, spread = {}, {}
    for key in ("cold_open_ms", "search_p50_ms", "search_p95_ms"):
        vals = [r[key] for r in runs]
        out[key] = round(statistics.median(vals), 2)
        spread[key] = [round(min(vals), 2), round(max(vals), 2)]
    out["runs"] = runs
    out["spread"] = spread
    return out


# ---- side A

def side_a(data, n):
    exe = WORK / "bench_jot_race"
    b = subprocess.run(["pixi", "run", "mojo", "build", "--disable-warnings", "-I", ".", "tests/bench_jot_race.mojo", "-o", str(exe)],
                       cwd=ROOT, capture_output=True, text=True)
    if b.returncode != 0:
        raise SystemExit("bench_jot_race build failed: " + (b.stdout + b.stderr)[-800:])
    db = WORK / "a" / "jot-race.db"
    shutil.rmtree(db.parent, ignore_errors=True)
    db.parent.mkdir(parents=True)
    print("A: building", flush=True)
    r = subprocess.run([str(exe), "build", str(data), str(db)], capture_output=True, text=True)
    line = next((l for l in r.stdout.splitlines() if l.startswith("BUILD ")), None)
    if r.returncode != 0 or not line:
        raise SystemExit("A build failed: " + (r.stdout + r.stderr)[-800:])
    built = json.loads(line[6:])
    runs, counts = [], None
    for k in range(RUNS + 1):  # (the first is the warm-up)
        t0 = time.monotonic_ns()
        r = subprocess.run([str(exe), "query", str(data), str(db)], capture_output=True, text=True)
        first = next(int(l.split()[1]) for l in r.stdout.splitlines() if l.startswith("FIRST "))
        q = json.loads(next(l for l in r.stdout.splitlines() if l.startswith("QUERY "))[6:])
        run = {"cold_open_ms": round((first - t0) / 1e6, 2), "search_p50_ms": round(statistics.median(q["ms"]), 3),
               "search_p95_ms": round(p95(q["ms"]), 3)}
        print(f"A run {k}{' (warm-up)' if k == 0 else ''}: {run}", flush=True)
        if k:
            runs.append(run)
            counts = counts or q["counts"]
            if q["counts"] != counts:
                raise SystemExit("A: counts differ between runs")
    out = {"notes": built["notes"], "build_s": round(built["build_s"], 2), **summary(runs), "counts": counts,
           "disk_mb": disk_mb([db, str(db) + "-wal", str(db) + "-shm"]), "engine": "mojoui.sqlite, system libsqlite3 (dlopen)"}
    return out


# ---- side B

class Handler(SimpleHTTPRequestHandler):
    data = None
    protocol_version = "HTTP/1.1"
    TYPES = {".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".html": "text/html",
             ".sql": "text/plain", ".txt": "text/plain", ".tsv": "text/plain"}

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0].lstrip("/") or "index.html"
        f = (self.data / path) if (self.data / path).is_file() and "/" not in path else WEB / path
        if ".." in path or not f.is_file():
            self.send_error(404)
            return
        body = f.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", self.TYPES.get(f.suffix, "application/octet-stream"))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)


def serve(data):
    Handler.data = data
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://localhost:{srv.server_address[1]}"


def browse(pw, profile, url, timeout_s):
    ctx = pw.chromium.launch_persistent_context(str(profile), executable_path=CHROMIUM, headless=True,
                                                args=["--no-first-run", "--disable-background-timer-throttling"])
    try:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(url)
        page.wait_for_function("window.result", timeout=timeout_s * 1000, polling=500)
        return page.evaluate("window.result")
    finally:
        ctx.close()


def side_b(data, n):
    if not (WEB / "node_modules" / "@sqlite.org" / "sqlite-wasm").exists():
        subprocess.run(["pixi", "run", "npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=WEB, check=True)
    from playwright.sync_api import sync_playwright
    srv, base = serve(data)
    results = {}
    try:
        with sync_playwright() as pw:
            for vfs in VFSES:
                profile = WORK / f"profile-{vfs}"
                shutil.rmtree(profile, ignore_errors=True)
                print(f"B ({vfs}): building", flush=True)
                built = browse(pw, profile, f"{base}/?mode=build&vfs={vfs}", 7200)
                if built.get("error"):
                    results[vfs] = {"error": built["error"], "notes": built.get("notes", 0)}
                    print(f"B ({vfs}): {built['error'][:300]}", flush=True)
                    continue
                runs, counts = [], None
                for k in range(RUNS + 1):
                    q = browse(pw, profile, f"{base}/?mode=query&vfs={vfs}", 1800)
                    if q.get("error"):
                        raise SystemExit(f"B ({vfs}) query failed: {q['error'][:400]}")
                    run = {"cold_open_ms": round(q["cold_open_ms"], 2), "search_p50_ms": round(statistics.median(q["ms"]), 3),
                           "search_p95_ms": round(p95(q["ms"]), 3)}
                    print(f"B ({vfs}) run {k}{' (warm-up)' if k == 0 else ''}: {run}", flush=True)
                    if k:
                        runs.append(run)
                        counts = counts or q["counts"]
                results[vfs] = {"notes": built["notes"], "build_s": round(built["build_s"], 2), **summary(runs), "counts": counts,
                                "disk_mb": disk_mb([profile / "Default" / "File System"]), "journal_mode": built["journal"],
                                "isolated": built["isolated"], "sqlite": built["version"]}
    finally:
        srv.shutdown()
    ok = {v: r for v, r in results.items() if not r.get("error")}
    if not ok:
        largest = max(r.get("notes", 0) for r in results.values())
        return {"error": "; ".join(f"{v}: {r['error'][:200]}" for v, r in results.items()), "notes": largest,
                "vfs_tried": VFSES, "vfs_results": results}
    best = min(ok, key=lambda v: ok[v]["search_p95_ms"])
    out = dict(ok[best])
    out.update({"vfs": best, "vfs_tried": VFSES,
                "vfs_results": {v: {k: x for k, x in r.items() if k not in ("counts", "runs")} for v, r in results.items()},
                "engine": "@sqlite.org/sqlite-wasm " + json.loads((WEB / "package.json").read_text())["dependencies"]["@sqlite.org/sqlite-wasm"]
                + " in a module Worker, headless " + subprocess.run([CHROMIUM, "--version"], capture_output=True, text=True).stdout.strip()})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--notes", type=int, default=1_000_000)
    ap.add_argument("--out", default=str(ROOT / "docs" / "goals" / "42" / "race.json"))
    ap.add_argument("--only", choices=["a", "b"])
    args = ap.parse_args()
    srcs = ["mojoui/sqlite.mojo", "scripts/jot_race.py"]
    dirty = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", *srcs], cwd=ROOT).returncode != 0
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    data = WORK / f"data-{args.notes}"
    t = time.time()
    generate(args.notes, data)
    print(f"data: {args.notes} notes in {data} ({time.time() - t:.0f} s)", flush=True)
    machine = {"load_before": os.getloadavg(), "cpus": os.cpu_count(),
               "cpu": next((l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")), "?"),
               "page_cache": "warm on both sides (the warm-up run; no root to drop caches)"}
    out = {"commit": commit if not dirty else "dirty", "date": time.strftime("%Y-%m-%d %H:%M"), "machine": machine,
           "notes": args.notes, "queries": N_QUERIES, "sql": {"pragmas": PRAGMAS, "query": QUERY.strip(), "insert": INSERT.strip()}}
    if args.only != "b":
        machine["load_a"] = os.getloadavg()
        out["a"] = side_a(data, args.notes)
    if args.only != "a":
        machine["load_b"] = os.getloadavg()
        out["b"] = side_b(data, args.notes)
    machine["load_after"] = os.getloadavg()
    a, b = out.get("a"), out.get("b")
    if a and b and not b.get("error"):
        out["same_counts"] = a["counts"] == b["counts"]
        out["ratio"] = {"search_p95": round(b["search_p95_ms"] / a["search_p95_ms"], 2),
                        "cold_open": round(b["cold_open_ms"] / a["cold_open_ms"], 2)}
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps({k: v for k, v in out.items() if k in ("same_counts", "ratio")}), flush=True)
    for side in ("a", "b"):
        s = out.get(side) or {}
        print(side.upper(), {k: s.get(k) for k in ("notes", "vfs", "build_s", "cold_open_ms", "search_p50_ms", "search_p95_ms", "disk_mb", "spread", "error")}, flush=True)


if __name__ == "__main__":
    main()
