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
    "Linux (GTK)": ["hello", "gallery", "todo", "gpu", "kitchen", "expenses", "layout", "lens", "analytics", "workbook", "mxstudio", "omxplorer", "themes", "kit", "httpcheck", "consolekit", "console", "widgets", "agentchat", "media", "sketch", "jot", "dictate", "keeper", "traycheck", "clips", "ribbon", "stage"],  # (stage: goal 77 M7a, docs/goals/77-stage-check.py; ribbon: goal 76 M1; clips: goal 71 M2; keeper, traycheck: goal 45; dictate: goal 43; jot: goal 42; sketch: goal 40; media: goal 39 M2/M11 run it headless; widgets: goal 34 M3, WebKitGTK views; agentchat: goal 35)
    "Web": ["hello", "gallery", "todo", "gpu", "kitchen", "expenses", "layout", "lens", "analytics", "workbook", "mxstudio", "omxplorer", "themes", "kit", "httpcheck", "consolekit", "console", "widgets", "agentchat", "jot", "clips", "ribbon", "stage"],  # (stage: goal 77 M7a, headless Chromium; ribbon: goal 76 M1; clips: goal 71 M2, docs/goals/71/clipgrid_web.py; kit: goal 18 runs it on GTK and the web; jot: goal 42 M3's web proof)
    "Android": ["hello", "gallery", "layout", "lens", "todo"],
    "Mac (AppKit)": [],
    "iPhone (UIKit)": [],
    "Agent (MCP)": ["kit", "omxplorer", "widgets", "ribbon"],  # (ribbon: goal 76 M1, its hidden tabs' tools; widgets: goal 34b M0, the agent attached to the web and GTK hosts)
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
    ("Secret field", "TextField(…).secret(), OutlinedField(secret=True): masked as typed, only its length in dumps and to agents", r"FIELD_SECRET|\"password\"|Secret field", "console"),
    ("Layout modifiers", ".padding .width .grow .fill .align .justify", r"pad_v", "layout"),
    ("Canvas: pan, zoom, tap", "on_gesture: PAN, ZOOM, TAP", r"\bPAN\b|PAN =", "lens"),
    ("Canvas: press, release, double", "PRESS, RELEASE, DOUBLE", r"\bDOUBLE\b|DOUBLE =", "workbook"),
    ("Canvas frames (animation)", "on_frame", r"tick|SET_FRAMES|on_frame", "lens"),
    ("Hidden (in the tree, not drawn; agents and test steps still reach it)", "View.hidden()", r"node\.hidden|n\.get\(\"hidden\"\)", "ribbon"),
    ("Arrive on a spring", "View.arrive(): fades and rises in once (AdwSpringAnimation; a CSS spring)", r"\.arrives\b|mojoui-arrive", "agentchat"),
    ("Canvas: pen pressure", "event.pressure on PRESS, PAN, RELEASE (0: none)", r"pressure", "sketch"),
    ("Canvas: scroll pans", "Canvas(scroll_pans=True): WHEEL; ctrl+scroll, pinch: ZOOM", r"\bWHEEL\b", "sketch"),
    ("Scene: polygon fill", "Painter.polygon (non-zero, antialiased)", r"OP_POLY|rt\.draw\(|web_draw|mod\.draw\(", "sketch"),
    ("Scene: layer transform", "Painter.layer_transform (pan/zoom moves a kept layer)", r"layer_tx|rt\.draw\(|web_draw|mod\.draw\(", "sketch"),
    ("Canvas: keys (focus on press)", "on_gesture: KEY (event.text, modifiers)", r"\"key-pressed\"|addEventListener\('keydown'", "mxstudio"),
    ("TextField: Escape cancels", "TextField(on_cancel=)", r"on_field_key|second: 2", "mxstudio"),
    ("Editor that echoes the grid's typing", "TextField(…).echo()", r"\.echo\(\): the canvas typing|value\"\] == 3", "mxstudio"),
    ("Board: drag, resize, snap", "Board(on_move, on_resize)", r"\bBOARD\b", "workbook"),
    ("Board: scrolls, reveals a child", "Board(reveal=, reveal_count=)", r"reveal", "workbook"),
    ("Board: phone-width list", "(automatic under 720 pt)", r"board_list|max-width: 719px", "workbook"),
    ("Board: tones (dimmed, lifted, held, a drop target)", "Board(tones=[BOARD_DIM, BOARD_LIFT, …])", r"SET_TONES", "omxplorer"),
    ("Board: hold a child (350 ms, still)", "Board(on_hold=…)", r"on_hold_timer|data-hold", "omxplorer"),
    ("Board: free canvas (live resize from 8 handles, snap guides, zoom, click to focus)", "mojoui.freeboard.FreeCanvas", r"is_free\(|free_board\(|board\.free", "omxplorer"),
    ("Canvas: hover and cursor", "Canvas(hover=True): HOVER; .cursor(name)", r"\bHOVER\b|data-hover|dataset\.hover", "omxplorer"),
    ("Canvas: click-through (shows only)", "Canvas(…).passthrough()", r"node\.size == 2|data-passthrough", "omxplorer"),
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
    ("SQLite database (mojoui.sqlite: prepared statements, transactions, FTS5)", "Database(path) · prepare(sql).bind/step · begin/commit", r"(?!)", "jot"),
    ("Save dialog", "FileSaver(title, on_save, suggested=)", r"gtk_file_dialog_save|/save/\{sid\}", "jot"),
    ("File drop from outside the app", "DropTarget(view, on_drop, on_file=)", r"gdk_file_list_get_type|/dropfile/", "jot"),
    ("Quit hook", "def closing(mut self)", r"rt\[?\]?\.closing\(|close_all|on_will_terminate", "jot"),
    ("Folder watcher (mojoui.watch: inotify / FSEvents on its own thread)", "FolderWatcher(path, wake=True) · start() · take()", r"(?!)", "keeper"),
    ("Background mode (keeps running with the window closed)", "def background(self) -> Bool · window_shown(shown)", r"app\.background\(\)", "keeper"),
    ("One instance (a second launch opens the running app)", "@staticmethod def one_instance() -> String", r"A\.one_instance\(\)", "keeper"),
    ("Tray item (StatusNotifierItem; NSStatusItem)", "published by the host for a background() app; Activate opens the window", r"TrayItem\(", "keeper"),
    ("Notifications (mojoui.notify)", "notify(app, title, body)", r"(?!)", "keeper"),
    ("HTTPS requests (FlareTransport behind mojoui.http; https:// through Flare, -D MOJOUI_FLARE)", "the same Request; AutoTransport picks FlareTransport", r"(?!)", "consoled"),
    ("HTTP server (mojoui.serve on Flare: routes, JSON, SSE Pipes, proxy)", "Service.answer(req) -> Reply · Server.run(service, port) · Pipe · proxy(request, pipe)", r"(?!)", "consoled"),
    ("Child processes (mojoui.process: spawn, log, health, stop the group, idle)", "Process.start(argv, log) · wait_healthy(url) · stop() · idle_ms()", r"(?!)", "consoled"),
    ("SHA-256 (mojoui.hash, plain Mojo)", "sha256_hex(text)", r"(?!)", "consoled"),
    ("Crypto (mojoui.crypto: HMAC-SHA256, OS random, base64url, constant-time compare, seals, PKCE)", "hmac_sha256 · random_token · b64url · same · seal/unseal · pkce_challenge", r"(?!)", "saas"),
    ("Accounts (mojoui.accounts: Google sign-in with PKCE, server-side sessions, tenants, roles, invites, one SQLite per tenant)", "Accounts(dir, AuthConfig.from_env()) · handle(req) · member(req) · tenant_db(member)", r"(?!)", "saas"),
    ("Billing (mojoui.billing: Stripe Checkout, signed webhooks applied once, return read-back, paywall)", "Billing(dir, BillingConfig.from_env()) · handle(req, accounts) · paywall(member)", r"(?!)", "saas"),
    ("Desktop sign-in (mojoui.signin: system browser + loopback redirect, PKCE; RFC 8252)", "DesktopSignIn(server) · .url · code() · token_request(msg, code)", r"(?!)", "saas"),
    ("Open in the system browser (an effect: App.opens, mojoui.browser)", "Browser.open(url) · def opens(mut self) -> List[String]", r"(?!)", "saas"),
]

