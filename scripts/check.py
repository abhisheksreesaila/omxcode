"""Milestone checker for GOAL.md (goal 32: one look on Linux, the web and the Mac, from components and a theme; goal 30's
checks run as M7, every earlier goal's inside them). Rebuilds from scratch, prints PASS/FAIL per milestone.

Run: scripts/check   (a subset without rebuilding: scripts/check M1 M2; earlier goals: through docs/goals/NN-check.py)
The Mac's pictures come from GitHub's Macs: scripts/build.sh omxplorer mac && scripts/mac-ci omxplorer maccheck. A
milestone that reads them fails while the newest run was built from other sources (side.mac_fresh).
"""

import importlib.util
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import parity  # noqa: E402
import side  # noqa: E402


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g30 = load("goal30", "docs/goals/30-check.py")
g20 = g30.g20
run, BUILD = g20.run, g20.BUILD
GOLDEN = ROOT / "docs" / "goals" / "32" / "golden"
_shot = {}


def shoot():
    """GTK and the web shot once per check run (every milestone reads the same pictures)."""
    if "problems" not in _shot:
        _shot["problems"] = side.shoot_all()
    return _shot["problems"]


def screens():
    return [(a, s) for a, s, _, _ in side.screens()]


def rows_for(app, screen):
    web = side.OUT / f"{app}-{screen}-web-rects.txt"
    mac = side.mac_dir() / f"{app}-{screen}-views.txt" if side.mac_dir() else None
    if not web.exists() or not mac or not mac.exists():
        return None
    return parity.compare(web.read_text(), mac.read_text())


def mac_ready():
    fresh, why = side.mac_fresh()
    return None if fresh else why


def m0():
    """The measure: GTK and the web shot, a Mac run from these sources, both sides' tagged views listed."""
    problems = list(shoot())
    stale = mac_ready()
    if stale:
        problems.append(stale)
    report = []
    for app, screen in screens():
        rows = rows_for(app, screen)
        if rows is None:
            problems.append(f"{app} {screen}: no web rects or no Mac view dump")
            continue
        if not any(r[1] for r in rows) or not any(r[2] for r in rows):
            problems.append(f"{app} {screen}: no tagged views on {'the web' if not any(r[1] for r in rows) else 'the Mac'}")
        report.append(f"== {app} · {screen}: {sum(r[3] for r in rows)} of {len(rows)} close\n" + parity.table(rows))
    (side.OUT / "parity.txt").write_text("\n".join(report) + "\n")
    return not problems, "; ".join(problems[:6]) or f"{len(screens())} screens on GTK, the web and the Mac; rects in build/side/parity.txt"


def pixel_change(a, b):
    """The share of pixels that differ by more than 8 in any channel (2 % of a channel: anti-aliasing noise)."""
    from PIL import Image, ImageChops
    x, y = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if x.size != y.size:
        return 1.0
    d = ImageChops.difference(x, y).point(lambda v: 255 if v > 8 else 0).convert("L")
    return sum(1 for v in d.getdata() if v) / (x.size[0] * x.size[1])


def framework_tags():
    tags = set()
    for f in (ROOT / "mojoui").rglob("*.mojo"):
        tags.update(re.findall(r'\.tag\("([\w-]+)"\)', f.read_text()))
        tags.update(re.findall(r'tag="([\w-]+)"', f.read_text()))
    return tags


