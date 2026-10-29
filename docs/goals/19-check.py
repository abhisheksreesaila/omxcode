"""Milestone checker for GOAL.md (goal 19: the agent host; goal 18's checks run as M4, earlier goals' inside them).
Rebuilds from scratch, prints PASS/FAIL per milestone. The agent host is driven by scripts/agent_client.py, a small MCP
client over stdio: no LLM runs here.

Run: scripts/check   (a subset without rebuilding: scripts/check M1 M2; earlier goals: through docs/goals/NN-check.py)
"""

import base64
import importlib.util
import io
import os
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


g18 = load("goal18", "docs/goals/18-check.py")
run, BUILD, EXAMPLES, kit, labels, lines = g18.run, g18.BUILD, g18.EXAMPLES, g18.kit, g18.labels, g18.lines
from agent_client import Client  # noqa: E402

CORE = ("screen", "act", "read", "render")


def env():
    """Where the apps keep documents and settings during a check (never the owner's own)."""
    d = BUILD / "agent-home"
    (d / "documents").mkdir(parents=True, exist_ok=True)
    (d / "config").mkdir(parents=True, exist_ok=True)
    return {"OMX_DOCUMENTS": str(d / "documents"), "OMX_CONFIG": str(d / "config"), "OMXCODE_UPLOADS": str(d / "uploads")}


def png_size(image):
    from PIL import Image
    pic = Image.open(io.BytesIO(base64.b64decode(image["data"])))
    return pic.size, len(pic.convert("RGB").getcolors(maxcolors=4096) or [None] * 4097)


def m1():
    """The agent host drives the kit: tools from the tree, act, the dialog's tools while it is open, the design, a picture,
    the context menu's tools, the sort; GTK with the same steps shows the same status lines."""
    problems = []
    c = Client(BUILD / "kit" / "web", env())
    try:
        if not c.init.get("capabilities", {}).get("tools", {}).get("listChanged"):
            problems.append("initialize doesn't announce tools.listChanged")
        tools = {t["name"]: t for t in c.tools()}
        for name in CORE + ("file-save", "view-skin-graphite", "save", "open-dialog", "canvas", "show-grid-lines", "sum-average-count"):
            if name not in tools:
                problems.append(f"no tool {name} (have {sorted(tools)[:12]}…)")
        for name in ("file-open", "edit-redo"):  # disabled items are not tools
            if name in tools:
                problems.append(f"the disabled item {name} is a tool")
        if "file-save" in tools and "Ctrl+S" not in tools["file-save"]["description"]:
            problems.append("file-save's description lacks its shortcut")
        if "save" in tools and tools["save"]["description"] != "Save the document (Ctrl+S)":
            problems.append(f"the Save button's tooltip isn't its description: {tools['save']['description']!r}")
        if "show-grid-lines" in tools and tools["show-grid-lines"]["inputSchema"].get("required") != ["on"]:
            problems.append("a checkbox tool doesn't require `on`")
        screen, _, err = c.call("screen")
        if err or "Menu bar: File, Edit, View, Help" not in screen or "design: Ledger" not in screen or "Canvas" not in screen:
            problems.append(f"screen lacks the menu bar, the design or the canvas: {screen[:300]!r}")
        text, _, err = c.call("open-dialog")
        names = set(c.names())
        if err or 'dialog "Settings"' not in text or not {"close-dialog", "settings-done", "settings-ledger-graphite-blueprint", "settings-show-grid-lines"} <= names:
            problems.append(f"open-dialog didn't open Settings with its tools: {text!r} {sorted(names)[-8:]}")
        if "notifications/tools/list_changed" not in c.notifications:
            problems.append("no tools/list_changed notification after acting")
        text, _, err = c.call("act", name="settings-ledger-graphite-blueprint", value={"option": "Graphite"})
        if err or "Design: Graphite" not in text:
            problems.append(f"the dialog's radio didn't switch the design: {text!r}")
        text, _, err = c.call("settings-done")
        names = set(c.names())
        if err or "settings-done" in names or "close-dialog" in names:
            problems.append(f"Done didn't close the dialog (its tools remain): {text!r}")
        screen, _, _ = c.call("screen")
        if "design: Graphite" not in screen:
            problems.append("screen doesn't say the design is Graphite")
        text, _, err = c.call("file-save")
        if err or "Saved kit.omx" not in text or "toast" not in text:
            problems.append(f"file-save didn't save with a toast: {text!r}")
        text, images, err = c.call("render", name="canvas", width=460, height=214)
        if err or len(images) != 1:
            problems.append(f"render gave no picture: {text!r}")
        else:
            size, colours = png_size(images[0])
            if size != (460, 214) or colours < 3:
                problems.append(f"the canvas picture is {size} with {colours} colours")
        text, _, err = c.call("canvas", gesture="secondary", x=120, y=80)
        names = set(c.names())
        if err or "context menu" not in text or not {"sort-z-a", "sort-a-z", "delete-column", "close-menu"} <= names:
            problems.append(f"a secondary gesture opened no context menu with its items as tools: {text!r}")
        text, _, err = c.call("sort-z-a")
        if err or "Sorted Z→A" not in text or "sort-z-a" in set(c.names()):
            problems.append(f"sort-z-a didn't sort and close the menu: {text!r}")
        text, _, err = c.call("nope")
        if not err or "no tool" not in text:
            problems.append(f"a wrong name isn't an error for the agent: {text!r}")
        text, _, err = c.call("act", name="ledger-graphite-blueprint", value={"option": "Ledger"})
        if err or "Design: Ledger" not in text:
            problems.append(f"the inspector's segmented control didn't switch the design back: {text!r}")
        texts, _, _ = c.call("read")
        status = [t[len("status-bar: "):] for t in texts.splitlines() if t.startswith("status-bar: ")]
    finally:
        log = c.close()
    if "Traceback" in log:
        problems.append("the agent host logged a traceback: " + log[-400:])
    gtk = kit("tap:Open dialog;radio:0=Graphite;tap:Done;menu:File>Save;rightclick:0=400,500;menu:>Sort Z→A;segment:0=Ledger", "kit-agent")  # (the web: a toast over a button blocks it, so the dialog first)
    if gtk[0] is None:
        problems.append(gtk[1])
    else:
        for host, k in (("GTK", 0), ("web", 1)):
            missing = [s for s in status if s not in labels(gtk[k])]
            if missing or not status:
                problems.append(f"{host}'s status lines after the same steps differ from the agent's: missing {missing} (agent: {status})")
    return not problems, "; ".join(problems) or f"the kit: {len(tools)} tools at the start, the dialog's and the context menu's while open, the same status as GTK and the web"


