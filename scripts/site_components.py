"""The public component page (docs/components.html) and the cover's component summary (docs/index.html, between
<!-- components:begin --> and <!-- components:end -->), generated from the two files the matrix scripts write:

  docs/components.json   the 36 pictured components: name, group, blurb, api, pictures, status per platform (scripts/catalog.py)
  docs/components.md     the composites (Mojo components built from those) and the JavaScript widgets (scripts/components.py)

  pixi run python scripts/site_components.py           # write both
  pixi run python scripts/site_components.py --check   # exit 1 when either is stale (scripts/check runs this)

Nothing here is typed by hand per component: names, statuses and counts come from those files. The only hand-written
words are each family's one line on what it solves and each platform's next step (the roadmap), below.
"""
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JSON = ROOT / "docs" / "components.json"
MD = ROOT / "docs" / "components.md"
PAGE = ROOT / "docs" / "components.html"
COVER = ROOT / "docs" / "index.html"
BEGIN, END = "<!-- components:begin -->", "<!-- components:end -->"

PLATS = [("linux", "Linux"), ("web", "Web"), ("mac", "Mac"), ("android", "Android"), ("iphone", "iPhone"), ("agent", "Agents")]
MD_COLS = ["linux", "web", "android", "mac", "iphone", "agent"]  # the matrix's column order
STATE = {"✅": "tested", "🔨": "builds", "❌": "missing"}
WORD = {"tested": "tested by a script", "builds": "builds, not run there yet", "missing": "not yet"}

# Where each platform goes next (the cover's roadmap, in the same words)
NEXT = {"linux": "Every component runs here on every check.",
        "web": "Runs today through the web host; next, GPU work in the browser with WebGPU.",
        "mac": "Apps run on GitHub's macOS runners; next, each component checked there.",
        "android": "Runs on the emulator; next, the data components and phones.",
        "iphone": "Builds and signs; next, running on a phone.",
        "agent": "Every app is an MCP tool server; next, every control a tool."}

# What a composite solves, for the ones whose matrix name has no "(…)" description of its own
SOLVES = {"DataGrid": "A spreadsheet grid over millions of rows: select, edit in place, sort, drag, drawn on a canvas.",
          "PivotTable": "Rows by columns with totals, from any table.",
          "ChartView": "Bars and lines you can pan, zoom and tap, drawn on a canvas.",
          "KpiView": "One big number with its trend, as a tile.",
          "FindingCard": "One finding from the data, said in words, with its evidence.",
          "Inspector": "A docked side panel of settings for whatever is selected.",
          "Toolbar · FormulaBar · StatusBar": "The chrome around a sheet: tools, the selected cell's value, totals.",
          "Format toggles": "Bold, italic, alignment and the rest, as pressed icon buttons.",
          "Bottom tabs, renamed in place": "Sheet tabs along the bottom; double-click to rename.",
          "Swatch picker": "Pick a colour from a popover of swatches.",
          "Column number formats": "Money, percent, decimals and dates per column.",
          "CodeBlock": "Code with a copy button, themed.",
          "LogView": "A log that scrolls and stays pinned to its end.",
          "Timeline": "Steps of a job with their state and progress.",
          "Breadcrumbs": "A trail back up through where you are.",
          "Chip · Badge": "A small label or status pill.",
          "Confirm": "A button that asks once more before a destructive action.",
          "Skeleton": "Grey placeholder rows while data loads.",
          "Markdown": "Formatted text from Markdown, drawn natively.",
          "Sparkline": "A tiny trend line inside a row or a tile."}