# Library features no host draws (pure Mojo over a C library): their state per host, set by hand from what ran
# (reasons in NOTES). Hosts not listed: ❌.
BY_HAND = {"SQLite database (mojoui.sqlite: prepared statements, transactions, FTS5)":
           {"Linux (GTK)": "✅", "Web": "✅", "Mac (AppKit)": "🔨"},
           "Folder watcher (mojoui.watch: inotify / FSEvents on its own thread)": {"Linux (GTK)": "✅", "Mac (AppKit)": "🔨"},
           "Notifications (mojoui.notify)": {"Linux (GTK)": "✅", "Mac (AppKit)": "🔨"},
           # goal 50: run by tests/test_https, test_serve, test_process and consoled on Linux; Flare targets macOS too (not built here yet)
           "HTTPS requests (FlareTransport behind mojoui.http; https:// through Flare, -D MOJOUI_FLARE)": {"Linux (GTK)": "✅"},
           "HTTP server (mojoui.serve on Flare: routes, JSON, SSE Pipes, proxy)": {"Linux (GTK)": "✅"},
           "Child processes (mojoui.process: spawn, log, health, stop the group, idle)": {"Linux (GTK)": "✅"},
           "SHA-256 (mojoui.hash, plain Mojo)": {"Linux (GTK)": "✅"},
           # goal 57: run by tests/test_crypto, test_accounts, test_billing, test_open_url and docs/goals/57-check.py M2–M4 on Linux;
           # M8 on the owner's Mac (macOS 27, arm64): the server passes M2/M3 there, the AppKit app signs in and pays
           "Crypto (mojoui.crypto: HMAC-SHA256, OS random, base64url, constant-time compare, seals, PKCE)": {"Linux (GTK)": "✅", "Mac (AppKit)": "✅"},
           "Accounts (mojoui.accounts: Google sign-in with PKCE, server-side sessions, tenants, roles, invites, one SQLite per tenant)": {"Linux (GTK)": "✅", "Mac (AppKit)": "✅"},
           "Billing (mojoui.billing: Stripe Checkout, signed webhooks applied once, return read-back, paywall)": {"Linux (GTK)": "✅", "Mac (AppKit)": "✅"},
           "Desktop sign-in (mojoui.signin: system browser + loopback redirect, PKCE; RFC 8252)": {"Linux (GTK)": "✅", "Mac (AppKit)": "✅"},
           "Open in the system browser (an effect: App.opens, mojoui.browser)": {"Linux (GTK)": "✅", "Mac (AppKit)": "✅"}}

