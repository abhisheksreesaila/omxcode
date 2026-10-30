"""The component × platform matrix, generated from the code (docs/components.md), so it can't drift.

  pixi run python scripts/components.py          # rewrite docs/components.md (and docs/llms-full.txt, which embeds it)
  pixi run python scripts/components.py --check  # exit 1 if docs/components.md is out of date (scripts/check runs this)

A cell is:
  ✅  implemented in that host AND run by a check on that platform (the example that proves it is listed)
  🔨  implemented in that host, builds, never run there (Mac and iPhone: no hardware yet; some Android screens)
  ❌  not implemented in that host (an app using it there would get nothing)

"Implemented" is read from the host source; "run" comes from which examples each platform's checks drive
(EVIDENCE below). Components that live inside one app (not in mojoui yet) are listed separately: they are
the debt to pay before the next app reuses them.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOSTS = [("Linux (GTK)", "mojoui/hosts/gtk.mojo"), ("Web", "mojoui/hosts/web.py"), ("Android", "mojoui/hosts/android.mojo"),
         ("Mac (AppKit)", "mojoui/hosts/appkit.mojo"), ("iPhone (UIKit)", "mojoui/hosts/uikit.mojo"),
         ("Agent (MCP)", "mojoui/hosts/agent.py")]

# The public constructor for each node kind (mojoui/view.mojo).
COMPONENTS = [
    ("Text", "TEXT"), ("Button", "BUTTON"), ("VStack", "VSTACK"), ("HStack", "HSTACK"), ("Spacer", "SPACER"),
    ("Card", "VSTACK"), ("Scroll", "SCROLL"), ("Grid", "GRID"), ("Divider", "DIVIDER"),
    ("TextField", "FIELD"), ("TextArea", "TEXTAREA"), ("Toggle", "TOGGLE"), ("Dropdown", "DROPDOWN"), ("Slider", "SLIDER"),
    ("Segmented", "SEGMENTED"), ("Radio", "RADIO"), ("DatePicker", "DATE"), ("ProgressBar", "PROGRESS"),
    ("Image", "IMAGE"), ("Icon", "ICON"), ("Alert", "ALERT"), ("Tabs", "TABS"), ("NavBar", "NAVBAR"),
    ("LazyList", "LAZYLIST"), ("Canvas", "CANVAS"), ("Board", "BOARD"), ("Overlay", "OVERLAY"),
    ("MenuBar", "MENUBAR"), ("Menu", "MENU"), ("Item", "ITEM"), ("ContextMenu", "MENU"),
    ("Dialog", "DIALOG"), ("Toast", "TOAST"), ("Popover", "POPOVER"), ("Checkbox", "TOGGLE"), ("Clipboard", "CLIPBOARD"),
    ("Table", "TABLE"), ("Route", "ROUTE"), ("Draggable", "DRAG"), ("DropTarget", "DROP"), ("WebFrame", "EMBED"),
    ("Paragraph", "PARAGRAPH"), ("WebComponent", "WEBCOMP"),
]

# Which examples each platform's checks actually run (docs/goals/*-check.py): GTK and the web run every
# example; the Android checks (goal 7) drive these on the emulator; Mac and iPhone only build and sign.
RUN_ON = {
    "Linux (GTK)": ["hello", "gallery", "todo", "gpu", "kitchen", "expenses", "layout", "lens", "analytics", "workbook", "mxstudio", "omxplorer", "themes", "kit", "httpcheck", "consolekit", "console", "widgets", "agentchat", "media"],  # (widgets: goal 34 M3, WebKitGTK views; agentchat: goal 35; media: goal 39 M2/M11 run it headless)
    "Web": ["hello", "gallery", "todo", "gpu", "kitchen", "expenses", "layout", "lens", "analytics", "workbook", "mxstudio", "omxplorer", "themes", "kit", "httpcheck", "consolekit", "console", "widgets", "agentchat"],  # (kit: goal 18 runs it on GTK and the web)
    "Android": ["hello", "gallery", "layout", "lens", "todo"],
    "Mac (AppKit)": [],
    "iPhone (UIKit)": [],
    "Agent (MCP)": ["kit", "omxplorer", "widgets"],  # (widgets: goal 34b M0, the agent attached to the web and GTK hosts)
}

# Variants, gestures, layout and design languages: (name, the API, a pattern that shows a host implements it,
# the example whose checks exercise it).
FEATURES = [
    ("Button with an icon", "Button(icon=…)", r"node\.hint != \"\"|n\[\"hint\"\]|adw_button_content", "workbook"),
    ("Card tones", "Card(tone=CARD_WARN / CARD_GOOD)", r"CARD_WARN|card warn|mui-warn", "mxstudio"),
    ("Text tones", "Text(…).tone(TONE_WARN…)", r"mui-tone|tone-warn", "mxstudio"),
    ("Quiet buttons", "style=SUBTLE / ICON_ONLY", r"\bSUBTLE\b|\bICON_ONLY\b", "workbook"),
    ("Lucide icon set", "Button(icon=\"table\")…", r"lucide|mojoui-", "workbook"),
    ("In-place editor", "TextField(…).focused()", r"value == 1|cell-editor", "workbook"),
    ("Layout modifiers", ".padding .width .grow .fill .align .justify", r"pad_v", "layout"),
    ("Canvas: pan, zoom, tap", "on_gesture: PAN, ZOOM, TAP", r"\bPAN\b|PAN =", "lens"),
    ("Canvas: press, release, double", "PRESS, RELEASE, DOUBLE", r"\bDOUBLE\b|DOUBLE =", "workbook"),
    ("Canvas frames (animation)", "on_frame", r"tick|SET_FRAMES|on_frame", "lens"),
    ("Canvas: keys (focus on press)", "on_gesture: KEY (event.text, modifiers)", r"\"key-pressed\"|addEventListener\('keydown'", "mxstudio"),
    ("TextField: Escape cancels", "TextField(on_cancel=)", r"on_field_key|second: 2", "mxstudio"),
    ("Editor that echoes the grid's typing", "TextField(…).echo()", r"\.echo\(\): the canvas typing|value\"\] == 3", "mxstudio"),
    ("Board: drag, resize, snap", "Board(on_move, on_resize)", r"\bBOARD\b", "workbook"),
    ("Board: scrolls, reveals a child", "Board(reveal=, reveal_count=)", r"reveal", "workbook"),
    ("Board: phone-width list", "(automatic under 720 pt)", r"board_list|max-width: 719px", "workbook"),
    ("Overlay islands", "Overlay(base, *islands) + .pin(h, v)", r"\bOVERLAY\b", "workbook"),
    ("Themes on top (themes/, or yours)", "def theme(self) -> Theme", r"gtk_css|web_css|theme_key|paint_native|mod\.theme", "themes"),
    ("Sentence with tappable words", "Sentence([Word(…)]) · Button(style=TOKEN)", r"\bTOKEN\b|mui-token|button\.token", "omxplorer"),
    ("Inspector pages", "NavRow(…) · InspectorPage(…) (made of buttons and stacks)", r"\bBUTTON\b", "omxplorer"),
    ("Light and dark from the system", "def appearance(mut self, dark)", r"rt\.appearance\(|/appearance/|mod\.appearance", "themes"),
    ("Shared data per process", "App.init_shared()", r"init_shared", "workbook"),
    ("Toolbar button (icon over label)", "Button(style=TOOL / TOOL_ON)", r"mui-tool|button\.tool", "omxplorer"),
    ("File picker", "FilePicker(title, on_pick)", r"gtk_file_dialog_open|/upload/", "omxplorer"),  # (GTK: built, but checks use the pick: step, not the dialog: UNPROVEN)
    ("Keyboard shortcuts (menu items)", "Item(shortcut=\"Ctrl+S\")", r"shortcut", "omxplorer"),
    ("Canvas: right-click", "on_gesture: SECONDARY (event.x, y)", r"\bSECONDARY\b", "omxplorer"),
    ("Submenus, checked, disabled and danger items", "Submenu(…), Item(checked=, disabled=, danger=)", r"mui-danger|mi-danger|danger", "omxplorer"),
    ("Tooltips", ".tooltip(text)", r"node\.tip|data-tip|\"tip\"", "omxplorer"),
    ("Icon toggle shown pressed", "Button(style=ICON_ON)", r"\bICON_ON\b", "omxplorer"),
    ("HTTP requests (effects; replies as Events)", "mojoui.http: Request.get/post_json · App.requests() · comptime HTTP", r"schedule_effects|mod\.poll", "httpcheck"),
    ("Timers", "App.every() -> [Every(ms, msg)]", r"schedule_effects|mod\.poll", "httpcheck"),
    ("Scroll pinned to its end", "Scroll(…, pinned=True)", r"on_pin_changed|data-pin|follow_ends", "consolekit"),
]

# Components built in Mojo from the ones above (drawn on a Canvas or assembled from native controls):
# (name, module, what it's made of: component or feature names above, the constructor apps call)
COMPOSITES = [
    ("DataGrid", "mojoui/datagrid.mojo", ["Canvas", "Canvas: press, release, double", "Canvas: keys (focus on press)", "In-place editor", "TextField: Escape cancels", "Editor that echoes the grid's typing", "Board: drag, resize, snap"], "DataGrid("),
    ("PivotTable", "mojoui/pivot.mojo", ["Grid", "Scroll", "Text tones"], "PivotTable("),
    ("ChartView", "mojoui/chartview.mojo", ["Canvas", "Canvas: pan, zoom, tap"], "ChartView"),
    ("KpiView", "mojoui/kpi.mojo", ["Card tones", "Text tones", "Canvas"], "KpiView("),
    ("FindingCard", "mojoui/finding.mojo", ["Card tones", "Text tones", "Quiet buttons"], "FindingCard("),
    ("Inspector", "mojoui/inspector.mojo", ["Segmented", "Dropdown", "Toggle", "Card", "Quiet buttons"], "Inspector("),
    ("Toolbar · FormulaBar · StatusBar", "mojoui/sheetchrome.mojo", ["Toolbar button (icon over label)", "TextField", "Text"], "Toolbar("),
    ("Format toggles (Bold, Italic, Align…)", "mojoui/sheetchrome.mojo", ["Icon toggle shown pressed", "Lucide icon set", "Tooltips", "Divider"], "toggles="),
    ("Bottom tabs, renamed in place", "mojoui/sheetchrome.mojo", ["Button", "In-place editor", "Quiet buttons"], "BottomTabs("),
    ("Cell styles (bold, italic, underline, strikethrough, colours, alignment)", "mojoui/cellstyle.mojo", ["Canvas"], "restyle("),
    ("Island (the window's living status: work, results, undo, errors)", "mojoui/island.mojo", ["Canvas", "Canvas: pan, zoom, tap", "Canvas frames (animation)"], "IslandView("),
    ("Swatch picker", "mojoui/swatches.mojo", ["Canvas", "Canvas: pan, zoom, tap", "Popover"], "SwatchPicker("),
    ("Column number formats", "mojoui/numformat.mojo", ["Canvas", "Text"], "set_format("),
    ("Sheet objects (charts, pivots)", "mojoui/sheetpage.mojo", ["Board: drag, resize, snap", "Canvas", "Card", "Grid"], "object_card("),
    ("Report page (KPI and chart tiles, filters)", "mojoui/reportpage.mojo", ["Grid", "Card", "Dropdown", "Canvas"], "ReportPage("),
    # the OMX Console's (goal 33 M4)
    ("CodeBlock", "mojoui/codeblock.mojo", ["Text", "Button with an icon", "Clipboard", "Themes on top (themes/, or yours)"], "CodeBlock("),
    ("LogView", "mojoui/logview.mojo", ["Scroll", "Text", "Scroll pinned to its end"], "LogView("),
    ("Timeline", "mojoui/timeline.mojo", ["Text", "Icon", "ProgressBar", "VStack", "HStack", "Themes on top (themes/, or yours)"], "Timeline("),
    ("Breadcrumbs", "mojoui/breadcrumbs.mojo", ["Button", "Icon", "Text", "Quiet buttons"], "Breadcrumbs("),
    ("Chip · Badge", "mojoui/chip.mojo", ["Text", "HStack", "Themes on top (themes/, or yours)"], "Chip("),
    ("Confirm", "mojoui/confirm.mojo", ["Button", "Timers"], "ConfirmButton("),
    ("Skeleton", "mojoui/skeleton.mojo", ["VStack", "Themes on top (themes/, or yours)"], "Skeleton("),
    ("Markdown", "mojoui/markdown.mojo", ["Paragraph", "Text", "VStack", "HStack", "Card", "Themes on top (themes/, or yours)"], "Markdown("),
    ("Sparkline", "mojoui/sparkline.mojo", ["Canvas"], "SparklineView("),
    # goal 39: media (a file component: no view of its own; Player, GPU image ops and the frame table build on it)
    ("VideoSource (a video file as RGBA frames: open, next, seek, read)", "mojoui/video.mojo", [], "VideoSource("),
    ("Player (a video with play/pause, a frame-accurate scrubber, the time; Space and arrows)", "mojoui/player.mojo", ["Canvas", "Canvas frames (animation)", "Canvas: pan, zoom, tap", "Canvas: keys (focus on press)", "Quiet buttons", "Card"], "Player("),
    ("TimeSeries (numbers over time, the row nearest a time) and the line chart's time cursor", "mojoui/timeseries.mojo", ["Canvas"], "TimeSeries("),
    ("Picture (a still from a file: PNG, JPEG, WebP…, aspect-fit and rounded)", "mojoui/picture.mojo", ["Canvas"], "Picture("),
    ("Media cards (videos and pictures on a page, each with its own messages; Board chrome; quiet actions and a work-in-progress line in the title bar)", "mojoui/mediacard.mojo", ["Board: drag, resize, snap", "Canvas", "Card", "Quiet buttons", "ProgressBar"], "MediaCards("),
    ("MediaTimeline (an iMovie-style editor: filmstrip clips, playhead, split/trim/delete/undo, data lanes, cut by a sentence, export)", "mojoui/mediatimeline.mojo", ["Canvas", "Canvas frames (animation)", "Canvas: pan, zoom, tap", "Canvas: keys (focus on press)", "Overlay", "ContextMenu", "Card", "Quiet buttons"], "MediaTimeline("),
    ("Table cards (more tables on a page: a DataGrid each, Export CSV, close; SQL over the page's tables by name)", "mojoui/tablecard.mojo", ["Board: drag, resize, snap", "Canvas", "Card", "Quiet buttons"], "TableCards("),
    # page components (goal 33 M5–M7, made generic in M7: D-414)
    ("App shell (bar, brand, nav links, page card)", "mojoui/shell.mojo", ["Text", "Button", "VStack", "HStack", "Themes on top (themes/, or yours)"], "Shell("),
    ("Page header (icon square, pill tabs, segments, tab header)", "mojoui/header.mojo", ["Text", "Button", "Icon", "VStack", "HStack", "Themes on top (themes/, or yours)"], "PageHeader("),
    ("Sidebar (heads, rows to pick, chips when compact)", "mojoui/sidebar.mojo", ["Text", "Button", "Icon", "VStack", "HStack", "Themes on top (themes/, or yours)"], "Sidebar("),
    ("Cards and panels (head, body, foot, stat tiles, facts)", "mojoui/panel.mojo", ["Text", "Button", "VStack", "HStack", "Themes on top (themes/, or yours)"], "PanelGrid("),
    ("Marks (hue and signal dots, status marks, hued icons)", "mojoui/marks.mojo", ["Text", "Icon", "VStack", "HStack", "Themes on top (themes/, or yours)"], "StatusMark("),
    ("Words (quiet, strong, mono lines, command lines)", "mojoui/words.mojo", ["Text", "HStack", "Themes on top (themes/, or yours)"], "CommandLine("),
    ("Buttons (flat, primary, small looks, text actions, links, Back)", "mojoui/buttons.mojo", ["Button", "Button with an icon", "Themes on top (themes/, or yours)"], "SmallButton("),
    ("Lists (split view, count line, name cells, selection bar)", "mojoui/lists.mojo", ["Text", "Button", "VStack", "HStack", "Divider", "Themes on top (themes/, or yours)"], "SplitView("),
    ("Document (markdown and code cells, outline, three columns)", "mojoui/document.mojo", ["Text", "Button", "Scroll", "Card", "Themes on top (themes/, or yours)"], "DocLayout("),
    ("Beacon (the one thing happening now)", "mojoui/beacon.mojo", ["Canvas", "Text", "HStack", "Themes on top (themes/, or yours)"], "Beacon("),
    ("Copy (copy row, labeled value, code panel, secret)", "mojoui/copy.mojo", ["Text", "Button", "Icon", "VStack", "HStack", "Clipboard", "Themes on top (themes/, or yours)"], "CopyRow("),
    ("Fields (search box, outlined field, filter chips, short field)", "mojoui/fields.mojo", ["TextField", "Button", "Text", "Icon", "VStack", "HStack", "Themes on top (themes/, or yours)"], "OutlinedField("),
    ("Search results (result rows, source badges, suggestions)", "mojoui/results.mojo", ["Text", "Button", "VStack", "HStack", "Themes on top (themes/, or yours)"], "ResultRow("),
    ("Meter (meter, usage bar, chart rows)", "mojoui/meter.mojo", ["Text", "ProgressBar", "Canvas", "HStack", "Themes on top (themes/, or yours)"], "Meter("),
    ("Feedback (note, warning, empty state)", "mojoui/feedback.mojo", ["Text", "Button", "Icon", "VStack", "HStack", "Themes on top (themes/, or yours)"], "EmptyState("),
    # agents (goal 35)
    ("GenUi (UI from an agent's data: catalogued components only, validated, drawn natively)", "mojoui/genui.mojo", ["Card", "Text", "Paragraph", "Table", "Canvas", "Button", "TextField", "Toggle", "Segmented", "ProgressBar", "VStack", "HStack", "Divider"], "GenUi("),
    ("LogPane (a live log with its head, Hide log, coloured lines)", "mojoui/logview.mojo", ["Scroll pinned to its end", "Text", "Button", "Icon", "Themes on top (themes/, or yours)"], "LogPane("),
    # media (goal 39)
    ("ImageOps (blur a rectangle, crop and scale, burn a caption in, fill/outline a rectangle on an RGBA frame, GPU or CPU)", "mojoui/imageops.mojo", ["Canvas"], "ImageOps("),
    ("VideoTable (a video becomes rows: GPU colour cells, regions, motion, brightness; Analyzer slot; tracked, coded objects; faces)", "mojoui/videotable.mojo", [], "scan("),
    ("VideoWriter · cut (an mp4 from RGBA frames: H.264, yuv420p, faststart; segments of a video, each frame edited by a plan: blur, outline, captions)", "mojoui/videoexport.mojo", [], "cut("),
    ("Vision presets (colour ranges, sizes and the stripe-code layout for videotable's analyzers, per kind of footage)", "mojoui/vision_presets.mojo", [], "warehouse_analyzer("),
    ("Geo (a nadir camera's pixels on the map from a pose log, haversine, georeferenced VideoTable rows, places joined across frames, names along the route)", "mojoui/geo.mojo", [], "georeference("),
    ("Inspection (defects on assets with a size-class severity, two inspections compared, worse assets, the next flight's waypoints)", "mojoui/inspection.mojo", [], "compare("),
    ("Video jobs (analyze with a registered analyzer, make a reel from a table's flag, as background jobs with progress; rows as a table, lookups that find their key)", "mojoui/videojobs.mojo", [], "analyze_job("),
]

# Built inside one app, not in mojoui yet: each should become a component before another app needs it.
APP_LOCAL = [
    ("FormulaBar", "examples/workbook", "what's selected, its value, a formula field; migrate to mojoui.sheetchrome.FormulaBar"),
    ("Inspector", "examples/mxstudio", "the side panel: Comes from, Feeds, Your edits, Undo all (lineage and the edit log); migrate to mojoui.inspector"),
    ("Toolbar / StatusBar islands", "examples/workbook", "the island contents (title, Insert buttons, status) are assembled by the app; migrate to mojoui.sheetchrome"),
    ("Selection totals (sum, average of a column on the GPU)", "examples/omxplorer", "the status bar's numbers: a group-by with one group, formatted by the column"),
    ("Import review (columns, types, empties, first rows)", "examples/omxplorer", "the Import step's table; a component once a second app imports files"),
    ("Chart / pivot inspector sections", "examples/omxplorer", "type, value, group by, rows and columns as Inspector sections; belongs beside mojoui.sheetpage"),
    ("Report toolbar controls (tile column, add-tile tools, filter)", "examples/omxplorer", "the column new tiles use, the Sum / Average / Count / Chart tile tools and the filter (column, value), in the Report's toolbar; belongs in mojoui.reportpage"),
]


# A host's other source files: the web host's base style sheet moved out of web.py into the file it serves (goal 34 M3,
# 5b28808), and the features it styles (the toolbar button's button.tool) went ❌ on the web with it (D-765)
HOST_EXTRA = {"mojoui/hosts/web.py": ["mojoui/hosts/static/mojoui.css"]}


def host_text(path):
    return "\n".join((ROOT / p).read_text() for p in [path] + HOST_EXTRA.get(path, []))


def implemented(src, kind):
    """A host implements a kind if the kind's constant appears beyond its import line."""
    lines = [l for l in src.splitlines() if re.search(rf"\b{kind}\b", l)]
    lines = [l for l in lines if not re.match(r"\s*(from |\(TEXT|TEXT, |    [A-Z_, ]+,?$|\s*[A-Z_]+(, [A-Z_]+)+,?\)?( = range.*)?$)", l)]
    return bool(lines)