# Families: (key, title, what it solves, module stems or json groups that belong to it)
FAMILIES = [
    ("data", "Data and sheets", "Spreadsheets and analytics over millions of rows: grids, pivots, charts, KPIs, SQL.",
     "datagrid pivot chartview kpi finding inspector sheetchrome regions cellstyle island swatches numformat sheetpage "
     "reportpage tablecard tablejobs asksql sparkline".split()),
    ("video", "Video and vision", "Videos as data: play, scrub, analyze into rows, cut reels, decoded off the UI thread.",
     "video player timeseries picture mediacard mediatimeline imageops videotable videoexport vision_presets videojobs "
     "framefeed videocard timelane".split()),
    ("robotics", "Maps and robotics", "Telemetry beside its video, routes and findings on a map, inspections compared.",
     "geo inspection inspection_tables mapview trackcard".split()),
    ("docs", "Documents", "PDFs as pages and tables: read them (OCR), find fields, pack the evidence.",
     "pdfsource documentcard ocrmodel texttable formfields documentjobs documentset packpdf pack".split()),
    ("links", "Links", "Tables, videos and documents connected by key, time or place, confirmed by you.",
     "links linkdrag peek".split()),
    ("agents", "Agents", "Screens an agent builds as data, checked against the catalog, drawn natively.", ["genui"]),
    ("parts", "App parts", "The pieces every app needs: shells, lists, fields, logs, code, feedback.",
     "codeblock logview timeline breadcrumbs chip confirm skeleton markdown shell header sidebar panel marks words "
     "buttons lists document beacon copy fields results meter feedback ink spring".split()),
    ("basics", "Controls and layout", "The native controls: text, buttons, fields, menus, dialogs, stacks, canvases.",
     ["Basics", "Layout", "Input", "Feedback", "Menus & overlays", "Data & GPU"]),
    ("js", "JavaScript widgets", "Libraries from npm inside a native app: an editor, charts, your own.", []),
]


def esc(s):
    return html.escape(str(s), quote=True)


def split_name(full):
    """'Player (a video with play/pause…)' → ('Player', 'a video with play/pause…')."""
    m = re.match(r"^(.*?) \((.*)\)$", full)
    return (m.group(1), m.group(2)) if m else (full, "")


def md_rows(section):
    text = MD.read_text()
    body = text.split("## " + section, 1)[1].split("\n## ", 1)[0]
    return [[c.strip() for c in line.strip().strip("|").split("|")] for line in body.splitlines() if line.startswith("| `")]


def load():
    items = []
    for c in json.loads(JSON.read_text()):
        fam = next((f for f in FAMILIES if c["group"] in f[3]), FAMILIES[7])
        items.append({"name": c["name"], "solves": c["blurb"], "family": fam[0], "status": c["status"], "api": c.get("api", ""),
                      "image": c.get("image", ""), "image_web": c.get("image_web", ""), "module": "mojoui/view.mojo"})
    seen = {i["name"] for i in items}
    for row in md_rows("Composite components"):
        full, module, parts = row[0].strip("`"), row[1].strip("`"), row[2]
        name, solves = split_name(full)
        if name in seen:
            continue
        seen.add(name)
        stem = Path(module).stem
        fam = next((f for f in FAMILIES if stem in f[3]), FAMILIES[6])
        status = {k: STATE.get(v, "missing") for k, v in zip(MD_COLS, row[3:9])}
        items.append({"name": name, "solves": SOLVES.get(name) or solves or f"Made of {parts}.", "family": fam[0], "status": status,
                      "api": "", "image": "", "image_web": "", "module": module, "parts": parts})
    for row in md_rows("JavaScript widgets"):
        tag, lib = row[0].strip("`"), row[1]
        status = {k: STATE.get(v, "missing") for k, v in zip(MD_COLS, row[3:9])}
        items.append({"name": tag, "solves": f"{lib}, as a WebComponent ({row[2]}).", "family": "js", "status": status,
                      "api": "", "image": "", "image_web": "", "module": row[9].strip("`")})
    return items


def counts(items):
    return {k: {s: sum(1 for i in items if i["status"].get(k) == s) for s in ("tested", "builds", "missing")} for k, _ in PLATS}


def next_line(st):
    run = [n for k, n in PLATS if st.get(k) == "builds"]
    build = [n for k, n in PLATS if st.get(k) == "missing"]
    bits = ([f"run on {', '.join(run)}"] if run else []) + ([f"build for {', '.join(build)}"] if build else [])
    return ("Next: " + "; ".join(bits)) if bits else "On every platform."