# Components built in Mojo from the ones above (drawn on a Canvas or assembled from native controls):
# (name, module, what it's made of: component or feature names above, the constructor apps call)
COMPOSITES = [
    ("Ink stroke (pressure ink, round ends, the eraser's hit test)", "mojoui/ink.mojo", ["Canvas", "Canvas: pen pressure", "Scene: polygon fill"], "Stroke("),
    ("DataGrid", "mojoui/datagrid.mojo", ["Canvas", "Canvas: press, release, double", "Canvas: keys (focus on press)", "In-place editor", "TextField: Escape cancels", "Editor that echoes the grid's typing", "Board: drag, resize, snap"], "DataGrid("),
    ("Free canvas (mojoui.freeboard: cards anywhere at any size, live 8-handle resize, snap guides, zoom, Tidy, Super/Alt keys)", "mojoui/freeboard.mojo", ["Board: free canvas (live resize from 8 handles, snap guides, zoom, click to focus)", "Board: drag, resize, snap", "Board: scrolls, reveals a child", "MenuBar"], "FreeCanvas("),
    ("PivotTable", "mojoui/pivot.mojo", ["Grid", "Scroll", "Text tones"], "PivotTable("),
    ("ChartView", "mojoui/chartview.mojo", ["Canvas", "Canvas: pan, zoom, tap"], "ChartView"),
    ("KpiView", "mojoui/kpi.mojo", ["Card tones", "Text tones", "Canvas"], "KpiView("),
    ("FindingCard", "mojoui/finding.mojo", ["Card tones", "Text tones", "Quiet buttons"], "FindingCard("),
    ("Inspector", "mojoui/inspector.mojo", ["Segmented", "Dropdown", "Toggle", "Card", "Quiet buttons"], "Inspector("),
    ("Toolbar · FormulaBar · StatusBar", "mojoui/sheetchrome.mojo", ["Toolbar button (icon over label)", "TextField", "Text"], "Toolbar("),
    ("Format toggles (Bold, Italic, Align…)", "mojoui/sheetchrome.mojo", ["Icon toggle shown pressed", "Lucide icon set", "Tooltips", "Divider"], "toggles="),
    ("Bottom tabs, renamed in place", "mojoui/sheetchrome.mojo", ["Button", "In-place editor", "Quiet buttons"], "BottomTabs("),
    ("Rail (a slim column of icon tools beside the sheet: role sidebar)", "mojoui/sheetchrome.mojo", ["Button with an icon", "Tooltips", "VStack"], "Rail("),
    ("Ribbon (tabs of captioned tool groups; the other tabs' tools hidden, still reachable)", "mojoui/ribbon.mojo", ["Toolbar button (icon over label)", "Icon toggle shown pressed", "File picker", "Hidden (in the tree, not drawn; agents and test steps still reach it)", "Divider", "Tooltips"], "Ribbon("),
    ("Regions (the window's sidebar, toolbar, sheet, inspector, status bar and cards, named from the shells' roles: GTK's and the web driver's regions: step)", "mojoui/regions.mojo", [], "regions("),
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
    ("ClipGrid (clips to tap, compare and pick: a poster, a title, a badge, a pick toggle; goal 71)", "mojoui/clipgrid.mojo", ["Image", "Text", "Button with an icon", "Grid", "Card"], "ClipGrid("),
    ("Confirm", "mojoui/confirm.mojo", ["Button", "Timers"], "ConfirmButton("),
    ("Skeleton", "mojoui/skeleton.mojo", ["VStack", "Themes on top (themes/, or yours)"], "Skeleton("),
    ("Markdown", "mojoui/markdown.mojo", ["Paragraph", "Text", "VStack", "HStack", "Card", "Themes on top (themes/, or yours)"], "Markdown("),
    ("Sparkline", "mojoui/sparkline.mojo", ["Canvas"], "SparklineView("),
    ("Disclosure (a section that folds: a quiet header with a chevron, its body while open)", "mojoui/disclosure.mojo", ["Button with an icon", "Quiet buttons", "VStack"], "Disclosure("),
    # goal 39: media (a file component: no view of its own; Player, GPU image ops and the frame table build on it)
    ("VideoSource (a video file as RGBA frames: open, next, seek, read)", "mojoui/video.mojo", [], "VideoSource("),
    ("Player (a video with play/pause, a frame-accurate scrubber, the time; Space and arrows)", "mojoui/player.mojo", ["Canvas", "Canvas frames (animation)", "Canvas: pan, zoom, tap", "Canvas: keys (focus on press)", "Quiet buttons", "Card"], "Player("),
    ("TimeSeries (numbers over time, the row nearest a time) and the line chart's time cursor", "mojoui/timeseries.mojo", ["Canvas"], "TimeSeries("),
    ("Picture (a still from a file: PNG, JPEG, WebP…, aspect-fit and rounded)", "mojoui/picture.mojo", ["Canvas"], "Picture.opening("),
    ("Album (pictures an app holds for its agent's UI, by name: the agent names one, never sends pixels)", "mojoui/album.mojo", ["Canvas"], "Album("),
    ("Media cards (videos and pictures on a page, each with its own messages; Board chrome; quiet actions and a work-in-progress line in the title bar)", "mojoui/mediacard.mojo", ["Board: drag, resize, snap", "Canvas", "Card", "Quiet buttons", "ProgressBar"], "MediaCards("),
    ("MediaTimeline (an iMovie-style editor: filmstrip clips, playhead, split/trim/delete/undo, data lanes, cut by a sentence, export)", "mojoui/mediatimeline.mojo", ["Canvas", "Canvas frames (animation)", "Canvas: pan, zoom, tap", "Canvas: keys (focus on press)", "Overlay", "ContextMenu", "Card", "Quiet buttons"], "MediaTimeline.open_with("),
    ("Table cards (more tables on a page: a DataGrid each, Export CSV, close; SQL over the page's tables by name)", "mojoui/tablecard.mojo", ["Board: drag, resize, snap", "Canvas", "Card", "Quiet buttons"], "TableCards("),
    # page components (goal 33 M5–M7, made generic in M7: D-414)
    ("App shell (bar, brand, nav links, page card)", "mojoui/shell.mojo", ["Text", "Button", "VStack", "HStack", "Themes on top (themes/, or yours)"], "Shell("),
    ("Page header (icon square, pill tabs, segments, tab header)", "mojoui/header.mojo", ["Text", "Button", "Icon", "VStack", "HStack", "Themes on top (themes/, or yours)"], "PageHeader("),
    ("Sidebar (heads, rows to pick, chips when compact)", "mojoui/sidebar.mojo", ["Text", "Button", "Icon", "VStack", "HStack", "Themes on top (themes/, or yours)"], "Sidebar("),
    ("Cards and panels (head, body, foot, stat tiles, facts)", "mojoui/panel.mojo", ["Text", "Button", "VStack", "HStack", "Themes on top (themes/, or yours)"], "PanelGrid("),
    ("Marks (hue and signal dots, status marks, hued icons)", "mojoui/marks.mojo", ["Text", "Icon", "VStack", "HStack", "Themes on top (themes/, or yours)"], "StatusMark("),
    ("Words (quiet, strong, mono lines, hints)", "mojoui/words.mojo", ["Text", "HStack", "Themes on top (themes/, or yours)"], "QuietText("),
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
    ("GenUi (UI from an agent's data: 38 catalogued components, validated, drawn natively, previewed while it streams)", "mojoui/genui.mojo", ["Card", "Text", "Paragraph", "Table", "Canvas", "Button", "TextField", "TextArea", "Toggle", "Checkbox", "Segmented", "Dropdown", "Slider", "Radio", "DatePicker", "Tabs", "Grid", "ProgressBar", "Icon", "VStack", "HStack", "Divider", "Spacer"], "GenUi("),
    ("AgentChat (a chat on an AG-UI agent: streaming Markdown, tool stages, approvals, interrupts, suggestions, Stop, Retry, Regenerate; panel, sidebar or popup)", "mojoui/agentchat.mojo", ["Scroll pinned to its end", "Card", "Text", "Button", "TextField", "Icon", "Overlay", "Clipboard", "Arrive on a spring"], "AgentChat"),
    ("Rows (a DataGrid's source over plain rows of text)", "mojoui/rowsource.mojo", ["Canvas"], "Rows("),
    ("SheetHub (datasets an agent's UI names instead of sending rows: MX frame sheets, the GPU)", "mojoui/sheethub.mojo", ["Canvas"], "SheetHub("),
    ("LogPane (a live log with its head, Hide log, coloured lines)", "mojoui/logview.mojo", ["Scroll pinned to its end", "Text", "Button", "Icon", "Themes on top (themes/, or yours)"], "LogPane("),
    # media (goal 39)
    ("ImageOps (blur a rectangle, crop and scale, burn a caption in, fill/outline a rectangle on an RGBA frame, GPU or CPU)", "mojoui/imageops.mojo", ["Canvas"], "ImageOps("),
    ("VideoTable (a video becomes rows: GPU colour cells, regions, motion, brightness; Analyzer slot; tracked, coded objects; faces)", "mojoui/videotable.mojo", [], "scan_with("),
    ("VideoWriter · cut (an mp4 from RGBA frames: H.264, yuv420p, faststart; segments of a video, each frame edited by a plan: blur, outline, captions)", "mojoui/videoexport.mojo", [], "cut("),
    ("Vision presets (colour ranges, sizes and the stripe-code layout for videotable's analyzers, per kind of footage)", "mojoui/vision_presets.mojo", [], "warehouse_analyzer("),
    ("Geo (a nadir camera's pixels on the map from a pose log, haversine, georeferenced VideoTable rows, places joined across frames, names along the route)", "mojoui/geo.mojo", [], "georeference("),
    ("Inspection (defects on assets with a size-class severity, two inspections compared, worse assets, the next flight's waypoints)", "mojoui/inspection.mojo", [], "compare("),
    ("Video jobs (analyze with a registered analyzer, make a reel from a table's flag, as background jobs with progress; rows as a table, lookups that find their key)", "mojoui/videojobs.mojo", [], "analyze_job("),
    ("MapView (a route, places and findings on a small offline map, north up, metres to scale, the playhead as a dot)", "mojoui/mapview.mojo", ["Canvas"], "MapView("),
    ("Track cards (a recording's log beside its video: a line chart whose cursor follows the playhead, tap to seek; the route's map)", "mojoui/trackcard.mojo", ["Board: drag, resize, snap", "Canvas", "Card", "Segmented", "Quiet buttons"], "TrackCards("),
    ("Inspection tables (places as a table, two inspections compared from their tables, the next flight plan, map marks)", "mojoui/inspection_tables.mojo", [], "compare_tables("),
    # documents (goal 41 M7)
    ("PdfSource (a PDF's pages as RGBA pictures at any dpi, page sizes in points, points ↔ pixels; its text layer for checks)", "mojoui/pdfsource.mojo", [], "PdfSource("),
    ("Document card (a PDF page on a card: page through, zoom, pan, highlight a box in page points; Board chrome, quiet actions)", "mojoui/documentcard.mojo", ["Canvas", "Canvas: pan, zoom, tap", "Canvas: press, release, double", "Canvas: keys (focus on press)", "Card", "Quiet buttons", "ProgressBar"], "DocumentCard("),
    ("OcrModel (the reader slot: docTR in process, words with boxes and confidence; a page's picture read into rows)", "mojoui/ocrmodel.mojo", [], "OcrModel("),
    ("TextTable (words as rows: page, text, box, confidence; CSV in and out)", "mojoui/texttable.mojo", [], "TextTable("),
    ("Form fields (a label's value by geometry: right on its line or under it; the labels are data)", "mojoui/formfields.mojo", [], "find_fields("),
    ("Document jobs (a page drawn and a document read off the UI thread; Python on a job's thread)", "mojoui/documentjobs.mojo", [], "DocumentFeed("),
    # models and robot bags (goal 68)
    ("Model plugins (a folder with plugin.json: kind, runner tree/max/torch/onnx/skops, inputs, outputs; found at run time; pickles, ../ paths and links out refused)", "mojoui/plugins.mojo", [], "find_plugins("),
    ("Decision model files in Mojo (XGBoost JSON, LightGBM text, Learn's own tree: the libraries' predictions to 4e-7)", "mojoui/treefile.mojo", [], "Forest.load("),
    ("Plugin runs (a tabular model's columns matched by name and type, never guessed; torch, ONNX and skops in the app's process)", "mojoui/pluginrun.mojo", [], "match_columns("),
    ("Add a model (paste a Hugging Face name, drop a file or folder, or the agent: one line before any download, consent for a model's own code, progress, an answer where you're looking, run on all)", "mojoui/addmodel.mojo", ["TextField", "File picker", "ProgressBar", "Image", "Button", "Text"], "AddModel("),
    ("Decision tree that says its rule (CART in Mojo, depth-limited, round thresholds, held-out accuracy)", "mojoui/tree.mojo", [], "learn_tree("),
    ("Learn from my labels (a label column, picks, label-rows, Learn: learned and sure columns, the rule in words, relearn on edit)", "mojoui/learn.mojo", ["TextField", "Button", "Text", "VStack"], "LearnPanel("),
    ("ROS 2 bags (MCAP with zstd/lz4 chunks, rosbag2 sqlite3, CDR from the file's own schemas, JSON channels; topics as tables; cameras as videos)", "mojoui/bag.mojo", [], "Bag.open("),
    ("Motion JPEG AVI writer (JPEGs into a video, not re-encoded)", "mojoui/avi.mojo", [], "MjpegAvi("),
    ("A fleet of bags (runs, every topic joined on time at 10 Hz, stops, story.json; read off the UI thread)", "mojoui/fleet.mojo", [], "read_fleet("),
    # links (goal 41)
    ("Links (explicit key, time and place links between cards; match counts; the JOIN a key link implies; a selection followed to each linked card's react hook; the link, unlink and links agent tools; the inspector's Links panel: Unlink, time offsets)", "mojoui/links.mojo", ["Button", "TextField", "Dropdown", "Text", "VStack"], "Links("),
    ("Inspection tables (places as a table, two inspections compared from their tables, the next flight plan, map marks)", "mojoui/inspection_tables.mojo", [], "compare_job("),
    ("FrameFeed (a video or still decoded on a thread of its own: opens without waiting, the newest seek wins, frames swapped in, the UI woken)", "mojoui/framefeed.mojo", [], "FrameFeed("),
    ("Table jobs (Insert > Table, a SQL query, Export CSV as jobs that wake the UI; the answer placed as a card)", "mojoui/tablejobs.mojo", [], "TableWork("),
    ("Link drag (a column's header dragged onto another card: the card lights up with its matching columns and counts, a panel confirms; a time column onto a video: a time link with its offset)", "mojoui/linkdrag.mojo", ["Board: tones (dimmed, lifted, held, a drop target)", "Button", "TextField", "ProgressBar", "Text"], "LinkDrag("),
    ("Peek (hold a card: unlinked cards dim, linked ones lift on a spring, labelled ghost lines; let go and it settles)", "mojoui/peek.mojo", ["Board: hold a child (350 ms, still)", "Board: tones (dimmed, lifted, held, a drop target)", "Canvas: click-through (shows only)", "Canvas frames (animation)", "Text"], "Peek("),
    ("Time lane (a log linked by time drawn under its video on the video's clock; the playhead its cursor; tap to seek)", "mojoui/timelane.mojo", ["Canvas", "Canvas: pan, zoom, tap"], "TimeLane."),
    ("Spring (a value that settles like a spring, stepped by display frames)", "mojoui/spring.mojo", ["Canvas frames (animation)"], "Spring("),
    ("Video card work (Analyze / Make a reel / Edit for media cards: one analysis path, progress on the card, the editor given its rows)", "mojoui/videocard.mojo", [], "VideoWork("),
    # the claim, end to end (goal 41 M10)
    ("Document set (a folder of PDFs as one card: page through files, the fields to read as labels (data), Read → a table of fields per file; a linked row shows its file with the chosen field marked)", "mojoui/documentset.mojo", ["Canvas", "Canvas: pan, zoom, tap", "Card", "TextField", "Dropdown", "Quiet buttons", "ProgressBar"], "DocumentSet("),
    ("Folder jobs (a folder opened and read off the UI thread: OCR every page, fields by geometry, the fields' table card)", "mojoui/documentjobs.mojo", [], "FolderFeed("),
    ("Ask → SQL (JOIN LINKED: the joins the sheet's key links imply; an answer's lineage, so its rows follow like its source's; questions taught with their SQL)", "mojoui/asksql.mojo", [], "implied_sql("),
    ("Pack PDF (a title and pages of blocks: facts, words, a table, a PDF page or a video frame with boxes marked; HTML printed to PDF by Chromium)", "mojoui/packpdf.mojo", [], "Pack("),
    # the robot fleet (goal 47)
    ("Telemetry lanes (many channels of a recording as stacked lanes on one clock: families from column names, one cursor with a dot and value per channel, event marks, spec lines; Raw/Smoothed on a track card)", "mojoui/telemetrychart.mojo", ["Canvas", "Canvas: pan, zoom, tap"], "TelemetryChart("),
    ("Signal steps (unwrap angles, centred smoothing, on/off steps with hysteresis, peaks, a chart's span)", "mojoui/signal.mojo", [], "smooth("),
    ("Export pack (per item a PDF and a video clip, faces blurred, a caption burned in: one job)", "mojoui/pack.mojo", [], "PackJob("),
    # the Stage (goal 77 M7)
    ("Stage (one screen for a counter or a tablet: a top bar, the passive left, the raised stage and its chat bar in the centre, the live right; the sides shaded; a phone stacks it; clock, labels, cards, Live rows, avatars, pills)", "mojoui/stage.mojo", ["Text", "Button", "Icon", "TextField", "VStack", "HStack", "Scroll", "Canvas", "Themes on top (themes/, or yours)"], "StageChat("),  # (StageChat: mojoui.timeline has a Stage( of its own)
]