def m2():
    """omxplorer by an agent: the sample opens, Data > Sort largest first sorts, read gives the grid's rows, render a picture."""
    problems = []
    c = Client(BUILD / "omxplorer" / "web", env())
    try:
        screen, _, err = c.call("screen")
        if err or "open-the-sample" not in c.names():
            problems.append(f"the Start screen has no open-the-sample tool: {screen[:300]!r}")
        text, _, err = c.call("open-the-sample")
        if err or "Rows 1,000,000" not in text:
            problems.append(f"the sample didn't open with its rows: {text[:300]!r}")
        screen, _, _ = c.call("screen")
        for needle in ("data-sort-largest-first", "status-bar", "Sum ", "Average ", "Rows 1,000,000", "Canvas"):
            if needle not in screen:
                problems.append(f"the sheet's screen lacks {needle!r}")
        before, _, _ = c.call("read", name="grid", count=50)
        text, _, err = c.call("data-sort-largest-first")
        if err or "Sorted by revenue" not in text:
            problems.append(f"Data > Sort largest first didn't sort: {text[:300]!r}")
        rows, _, err = c.call("read", name="grid", count=50)
        head, *body = rows.splitlines()
        cols = head.split("\t")
        if err or cols[:2] != ["order", "day"] or "revenue" not in cols or len(body) != 50:
            problems.append(f"read grid isn't the header and 50 rows: {rows[:200]!r}")
        else:
            rev = [float(r.split("\t")[cols.index("revenue")].replace(",", "")) for r in body]
            if rev != sorted(rev, reverse=True):
                problems.append(f"the rows aren't sorted by revenue, largest first: {rev[:6]}")
            if rows == before:
                problems.append("the grid reads the same before and after the sort")
        text, images, err = c.call("render", name="grid", width=900, height=400)
        if err or len(images) != 1:
            problems.append(f"render grid gave no picture: {text!r}")
        else:
            size, colours = png_size(images[0])
            if size != (900, 400) or colours < 4:
                problems.append(f"the grid picture is {size} with {colours} colours")
    finally:
        log = c.close()
    if "Traceback" in log:
        problems.append("the agent host logged a traceback: " + log[-400:])
    return not problems, "; ".join(problems) or "omxplorer: the sample, a sort from the Data menu, the grid's rows as text, a picture of it"


