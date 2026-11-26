import importlib.util, re, sys
sp = importlib.util.spec_from_file_location("c", "docs/goals/79-check.py"); c = importlib.util.module_from_spec(sp); sp.loader.exec_module(c)
for f, hz in [("docs/goals/79/race.md", 60.0), ("docs/goals/79/race-mac.md", 144.0)]:
    print(f"== {f} at {hz:g} Hz")
    changed = 0
    for l in open(f):
        cols = [x.strip() for x in l.split("|")]
        if len(cols) < 7 or not cols[5].startswith(("✓", "✗")):
            continue
        note, label, w, n, v = cols[1:6]
        nums = lambda t: [float(x) for x in re.findall(r"[\d.]+", t.split("(")[0])][:2]
        wv, nv = nums(w), nums(n)
        if len(wv) == 1: wv, nv = wv * 1, nv * 1
        gaps = "(frames)" in label or "(gaps)" in label
        good, said = c.verdicts(list(zip(nv, wv)), gaps, hz)
        old = v.lstrip("✓✗ ").strip()
        new = said if good else "worse than the web"
        if (v.startswith("✓")) != good or (good and old != new):
            changed += 1
            print(f"  {note} | {label} | web {w} | native {n} | was: {v} → now: {'✓' if good else '✗'} {new}")
    print("  rows changed:", changed)