def bars(items, cls="pbars"):
    total = len(items)
    rows = []
    for k, n in PLATS:
        c = counts(items)[k]
        t, b = c["tested"] * 100 / total, c["builds"] * 100 / total
        rows.append(f'<div class="pbar"><b>{n}</b><span class="track" role="img" aria-label="{n}: {c["tested"]} tested, '
                    f'{c["builds"]} build, {c["missing"]} not yet"><i class="t" style="width:{t:.1f}%"></i><i class="b" '
                    f'style="width:{b:.1f}%"></i></span><em>{c["tested"]}<small> / {total}</small></em></div>')
    return f'<div class="{cls}">' + "".join(rows) + "</div>"


def cover_block(items):
    fams = []
    for key, title, solves, _ in FAMILIES:
        mine = [i for i in items if i["family"] == key]
        if not mine:
            continue
        tested = sum(1 for i in mine if i["status"]["linux"] == "tested" and i["status"]["web"] == "tested")
        names = ", ".join(i["name"] for i in mine[:3])
        fams.append(f'<a class="fam" href="components.html#{key}"><span class="fn">{len(mine)}</span><h3>{esc(title)}</h3>'
                    f'<p>{esc(solves)}</p><small>{esc(names)}…</small><span class="ft">{tested} tested on Linux and the web</span></a>')
    total = len(items)
    both = sum(1 for i in items if i["status"]["linux"] == "tested" and i["status"]["web"] == "tested")
    return (f'{BEGIN}\n<div class="compsum rv">\n  <div class="cs-left"><div class="big">{total}<small>components</small></div>'
            f'<p><b>{both} run on Linux and the web</b> under a script on every check. The bars: tested, then builds.</p>'
            f'{bars(items)}<p class="fine">Mac apps run on GitHub\'s macOS runners (scripts/mac-ci); checking each component there is next.</p>'
            f'<a class="more" href="components.html">Browse all {total}</a></div>\n'
            f'  <div class="fams">{"".join(fams)}</div>\n</div>\n'
            f'<p class="srcline">generated by scripts/site_components.py from docs/components.json and docs/components.md</p>\n{END}')


def card(i):
    pic = (f'<div class="pic"><img src="{esc(i["image"])}" alt="{esc(i["name"])}, drawn by omxcode on Linux" loading="lazy"></div>'
           if i["image"] else f'<div class="pic none f-{i["family"]}"><span>{esc(i["module"].split("/")[-1])}</span></div>')
    dots = "".join(f'<span title="{n}: {WORD[i["status"].get(k, "missing")]}"><i class="dot {i["status"].get(k, "missing")}"></i>{n}</span>'
                   for k, n in PLATS)
    tested = " ".join(k for k, _ in PLATS if i["status"].get(k) == "tested")
    data = {k: i[k] for k in ("name", "solves", "api", "image", "image_web", "module", "status")}
    return (f'<button class="comp" type="button" data-f="{i["family"]}" data-t="{tested}" data-q="{esc((i["name"] + " " + i["solves"]).lower())}" '
            f'data-c="{esc(json.dumps(data))}">{pic}<div class="ct"><h3>{esc(i["name"])}</h3><p>{esc(i["solves"])}</p>'
            f'<div class="pl">{dots}</div><small class="nx">{esc(next_line(i["status"]))}</small></div></button>')


def page(items):
    total = len(items)
    c = counts(items)
    fam_chips = "".join(f'<button class="fchip" type="button" data-g="{k}">{esc(t)} <span>{sum(1 for i in items if i["family"] == k)}</span></button>'
                        for k, t, _, _ in FAMILIES if any(i["family"] == k for i in items))
    plat_chips = "".join(f'<button class="fchip" type="button" data-p="{k}"><i class="dot tested"></i>{n} <span>{c[k]["tested"]}</span></button>' for k, n in PLATS)
    nexts = "".join(f'<div><b>{n}</b><span>{c[k]["tested"]} tested · {c[k]["builds"]} build</span><p>{esc(NEXT[k])}</p></div>' for k, n in PLATS)
    sections = []
    for key, title, solves, _ in FAMILIES:
        mine = [i for i in items if i["family"] == key]
        if mine:
            sections.append(f'<section class="fsec" id="{key}" data-fam="{key}"><div class="fhead"><h2>{esc(title)} <span>{len(mine)}</span></h2>'
                            f'<p>{esc(solves)}</p></div><div class="grid">{"".join(card(i) for i in mine)}</div></section>')
    return TEMPLATE.replace("{{TOTAL}}", str(total)).replace("{{BARS}}", bars(items)).replace("{{NEXTS}}", nexts) \
        .replace("{{FAMCHIPS}}", fam_chips).replace("{{PLATCHIPS}}", plat_chips).replace("{{SECTIONS}}", "\n".join(sections))