# Constructors that live in a module of their own: an app uses them only if it imports that module (analytics has a
# Table of its own).
MODULE_OF = {"Table": "mojoui.table", "Route": "mojoui.route", "Paragraph": "mojoui.paragraph"}


def example_text(example):
    """An example's code: app.mojo and the files beside it (the console keeps a file per page)."""
    d = ROOT / "examples" / example
    if not (d / "app.mojo").exists():
        return ""
    return "".join(f.read_text() for f in sorted(d.glob("*.mojo")))


def composes(example, ctor, module):
    """The example builds `ctor`: in its own code, or through a mojoui module it imports (`from mojoui.x import`, one
    level) whose code calls it (not a docstring, comment or definition), other than the composite's own `module`
    (agentchat's GenUi comes from mojoui.agentui's Screens since goal 35's review). Import level, not proof the app
    reaches the call: an app checked to run the composite another way is what turns a cell ✅."""
    text = example_text(example)
    call = re.compile(rf"(?<!def )\b{re.escape(ctor.rstrip('('))}\(")
    if re.search(rf"\b{re.escape(ctor)}", text):  # (a whole name: Timeline( isn't MediaTimeline()
        return True
    for mod in dict.fromkeys(re.findall(r"^from (mojoui(?:\.\w+)+) import", text, re.M)):
        f = ROOT / (mod.replace(".", "/") + ".mojo")
        if not f.exists() or f.relative_to(ROOT).as_posix() == module:
            continue
        code = re.sub(r'"""[\s\S]*?"""', "", f.read_text())  # (docstrings, then comments, then definitions: calls only)
        code = "\n".join(l.split("#", 1)[0] for l in code.splitlines() if not re.match(r"\s*(def|fn|struct|trait|comptime|alias) ", l))
        if call.search(code):
            return True
    return False