def m3():
    """A fifth host: the matrix has an Agent column, the one command, the doc."""
    problems = []
    r = run(["pixi", "run", "python", "scripts/components.py", "--check"], timeout=120)
    if r.returncode != 0:
        problems.append("docs/components.md is stale")
    doc = (ROOT / "docs/components.md").read_text()
    if "Agent (MCP)" not in doc.splitlines()[10]:
        problems.append("docs/components.md has no Agent (MCP) column")
    for row in ("`Button`", "`MenuBar`", "`Item`", "`Dialog`", "`Canvas`", "`Toggle`"):
        line = next((l for l in doc.splitlines() if l.startswith(f"| {row} |")), "")
        if line.split("|")[-3].strip() != "✅":
            problems.append(f"{row} isn't ✅ for the agent: {line!r}")
    r = run(["scripts/agent.sh", "kit"], timeout=600)
    if r.returncode != 0 or not r.stdout.startswith("claude mcp add kit -- ") or "mojoui/hosts/agent.py" not in r.stdout:
        problems.append(f"scripts/agent.sh kit doesn't print the Claude Code command: {r.stdout!r} {r.stderr[-200:]!r}")
    p = ROOT / "docs/agent.md"
    text = p.read_text() if p.exists() else ""
    for needle in ("screen", "act", "read", "render", "list_changed", "nothing a person couldn't", "claude mcp add"):
        if needle not in text:
            problems.append(f"docs/agent.md lacks {needle!r}")
    return not problems, "; ".join(problems) or "the matrix's Agent column, scripts/agent.sh, docs/agent.md"


def m4():
    """Nothing regressed: goal 18's milestones (every earlier goal's inside them)."""
    problems = []
    for name, fn in [("18-M1", g18.m1), ("18-M2", g18.m2), ("18-M3", g18.m3), ("18-M4", g18.m4), ("18-M5", g18.m5)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    return not problems, "; ".join(problems) or "goal 18's M1–M5 (goals 3–17 inside them) pass"


def m5():
    """F-138c (goal 18's M-numbers moved to docs/goals/18-check.py): omxplorer runs on the MX frame package, and its Linux binary carries no Python."""
    problems = []
    exe = BUILD / "omxplorer" / "linux" / "omxplorer"
    if not exe.exists():
        return False, f"{exe} isn't built"
    ldd = run(["ldd", str(exe)]).stdout
    if "libpython" in ldd.lower():
        problems.append("ldd shows libpython")
    nm = run(["nm", "-D", str(exe)]).stdout
    if "KGEN_CompilerRT_Python" in nm:
        problems.append("nm -D shows KGEN_CompilerRT_Python (Mojo's Python interop)")
    strings = run(["strings", str(exe)]).stdout
    if re.search(r"^Py_Initialize", strings, re.M):
        problems.append("strings shows Py_Initialize")
    for needle in ("from std.python", "import pyarrow", "from mojoui.frame ", "from mojoui.frame_gpu"):
        for f in ("mojoui/csvio.mojo", "mojoui/omxfile.mojo", "mojoui/sample.mojo", "mojoui/json.mojo", "mojoui/sheet.mojo", "mojoui/sheetpage.mojo", "mojoui/reportpage.mojo", "examples/omxplorer/app.mojo"):
            if needle in (ROOT / f).read_text():
                problems.append(f"{f} uses {needle}")
    if not (ROOT / "vendor/omxcore.mojoc").exists() or not (ROOT / "vendor/OMXCORE_COMMIT").read_text().strip():
        problems.append("vendor/omxcore.mojoc or its recorded source commit is missing")
    return not problems, "; ".join(problems) or "the omxplorer Linux binary has no libpython (ldd), no KGEN_CompilerRT_Python (nm -D) and no Py_Initialize (strings); its engine modules import only the MX frame package; the package is vendored with its source commit"


def main():
    import shutil
    import headless
    headless.ensure()
    only = sys.argv[1:]
    if not only:
        for ex in EXAMPLES:
            shutil.rmtree(BUILD / ex, ignore_errors=True)
        for ex in EXAMPLES:
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
    for name, fn in [("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5)]:
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
