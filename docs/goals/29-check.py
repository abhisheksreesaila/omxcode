"""Milestone checker for GOAL.md (goal 29: charts that ask MX frame 321870f more; goal 28's checks run as M5, every
earlier goal's inside them). Rebuilds from scratch, prints PASS/FAIL per milestone.

Run: scripts/check   (a subset without rebuilding: scripts/check M1 M2; earlier goals: through docs/goals/NN-check.py)
"""

import importlib.util
import math
import re
import sys
import time
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())  # (archived in docs/goals/)
sys.path.insert(0, str(ROOT / "scripts"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g28 = load("goal28", "docs/goals/28-check.py")
g27, g26, g25 = g28.g27, g28.g26, g28.g25
g20 = g25.g20
run, BUILD = g20.run, g20.BUILD
OUT = BUILD / "g29"
labels = g25.labels
APPS = ["hello", "gallery", "todo", "gpu", "kitchen", "expenses", "layout", "lens", "analytics", "workbook", "mxstudio", "omxplorer", "kit", "themes"]


def m0():
    """The new engine everywhere: vendored from 321870f; every example built for every platform it lists; FLOAT columns."""
    problems = []
    from engine_lineage import vendored_at_least  # (D-269: 321870f or a later stable engine, proved from its archive)
    why = vendored_at_least("321870f")
    if why:
        problems.append(why)
    for ex in APPS:
        plats = (ROOT / "examples" / ex / "platforms").read_text().split() if (ROOT / "examples" / ex / "platforms").exists() else ["linux", "web", "mac", "ios"]
        for plat in plats:
            if plat in ("linux", "web", "mac", "ios") and not (BUILD / ex / plat).exists():
                problems.append(f"{ex} has no {plat} build")
    err = g20.mojo_test("tests/test_float_column.mojo", "PASSED", "test_float_column", "tests")
    if err:
        problems.append(err)
    return not problems, "; ".join(problems[:6]) or "vendor/ is MX frame 321870f; every example built for Linux, the web, Mac and iPhone (as its platforms list); FLOAT columns show their numbers"


STATS = [("median", "table", 0, None), ("p90", "table", 0, None), ("median", "largest", 3, None), ("median", "table", 0, True),
         ("p90", "az", 0, False), ("p90", "smallest", 2, None)]


def stat(vals, how):
    v = sorted(vals)
    if not v:
        return None
    if how == "median":
        n = len(v)
        return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2
    return v[max(math.ceil(0.9 * len(v)) - 1, 0)]  # (DuckDB's quantile_disc)


def m1():
    """Median and p90 per group: six specs equal pyarrow's (the "(blank)" group has none yet: "—")."""
    import pyarrow.parquet as pq
    problems = []
    b = run(["scripts/mxbuild.sh", "tests/chartstats_dump.mojo", "-o", str(BUILD / "chartstats_dump")], timeout=1800)
    if b.returncode != 0:
        return False, "chartstats_dump: " + (b.stdout + b.stderr)[-400:]
    out = run([str(BUILD / "chartstats_dump"), g25.small()], timeout=300).stdout
    rows = pq.read_table(g25.small()).to_pylist()
    blocks = re.split(r"^SPEC \d+\n", out.split("END")[0], flags=re.M)[1:]
    if len(blocks) != len(STATS):
        return False, f"{len(blocks)} charts printed: {out[-300:]}"
    for k, (block, (how, order, top, paid)) in enumerate(zip(blocks, STATS)):
        groups = {}
        for r in rows:
            if paid is not None and r["paid"] is not paid:
                continue
            if r["region"] is None:
                continue
            groups.setdefault(r["region"], []).append(float(r["amount"]) if r["amount"] is not None else None)
        want = {g: stat([v for v in vs if v is not None], how) for g, vs in groups.items()}
        got = [(l.split("\t")[0], l.split("\t")[1]) for l in block.strip().split("\n")[1:]]
        for name, text in got:
            if name == "(blank)":
                if text != "—":
                    problems.append(f"spec {k}: (blank) reads {text}")
                continue
            if abs(float(text.replace(",", "")) - want[name]) > 0.006:
                problems.append(f"spec {k} ({how}, {order}): {name} {text} vs pyarrow {want[name]:.3f}")
        named = [n for n, _ in got if n != "(blank)"]
        if len(named) != (min(top, len(want)) if top else len(want)) or not set(named) <= set(want):
            problems.append(f"spec {k}: {len(named)} groups shown, want {min(top, len(want)) if top else len(want)}: {named}")
        if order == "az" and named != sorted(named):
            problems.append(f"spec {k}: not A to Z: {named}")
        if order == "largest" and named != sorted(named, key=lambda n: -want[n])[:len(named)]:
            problems.append(f"spec {k}: not largest first: {named}")
        if order == "smallest" and named != sorted(want, key=lambda n: want[n])[:top]:
            problems.append(f"spec {k}: not the {top} smallest: {named}")
    for phrase, sentence in (("median", "Median of amount by region"), ("p90", "p90 of amount by region")):
        o = g25.gtk(g25.SHEET + ";tap:Chart;pause:300;" + g28.ASK + phrase + ";pause:400", f"m1-{phrase}")[0]
        if not any(l.startswith(sentence) for l in labels(o)):
            problems.append(f"GTK: asking \"{phrase}\" didn't make {sentence}")
    return not problems, "; ".join(problems[:6]) or ("median and p90 per group equal pyarrow's for 6 specs (interpolated median; quantile_disc), "
                                                      "in every order and with a filter; \"median\" and \"p90\" asked on GTK")


NUMS = [("sum", ">", 5000, None, None, "amount"), ("count", "<", None, 1000, None, "amount"), ("mean", "between", 2000, 4000, None, "amount"),
        ("sum", ">", 5000, None, True, "amount"), ("median", ">=", 5000, None, None, "amount"),
        ("count", ">", 2500, None, None, "order"), ("count", ">=", 2500, None, None, "order"), ("sum", "<=", None, 10, None, "order")]


def m2():
    """Numbers as filters: five charts with number conditions (and a Yes/No one) equal pyarrow's; the ask and the Rows page set them."""
    import pyarrow.parquet as pq
    problems = []
    b = run(["scripts/mxbuild.sh", "tests/chartnum_dump.mojo", "-o", str(BUILD / "chartnum_dump")], timeout=1800)
    if b.returncode != 0:
        return False, "chartnum_dump: " + (b.stdout + b.stderr)[-400:]
    out = run([str(BUILD / "chartnum_dump"), g25.small()], timeout=300).stdout
    rows = pq.read_table(g25.small()).to_pylist()
    blocks = re.split(r"^SPEC \d+\n", out.split("END")[0], flags=re.M)[1:]
    if len(blocks) != len(NUMS):
        return False, f"{len(blocks)} charts printed: {out[-300:]}"
    for k, (block, (how, op, lo, hi, paid, on)) in enumerate(zip(blocks, NUMS)):
        keep = lambda a: a is not None and ((op == ">" and a > lo) or (op == "<" and a < hi) or (op == "between" and lo <= a <= hi) or (op == ">=" and a >= lo)
                                            or (op == "<=" and a <= hi))
        groups = {}
        for r in rows:
            if paid is not None and r["paid"] is not paid:
                continue
            if not keep(float(r[on]) if r[on] is not None else None):
                continue
            groups.setdefault(r["region"] if r["region"] is not None else "(blank)", []).append(float(r["amount"]) if r["amount"] is not None else None)
        lines = block.strip().split("\n")[1:]
        shown = {l.split("\t")[0] for l in lines}
        if set(g for g in groups if g != "(blank)") - shown:
            problems.append(f"spec {k}: groups missing {sorted(set(groups) - shown)}")
        for line in lines:
            name, text = line.split("\t")
            vals = [v for v in groups.get(name, []) if v is not None] if how != "count" else groups.get(name, [])
            want = (sum(vals) if how == "sum" else len(vals) if how == "count" else (sum(vals) / len(vals) if vals else None) if how == "mean"
                    else stat(vals, "median"))
            if text == "—":
                if want is not None and name != "(blank)":
                    problems.append(f"spec {k}: {name} reads — but pyarrow has {want}")
                continue
            if want is None or abs(float(text.replace(",", "")) - want) > 0.006:
                problems.append(f"spec {k} ({how} {op}): {name} {text} vs pyarrow {want}")
    asked = g25.gtk(g25.SHEET + ";tap:Chart;pause:300;" + g28.ASK + "only paid and over 5,000;pause:400", "m2-ask")[0]
    if "paid, amount over 5,000.00" not in " ".join(re.findall(r"^BUTTON: (.*)$", asked, re.M)):
        problems.append("GTK: asking \"only paid and over 5,000\" didn't set both")
    page = g25.gtk(g25.SHEET + ";tap:Chart;pause:300;tap:Rows;pause:300;select:1=Over;pause:300;enter:From=2,500;pause:400", "m2-page")[0]
    if "amount over 2,500.00" not in re.findall(r"^BUTTON: (.*)$", page, re.M):
        problems.append(f"GTK Rows page: {[b for b in re.findall(r'^BUTTON: (.*)$', page, re.M) if 'amount' in b]}")
    return not problems, "; ".join(problems[:6]) or ("eight number conditions (over, under, between, at least, at most; on a decimal and a whole-number "
                                                      "column, at an exact value; with a Yes/No filter too) equal pyarrow's, every group; "
                                                      "\"only paid and over 5,000\" sets both; the Rows page's Over 2,500 filters the chart (GTK)")


CALS = [("sum", "month", None), ("count", "quarter", None), ("mean", "weekday", None), ("median", "month", True)]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def m3():
    """By month, quarter or weekday of a date column: four charts equal pyarrow's, in calendar order; asked on GTK."""
    import pyarrow.parquet as pq
    problems = []
    b = run(["scripts/mxbuild.sh", "tests/chartcal_dump.mojo", "-o", str(BUILD / "chartcal_dump")], timeout=1800)
    if b.returncode != 0:
        return False, "chartcal_dump: " + (b.stdout + b.stderr)[-400:]
    out = run([str(BUILD / "chartcal_dump"), g25.small()], timeout=300).stdout
    rows = pq.read_table(g25.small()).to_pylist()
    blocks = re.split(r"^SPEC \d+\n", out.split("END")[0], flags=re.M)[1:]
    if len(blocks) != len(CALS):
        return False, f"{len(blocks)} charts printed: {out[-300:]}"
    for k, (block, (how, part, paid)) in enumerate(zip(blocks, CALS)):
        groups = {}
        for r in rows:
            if paid is not None and r["paid"] is not paid:
                continue
            d = r["day"]
            name = "(blank)" if d is None else (f"{MONTHS[d.month - 1]} {d.year}" if part == "month" else
                                                (f"Q{(d.month - 1) // 3 + 1} {d.year}" if part == "quarter" else WEEKDAYS[d.weekday()]))
            groups.setdefault(name, []).append(float(r["amount"]) if r["amount"] is not None else None)
        got = [l.split("\t") for l in block.strip().split("\n")[1:]]
        names = [g[0] for g in got]
        for name, text in got:
            vals = [v for v in groups.get(name, []) if v is not None]
            want = (sum(vals) if how == "sum" else len(groups.get(name, [])) if how == "count" else
                    (sum(vals) / len(vals) if vals else None) if how == "mean" else stat(vals, "median"))
            if text == "—":
                if want is not None and name != "(blank)":
                    problems.append(f"spec {k}: {name} reads —")
                continue
            if want is None or abs(float(text.replace(",", "")) - want) > 0.006:
                problems.append(f"spec {k} ({how} by {part}): {name} {text} vs pyarrow {want}")
        dated = [n for n in names if n != "(blank)"]
        if part == "weekday" and dated != WEEKDAYS:
            problems.append(f"spec {k}: weekdays in order {dated}")
        days = [r["day"] for r in rows if r["day"] is not None]
        lo, hi = min(days), max(days)
        if part == "month":
            span = [f"{MONTHS[(lo.month - 1 + i) % 12]} {lo.year + (lo.month - 1 + i) // 12}" for i in range((hi.year - lo.year) * 12 + hi.month - lo.month + 1)]
            if dated != span:
                problems.append(f"spec {k}: months {dated[:3]}… not the span's {span[:3]}… ({len(dated)} vs {len(span)})")
        if part == "quarter":
            q0 = (lo.month - 1) // 3
            span = [f"Q{(q0 + i) % 4 + 1} {lo.year + (q0 + i) // 4}" for i in range((hi.year - lo.year) * 4 + (hi.month - 1) // 3 - q0 + 1)]
            if dated != span:
                problems.append(f"spec {k}: quarters {dated} not the span's {span}")
    err = g20.mojo_test("tests/test_calendar.mojo", "PASSED", "test_calendar", "tests")
    if err:
        problems.append(err)
    asked = g25.gtk(g25.SHEET + ";tap:Chart;pause:300;" + g28.ASK + "by month of day, as a line;pause:400", "m3-ask")[0]
    if not {"month", "a line"} <= set(re.findall(r"^BUTTON: (.*)$", asked, re.M)):
        problems.append("GTK: asking \"by month of day, as a line\" didn't group by month")
    return not problems, "; ".join(problems[:6]) or ("sum by month, count by quarter, average by weekday and median by month (paid) equal pyarrow's, "
                                                      "every month and quarter of the span, in calendar order; before 1970, across a year's end and centuries away "
                                                      "(tests/test_calendar.mojo); \"by month of day, as a line\" asked on GTK")


def m4():
    """What a chart costs: at 1M rows each kind (sum, median, by month) fits one 60 Hz frame; at 100M rows the times are
    recorded (median and months there wait for MX frame's background queries: goal 30)."""
    b = run(["scripts/mxbuild.sh", "tests/chartbench.mojo", "-o", str(BUILD / "chartbench")], timeout=1800)
    if b.returncode != 0:
        return False, "chartbench: " + (b.stdout + b.stderr)[-400:]
    lines = []
    problems = []
    big = ROOT.parent / "mojo-ui" / "build" / "g20" / "big.parquet"
    for path in [ROOT.parent / "mojo-ui" / "build" / "data" / "orders_1m.csv", big if big.exists() else BUILD / "g20" / "big.parquet"]:
        if not path.exists():
            continue
        out = run([str(BUILD / "chartbench"), str(path)], timeout=1800).stdout
        m = re.search(r"^BENCH rows=(\d+) streamed=(\w+) sum_ms=([\d.]+) median_ms=([\d.]+) month_ms=([\d.]+)$", out, re.M)
        if not m:
            problems.append(f"{path.name}: {out[-200:]}")
            continue
        rows, streamed, s, med, mon = int(m.group(1)), m.group(2), float(m.group(3)), float(m.group(4)), float(m.group(5))
        lines.append(f"{rows:,} rows ({'streamed' if streamed == 'True' else 'in memory'}): sum by region {s:.1f} ms, median by region {med:.1f} ms, sum by month {mon:.1f} ms")
        if rows <= 1_000_000 and max(s, med, mon) > 16.0:
            problems.append(f"at {rows:,} rows a chart took {max(s, med, mon):.1f} ms (want ≤ 16: one frame)")
    (ROOT / "docs/goals/29").mkdir(parents=True, exist_ok=True)
    (ROOT / "docs/goals/29/bench.txt").write_text("Goal 29: what a chart costs (best of three, engine 321870f, this machine)\n" + "\n".join(lines) + "\n")
    if not any(l.startswith("1,000,000 rows") for l in lines):
        problems.append("the 1M-row bench didn't run (build/data/orders_1m.csv)")
    return not problems, "; ".join(problems) or "; ".join(lines) + " (docs/goals/29/bench.txt)"


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m5():
    """Goal 28's checks (every earlier goal's inside them), and docs/llms-full.txt is current."""
    problems = []
    for name, fn in [(f"28-M{i}", getattr(g28, f"m{i}")) for i in range(8)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    llms = run(["pixi", "run", "python", "scripts/llms.py", "--check"], timeout=120)
    if llms.returncode != 0:
        problems.append(llms.stdout.strip())
    return not problems, "; ".join(problems) or "goal 28's M0–M7 (goals 3–27 inside them) pass; docs/llms-full.txt current"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5)]


def main():
    import shutil
    import headless
    headless.ensure()
    only = sys.argv[1:]
    if not only:
        every = list(dict.fromkeys(list(g20.EXAMPLES) + APPS))  # (goal 20's list predates kit and themes)
        for ex in every:
            shutil.rmtree(BUILD / ex, ignore_errors=True)
        for ex in every:
            if not (ROOT / "examples" / ex / "app.mojo").exists():
                continue
            b = run(["scripts/build.sh", ex, "all"], timeout=3600)
            if b.returncode != 0:
                print(f"build {ex} failed:\n" + (b.stdout + b.stderr)[-1500:])
            if ex in ("hello", "gallery", "layout", "lens", "todo"):
                a = run(["scripts/build.sh", ex, "android"], timeout=3600)
                if a.returncode != 0:
                    print(f"android build {ex} failed:\n" + (a.stdout + a.stderr)[-1500:])
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