# Kinds a host builds whose checks drive them through a stand-in, not real input: 🔨 until one does.
KIND_UNPROVEN = {("Linux (GTK)", "DRAG"): "the dragto: step reads the GtkDragSource's content and calls the GtkDropTarget's drop handler; a pointer drag isn't driven headless",
                 ("Linux (GTK)", "DROP"): "the same"}


def used_by(example, ctor):
    text = example_text(example)
    if not text:
        return False
    return re.search(rf"\b{ctor}\(", text) is not None and MODULE_OF.get(ctor, "") in text


def cell(host, src, ctor, kind):
    web_stacks = host == "Web" and kind in ("HSTACK", "VSTACK")  # (the web renders stacks in its default branch)
    if not (web_stacks or implemented(src, kind)):
        return "❌"
    proof = [e for e in RUN_ON[host] if used_by(e, ctor)]
    if (host, kind) in KIND_UNPROVEN:
        return "🔨"
    return "✅" if proof else "🔨"


# Features a host implements but no check runs there (a stand-in drives it instead): 🔨 until one does.
UNPROVEN = {("Linux (GTK)", "File picker"): "the checks hand the path in with the pick: step; GTK's own dialog isn't driven"}


def feature_cell(host, src, pattern, example, name=""):
    if not re.search(pattern, src):
        return "❌"
    if (host, name) in UNPROVEN:
        return "🔨"
    return "✅" if example in RUN_ON[host] else "🔨"