def m1():
    """A theme is data: a Look in the framework, declared by Liquid and Omarchy, its rules written by the hosts; GTK and
    the web unchanged; themes style only framework tags."""
    problems = []
    theme = (ROOT / "mojoui/theme.mojo").read_text()
    if "struct Look" not in theme:
        problems.append("mojoui/theme.mojo has no Look")
    looks = re.findall(r"struct (\w+)\(", theme)
    for name in ("liquid", "omarchy"):
        text = (ROOT / f"themes/{name}.mojo").read_text()
        if "Look(" not in text:
            problems.append(f"themes/{name}.mojo declares no Look")
    # every surface role a Look names is written by the hosts, not by hand in themes/
    roles = set(re.findall(r'\b(?:Surface|glass|solid|band)\("([\w-]+)"', "".join(f.read_text() for f in (ROOT / "themes").glob("*.mojo"))))  # (with the helpers that make one: D-299)
    shape = re.compile(r"\b(background(-color)?|border-radius|margin|padding|box-shadow|border(-top|-bottom)?|min-height)\s*:")
    for f in (ROOT / "themes").glob("*.mojo"):
        text = f.read_text()
        for role in roles:  # (a rule of its own for the role: animations and hover stay by hand; its shape doesn't)
            for m in re.finditer(r"(?:mui-tag-|\[data-tag=)" + re.escape(role) + r"\]? \{([^}]*)\}", text):
                if shape.search(m.group(1)):
                    problems.append(f"{f.name} still shapes {role} by hand ({m.group(0)[:60]})")
    if not roles:
        problems.append("no theme declares a Surface")
    # themes style only tags the framework's components set
    known = framework_tags()
    for f in (ROOT / "themes").glob("*.mojo"):
        for tag in sorted(set(re.findall(r"mui-tag-([\w-]+)", f.read_text())) | set(re.findall(r"data-tag=([\w-]+)", f.read_text()))):
            if tag not in known:
                problems.append(f"{f.name} styles '{tag}', which no framework component sets")
    shoot()
    for app, screen in screens():
        for host in ("gtk", "web"):
            gold = GOLDEN / f"{app}-{screen}-{host}.png"
            now = side.OUT / f"{app}-{screen}-{host}.png"
            if not gold.exists():
                problems.append(f"no golden {gold.name}")
            elif not now.exists():
                problems.append(f"no picture {now.name}")
            else:
                c = pixel_change(gold, now)
                if c > 0.005:
                    problems.append(f"{now.name} changed {c:.2%} from its golden")
    return not problems, "; ".join(dict.fromkeys(problems[:8])) or f"a Look ({len(roles)} surface roles) written by the hosts; GTK and the web as before"


def toolbar_rows():
    out = []
    for screen in ("sheet", "report"):
        rows = rows_for("omxplorer", screen)
        if rows is None:
            return None
        out += [(screen,) + r for r in rows if r[0].split("/")[0].split(" ")[0] == "toolbar"]
    return out


def m2():
    """The toolbar, the same: every toolbar view within 4 pt of the web's; no Mac button's title cut."""
    shoot()
    problems = [p for p in [mac_ready()] if p]
    rows = toolbar_rows()
    if rows is None:
        problems.append("no sheet/report rects")
    else:
        if len(rows) < 10:
            problems.append(f"only {len(rows)} toolbar views matched")
        problems += [f"{s} {k}: web {parity.fmt(w)} mac {parity.fmt(m)}" for s, k, w, m, ok in rows if not ok]
    for screen in ("sheet", "report"):
        dump = side.mac_dir() / f"omxplorer-{screen}-views.txt" if side.mac_dir() else None
        if dump and dump.exists():
            problems += [f"{screen}: {l.strip()[:80]}" for l in dump.read_text().splitlines() if " CLIPPED" in l]
    return not problems, "; ".join(problems[:8]) or f"{len(rows)} toolbar views on the Mac within 4 pt of the web's, no title cut"


def similarity(a, b):
    """Mean absolute difference of two pictures, small and grey (0 = the same)."""
    from PIL import Image, ImageChops, ImageStat
    x = Image.open(a).convert("L").resize((360, 160))
    y = Image.open(b).convert("L").resize((360, 160))
    return ImageStat.Stat(ImageChops.difference(x, y)).mean[0]


def m3():
    """Every surface the same: every tagged view within tolerance; the Mac's picture as close to the web's as GTK's is."""
    shoot()
    problems = [p for p in [mac_ready()] if p]
    total = 0
    for app, screen in screens():
        rows = rows_for(app, screen)
        if rows is None:
            problems.append(f"{app} {screen}: no rects")
            continue
        total += len(rows)
        problems += [f"{app} {screen} {k}: web {parity.fmt(w)} mac {parity.fmt(m)}" for k, w, m, ok in rows if not ok]
        mac = side.mac_dir() / f"{app}-{screen}.png"
        web, gtk = side.OUT / f"{app}-{screen}-web.png", side.OUT / f"{app}-{screen}-gtk.png"
        if mac.exists() and web.exists() and gtk.exists():
            dm, dg = similarity(mac, web), similarity(gtk, web)
            if dm > 1.5 * max(dg, 1.0):
                problems.append(f"{app} {screen}: the Mac differs from the web by {dm:.1f}, GTK by {dg:.1f}")
    return not problems, f"{len(problems)} off: " + "; ".join(problems[:8]) if problems else f"{total} tagged views within 4 pt; pictures as close as GTK's"


