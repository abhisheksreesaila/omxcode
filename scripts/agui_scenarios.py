"""Goal 48's scripted AG-UI scenarios (scripts/agui_agent.py merges them into SCENARIOS): the examples worth showing,
streaming generative UI, human in the loop. Every UI here is data built only from catalogued components
(docs/genui.schema.json); the app validates it and draws it natively."""

import json

from ag_ui.core import (RunErrorEvent, StepStartedEvent, StepFinishedEvent, ToolCallStartEvent, ToolCallArgsEvent,
                         ToolCallEndEvent, ToolCallResultEvent, StateSnapshotEvent, StateDeltaEvent, CustomEvent,
                         TextMessageStartEvent, TextMessageContentEvent, TextMessageEndEvent)


def catalog_ui():
    """Every general component, grouped as docs/agui.md lists them (the catalog at a glance)."""
    def card(title, *kids):
        return {"component": "Card", "title": title, "children": list(kids)}
    return {"component": "VStack", "gap": "m", "children": [
        {"component": "Breadcrumbs", "items": ["Home", "Components", "Catalog"]},
        {"component": "Grid", "columns": 2, "children": [
            card("Words",
                 {"component": "Text", "text": "Revenue is up", "style": "headline", "tone": "accent"},
                 {"component": "Markdown", "text": "Markdown with **bold**, *italics* and `code`:\n\n- one\n- two"},
                 {"component": "HStack", "children": [{"component": "Chip", "text": "new", "hue": 1}, {"component": "Chip", "text": "beta", "hue": 3},
                                                       {"component": "Icon", "name": "map-pin", "size": 20}]},
                 {"component": "Alert", "title": "Heads up", "text": "Rain after 4 pm.", "tone": "warn"},
                 {"component": "Skeleton", "lines": 2}),
            card("Inputs",
                 {"component": "TextField", "label": "Name", "placeholder": "Your name", "bind": "/form/name"},
                 {"component": "Dropdown", "label": "City", "options": ["Lisbon", "Porto", "Faro"], "bind": "/form/city"},
                 {"component": "Slider", "label": "Guests", "bind": "/form/guests", "min": 1, "max": 10},
                 {"component": "Segmented", "options": ["Day", "Week", "Month"], "bind": "/form/range"},
                 {"component": "HStack", "children": [{"component": "Toggle", "label": "Alerts", "bind": "/form/alerts"},
                                                       {"component": "Checkbox", "label": "Terms", "bind": "/form/terms"}]},
                 {"component": "DatePicker", "label": "Date", "bind": "/form/date"}),
        ]},
        {"component": "Grid", "columns": 3, "children": [
            {"component": "KpiView", "label": "Revenue", "value": "$1.24M", "note": "+8.1%", "tone": "good", "spark": [3, 4, 4, 5, 7, 6, 8]},
            {"component": "KpiView", "label": "Orders", "value": "18,204", "note": "+2.3%", "tone": "good", "spark": [5, 5, 6, 5, 6, 7, 7]},
            {"component": "KpiView", "label": "Returns", "value": "3.1%", "note": "+0.4 pt", "tone": "warn", "spark": [2, 2, 3, 3, 3, 4, 4]},
        ]},
        {"component": "Tabs", "tabs": ["Chart", "Grid", "Map"], "children": [
            {"component": "ChartView", "kind": "bar", "title": "Sales by region", "labels": ["North", "South", "East", "West"], "values": [420, 380, 510, 290], "value_name": "sales"},
            {"component": "DataGrid", "columns": ["Region", "Sales", "Orders"], "rows": [["North", 420, 61], ["South", 380, 55], ["East", 510, 70], ["West", 290, 41]]},
            {"component": "MapView", "route": [[38.7139, -9.1394], [38.7071, -9.1355], [38.6916, -9.2160]],
             "places": [{"lat": 38.7139, "lon": -9.1394, "label": "Rossio"}, {"lat": 38.6916, "lon": -9.2160, "label": "Belém"}]},
        ]},
        {"component": "Grid", "columns": 2, "children": [
            card("Progress",
                 {"component": "Timeline", "steps": [{"label": "Plan", "status": "done"}, {"label": "Build", "status": "running", "detail": "3 of 5"}, {"label": "Ship"}]},
                 {"component": "ProgressBar", "value": 60, "label": "Uploading"},
                 {"component": "Meter", "label": "Disk", "value": 72, "figure": "72 GB of 100"}),
            card("Code and tables",
                 {"component": "CodeBlock", "code": "pixi run scripts/agentchat.sh", "language": "bash"},
                 {"component": "Table", "columns": ["City", "Trips"], "rows": [["Lisbon", 12], ["Porto", 7]]},
                 {"component": "Sparkline", "values": [1, 3, 2, 5, 4, 6], "label": "Trend"}),
        ]},
        {"component": "Confirm", "title": "Book the table?", "text": "Four guests, Friday at 19:30.", "approve": "Book", "reject": "Not now"},
    ]}