LIBRARIES = [("@codemirror/", "CodeMirror 6"), ("echarts", "Apache ECharts")]


def shared_users(stem):
    """The apps that pick shared widget `stem` (mojoui/widgets/) in their web/shared.json."""
    import json
    users = []
    for f in sorted(ROOT.glob("examples/*/web/shared.json")):
        if f.parent.parent.name.startswith("zz_"):
            continue
        try:
            if stem in json.loads(f.read_text()).get("widgets", []):
                users.append(f.parent.parent.name)
        except ValueError:
            pass
    return users


def js_widgets():
    """Every JS widget: an app's own (examples/*/web/widgets/*.js|ts) and the shared ones (mojoui/widgets/*.js|ts, used
    by the apps that pick them in web/shared.json): (tag, file, apps, library, what agents and themes get)."""
    found = []
    files = sorted(ROOT.glob("examples/*/web/widgets/*.[jt]s")) + sorted((ROOT / "mojoui" / "widgets").glob("*.[jt]s"))
    for f in files:
        shared = f.parent == ROOT / "mojoui" / "widgets"
        if f.name.endswith(".d.ts") or (not shared and f.parent.parent.parent.name.startswith("zz_")):
            continue
        src = f.read_text()
        m = re.search(r"tag:\s*'([a-z][a-z0-9._-]*-[a-z0-9._-]*)'", src)
        if not m:
            continue
        pkg = (f.parent if shared else f.parent.parent) / "package.json"
        deps = {}
        if pkg.exists():
            import json
            deps = json.loads(pkg.read_text()).get("dependencies", {})
        lib = "plain JS (vendored)"
        for prefix, name in LIBRARIES:
            hit = re.search(r"from '(" + re.escape(prefix) + r"[^']*)'", src)
            if hit:
                pkg_name = next((d for d in deps if hit.group(1) == d or hit.group(1).startswith(d + "/")), "")
                lib = name + (f" ({pkg_name} {deps[pkg_name]})" if pkg_name else "")
        traits = [t for t, pat in (("agent read", r"\bdescribe\("), ("agent set", r"\bfields:"), ("theme", r"\btheme\(el"), ("Tab stop", r"focusable:\s*true|contenteditable|<button|createElement\('button'\)|EditorView"))
                  if re.search(pat, src)]
        apps = shared_users(f.stem) if shared else [f.parent.parent.parent.name]
        found.append((m.group(1), str(f.relative_to(ROOT)), apps, lib, traits))
    return found