def m4():
    """Popovers, tiles and rows: the sentence popover's own picture and rects, within M3's tolerances."""
    shoot()
    problems = [p for p in [mac_ready()] if p]
    names = [s for a, s in screens() if a == "omxplorer"]
    for need in ("sentence-popover", "report", "start"):
        if need not in names:
            problems.append(f"side.txt has no omxplorer {need} screen")
            continue
        rows = rows_for("omxplorer", need)
        if rows is None:
            problems.append(f"{need}: no rects")
            continue
        problems += [f"{need} {k}: web {parity.fmt(w)} mac {parity.fmt(m)}" for k, w, m, ok in rows if not ok]
    if side.mac_dir() and not (side.mac_dir() / "omxplorer-sentence-popover-popover.png").exists():
        problems.append("no picture of the Mac's popover")
    return not problems, "; ".join(problems[:8]) or "the sentence popover, the add tiles and the start page's rows within 4 pt of the web's"


def labels_of(text, under):
    """The Mac view dump's Text lines under the view tagged `under`."""
    out, depth = [], None
    for line in text.splitlines():
        d = (len(line) - len(line.lstrip(" "))) // 2
        if depth is not None and d <= depth:
            depth = None
        if f" #{under}" in line:
            depth = d
        elif depth is not None and line.strip().startswith("Text '"):
            out.append(line.strip().split("'")[1])
    return out


def m5():
    """The Mac's hands: drag-select, a formula and Open, each ending with the status bar GTK shows."""
    shoot()
    problems = [p for p in [mac_ready()] if p]
    for screen in ("drag", "formula", "open"):
        if screen not in [s for a, s in screens() if a == "omxplorer"]:
            problems.append(f"side.txt has no omxplorer {screen} screen")
            continue
        dump = side.mac_dir() / f"omxplorer-{screen}-views.txt" if side.mac_dir() else None
        gtk = side.OUT / f"omxplorer-{screen}-gtk.txt"
        if not dump or not dump.exists() or not gtk.exists():
            problems.append(f"{screen}: no Mac dump or GTK output")
            continue
        mac_status = labels_of(dump.read_text(), "status-bar")
        gtk_labels = set(l[len("LABEL: "):] for l in gtk.read_text().splitlines() if l.startswith("LABEL: "))
        if not mac_status:
            problems.append(f"{screen}: the Mac's status bar is empty")
        problems += [f"{screen}: the Mac's status bar says '{t}', GTK's doesn't" for t in mac_status if t not in gtk_labels]
    return not problems, "; ".join(problems[:8]) or "drag, formula and Open end with GTK's status bar on the Mac"


def m6():
    """Speed, mapped: kernels fit Apple's threadgroup memory; a Mac GPU probe ran in CI; the plan is written."""
    problems = []
    a = run(["pixi", "run", "python", "scripts/gpu_audit.py"], timeout=120)
    if a.returncode != 0:
        problems.append("scripts/gpu_audit.py: " + (a.stdout + a.stderr)[-300:])
    probe = side.mac_dir().parent / "gpuprobe.txt" if side.mac_dir() else None
    if not probe or not probe.exists() or "DEVICE:" not in probe.read_text():
        problems.append("no Mac GPU probe result (DEVICE: line) in the newest Mac run")
    plan = ROOT / "docs/plans/speed.md"
    if not plan.exists():
        problems.append("no docs/plans/speed.md")
    else:
        text = plan.read_text()
        problems += [f"speed.md has no '{h}' section" for h in ("## Linux", "## Mac", "## Web", "## From MX frame") if h not in text]
    return not problems, "; ".join(problems) or "kernels fit 32 KB; the Mac probe ran; docs/plans/speed.md"


def m7():
    """Nothing regressed: goal 30's M0–M5 (goals 3–29 inside them)."""
    problems = []
    for name, fn in [(f"30-M{i}", getattr(g30, f"m{i}")) for i in range(6)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    return not problems, "; ".join(problems) or "goal 30's M0–M5 (goals 3–29 inside them) pass"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M6", m6), ("M7", m7)]


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
    if not only:
        g30.build_all()
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