def scenario_catalog(inp, r, words):
    mid = r.say("Here is every component I can use.", pieces=words("Here is every component I can use."))
    r.call("render_ui", {"ui": catalog_ui()}, parent=mid, chunks=6)


def scenario_error(inp, r, words):
    """The first run fails (RUN_ERROR); a retry (the next run) answers."""
    if inp.run_id.endswith("run1"):
        r.add(RunErrorEvent(message="the model is unavailable (scripted)"))
        return
    text = "Hello again: that worked."
    r.say(text, pieces=words(text))


RELEASE = """# Release 2.4

**Faster agents, nicer charts.** Highlights:

- Agent UI streams in as it's written
- 36 components an agent can use
- Approve or reject before anything runs

## Changes

| Area | Change |
|---|---|
| Chat | Stop, Retry, Regenerate |
| Charts | bars and lines from data |

Upgrade with:

```bash
pixi update omxcode
pixi run scripts/agentchat.sh
```
"""


def scenario_release(inp, r, words):
    if inp.messages and inp.messages[-1].role == "tool":
        r.say("Shipped.")
        return
    mid = r.say(RELEASE, pieces=words(RELEASE), delay=8)
    r.call("render_ui", {"ui": {"component": "Card", "title": "Rollout", "children": [
        {"component": "Timeline", "steps": [{"label": "Changes merged", "status": "done", "detail": "41 pull requests"},
                                            {"label": "Release candidate", "status": "done"},
                                            {"label": "Staged rollout", "status": "running", "detail": "25% of users"},
                                            {"label": "Everyone"}]},
        {"component": "HStack", "children": [{"component": "Chip", "text": "2.4.0", "hue": 1}, {"component": "Chip", "text": "stable", "hue": 2}]}]}}, parent=mid, chunks=3)


REGIONS = ["North", "South", "East", "West", "Central"]
REGION_SALES = [420, 380, 510, 290, 345]
MONTHS = ["Jul", "Aug", "Sep"]
PRODUCTS = [("Trail shoe", "Footwear", 1840, 92000), ("Rain shell", "Outerwear", 1210, 145200), ("Day pack", "Bags", 990, 59400),
            ("Wool socks", "Footwear", 3120, 37440), ("Fleece", "Outerwear", 870, 69600), ("Water bottle", "Gear", 2460, 29520),
            ("Headlamp", "Gear", 1330, 53200), ("Trek poles", "Gear", 640, 57600), ("Down vest", "Outerwear", 520, 78000),
            ("Sun hat", "Accessories", 1100, 27500), ("Camp mug", "Gear", 1980, 23760), ("Gaiters", "Footwear", 410, 16400)]


def dashboard_ui():
    """A Q3 sales dashboard (~40 components): KPIs, two charts, a grid of products, a breakdown, an export."""
    kpi = lambda label, value, note, tone, spark: {"component": "KpiView", "label": label, "value": value, "note": note, "tone": tone, "spark": spark}
    return {"component": "VStack", "gap": "m", "children": [
        {"component": "HStack", "children": [{"component": "Text", "text": "Q3 sales", "style": "title"}, {"component": "Spacer"},
                                             {"component": "Chip", "text": "Jul – Sep", "hue": 1}, {"component": "Chip", "text": "live", "hue": 2}]},
        {"component": "Grid", "columns": 4, "children": [
            kpi("Revenue", "$1.24M", "+8.1% vs Q2", "good", [310, 335, 360, 352, 390, 410, 428]),
            kpi("Orders", "18,204", "+2.3%", "good", [5.1, 5.3, 5.2, 5.8, 6.0, 6.1, 6.3]),
            kpi("Average order", "$68.10", "+5.6%", "good", [61, 62, 64, 63, 66, 67, 68]),
            kpi("Returns", "3.1%", "+0.4 pt", "warn", [2.4, 2.5, 2.7, 2.6, 2.9, 3.0, 3.1])]},
        {"component": "Grid", "columns": 2, "children": [
            {"component": "ChartView", "kind": "bar", "title": "Revenue by region ($k)", "labels": REGIONS, "values": REGION_SALES, "value_name": "revenue"},
            {"component": "ChartView", "kind": "line", "title": "Orders by month", "labels": MONTHS, "values": [5820, 6010, 6374], "value_name": "orders"}]},
        {"component": "Card", "title": "Top products", "subtitle": "by revenue, Q3", "children": [
            {"component": "DataGrid", "columns": ["Product", "Category", "Units", "Revenue"],
             "rows": [[p, c, u, r] for p, c, u, r in PRODUCTS], "height": 300}]},
        {"component": "Grid", "columns": 3, "children": [
            {"component": "Meter", "label": "Quarter target", "value": 83, "figure": "$1.24M of $1.5M"},
            {"component": "Meter", "label": "Repeat buyers", "value": 41, "figure": "41%"},
            {"component": "Meter", "label": "Stock cover", "value": 64, "figure": "6.4 weeks"}]},
        {"component": "Alert", "title": "Returns are rising", "text": "Footwear returns doubled in September: sizing on the Trail shoe.", "tone": "warn"},
        {"component": "HStack", "children": [{"component": "Button", "label": "Export CSV", "action": "export", "icon": "download"},
                                             {"component": "Button", "label": "Break down by category", "action": "drill", "style": "prominent"}]},
    ]}


