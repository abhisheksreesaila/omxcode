"""Goal 70 M1: the app's own query paths on the old engine (834ef9a) and the new one (a9a3c37), same machine, same run.

    pixi run python -I docs/goals/70/bench_m1.py [ROUNDS]       (default 3: each build starts one round)

Builds tests/bench_engine_paths.mojo three times, so the engine's change and the app's (D-7006) are told apart:
  main        834ef9a's package (build/eng-before), every sheet put in a query as a Frame (-D BENCH_MAIN_PATH): main today
  old+sheet   834ef9a's package with this branch's add_sheet (an untouched sheet as a plain table; its refuse_wide line
              left out, see old_engine_source)
  new         a9a3c37's package (vendor's, build/eng-after) with add_sheet: this branch
then for each spec in docs/goals/70/*.spec runs the three in turn, ROUNDS rounds of 5 runs each (interleaved, each round
starting with another build, so a busy neighbour slows all alike). Every answer file must be byte-equal across the three, and none may be an engine refusal.
Writes build/g70/m1.json and docs/goals/70-bench.md (the median of every run; ratios: the engine alone = old+sheet / new,
the branch = main / new; slower cases kept)."""
import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g70/m1"
SPECS = ["fleet68", "fleet47", "tpch"]
BUILDS = {"main": ("before", True), "old_sheet": ("before", False), "new": ("after", False)}  # name: (engine dir, main's add_frame)


def sh(args, **kw):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, **kw)


def old_engine_source():
    """tests/bench_engine_paths.mojo for 834ef9a: its add_sheet is mojoui.tablecard's, copied here without the
    `frame.refuse_wide()` line (834ef9a's Frame has no 128-bit columns, so no such method: the check is a no-op there)."""
    card = (ROOT / "mojoui/tablecard.mojo").read_text()
    a = card.index("def add_sheet(")
    body = card[a: card.index("\n\n\n", a)]
    if "    frame.refuse_wide()\n" not in body:
        raise SystemExit("mojoui.tablecard.add_sheet changed: update docs/goals/70/bench_m1.py's copy")
    body = body.replace("    frame.refuse_wide()\n", "").replace("frame: MxFrame", "frame: OldFrame")
    src = (ROOT / "tests/bench_engine_paths.mojo").read_text()
    want = "from mojoui.tablecard import query_table, add_sheet\n"
    if want not in src:
        raise SystemExit("tests/bench_engine_paths.mojo's imports changed: update docs/goals/70/bench_m1.py")
    src = src.replace(want, "from mojoui.tablecard import query_table\nfrom omxcore import Frame as OldFrame\n") + "\n\n" + body + "\n"
    out = OUT / "bench_engine_paths_834ef9a.mojo"
    out.write_text(src)
    return str(out)


def build(name):
    eng, main_path = BUILDS[name]
    exe = OUT / f"bench_engine_paths_{name}"
    link = sh(["bash", "-c", "source scripts/mxlink.sh; printf '%s\\n' \"${LINK[@]}\""]).stdout.split()
    flags = ["-D", "BENCH_MAIN_PATH"] if main_path else []
    src = old_engine_source() if eng == "before" else "tests/bench_engine_paths.mojo"
    r = sh(["pixi", "run", "mojo", "build", "--disable-warnings", "-I", ".", "-I", f"build/eng-{eng}", *flags, src, "-o", str(exe), *link])
    if r.returncode or not exe.exists():
        raise SystemExit(f"bench build ({name}) failed: " + (r.stdout + r.stderr)[-1500:])
    return exe


def engines_ready():
    """build/eng-before holds 834ef9a's package (main's vendor/omxcore.mojoc), build/eng-after vendor's."""
    for e in ("before", "after"):
        d = ROOT / f"build/eng-{e}"
        d.mkdir(parents=True, exist_ok=True)
        for sub in ("json", "flare"):
            if not (d / sub).exists():
                (d / sub).symlink_to(ROOT / "vendor" / sub)
    before = ROOT / "build/eng-before/omxcore.mojoc"
    if not before.exists():
        before.write_bytes(subprocess.run(["git", "show", "9e3e9d0f:vendor/omxcore.mojoc"], cwd=ROOT, capture_output=True).stdout)
    (ROOT / "build/eng-after/omxcore.mojoc").write_bytes((ROOT / "vendor/omxcore.mojoc").read_bytes())