# Built inside one app, not in mojoui yet: each should become a component before another app needs it.
APP_LOCAL = [
    ("Stage tiles from a tiles card (a Screens LiveTiles card read into stagefeed's ranking and placement, drawn by an app-owned LiveTiles, pins)", "examples/omx",
     "Main.place_stage (goal 77 M7f): reads the stage card's tiles (tile_of, kind_of), ranks them with stage_feed and the pins, sets the app's LiveTiles and places the sides; belongs in mojoui.stagefeed beside stage_tiles once a second app shows a Screens card on a Stage (examples/stage builds its feed from its own days)"),
    ("Starter story (the Start screen's starter card, the inspector's Story panel with each question's SQL and Run, the one-click set-up chain: sheet → table cards → typed links → the hero's row → documents)", "examples/omxplorer",
     "start_story, story_sheet_read, story_tables_read, story_hero, story_ready, run_question, story_panel (goal 62): mojoui.starter reads story.json and shares its tables; the card, the panel and the chain belong in a mojoui.starterpanel component any app with a Board can offer"),
    ("Row follow reactions (a key link onto a video card's file plays the row's file; onto a time-linked log, its slice in lanes; a log's key index job; a spec table's limits)", "examples/omxplorer",
     "follow_file, follow_log, near_file, time_linked_video, take_index and the spec-table read in follow_log (goal 47, review round 1): the pieces they call are components (MediaCards.named, series_where_indexed, KeyIndexJob, TrackCard.limits); the glue that picks which card reacts belongs in mojoui.links' react hooks with tests"),
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
    level or two) whose code calls it (not a docstring, comment or definition), other than the composite's own `module`
    (agentchat's GenUi comes from mojoui.agentui's Screens since goal 35's review). Import level, not proof the app
    reaches the call: an app checked to run the composite another way is what turns a cell ✅."""
    text = example_text(example)
    call = re.compile(rf"(?<!def )\b{re.escape(ctor.rstrip('('))}(?:\[[^\]\n]*\])?\(")  # (a generic one too: GenUi[Self.H](…))
    if re.search(rf"\b{re.escape(ctor)}", text):  # (a whole name: Timeline( isn't MediaTimeline()
        return True
    # two levels: agentchat's chat (mojoui.agentchat) shows the agent's screens through mojoui.agentui, which builds
    # GenUi (goal 48); one level read GenUi as unused by the app whose checks draw it on both hosts
    seen, level = set(), [text]
    for _ in range(2):
        nxt = []
        for t in level:
            for mod in dict.fromkeys(re.findall(r"^from (mojoui(?:\.\w+)+) import", t, re.M)):
                f = ROOT / (mod.replace(".", "/") + ".mojo")
                if mod in seen or not f.exists() or f.relative_to(ROOT).as_posix() == module:
                    continue
                seen.add(mod)
                src = f.read_text()
                code = re.sub(r'"""[\s\S]*?"""', "", src)  # (docstrings, then comments, then definitions: calls only)
                code = "\n".join(l.split("#", 1)[0] for l in code.splitlines() if not re.match(r"\s*(def|fn|struct|trait|comptime|alias) ", l))
                if call.search(code):
                    return True
                nxt.append(src)
        level = nxt
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
UNPROVEN = {("Linux (GTK)", "File picker"): "the checks hand the path in with the pick: step; GTK's own dialog isn't driven",
            ("Linux (GTK)", "Canvas: pen pressure"): "only injected pressure ran (the stroke: test step sets it where GDK's "
                                                     "pressure axis is read); no real pen yet",
            ("Linux (GTK)", "Save dialog"): "the checks hand the path in with the save: step; GTK's own save dialog isn't driven",
            ("Linux (GTK)", "File drop from outside the app"): "the dropfile: step builds a real GdkFileList and emits the GtkDropTarget's "
                                                                "drop signal; a drag from a real file manager isn't driven headless",
            ("Web", "File drop from outside the app"): "drive.py's dropfile: dispatches a drop event carrying a File (no OS drag)",
            ("Web", "Quit hook"): "the session's App.closing runs when it's evicted or the server stops (tried by hand: a SIGINT); "
                                  "no check runs it, and closing a tab doesn't end its session"}


# What a reader should know about a feature row beyond its cells (limits, not states).
NOTES = {"Accounts (mojoui.accounts: Google sign-in with PKCE, server-side sessions, tenants, roles, invites, one SQLite per tenant)":
         "a server piece (mojoui.serve, Flare: Linux and macOS); proved against the checker's OAuth stand-in (goal 57 M2) and, with "
         "the owner's keys, Google itself (M5); one tenant per user, invites join new people only (D-5712); docs/saas.md maps fh-saas",
         "Billing (mojoui.billing: Stripe Checkout, signed webhooks applied once, return read-back, paywall)":
         "subscriptions only (no one-off payments, no customer portal yet); webhooks proved against the checker's signer, the live "
         "run reads the session back on return (D-5706, D-5716)",
         "Open in the system browser (an effect: App.opens, mojoui.browser)":
         "GTK: xdg-open or $MOJOUI_OPENER; AppKit: `open` or $MOJOUI_OPENER through posix_spawnp; the web and the phones don't open "
         "pages yet (D-5718)",
         "SQLite database (mojoui.sqlite: prepared statements, transactions, FTS5)":
         "the system's libsqlite3 loaded at run time (dlopen, D-1304/D-1311); Android and iPhone don't build it yet; the Mac links "
         "against nothing new and loads /usr/lib/libsqlite3.dylib (built, not run)",
         "Folder watcher (mojoui.watch: inotify / FSEvents on its own thread)":
             "Linux: inotify on a pthread, new folders followed, one event per change, p95 lag 0.01 ms for 1,000 changes (goal 45 M0); "
             "a folder renamed inside reports its files under the new name, an overflow re-watches and says rescan, a folder it can't "
             "watch makes it partial() with the reason, names with newlines or non-UTF-8 bytes arrive whole (tests/test_watch_edges.mojo); "
             "Mac: FSEvents (file-level events, a dispatch queue), built, not run, and it doesn't pair a rename's two halves; the web "
             "has FileSystemObserver only on a folder the person picked or dropped, only while the tab is open (docs/goals/45/web.json)",
         "Background mode (keeps running with the window closed)":
             "GTK: the window hides on close only while a panel's StatusNotifierWatcher has the tray item (otherwise closing ends the "
             "app); an app that declares one_instance() runs once (see the row below); the Mac has none yet (the AppKit host still "
             "quits when its last window closes); a web page's code stops when its tab closes (docs/goals/45/web.json)",
         "One instance (a second launch opens the running app)":
             "GTK: registers dev.mojoui.bg.<name> on the session bus before building anything; a second launch sends activate and "
             "exits without building its App (goal 45 M1, D-1706); elsewhere each launch is its own",
         "Tray item (StatusNotifierItem; NSStatusItem)":
             "Linux: a StatusNotifierItem on the session bus (Activate, SecondaryActivate, ContextMenu open the window), a minimal "
             "com.canonical.dbusmenu with Open and Quit, registered again whenever a panel's watcher appears; checked on a private bus "
             "with a pretend watcher, no real panel; "
             "Mac: NSStatusItem not built yet; the web has no tray API",
         "Notifications (mojoui.notify)":
             "Linux: org.freedesktop.Notifications.Notify, asynchronous (goal 45 M1, M2); Mac: UNUserNotificationCenter, built, not "
             "run, and it doesn't ask the person's permission yet (that needs a block)",
         "Save dialog": "the app writes the file at the path it's given; on the web that path is the page's downloads folder and the "
                        "page downloads it; the Mac has no NSSavePanel yet (nor an NSOpenPanel for the file picker)",
         "Scene: layer transform": "GTK shows a moved, kept layer through a texture of at most 4096 px a side (D-1216): on a "
                                   "big page at a big zoom it's softer than the strokes until the zoom comes back within the cap"}


def feature_cell(host, src, pattern, example, name=""):
    if name in BY_HAND:
        return BY_HAND[name].get(host, "❌")
    if not re.search(pattern, src):
        return "❌"
    if (host, name) in UNPROVEN:
        return "🔨"
    return "✅" if example in RUN_ON[host] else "🔨"


# Native services (goal 43): what an app reaches on the machine itself, not a widget. (name, module and API, the
# example whose checks run it, per host: (state, why) for the hosts where it isn't simply "run by that example's check").
SERVICES = [
    ("Microphone", "mojoui.audio: Microphone().start(), read(since), level(); 16 kHz mono on its own thread", "dictate",
     {"Linux (GTK)": None, "Web": ("✅", "tests/test_web_audio.py: the browser's microphone reaches the app (examples/echo): 100 % match with the fake mic's .wav, over https on the tailnet too"),
      "Android": ("❌", "not built"), "Mac (AppKit)": ("🔨", "builds; start() reports \"no microphone on this host yet\" (AVAudioEngine planned)"),
      "iPhone (UIKit)": ("❌", "not built"), "Agent (MCP)": ("—", "")}),
    ("Speech model in process", "mojoui.speech: SpeechModel().transcribe(samples), SpeechStream feed/poll (whisper-large-v3-turbo, GPU)", "dictate",
     {"Linux (GTK)": None, "Web": ("❌", "the model needs CPython + torch in the app's process"),
      "Android": ("❌", "not built"), "Mac (AppKit)": ("🔨", "builds; needs CPython with torch beside the app (MPS), never run"),
      "iPhone (UIKit)": ("❌", "no CPython on the phone"), "Agent (MCP)": ("—", "")}),
    ("Language model in process", "mojoui.llm: Llm(gguf, gpu).chat(messages, tools) -> id, poll(id) -> TEXT / REASONING / TOOL_CALLS / DONE events, cancel(id); two sequences; prompt cache (llama.cpp library through bridge/llm_shim.cpp)", "",
     {"Linux (GTK)": ("✅", "tests/test_llm.mojo: Qwen3.8-27B on a 3090 (goal 72 M1); examples/omx runs it in the app (M4)"), "Web": ("❌", "needs libllama in the app's process"),
      "Android": ("❌", "not built"), "Mac (AppKit)": ("❌", "not built (llama.cpp has Metal; the shim is untried there)"),
      "iPhone (UIKit)": ("❌", "not built"), "Agent (MCP)": ("—", "")}),
    # Goal 72 M2 (the voice components, run by tests/test_voice.mojo in the `voice` pixi environment, GPU 1 + a null sink)
    ("Speaker", "mojoui.speaker: Speaker().play(samples, rate), stop() (barge-in), playing(), first_ns(); 24 kHz mono on its own thread", "",
     {"Linux (GTK)": ("✅", "tests/test_voice: heard on a PulseAudio null sink's monitor, silent 25 ms after stop()"),
      "Web": ("✅", "tests/test_web_audio.py: the browser's AudioContext plays it gap-free (440 Hz at the right level), stop() flushes the page in 16 ms"), "Android": ("❌", "not built"),
      "Mac (AppKit)": ("🔨", "builds; play() reports \"no speaker on this host yet\" (AVAudioEngine planned)"),
      "iPhone (UIKit)": ("❌", "not built"), "Agent (MCP)": ("—", "")}),
    ("Voice (text to speech)", "mojoui.voice: Voice().say(text), poll()/pump(speaker), cancel(); Kokoro-82M in process, clause by clause", "",
     {"Linux (GTK)": ("✅", "tests/test_voice: first audio under 70 ms on a free 3090"),
      "Web": ("❌", "the model needs CPython + torch in the app's process"), "Android": ("❌", "not built"),
      "Mac (AppKit)": ("🔨", "builds; needs CPython with torch beside the app, never run"),
      "iPhone (UIKit)": ("❌", "no CPython on the phone"), "Agent (MCP)": ("—", "")}),
    ("Speech model: Parakeet", "mojoui.speech: SpeechModel(\"parakeet\") (Parakeet TDT 0.6B v3 int8, onnx_asr, GPU), same transcribe()/SpeechStream", "",
     {"Linux (GTK)": ("✅", "tests/test_voice: WER 0.0 on the TTS'd sentence, about 0.14 s an utterance on a free 3090"),
      "Web": ("❌", "the model needs CPython + onnxruntime in the app's process"), "Android": ("❌", "not built"),
      "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("❌", "no CPython on the phone"), "Agent (MCP)": ("—", "")}),
    ("Endpointer (turn-taking)", "mojoui.voice: Endpointer().feed(samples, captured_ns, playing), poll() -> START / BARGE / END (Silero VAD)", "",
     {"Linux (GTK)": ("✅", "tests/test_voice: one START and one END per utterance, BARGE over a playing speaker"),
      "Web": ("❌", "needs CPython + torch in the app's process"), "Android": ("❌", "not built"),
      "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("❌", "no CPython on the phone"), "Agent (MCP)": ("—", "")}),
    ("Voice loop (turn-taking)", "mojoui.voiceloop: VoiceLoop().tick() -> HEARD / STARTED / BARGED events, say(delta) / end_reply(); microphone -> VAD -> Parakeet, the reply's sentences -> Kokoro -> Speaker; barge-in, merge while thinking, first-audio and barge stamps; Microphone also plays a recorded voice (`file:a.wav@2.5`)", "",
     {"Linux (GTK)": ("✅", "docs/goals/72-check.py M4 on examples/omx: first audio 882 ms after the question's last word, an interruption stops the speaker in 212 ms; tests/test_voiceloop_parts, tests/test_audio_file"),
      "Web": ("✅", "scripts/omx_tablet_check.py (M5): over the tailnet name, question to first audio in the page 1.1 s; one tab at a time (each page load loads its own models)"),
      "Android": ("❌", "not built"), "Mac (AppKit)": ("❌", "needs CPython with torch beside the app and a microphone host; never run"),
      "iPhone (UIKit)": ("❌", "no CPython on the phone"), "Agent (MCP)": ("—", "")}),
    ("Camera", "mojoui.camera: Camera().start(), snapshot(), tick() -> a new JPEG (jpeg, width, height); the browser's rear camera on the web host (a still only when asked, tag 3 of the /audio socket, mojoui.webcamera), this machine's V4L2 camera elsewhere", "",
     {"Linux (GTK)": ("✅", "tests/test_camera desktop: this machine's webcam through ffmpeg/V4L2, 1280x720 JPEG, a fresh frame 190 ms after a request, its file deleted at stop()"),
      "Web": ("✅", "scripts/g77_camera_check.py (goal 77 M6): headless Chromium's fake camera plays the scene file, the page sends one still per request; tests/test_camera web: the hub"),
      "Android": ("❌", "not built"), "Mac (AppKit)": ("❌", "not built (AVFoundation capture planned)"),
      "iPhone (UIKit)": ("❌", "not built"), "Agent (MCP)": ("—", "")}),
    ("Camera card and look tool", "mojoui.looker: Looker.tools() / call() / tick(llm) / views() / parts(since) (each box a pointer part: mojoui.pointer.area_part); mojoui.sight: draw_sight() (a picture with boxes named by their labels); mojoui.grounding: Qwen's 0-1000 boxes validated into pixels; genui's Sight component", "",
     {"Linux (GTK)": ("🔨", "examples/omx compiles with it there; checked on the web host (the model side runs in-process the same way: tests/test_llm_vision)"),
      "Web": ("✅", "scripts/g77_camera_check.py: \"Where is the banana?\" -> the card's banana box IoU 0.85 with the truth, the part on the banana, \"What does the sign say?\" -> PURPLE OTTER 42; docs/goals/77/m6-camera-banana.png"),
      "Android": ("🔨", "plain canvases; never run with this app"), "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("🔨", "builds; never run"), "Agent (MCP)": ("—", "")}),
    ("Map card and show_map tool", "mojoui.tripmap: TripMap (real OpenStreetMap tiles, numbered stops in the order visited, a route, fitted; each stop a pointer part card.stopN; point(tag) flies there, van Wijk-Nuij eased; the ring follows the marker through mojoui.geometry spots) and genui's TripMap (component 8); mojoui.maptool: show_map; mojoui.tiles (TileStore: HTTPS on worker threads, disk cache, attribution), mojoui.geocode (Nominatim one a second, cached, the 60 km rule), mojoui.webcache, mojoui.pngread", "",
     {"Linux (GTK)": ("✅", "docs/goals/77-check.py M3: two trips typed into examples/omx at 820x1180, every stop within 2 km of the truth, 3 points on stops each within 25 ms of their audio, a flight per point; tests/test_tripmap, test_pngread, test_mapweb (live tiles and Nominatim); docs/goals/77/m3-map-gtk.png"),
      "Web": ("✅", "scripts/omx_map_web.py (M3): the same trips in headless Chromium at 820x1180, tiles in the browser, the ring round the named stop's marker after the flight; docs/goals/77/m3-map-tablet-1.png, -2.png"),
      "Android": ("🔨", "a plain canvas; https needs Flare, which isn't built there"), "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("🔨", "no Flare on iOS: no tiles"), "Agent (MCP)": ("—", "")}),
    ("Isometric explainer", "mojoui.iso: genui's Iso component (3-6 blocks as isometric boxes tinted by kind, arrows with labels, numbered step badges, the steps listed under it; layered by the links, painter's order), IsoDiagram.parts() (each block a pointer part named by its label: mojoui.pointer.area_part; a pointed-at block rises and its step is marked: Screens.point_at); mojoui.explain: the agent's explain tool (explain_tool(), explain_ui() -> render_ui's card, shown by Screens.adopt through mojoui.agentui.tool_card)", "",
     {"Linux (GTK)": ("✅", "docs/goals/77-check.py M4 on examples/omx: three \"how does X work?\" questions at phone width, light and dark, points on the blocks as they are named; tests/test_iso"),
      "Web": ("🔨", "the same canvas and parts (the web host draws canvases and reports tagged rects); not run by a check in the browser"),
      "Android": ("🔨", "plain canvases; never run with this app"), "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("🔨", "builds; never run"), "Agent (MCP)": ("—", "")}),
    ("Agent-driven live tiles", "genui's LiveTiles (component 10: tiles in importance order with an id, kind centre / passive / live, tint, icon, head, faces, why, actions, big, charm; the centre tiles drawn by mojoui.livetiles on one Canvas, the others named under it; each tile a pointer part card.<id>, a pointed tile rises); mojoui.tilescard (the rules a schema can't say, the tints, the tiles tool's ops as a JSON Patch); mojoui.agentui: Screens.patch (a JSON Patch on a shown card's render_ui arguments, validated again, its tiles' motion kept so they glide), custom() (a CUSTOM ui_patch event), tiles_tool() / tiles() / take_tiles() (promote, add, remove, set_face); what the person does to a tile comes back as a screen action; an app's own tiles card: Screens.show / keep (its tiles kept in step, samples stepping aside for an agent's tile of their name and back when it goes, a refused add not retried until the tile changes), agent_tile_ids, tiles(args, into=) / aimed() (calls naming no card or an agent's tiles card go to the app's), merge_tiles (an agent's LiveTiles card joins it); mojoui.tilescard is_sample / sample_plain", "",
     {"Linux (GTK)": ("✅", "docs/goals/77-check.py M7C on examples/agenttiles: a scripted AG-UI agent shows the tiles (render_ui), promotes weather with the tiles tool (first, large, 0 holes), points at it (the ring's rect and its pixels on the tile); tests/test_genui_tiles, test_tiles_agent; docs/goals/77/m7c-gtk-point.png"),
      "Web": ("✅", "the same run in headless Chromium (M7C): the promote and the ring on the weather tile; docs/goals/77/m7c-web-point.png"),
      "Android": ("🔨", "a plain canvas; never run with this app"), "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("🔨", "builds; never run"), "Agent (MCP)": ("—", "")}),
    ("The Stage's TV", "mojoui.stagetv: the chat bar grows over the whole centre when she explains (StageTV: open / show / close / speaking / tick, the 12 s quiet; the box drawn on a see-through canvas on gitaway's soft spring, the tiles fading under a veil, the body arriving 160 ms in); a card on the left (any view: genui's Word, Iso, TripMap, Sight), StageThread (bubbles) on the right, StageChips with no card; Stage(…, tv=, content=); pointed_parts leaves hidden tiles out of the pointer, StageTV.target (the card shown or swapping in) and mojoui.agentui.stage_parts (this turn's card in the TV, an app card's own boxes, the tiles while they show) say what she may point at; RecentCards (the cards shown before, newest first, one tap back); Overlay bands (.pin(STRETCH, END))", "",
     {"Linux (GTK)": ("✅", "docs/goals/77-check.py M7D on examples/stage: open, swap, close sampled frame by frame (overshoot 1.7 %, settled < 0.8 s), the body over the panel, the card inside it, the quiet closing it; tests/test_stagetv; docs/goals/77/m7d-gtk-open.png"),
      "Web": ("✅", "the same run in headless Chromium (M7D), plus the box measured in screenshots every ~60 ms; docs/goals/77/m7d-web-open.png"),
      "Android": ("🔨", "canvases and overlays run there; the band (STRETCH) is not in its host yet"), "Mac (AppKit)": ("🔨", "the band anchors added; builds, never run"),
      "iPhone (UIKit)": ("🔨", "the band anchors added; builds, never run"), "Agent (MCP)": ("—", "")}),
    ("The Stage's sides, pins and charms", "mojoui.stagefeed: stage_feed(ranked tiles with kinds, urgent, pins) says what stands on the stage (the urgent tile first, the centre ones, tiles that fill up to five) and what goes to Today, Live and Pinned (StageFeed.place: from what the grid really shows); occasions (school, game, Thanksgiving, rain, birthday, flight) put their charm on a tile (wear_occasion); mojoui.livetiles: drop zones outside the grid (drop_zone, DROPPED, hover_zone: a tile dragged onto Pinned) and a phone's two columns of 112 pt rows (set_columns, compact_height); mojoui.charms: draw_charm (bag, pennant, hat, umbrella, luggage tag, turkey, pin: drawn in code, coloured from the palette, swinging or flapping); mojoui.vector: an SVG subset on a canvas (draw_icon: mojoui's Lucide icons on a tile); mojoui.stage: StageRow (a number mono, words quiet), StageNote, StageCard(on_unpin)", "",
     {"Linux (GTK)": ("✅", "docs/goals/77-check.py M7E on examples/stage: weather in Today, then the large tile on the rain day; a drag pins the to-do tile (0 holes) and Unpin brings it back; each occasion's charm on its tile and in the picture; the Live row ticking in the window; two columns at 390 wide; tests/test_stagefeed, test_livetiles, test_vector; docs/goals/77/m7e-gtk-*.png"),
      "Web": ("✅", "the same run in headless Chromium (M7E), the drag with Playwright's mouse, the page's own Live row read twice; docs/goals/77/m7e-web-*.png"),
      "Android": ("🔨", "plain canvases and views; never run with this app"), "Mac (AppKit)": ("🔨", "the icons mapped to SF Symbols; never run"),
      "iPhone (UIKit)": ("🔨", "never run"), "Agent (MCP)": ("—", "")}),
    ("Orb and cloud rim", "mojoui.orb: Orb (listens / thinks / speaks, driven by a level, springs), OrbView(big), draw_rim / RimView (the cloud lane's frame); passthrough canvases", "",
     {"Linux (GTK)": ("✅", "tests/test_orb; screenshots in docs/goals/72, light and dark"), "Web": ("✅", "the same canvases in the browser (docs/goals/72/tablet.png)"),
      "Android": ("🔨", "canvases run there; never drawn"), "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("🔨", "builds; never run"), "Agent (MCP)": ("—", "")}),
    ("Voice screens", "mojoui.voiceui: VoiceHome, VoiceWork, VoiceDock (Mute / Type / Stop: the agent's tools), VoiceLane, VoiceChips; Screens.adopt(agent): cards an in-process agent already ran (render_ui)", "",
     {"Linux (GTK)": ("✅", "examples/omx (72-check M4): the card on the shelf, phone width and desktop, light and dark; tests/test_agentui_adopt"), "Web": ("✅", "examples/omx in the browser (M5)"),
      "Android": ("🔨", "plain views; never run with this app"), "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("🔨", "builds; never run"), "Agent (MCP)": ("—", "")}),
    ("To-do list", "mojoui.todo: TodoList(path) in a JSON file (add several, done / remove by number or words, ambiguity refused, refresh() when another writer changed it), TodoCard (a tick box per thing), todo_functions() the agent's four tools", "",
     {"Linux (GTK)": ("✅", "tests/test_todo; 72-check M6-TODO on examples/omx: five things in one spoken-style turn, 'I called mum' ticks it, a tap on a tick box, 'what's left', still there after a restart"),
      "Web": ("🔨", "the same file and tools; never run in the browser"), "Android": ("🔨", "plain views; never run"), "Mac (AppKit)": ("🔨", "builds; never run"),
      "iPhone (UIKit)": ("🔨", "builds; never run"), "Agent (MCP)": ("—", "")}),
    ("News headlines", "mojoui.news: news_url, parse_headlines (Google News RSS: title, source, link, age; entities decoded, newest first), NewsCard (each headline a link), news_for_model", "",
     {"Linux (GTK)": ("✅", "tests/test_news; 72-check M6-NEWS: two topics, 6 headlines with sources, the card 1.3-2.3 s after the question (limit 12), a two-sentence gist; https through Flare (examples/omx/needs: flare)"),
      "Web": ("🔨", "the request is mojoui.http, but the web build has no TLS (plain http only): the tool answers that it can't reach the news"), "Android": ("❌", "Flare isn't built for Android"),
      "Mac (AppKit)": ("🔨", "Flare runs on the Mac; never run with this"), "iPhone (UIKit)": ("❌", "Flare isn't built for iOS"), "Agent (MCP)": ("—", "")}),
    ("Think-it-through job", "mojoui.llmjob: ThinkJob(title, task).start(llm) on the model's second sequence with thinking on, poll(), ThinkCard (a clock, then the answer; the thinking is never shown), job_notice / job_memory; LlmAgent.remember", "",
     {"Linux (GTK)": ("✅", "tests/test_llmjob (the conversation answered in 372 ms while the job ran); 72-check M6-JOBS: a spoken question during the job, first audio within 1.5 s, the notice heard back, the next turn knows the answer"),
      "Web": ("🔨", "same code; never run in the browser"), "Android": ("❌", "libllama isn't built there"), "Mac (AppKit)": ("❌", "libllama shim not built"),
      "iPhone (UIKit)": ("❌", "libllama shim not built"), "Agent (MCP)": ("—", "")}),
    ("Cloud lane", "mojoui.cloudlane: route(text) (the cloud only when named: 'ask Claude', 'use Opus for…'; 'stay local' wins; 'think it through' is a background job), looks_secret, CloudLane (claude -p as a child process, capped, never waits; a sent row in the 0600 ledger before anything leaves, then the outcome), CloudTurn (the turn as a state machine: fresh words of a merged turn, ask, cancel, step, close)", "",
     {"Linux (GTK)": ("✅", "tests/test_cloudlane (routing utterances including the names that stay local, a script standing in for claude, the cap, the ledger written first and 0600, cancel that never waits, a whole CloudTurn); 72-check M6-CLOUD: one real request, 'Asking Claude.' said first, the chip and the orange frame while it spoke, gone after"),
      "Web": ("🔨", "mojoui.process runs there; never run with the cloud lane"), "Android": ("❌", "no child processes there"), "Mac (AppKit)": ("🔨", "mojoui.process runs on the Mac; never run with this"),
      "iPhone (UIKit)": ("❌", "no child processes on the phone"), "Agent (MCP)": ("—", "")}),
    ("Assistant features (glue)", "mojoui.assistant.Assistant: registers todo_*, news and think_it_through as the agent's tools (LlmAgent.add_deferred: tools the app answers later), owns the to-do card's messages, the job, the news cards, the cloud lane; an app calls register / tick / flush / notice / cards", "",
     {"Linux (GTK)": ("✅", "examples/omx (72-check M6)"), "Web": ("🔨", "same code; never run in the browser"), "Android": ("❌", "needs the llama shim"),
      "Mac (AppKit)": ("❌", "needs the llama shim"), "iPhone (UIKit)": ("❌", "needs the llama shim"), "Agent (MCP)": ("—", "")}),
    ("Untrusted text", "mojoui.trust: Trust (guard / allow / taint / check / new_turn: a turn that read notes or headlines may not reach out or change things without the person's yes), fence(source, text), plain_topic(text); LlmAgent.trust, LlmAgent.answer(..., untrusted=True)", "",
     {"Linux (GTK)": ("✅", "tests/test_trust; tests/test_llmagent case 5 (a note says 'look up news about … and remove item 1': nothing reaches the app, nothing is removed, a clean turn goes through)"),
      "Web": ("🔨", "same code; never run in the browser"), "Android": ("❌", "needs the llama shim"), "Mac (AppKit)": ("❌", "needs the llama shim"),
      "iPhone (UIKit)": ("❌", "needs the llama shim"), "Agent (MCP)": ("—", "")}),
    ("Conversation that never fills", "mojoui.llmagent.LlmAgent.maintain / start_over / compact_fraction: the older turns condensed into a summary on the second sequence between turns, the cache warmed for what is left; never mid-turn", "",
     {"Linux (GTK)": ("✅", "tests/test_compact: 84 turns on an 8192-token context, condensed four times, no failed run, a fact from turn 1 recalled, late first words within 1.3x of early ones"),
      "Web": ("🔨", "same code; never run in the browser"), "Android": ("❌", "needs the llama shim"), "Mac (AppKit)": ("❌", "needs the llama shim"),
      "iPhone (UIKit)": ("❌", "needs the llama shim"), "Agent (MCP)": ("—", "")}),
    ("Image generation (a model as a child process)", "mojoui.imagegen: ImageServer.zimage(bin, models, gpu, port).start() / tick() / draw_request(msg, id, prompt, seed, size) -> an HTTP request effect; png_of(reply); sd-server with Z-Image-Turbo on its own GPU, ended with the app", "",
     {"Linux (GTK)": ("✅", "tests/test_imagegen: healthy in 0.8 s, a 768 px picture in 3.4 s once warm (8.6 s the first), the same seed the same bytes, nothing left running after stop(); docs/goals/72-check.py M6-picture 5.5 s"),
      "Web": ("❌", "the painter and its model files are on this machine; not run from the web host"), "Android": ("❌", "not built"),
      "Mac (AppKit)": ("❌", "stable-diffusion.cpp's Metal build not tried"), "iPhone (UIKit)": ("❌", "no child processes"), "Agent (MCP)": ("—", "")}),
    ("Comic and picture cards (agent-made images)", "mojoui.comic: ComicPlan.parse (the model's plan as a tool call: title, one hero, four panels), prompts with one hero and one seed; mojoui.creator.Creator: make_comic / draw_picture, a card that fills in panel by panel with a fade, full PNGs kept, Album.hold (a safe name; the agent never sends pixels)", "",
     {"Linux (GTK)": ("✅", "docs/goals/72-check.py M6-comic on examples/omx: first panel 10.6-15.7 s, four 21-26 s, none blank, Qwen sees the hero in panel 1; tests/test_creator; docs/goals/72/comic_card.png, picture_card.png"),
      "Web": ("🔨", "plain views and canvases; never run with this app"), "Android": ("🔨", "plain views and canvases; never run"),
      "Mac (AppKit)": ("🔨", "builds; never run"), "iPhone (UIKit)": ("🔨", "builds; never run"), "Agent (MCP)": ("—", "")}),
    ("Find in my notes (in-process embeddings)", "mojoui.notes: NotesIndex(folder, pack, cache).step(ms) / search(question, folder, k) -> files + passages; e5-small-v2 by MAX, a cached index, one folder only (no .., links, hidden files, > 1 MB); Creator.find_in_notes cites the files on a card", "",
     {"Linux (GTK)": ("✅", "tests/test_notes: five questions each find the right file first (4 ms a search), unrelated finds nothing, cache reuse, confinement; docs/goals/72-check.py M6-notes 5/5 answered and cited; docs/goals/72/notes_card.png"),
      "Web": ("❌", "needs the notes folder and MAX in the app's process"), "Android": ("❌", "no MAX"),
      "Mac (AppKit)": ("❌", "MAX has no Mac GPU path here"), "iPhone (UIKit)": ("❌", "no MAX"), "Agent (MCP)": ("—", "")}),
]


def service_cell(host, example, special):
    got = special.get(host)
    if got is None:
        return ("✅" if example in RUN_ON[host] else "🔨"), ""
    return got


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
    notes = [f"- {name} ({host}): 🔨 though a check runs it: {why}." for (host, name), why in UNPROVEN.items()]
    notes += [f"- {name}: {why}." for name, why in NOTES.items()]
    if notes:
        out += [""] + notes
    known = {}
    for h in names:
        for ctor, kind in COMPONENTS:
            known[(h, ctor)] = cell(h, srcs[h], ctor, kind)
        for name, api, pattern, example in FEATURES:
            known[(h, name)] = feature_cell(h, srcs[h], pattern, example, name)
    out += ["", "## Native services (the machine, not a widget)", "",
            "| Service | API | " + " | ".join(names) + " |",
            "|---|---|" + "---|" * len(names)]
    why = []
    for name, api, example, special in SERVICES:
        cells = [service_cell(h, example, special) for h in names]
        out.append(f"| {name} | `{api}` | " + " | ".join(c for c, _ in cells) + " |")
        why += [f"- {name} ({h}): {w}." for h, (c, w) in zip(names, cells) if w]
    out += [""] + why
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
