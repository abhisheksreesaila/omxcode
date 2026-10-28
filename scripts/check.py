"""Milestone checker for GOAL.md (goal 34b: JS widgets everywhere, and agents see them; goal 34's M0–M3 and goal 33's
M1, M4 run as M3, minimal regression by the owner's choice). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M1)
Each milestone's proof is written before its work starts (todo() until then: it fails), from GOAL.md's words.
"""

import importlib.util
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g34 = load("goal34", "docs/goals/34-check.py")
g33 = g34.g33


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m3():
    """Nothing regressed (minimal, owner): goal 34's M0–M3, goal 33's M1 and M4."""
    problems = []
    for label, fn in [("34-M0", g34.m0), ("34-M1", g34.m1), ("34-M2", g34.m2), ("34-M3", g34.m3), ("33-M1", g33.m1), ("33-M4", g33.m4)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{label}: {msg}")
    return not problems, "; ".join(problems) or "goal 34's M0–M3 and goal 33's M1, M4 pass"

# ---- M2: the Mac, the same widgets (WKWebView), proven on GitHub's Mac runner ----
# The widgets app's side.txt lines (ci/mac/side.txt): one launch each at side.SIZE on GitHub's Macs (ci/mac/run.sh);
# their view dumps (WEBVIEW:/WIDGET: lines, the tree with each view's box) and logs (JS: lines) come back with the run.
MAC_PROBES = [(n, js) for n, js in g34.GTK_PROBES]  # (the same probes GTK's view passed: WKWebView offers the same handler API)
MAC_STEPS = {
    "start": "pause:3000",
    "typed": "pause:3000;webtype:mx-editor#1=one two three;pause:2000",
    "sample": "pause:3000;tap:Load sample;pause:2000",
    "counter": ("pause:3000;webclick:mx-counter#1=.inc;pause:600;webclick:mx-counter#1=.inc;pause:600;webclick:mx-counter#1=.inc;pause:800;"
                "tap:Bigger steps;pause:800;webclick:mx-counter#1=.inc;pause:800;tap:Ask the counter;pause:1500;tap:Show details;pause:2000"),
    "security": "pause:3000;" + ";".join(f"webjs:mx-counter#1={js}" for _, js in MAC_PROBES) + ";pause:1000",
    "crash1": "pause:3000;webkill:mx-counter#1;pause:4000",
    "crash2": "pause:3000;webkill:mx-counter#1;pause:4000;webkill:mx-counter#1;pause:3000",
}
M2_OUT = ROOT / "docs" / "goals" / "34b"


def mac_webviews(text):
    return g34.webviews(text)


def mac_labels(dump):
    """The texts the Mac's screen shows (the view dump's Text lines, not hidden)."""
    import re
    return [m.group(1) for m in re.finditer(r"^\s*Text '(.*?)'(?: \[[^\]]*\])?(?: #\S+)? @ [^\n]*$", dump, re.M)
            if " hidden" not in m.group(0)]


def m2():
    """The Mac, the same widgets: on the Mac each WebComponent runs in a WKWebView with the same bundle (the web's files,
    byte for byte), runtime (mojoui-widgets.js) and CSP (the web's, frame-src 'none'), served by a URL scheme handler
    that serves only the bundle; no network, no navigation away, no popups; JS↔native through a script message handler,
    JSON only, with GTK's owner/seq checks; the view kept across rebuilds; a crashed web content process reloads once,
    then the WebComponent shows `instead`. Proven on GitHub's Mac runner (scripts/mac-ci, fresh against these sources:
    side.mac_fresh, a stamp covering examples/widgets): typing in the editor reaches update() (Words: 3, the editor
    holds the words), Mojo sets its text (Load sample: Words: 9, the editor shows it), the counter's real clicks reach
    Mojo and its command gets its reply (count 5), a rebuild keeps one mount; the chart draws (any other WebComponent
    the app shows: ready, mounted once, no CSP violation; skipped only while the app has none); the boxes are within
    goal 32's parity (4 pt or 3 %) of the web's at side.SIZE; the security probes give GTK's answers; a picture."""
    import json
    import re
    import side
    import parity
    problems, notes = [], []
    host = ROOT / "mojoui/hosts/appkit_webview.mojo"
    if not host.exists():
        return False, "no mojoui/hosts/appkit_webview.mojo"
    src = host.read_text() + (ROOT / "mojoui/hosts/appkit.mojo").read_text()
    for need in ("WKWebView", "setURLSchemeHandler:forURLScheme:", "addScriptMessageHandler:", "decidePolicyForNavigationAction",
                 "webViewWebContentProcessDidTerminate:", "callAsyncJavaScript:"):
        if need not in src:
            problems.append(f"the Mac host doesn't use {need}")
    for name in ("mx-editor", "mx-counter", "examples/widgets", "Load sample"):
        if name in src:
            problems.append(f"the Mac host names {name!r}: it must work for any WebComponent in any app")
    if "WKWebView" not in (ROOT / "docs/js.md").read_text():
        problems.append("docs/js.md doesn't say how widgets run on the Mac (WKWebView)")
    if "examples/widgets" not in side.SOURCES:
        problems.append("scripts/side.py's stamp doesn't cover examples/widgets: no Mac run can be shown to be built from it")
    if "mac" not in (ROOT / "examples/widgets/platforms").read_text().split():
        problems.append("examples/widgets/platforms doesn't list mac")
    err = g34.build(g34.WIDGETS, "web", "mac")
    if err:
        return False, "; ".join(problems + [err])
    # the same bundle and runtime in the app
    app = next((g34.BUILD / g34.WIDGETS / "mac").glob("*.app"), None)
    res = app / "Contents" / "Resources" / "webview" if app else None
    web_assets = g34.BUILD / g34.WIDGETS / "web" / "assets"
    wm = json.loads((web_assets / "manifest.json").read_text())
    mm = json.loads((res / "assets" / "manifest.json").read_text()) if res and (res / "assets" / "manifest.json").exists() else {}
    if {k: v["file"] for k, v in wm.items()} != {k: v["file"] for k, v in mm.items()}:
        problems.append(f"the Mac app's bundles aren't the web's ({sorted(v['file'] for v in mm.values())})")
    else:
        for v in wm.values():
            if (web_assets / v["file"]).read_bytes() != (res / "assets" / v["file"]).read_bytes():
                problems.append(f"{v['file']} differs between the web and Mac builds")
    if not res or (res / "mojoui-widgets.js").read_bytes() != (ROOT / "mojoui/hosts/static/mojoui-widgets.js").read_bytes():
        problems.append("the Mac app's mojoui-widgets.js isn't the web host's runtime")
    # every C function the Mac binary needs is in apple/sdk's stubs (Objective-C goes by name at run time)
    exe = next((app / "Contents" / "MacOS").iterdir()) if app else None
    nm = g34.run(["pixi", "run", "llvm-nm", "-u", str(exe)]) if exe else None
    undefined = {l.split()[-1] for l in nm.stdout.splitlines() if l.strip()} if nm and nm.returncode == 0 else None
    stubs = " ".join(f.read_text() for f in (ROOT / "apple/sdk/macos").glob("*.tbd"))
    if undefined is None:
        problems.append("llvm-nm -u failed on the Mac binary")
    else:
        missing = sorted(s for s in undefined if not re.search(r"[\[\s,]" + re.escape(s) + r"[\],\s]", stubs))
        if missing:
            problems.append(f"undefined symbols not in apple/sdk/macos: {missing[:10]}")
        notes.append(f"{len(undefined)} undefined symbols, all stubbed")
    # side.txt's widgets lines are M2's steps
    lines = {s: steps for a, s, _, steps in side.screens() if a == g34.WIDGETS}
    for name, steps in MAC_STEPS.items():
        if lines.get(name) != steps:
            problems.append(f"ci/mac/side.txt's widgets|{name} steps aren't M2's")
    if problems:
        return False, "; ".join(problems[:10])
    # the run: fresh, from GitHub's macOS 26
    fresh, why = side.mac_fresh()
    if not fresh:
        return False, f"Mac: stale: {why} (scripts/build.sh widgets mac; scripts/mac-ci widgets)"
    mac = side.mac_dir()
    run_id = mac.parent.parent.name
    def got(screen, what):
        f = mac / f"{g34.WIDGETS}-{screen}-{what}.txt"
        return f.read_text() if f.exists() else None
    dumps = {s: got(s, "views") for s in MAC_STEPS}
    logs = {s: got(s, "log") for s in MAC_STEPS}
    for s, d in dumps.items():
        if d is None:
            problems.append(f"run {run_id}: no view dump for widgets|{s} (its log: {(logs[s] or '')[-300:]})")
    if problems:
        return False, "; ".join(problems[:8])
    tags = sorted(set(re.findall(r'WebComponent\("([a-z][a-z0-9._-]*)"', (ROOT / "examples/widgets/app.mojo").read_text())))
    # start: every view ready, mounted once, no CSP violation; the boxes against the web's
    v0 = mac_webviews(dumps["start"])
    for tag in tags:
        v = v0.get(f"{tag}#1")
        if not v or v["state"] != "ready" or v.get("mounts") != 1 or v.get("csp") != 0:
            problems.append(f"{tag}#1's WKWebView: {v} (wants ready, mounts=1, csp=0)")
    others = [t for t in tags if t not in ("mx-editor", "mx-counter")]
    notes.append(f"chart: {', '.join(others)} drawn" if others else "chart: the app has no chart widget yet (M1's ECharts not merged): skipped")
    rects = side.OUT / "widgets-start-web-rects.txt"
    rects.parent.mkdir(parents=True, exist_ok=True)
    ok, wout = True, ""
    try:
        import drive
        r, wout = drive.web_run(g34.BUILD / g34.WIDGETS / "web", "pause:1500", viewport=side.SIZE, rects=str(rects), color_scheme="light")
        ok = r.returncode == 0
    except Exception as e:
        ok, wout = False, repr(e)
    if not ok or not rects.exists():
        problems.append("the web run for the boxes failed: " + wout[-300:])
    else:
        rows = {k: (w, m, good) for k, w, m, good in parity.compare(rects.read_text(), dumps["start"])}
        for key in ["editor", "counter", "note-bar/Load sample", "counter-bar/Ask the counter"] + [t for t in others]:
            if key in others:
                continue
            w, m, good = rows.get(key, (None, None, False))
            if not good:
                problems.append(f"{key}: web {w} vs Mac {m} (beyond 4 pt / 3 %)")
    # typing reaches update(); Mojo sets the text
    lt, wt = mac_labels(dumps["typed"]), g34.widget_lines(dumps["typed"])
    if "Words: 3" not in lt or '"one two three"' not in wt.get("mx-editor#1", ""):
        problems.append(f"typing on the Mac: labels {[l for l in lt if l.startswith('Words')]}, editor {wt.get('mx-editor#1')}: {(logs['typed'] or '')[-300:]}")
    ls, ws = mac_labels(dumps["sample"]), g34.widget_lines(dumps["sample"])
    if "Words: 9" not in ls or json.dumps(g34.SAMPLE) not in ws.get("mx-editor#1", ""):
        problems.append(f"Load sample on the Mac: labels {[l for l in ls if l.startswith('Words')]}, editor {ws.get('mx-editor#1')}")
    # the counter: real clicks, props, a command's reply, a rebuild
    lc, wc, vc = mac_labels(dumps["counter"]), g34.widget_lines(dumps["counter"]), mac_webviews(dumps["counter"])
    for want in ("Clicks seen by Mojo: 4", "Last count: 5", "Step: 2", "Counter replied: count 5", "Details shown"):
        if want not in lc:
            problems.append(f"the counter on the Mac: no label {want!r} ({[l for l in lc if ':' in l][:8]})")
    if not wc.get("mx-counter#1", "").startswith("count 5, step 2"):
        problems.append(f"the counter's own state on the Mac: {wc.get('mx-counter#1')} (wants count 5, step 2)")
    for key in ("mx-editor#1", "mx-counter#1"):
        v = vc.get(key, {})
        if v.get("mounts") != 1 or v.get("csp") != 0 or v.get("refused") != 0:
            problems.append(f"{key} after the counter run: {v} (wants mounts=1, csp=0, refused=0)")
    # security: GTK's probes, GTK's answers
    vals = [json.loads(l[len("JS: "):]) for l in (logs["security"] or "").splitlines() if l.startswith("JS: ")]
    if len(vals) != len(MAC_PROBES):
        problems.append(f"the security probes returned {len(vals)} of {len(MAC_PROBES)} values: {(logs['security'] or '')[-400:]}")
    else:
        got_p = dict(zip([n for n, _ in MAC_PROBES], vals))
        want_csp = g34.CSP_WEB().replace("frame-src 'self' http: https:", "frame-src 'none'")
        if got_p["csp"] != want_csp:
            problems.append(f"the WKWebView's CSP is {got_p['csp']!r}, not the web's (frame-src 'none')")
        for k, v in g34.GTK_PROBE_WANT.items():
            if got_p[k] != v:
                problems.append(f"probe {k}: {got_p[k]!r} (wants {v!r})")
        for k in ("outside", "unlisted"):
            if got_p[k] == "loaded":
                problems.append(f"probe {k}: a file outside the bundle was served")
        if not str(got_p["where"]).startswith("mojoui://"):
            problems.append(f"the WKWebView navigated away: {got_p['where']!r}")
        l4 = mac_labels(dumps["security"])
        if "Clicks seen by Mojo: 0" not in l4 or "Words: 0" not in l4:
            problems.append(f"a refused message reached update() ({[l for l in l4 if 'Clicks' in l or 'Words' in l]})")
        v4 = mac_webviews(dumps["security"]).get("mx-counter#1", {})
        if v4.get("refused", 0) < 4 or v4.get("blocked", 0) < 2:
            problems.append(f"the Mac host didn't count the refused messages and blocked navigations: {v4}")
    # a crashed web content process: reload once (Mojo's props again), then `instead`
    for screen, kills, want in (("crash1", 1, "ready"), ("crash2", 2, "gone")):
        v = mac_webviews(dumps[screen]).get("mx-counter#1", {})
        if v.get("state") != want or v.get("crashes") != kills:
            problems.append(f"after {kills} ended web process(es) the counter's view is {v} (wants {want}, crashes={kills})")
        elif want == "ready" and not g34.widget_lines(dumps[screen]).get("mx-counter#1", "").startswith("count 0, step 1, label " + g34.LABEL_PROP):
            problems.append(f"the reloaded counter didn't get Mojo's props again: {g34.widget_lines(dumps[screen]).get('mx-counter#1')}")
        elif v.get("instead") != (1 if want == "gone" else 0):
            problems.append(f"after {kills} ended web process(es) the counter's `instead` view is {'hidden' if want == 'gone' else 'shown'} ({v})")
    # a picture: the typed screen, with words in the editor's box
    shot = mac / f"{g34.WIDGETS}-typed.png"
    if not shot.exists():
        problems.append(f"run {run_id}: no picture widgets-typed.png")
    else:
        import shutil
        from PIL import Image
        M2_OUT.mkdir(parents=True, exist_ok=True)
        shutil.copy(shot, M2_OUT / "m2-widgets-mac.png")
        m = parity.mac_rects(dumps["typed"]).get("editor")
        im = Image.open(shot).convert("RGB")
        if m:
            sx = im.width / float(re.search(r"window content (\d+)", dumps["typed"]).group(1))
            x, y, w, h = (int(v * sx) for v in m)
            px = im.crop((x + 4, y + 4, x + w - 4, min(y + int(60 * sx), y + h - 4))).tobytes()
            dark = sum(1 for i in range(0, len(px), 3) if px[i] + px[i + 1] + px[i + 2] < 300)
            if dark < 80:
                problems.append(f"the Mac picture shows no text in the editor's box ({dark} dark pixels)")
        else:
            problems.append("no editor box in the typed screen's dump")
    tail = f"run {run_id}; " + "; ".join(notes)
    return not problems, ("; ".join(problems[:12]) + " | " + tail) if problems else (
        "each WebComponent in a WKWebView of its own (mojoui:// scheme handler serving only the bundle, the web's files byte "
        "for byte, the web's CSP with frame-src 'none', no network): typing reaches update() (Words: 3), Load sample shows "
        "Mojo's text, 4 real clicks reach Mojo, a command's reply arrives (count 5), one mount across a rebuild; boxes "
        "within parity of the web's; GTK's security probes pass; a crash reloads once, then `instead`; picture "
        f"{(M2_OUT / 'm2-widgets-mac.png').relative_to(ROOT)}; " + tail)


MILESTONES = [
    ("M0", todo("agents see JS widgets: describe(), settable fields, the agent host's tools (GOAL.md M0)")),
    ("M1", todo("ECharts from npm with no host changes (GOAL.md M1)")),
    ("M2", m2),
    ("M3", m3),
]


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
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