def ratio(a, b):
    return a / b if b > 0 else None


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    OUT.mkdir(parents=True, exist_ok=True)
    sh(["pixi", "run", "python", "-I", "docs/goals/70/make_tpch.py"])
    engines_ready()
    exes = {b: build(b) for b in BUILDS}
    times = {}  # spec -> step -> build -> [ms]
    opens = {}
    loads = []
    for spec in SPECS:
        times[spec] = {}
        for rnd in range(rounds):
            order = list(BUILDS)[rnd % 3:] + list(BUILDS)[: rnd % 3]  # (each round starts with another build)
            for b in order:
                loads.append(os.getloadavg()[0])
                r = sh(["pixi", "run", str(exes[b]), f"docs/goals/70/{spec}.spec", str(OUT / b / spec), "5"], timeout=3600)
                if r.returncode:
                    raise SystemExit(f"{spec} ({b}): " + (r.stdout + r.stderr)[-1500:])
                print(f"{spec} round {rnd + 1} {b} (load {loads[-1]:.1f}) done", flush=True)
                for name, xs in re.findall(r"^TIME (\S+) (.*?) median=", r.stdout, re.M):
                    times[spec].setdefault(name, {}).setdefault(b, []).extend(float(x) for x in xs.split())
                for name, ms in re.findall(r"^OPEN (\S+) rows=\d+ ms=(\S+)", r.stdout, re.M):
                    opens.setdefault(f"{spec}/{name}", {}).setdefault(b, []).append(float(ms))
    diffs, count = [], 0
    for spec in SPECS:
        for f in sorted((OUT / "main" / spec).glob("*.txt")):
            count += 1
            for b in ("old_sheet", "new"):
                g = OUT / b / spec / f.name
                if not g.exists() or g.read_bytes() != f.read_bytes():
                    diffs.append(f"{b}:{spec}/{f.name}")
    errors = sorted(f"{b}:{spec}/{f.name}" for b in BUILDS for spec in SPECS for f in (OUT / b / spec).glob("*.txt") if f.read_text().startswith("ERROR:"))
    rows = []
    for spec in SPECS:
        for name, by in times[spec].items():
            m, o, n = (statistics.median(by[b]) for b in BUILDS)
            rows.append({"spec": spec, "step": name, "main_ms": m, "old_sheet_ms": o, "new_ms": n,
                         "engine_ratio": ratio(o, n), "branch_ratio": ratio(m, n), "runs": len(by["new"])})
    # the noise seen: charts and pivots (sheetpage.compute) never touch the catalog, so main and old+sheet run the same
    # code on the same engine there; how far apart their medians land is how far apart identical work lands in this run
    same = [max(r["main_ms"], r["old_sheet_ms"]) / min(r["main_ms"], r["old_sheet_ms"]) for r in rows
            if ("chart" in r["step"] or "pivot" in r["step"]) and min(r["main_ms"], r["old_sheet_ms"]) > 0]
    noise = max(same) if same else 1.0
    res = {"noise": noise, "rounds": rounds, "answers": count, "differ": diffs, "errors": errors, "rows": rows, "opens": opens,
           "load": [min(loads), max(loads)]}
    (OUT.parent / "m1.json").write_text(json.dumps(res, indent=1))
    fmt = lambda x: f"{x:.2f}×" if x else "–"  # noqa: E731
    lines = ["# Goal 70 M1: the app's query paths, omxcore 834ef9a vs a9a3c37", "",
             f"Same machine, same run: {rounds} interleaved rounds of 5 runs each per build (median of {5 * rounds}); load average "
             f"{min(loads):.1f}–{max(loads):.1f} on 24 cores (other sessions). Noise seen: identical code (charts and pivots, main vs old+sheet: "
             f"they don't touch the catalog) landed up to {noise:.2f}× apart, so a single step's ratio within that is not a finding. {count} answers compared byte "
             f"for byte across the three builds: {len(diffs)} differ, {len(errors)} are refusals. Made by `docs/goals/70/bench_m1.py`; "
             "the paths are tests/bench_engine_paths.mojo's (implied_sql + query_table, sheetpage.compute).", "",
             "Builds: **main** = 834ef9a, every sheet as a Frame (main today); **old+sheet** = 834ef9a with this branch's add_sheet "
             "(an untouched sheet as a plain table, D-7006); **new** = a9a3c37 with add_sheet (this branch). **Engine** = old+sheet / new "
             "(the engine's change alone); **branch** = main / new (what a user gets). Above 1: faster.", "",
             "| data | step | main ms | old+sheet ms | new ms | engine | branch |", "|---|---|---:|---:|---:|---:|---:|"]
    for r in rows:
        lines.append(f"| {r['spec']} | {r['step']} | {r['main_ms']:.2f} | {r['old_sheet_ms']:.2f} | {r['new_ms']:.2f} | {fmt(r['engine_ratio'])} | {fmt(r['branch_ratio'])} |")
    lines += ["", "Opening the tables (read_table, not timed above; main → new): " + "; ".join(
        f"{k} {statistics.median(v['main']):.0f} → {statistics.median(v['new']):.0f} ms" for k, v in opens.items())]
    if errors:
        lines += ["", "Refused: " + ", ".join(errors)]
    (ROOT / "docs/goals/70-bench.md").write_text("\n".join(lines) + "\n")
    print(f"answers {count}, differ {len(diffs)}: {diffs[:10]}; refusals {len(errors)}")
    sys.exit(1 if diffs or errors else 0)


if __name__ == "__main__":
    main()