def render():
    srcs = {h: host_text(p) for h, p in HOSTS}
    names = [h for h, _ in HOSTS]
    out = ["# Components × platforms",
           "",
           "Generated by `scripts/components.py` from the host code and the checks (don't edit by hand; `scripts/check` fails when it's stale).",
           "",
           "✅ implemented and run by a check on that platform · 🔨 implemented, builds, never run there · ❌ not implemented",
           "",
           "Mac and iPhone builds are signed but haven't run on hardware yet; Android runs on the emulator.",
           "",
           "## Components",
           "",
           "| Component | " + " | ".join(names) + " | Proven by |",
           "|---|" + "---|" * len(names) + "---|"]
    for ctor, kind in COMPONENTS:
        row = [cell(h, srcs[h], ctor, kind) for h in names]
        proof = [e for e in RUN_ON["Linux (GTK)"] if used_by(e, ctor)]
        out.append(f"| `{ctor}` | " + " | ".join(row) + f" | {', '.join(proof) or '—'} |")
    out += ["", "## Variants, gestures, layout, design languages", "",
            "| Feature | API | " + " | ".join(names) + " |",
            "|---|---|" + "---|" * len(names)]
    for name, api, pattern, example in FEATURES:
        row = [feature_cell(h, srcs[h], pattern, example, name) for h in names]
        out.append(f"| {name} | `{api}` | " + " | ".join(row) + " |")
    known = {}
    for h in names:
        for ctor, kind in COMPONENTS:
            known[(h, ctor)] = cell(h, srcs[h], ctor, kind)
        for name, api, pattern, example in FEATURES:
            known[(h, name)] = feature_cell(h, srcs[h], pattern, example, name)
    out += ["", "## Composite components (Mojo, built from the ones above)", "",
            "A composite is only as far along on a platform as the least-proven piece it's made of.", "",
            "| Component | Module | Made of | " + " | ".join(names) + " | Used by |",
            "|---|---|---|" + "---|" * len(names) + "---|"]
    comp_cells = {}
    for name, module, parts, ctor in COMPOSITES:
        users = [e.name for e in sorted((ROOT / "examples").iterdir()) if (e / "app.mojo").exists() and composes(e.name, ctor, module)]
        row = []
        for h in names:
            states = [known[(h, part)] for part in parts]
            state = "❌" if "❌" in states else ("🔨" if "🔨" in states else "✅")
            if state == "✅" and not any(u in RUN_ON[h] for u in users):
                state = "🔨"
            row.append(state)
            comp_cells.setdefault(h, []).append(state)
        out.append(f"| `{name}` | `{module}` | {', '.join(parts)} | " + " | ".join(row) + f" | {', '.join(users) or '—'} |")
    out += ["", "## JavaScript widgets (WebComponent)", "",
            "Each is a `WebComponent` (above) with its own bundle; a cell is the WebComponent's state on that host, ✅ only "
            "where a check runs the app that ships the widget. Agent: ✅ where the widget describes itself and the agent's "
            "checks drive the app attached to a host (goal 34b M0).", "",
            "| Widget | Library | Gets | " + " | ".join(names) + " | Lives in |",
            "|---|---|---|" + "---|" * len(names) + "---|"]
    for tag, path, apps, lib, traits in js_widgets():
        row = []
        for h in names:
            state = known[(h, "WebComponent")]
            if state == "✅" and not any(a in RUN_ON[h] for a in apps):
                state = "🔨"
            if h == "Agent (MCP)" and state == "✅" and "agent read" not in traits:
                state = "🔨"
            row.append(state)
        out.append(f"| `{tag}` | {lib} | {', '.join(traits) or '—'} | " + " | ".join(row) + f" | `{path}` |")
    totals = {h: [cell(h, srcs[h], c, k) for c, k in COMPONENTS] + [feature_cell(h, srcs[h], p, e, n) for n, _, p, e in FEATURES] + comp_cells[h] for h in names}
    out += ["", "## Totals", "", "| Platform | ✅ | 🔨 | ❌ |", "|---|---|---|---|"]
    for h in names:
        t = totals[h]
        out.append(f"| {h} | {t.count('✅')} | {t.count('🔨')} | {t.count('❌')} |")
    out += ["", "## Inside one app, not components yet (the debt)", "",
            "| Should become | Lives in | What it is |", "|---|---|---|"]
    for name, where, what in APP_LOCAL:
        out.append(f"| `{name}` | {where} | {what} |")
    out += ["", "## The rule", "",
            "Before building a feature: list the components it needs, mark each ✅ / 🔨 / ❌ here, build or extend the "
            "component in `mojoui/` first (its own test, every host it can reach), then build the app from it. An app never "
            "draws something another app would need; if it does, it goes in the table above until it's extracted.", ""]
    return "\n".join(out)


