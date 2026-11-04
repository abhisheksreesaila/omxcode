"""Goal 48's scripted AG-UI scenarios (scripts/agui_agent.py merges them into SCENARIOS): the examples worth showing,
streaming generative UI, human in the loop. Every UI here is data built only from catalogued components
(docs/genui.schema.json); the app validates it and draws it natively."""

import json


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


SCENARIOS = {"catalog": scenario_catalog}