def stream_call(r, name, args, parent, pieces, delay):
    """A tool call whose arguments arrive in `pieces` parts, `delay` ms apart (a model writing them)."""
    cid = r.id("call")
    r.add(ToolCallStartEvent(tool_call_id=cid, tool_call_name=name, parent_message_id=parent))
    text = json.dumps(args)
    step = max(1, len(text) // pieces + 1)
    for i in range(0, len(text), step):
        r.add(ToolCallArgsEvent(tool_call_id=cid, delta=text[i:i + step]), delay)
    r.add(ToolCallEndEvent(tool_call_id=cid))
    return cid


def scenario_stream(inp, r, words):
    """Agentic generative UI: a step that searches (a backend tool, its result in the stream), then a dashboard streamed
    as render_ui's arguments a few bytes at a time, drawn while it arrives."""
    if inp.messages and inp.messages[-1].role == "tool":
        r.say("Exported." if "export" in inp.messages[-1].content else "Here's the breakdown.")
        return
    r.add(StepStartedEvent(step_name="search"), 60)
    cid = r.id("call")
    mid = r.id("m")
    r.add(ToolCallStartEvent(tool_call_id=cid, tool_call_name="search_sales", parent_message_id=mid), 40)
    r.add(ToolCallArgsEvent(tool_call_id=cid, delta=json.dumps({"quarter": "Q3", "group_by": "region"})), 40)
    r.add(ToolCallEndEvent(tool_call_id=cid), 20)
    r.add(ToolCallResultEvent(message_id=r.id("t"), tool_call_id=cid, content=json.dumps({"rows": 18204, "regions": 5}), role="tool"), 160)
    r.add(StepFinishedEvent(step_name="search"))
    r.add(StepStartedEvent(step_name="design"), 30)
    text = "Here's your Q3 dashboard: revenue is up, returns need a look."
    r.add(TextMessageStartEvent(message_id=mid, role="assistant"))
    for p in words(text):
        r.add(TextMessageContentEvent(message_id=mid, delta=p), 15)
    r.add(TextMessageEndEvent(message_id=mid))
    stream_call(r, "render_ui", {"ui": dashboard_ui()}, mid, pieces=90, delay=45)
    r.add(StepFinishedEvent(step_name="design"))
    r.add(CustomEvent(name="suggestions", value=["Break down by category", "Why are returns rising?", "Compare with Q2"]))


def scenario_approval(inp, r, words):
    """Human in the loop: the agent asks to run refund_order, a tool the app asks the person about first."""
    last = inp.messages[-1] if inp.messages else None
    if last is not None and last.role == "tool":
        got = json.loads(last.content) if last.content.startswith("{") else {}
        if got.get("decision") == "approved":
            text = "Refunded order 1042: $42.00 is on its way back to the card."
        else:
            text = "Okay, I won't refund order 1042."
        r.say(text, pieces=words(text), delay=20)
        return
    mid = r.say("Order 1042 arrived damaged, so a refund fits. I need your approval first.", delay=10)
    stream_call(r, "refund_order", {"order": "1042", "amount": 42.0, "reason": "Arrived damaged"}, mid, pieces=4, delay=20)


def scenario_interrupt(inp, r, words):
    """An interrupt: the run stops to ask; the next run resumes with the answer (forwardedProps.command.resume)."""
    fp = inp.forwarded_props if isinstance(inp.forwarded_props, dict) else {}
    resume = (fp.get("command") or {}).get("resume")
    if resume:
        text = f"Deployed to {resume}: build 2.4.0 is live there."
        r.say(text, pieces=words(text), delay=20)
        return
    r.say("The build passed. Where should it go?", pieces=words("The build passed. Where should it go?"), delay=10)
    r.add(CustomEvent(name="on_interrupt", value={"question": "Deploy build 2.4.0 to…", "options": ["Staging", "Production"]}))


SCENARIOS = {"stream": scenario_stream, "approval": scenario_approval, "interrupt": scenario_interrupt, "catalog": scenario_catalog, "error": scenario_error, "release": scenario_release}