def icons_without_symbols():
    """Icon names an app or component uses that the Apple hosts can't show: sf_symbol() has no case for them, so the
    Mac drew a '?' box (omxplorer's inspector chevrons, the GitHub Mac runner, 2026-10-23)."""
    used = set()
    for folder in ("examples", "mojoui", "themes"):
        for f in (ROOT / folder).rglob("*.mojo"):
            used |= set(re.findall(r'icon="([a-z0-9-]+)"', f.read_text()))
    mapped = set(re.findall(r'if name == "([a-z0-9-]+)"', (ROOT / "mojoui/hosts/objc.mojo").read_text()))
    return sorted(used - mapped)


def main():
    doc = render()
    path = ROOT / "docs" / "components.md"
    if "--check" in sys.argv:
        missing = icons_without_symbols()
        if missing:
            print("icons with no SF Symbol in mojoui/hosts/objc.mojo sf_symbol(): " + ", ".join(missing))
            return 1
        if not path.exists() or path.read_text() != doc:
            print("docs/components.md is stale: run pixi run python scripts/components.py")
            return 1
        print("docs/components.md is current")
        return 0
    path.write_text(doc)
    print(f"wrote {path}")
    # docs/llms-full.txt embeds this matrix: rewrite it too, or a regenerated matrix leaves it stale (twice in goal 33, D-580)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import llms
    llms.OUT.write_text(llms.build())
    print(f"wrote {llms.OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