def outputs():
    items = load()
    cover = COVER.read_text()
    if BEGIN not in cover or END not in cover:
        raise SystemExit(f"docs/index.html has no {BEGIN} … {END} markers")
    head, rest = cover.split(BEGIN, 1)
    new_cover = head + cover_block(items) + rest.split(END, 1)[1]
    return {PAGE: page(items), COVER: new_cover}


def main():
    outs = outputs()
    if "--check" in sys.argv:
        stale = [p.name for p, t in outs.items() if not p.exists() or p.read_text() != t]
        if stale:
            print("stale: " + ", ".join(stale) + ": run pixi run python scripts/site_components.py")
            return 1
        print("docs/components.html and the cover's component block are current")
        return 0
    for p, t in outs.items():
        p.write_text(t)
        print(f"wrote {p.relative_to(ROOT)}")
    return 0


TEMPLATE = """<!doctype html>
<html lang="en" class="oq-root oq-night oq-family-dev">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>omxcode components · what each one solves and where it runs</title>
<meta name="description" content="Every omxcode component: what it solves, where a script tests it (Linux, web, Mac, Android, iPhone, agents) and what's next.">
<meta name="theme-color" content="#000000">
<link rel="icon" href="img/logo.svg" type="image/svg+xml">
<!-- generated by scripts/site_components.py from docs/components.json and docs/components.md: don't edit by hand -->
<link rel="stylesheet" href="omxqua/src/fonts.css">
<link rel="stylesheet" href="omxqua/src/tokens.css">
<link rel="stylesheet" href="omxqua/src/components.css">
<link rel="stylesheet" href="site.css">
<style>
.chead { padding: 72px 24px 24px; }
.chead h1 { font-size: clamp(40px, 5.4vw, 64px); }
.chead .lede { font-size: clamp(17px, 1.7vw, 21px); }
.top2 { display: grid; grid-template-columns: minmax(0, 5fr) minmax(0, 7fr); gap: 20px; margin-top: 36px; }
.box2 { border-radius: 22px; background: var(--oq-surface-1); box-shadow: 0 0 0 1px var(--line); padding: 20px 22px; }
.box2 h4 { margin: 0 0 12px; font: 600 11px var(--mono); letter-spacing: .1em; text-transform: uppercase; color: var(--ink2); }
.pbars { display: grid; gap: 9px; }
.pbar { display: grid; grid-template-columns: 70px 1fr 64px; gap: 12px; align-items: center; font-size: 14px; }
.pbar b { font-weight: 600; } .pbar em { font: 600 14px var(--mono); font-style: normal; text-align: right; } .pbar em small { color: var(--ink2); font-weight: 400; }
.track { display: flex; height: 8px; border-radius: 4px; background: var(--oq-surface-3); overflow: hidden; }
.track .t { background: var(--oq-ok); } .track .b { background: color-mix(in srgb, var(--oq-info) 70%, transparent); }
.nexts { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px 18px; }
.nexts b { font: 600 14px var(--sans); } .nexts span { display: block; font: 12px var(--mono); color: var(--ink2); margin-top: 2px; }
.nexts p { margin: 4px 0 0; font-size: 13.5px; line-height: 1.45; color: var(--ink2); }
.legend { display: flex; gap: 18px; flex-wrap: wrap; margin-top: 16px; font: 13px var(--mono); color: var(--ink2); }
.legend span { display: inline-flex; gap: 7px; align-items: center; }
.dot { width: 9px; height: 9px; border-radius: 50%; flex: none; display: inline-block; }
.dot.tested { background: var(--oq-ok); } .dot.builds { background: var(--oq-info); } .dot.missing { background: transparent; box-shadow: inset 0 0 0 1.5px var(--ink2); }
.filters { position: sticky; top: 59px; z-index: 20; background: var(--bg); padding: 14px 0 12px; display: grid; gap: 8px; box-shadow: 0 1px 0 var(--oq-line-2); }
.frow { display: flex; gap: 7px; flex-wrap: wrap; align-items: center; }
.frow .lbl { font: 600 11px var(--mono); letter-spacing: .1em; text-transform: uppercase; color: var(--ink2); width: 76px; }
.search { flex: 1; min-width: 200px; height: 40px; border-radius: 999px; border: 0; padding: 0 18px; background: var(--oq-surface-1); box-shadow: 0 0 0 1px var(--line); color: var(--ink); font: 500 15px var(--sans); }
.search:focus { outline: 2px solid var(--oq-accent); outline-offset: 2px; }
.fchip { all: unset; }
.frow .fchip { cursor: pointer; font-family: var(--sans); font-size: 13px; font-weight: 500; color: var(--ink2); padding: 6px 12px; border-radius: 999px; box-shadow: inset 0 0 0 1px var(--line); display: inline-flex; gap: 6px; align-items: center;
  transition: background .15s, color .15s, transform var(--oq-spring-fast-dur) var(--oq-island-spring); }
.fchip span { opacity: .6; font-family: var(--mono); font-size: 12px; }
.fchip:hover { color: var(--ink); } .fchip:active { transform: scale(.96); }
.fchip.on { background: var(--oq-accent); color: var(--oq-on-accent); box-shadow: none; }
.fchip:focus-visible { outline: 2px solid var(--oq-accent); outline-offset: 2px; }
.count { font: 13px var(--mono); color: var(--ink2); margin-left: auto; }
.fsec { padding: 34px 0 0; } .fsec[hidden] { display: none; }
.fhead { display: flex; gap: 6px 18px; align-items: baseline; flex-wrap: wrap; }
.fhead h2 { font: 700 26px var(--display); letter-spacing: -.03em; margin: 0; } .fhead h2 span { color: var(--ink2); font: 500 15px var(--mono); }
.fhead p { margin: 0; color: var(--ink2); font-size: 15px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px; margin-top: 16px; }
.comp { all: unset; }
.comp { cursor: pointer; display: flex; flex-direction: column; border-radius: 20px; background: var(--oq-surface-1); box-shadow: 0 0 0 1px var(--line); overflow: hidden; min-width: 0;
  transition: transform var(--oq-spring-fast-dur) var(--oq-island-spring), box-shadow .2s; }
.comp:hover { transform: translateY(-2px); box-shadow: 0 0 0 1px var(--line), var(--oq-shadow-2); } .comp:active { transform: scale(.98); }
.comp:focus-visible { outline: 2px solid var(--oq-accent); outline-offset: 3px; }
.comp[hidden] { display: none; }
.pic { height: 120px; background: #f3f3f5; display: grid; place-items: center; overflow: hidden; }
.pic img { max-width: 90%; max-height: 104px; object-fit: contain; }
.pic.none { background: color-mix(in srgb, var(--fh, var(--word)) 14%, var(--oq-surface-2)); height: 64px; }
.pic.none { height: 40px; place-items: center start; padding: 0 14px; }
.pic.none span { font: 600 12px var(--mono); color: var(--fh, var(--word)); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 100%; }
.f-data { --fh: var(--oq-data-1); } .f-video { --fh: var(--oq-data-2); } .f-robotics { --fh: var(--oq-data-3); } .f-docs { --fh: var(--oq-data-4); }
.f-links { --fh: var(--oq-ok); } .f-agents { --fh: var(--oq-info); } .f-js { --fh: var(--oq-warn); }
.ct { padding: 12px 14px 14px; display: grid; gap: 6px; }
.ct h3 { font: 650 15.5px var(--mono); letter-spacing: -.01em; overflow-wrap: anywhere; }
.ct p { margin: 0; font-size: 13.5px; color: var(--ink2); line-height: 1.4; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.pl { display: flex; gap: 4px 9px; flex-wrap: wrap; margin-top: 2px; }
.pl span { display: inline-flex; gap: 4px; align-items: center; font: 500 11px var(--mono); color: var(--ink2); }
.nx { font: 11.5px/1.4 var(--mono); color: color-mix(in srgb, var(--ink2) 80%, transparent); }
.empty { text-align: center; color: var(--ink2); padding: 60px 0; }
dialog.sheet { border: 0; padding: 0; border-radius: 26px; background: var(--oq-surface-1); color: var(--ink); width: min(820px, 94vw); max-height: 90vh; box-shadow: var(--oq-shadow-4), 0 0 0 1px var(--line); }
dialog.sheet::backdrop { background: rgb(0 0 0 / .6); }
dialog.sheet[open] { animation: rise2 .28s var(--ease); }
@keyframes rise2 { from { opacity: 0; transform: translateY(12px); } }
.sh { display: grid; grid-template-columns: 1.1fr 1fr; } .sh.nopic { grid-template-columns: 1fr; }
.sh .big { background: #f3f3f5; display: grid; place-items: center; min-height: 280px; padding: 20px; }
.sh .big img { max-width: 100%; max-height: 380px; object-fit: contain; }
.sh .info { padding: 24px 24px 22px; display: grid; gap: 12px; align-content: start; }
.sh h2 { font: 700 26px var(--mono); letter-spacing: -.03em; margin: 0; padding-right: 40px; overflow-wrap: anywhere; }
.sh p { margin: 0; color: var(--ink2); font-size: 15px; }
.sh pre { margin: 0; padding: 12px 14px; border-radius: 12px; background: var(--bg); font: 13px/1.6 var(--mono); white-space: pre-wrap; word-break: break-word; }
.prow { display: grid; gap: 5px; } .prow div { display: grid; grid-template-columns: 80px 1fr; gap: 10px; font-size: 14px; } .prow div span { color: var(--ink2); display: flex; gap: 8px; align-items: center; }
.close { all: unset; }
.close { cursor: pointer; position: absolute; top: 12px; right: 12px; width: 36px; height: 36px; border-radius: 50%; display: grid; place-items: center; background: var(--oq-surface-2); font-size: 16px; z-index: 2; }
.close:focus-visible { outline: 2px solid var(--oq-accent); }
@media (max-width: 860px) {
  .top2, .sh { grid-template-columns: 1fr; } .nexts { grid-template-columns: 1fr 1fr; } .frow .lbl { width: 100%; } .filters { top: 59px; position: static; }
  .grid { grid-template-columns: 1fr 1fr; gap: 10px; } .pic { height: 96px; } .ct p { -webkit-line-clamp: 4; }
}
@media (max-width: 480px) { .grid { grid-template-columns: 1fr; } .nexts { grid-template-columns: 1fr; } }
</style>
</head>
<body>

<nav class="lnav">
  <a class="brand" href="index.html"><span class="mark">ox</span>omxcode <span class="sub">/ components</span></a>
  <div class="pill"><span class="ind" aria-hidden="true"></span><a href="index.html#roadmap">Roadmap</a><a href="index.html#gallery">Gallery</a><a href="omxplorer.html">omxplorer</a></div>
  <div class="right"><a class="cta" href="index.html#get">Get the alpha</a></div>
</nav>

<main>
<section class="chead">
  <div class="wrap">
    <div class="eyebrow"><span>Components</span></div>
    <h1>{{TOTAL}} components. <span class="two">Each one tested by a script.</span></h1>
    <p class="lede">What each one solves, where a script runs it today, and where it goes next. Generated from the code and the checks, never typed by hand.</p>
    <div class="top2">
      <div class="box2"><h4>Tested on each platform</h4>{{BARS}}
        <div class="legend"><span><i class="dot tested"></i>tested by a script</span><span><i class="dot builds"></i>builds, not run there yet</span><span><i class="dot missing"></i>not yet</span></div></div>
      <div class="box2"><h4>What's next, per platform</h4><div class="nexts">{{NEXTS}}</div></div>
    </div>
  </div>
</section>

<section style="padding-top:8px">
  <div class="wrap">
    <div class="filters">
      <div class="frow"><input class="search" id="q" type="search" placeholder="Search: grid, video, menu, PDF…" aria-label="Search components"><span class="count" id="count"></span></div>
      <div class="frow" id="groups"><span class="lbl">Family</span><button class="fchip on" type="button" data-g="">All</button>{{FAMCHIPS}}</div>
      <div class="frow" id="plats"><span class="lbl">Tested on</span><button class="fchip on" type="button" data-p="">Any</button>{{PLATCHIPS}}</div>
    </div>
{{SECTIONS}}
    <p class="empty" id="empty" hidden>Nothing matches. Try another word, or "Any" platform.</p>
  </div>
</section>
</main>

<dialog class="sheet" id="sheet" aria-labelledby="sname">
  <button class="close" type="button" aria-label="Close">✕</button>
  <div class="sh"><div class="big"><img id="simg" alt=""></div>
    <div class="info"><h2 id="sname"></h2><p id="ssolves"></p><pre id="sapi"></pre><p class="mono" id="smod" style="font-size:12.5px"></p><div class="prow" id="splats"></div><p class="mono" id="snext" style="font-size:12.5px"></p></div></div>
</dialog>

<footer>
  <div class="wrap">
    <p class="note">Generated by scripts/site_components.py from docs/components.json (pictures and statuses, scripts/catalog.py) and docs/components.md (the composites and JS widgets, scripts/components.py). "Tested" means a check runs it on that platform; Mac apps also run on GitHub's macOS runners (scripts/mac-ci).</p>
    <div class="fine"><span>omxcode · components · MIT licence</span><a href="https://github.com/abhisheksreesaila/omxcode/blob/main/docs/components.md">The full matrix on GitHub</a></div>
  </div>
</footer>

<script src="site.js"></script>
<script>
(() => {
  const { $, $$ } = window.omx;
  const PLATS = [["linux", "Linux"], ["web", "Web"], ["mac", "Mac"], ["android", "Android"], ["iphone", "iPhone"], ["agent", "Agents"]];
  const WORD = { tested: "tested by a script", builds: "builds, not run there yet", missing: "not yet" };
  let fam = "", plat = "", q = "";
  const cards = $$(".comp"), secs = $$(".fsec");
  function draw() {
    let n = 0;
    cards.forEach(c => { const ok = (!fam || c.dataset.f === fam) && (!plat || c.dataset.t.split(" ").includes(plat)) && (!q || c.dataset.q.includes(q)); c.hidden = !ok; n += ok; });
    secs.forEach(s => s.hidden = !$$(".comp", s).some(c => !c.hidden));
    $("#count").textContent = `${n} of ${cards.length}`; $("#empty").hidden = n > 0;
  }
  document.addEventListener("click", e => {
    const g = e.target.closest("[data-g]"), p = e.target.closest("[data-p]"), c = e.target.closest(".comp");
    if (g) { fam = g.dataset.g; $$("[data-g]").forEach(b => b.classList.toggle("on", b === g)); draw(); }
    if (p) { plat = p.dataset.p; $$("[data-p]").forEach(b => b.classList.toggle("on", b === p)); draw(); }
    if (c) open(JSON.parse(c.dataset.c), c);
  });
  $("#q").addEventListener("input", e => { q = e.target.value.trim().toLowerCase(); draw(); });
  const sheet = $("#sheet");
  function open(d, card) {
    $(".sh", sheet).classList.toggle("nopic", !d.image); $(".big", sheet).hidden = !d.image;
    $("#simg").src = d.image || ""; $("#simg").alt = d.image ? d.name + ", drawn by omxcode on Linux" : "";
    $("#sname").textContent = d.name; $("#ssolves").textContent = d.solves;
    $("#sapi").hidden = !d.api; $("#sapi").textContent = d.api; $("#smod").textContent = d.module;
    $("#splats").innerHTML = PLATS.map(([k, n]) => `<div><b>${n}</b><span><i class="dot ${d.status[k] || "missing"}"></i>${WORD[d.status[k] || "missing"]}</span></div>`).join("");
    $("#snext").textContent = $(".nx", card).textContent;
    sheet.showModal();
  }
  $(".close", sheet).addEventListener("click", () => sheet.close());
  sheet.addEventListener("click", e => { if (e.target === sheet) sheet.close(); });
  draw();
})();
</script>
<script src="omxqua/src/omxqua.js" defer></script>
</body>
</html>
"""

if __name__ == "__main__":
    sys.exit(main())
