# Goal 79 M4: writes docs/goals/79/steps.json, the one step script both apps play (the web actions in logical px; the
# native test-mode steps derived from them: taps in thousandths of the window, drags as stroke: points, keys by their web
# names). Run: pixi run python docs/goals/79/make_steps.py
import json
S = []
W, H = 1440.0, 900.0
ROW5 = [167, 413]  # the sixth row of the Inbox (the note opened next is always the oldest edited one there)
BOXES = {"#toggle-sidebar": [38, 38], "#island-title": [720, 38], "#note-title": [720, 50], "#search-button": [1402, 38],
         '[aria-label="Sticky note"]': [1396, 481], '[aria-label="Pen"]': [1396, 343], '[aria-label="Select"]': [1396, 251],
         "#undo": [45, 860], "#redo": [91, 860], "#zoom-in": [1352, 860], "#top-properties": [570.75, 324.59],
         '[data-note-id="1"]': ROW5, '[data-note-id="2"]': ROW5, '[data-note-id="3"]': ROW5}
def tap(x, y):
    return f"tapat:desk={round(x / W * 1000)},{round(y / H * 1000)}"
def native_of(web):
    out = []
    for a in web:
        if a == "reload":
            out.append("relaunch"); continue
        if "click" in a: out += [tap(*BOXES[a["click"]]), "wait:300"]
        elif "at" in a: out += [tap(*a["at"]), "wait:300"]
        elif "drag" in a:
            pts = a["drag"]; seq = [pts[0]]
            for k in range(1, len(pts)):
                for t in range(1, 7):
                    seq.append([pts[k - 1][0] + (pts[k][0] - pts[k - 1][0]) * t / 6, pts[k - 1][1] + (pts[k][1] - pts[k - 1][1]) * t / 6])
            out += ["stroke:desk=" + ";".join(f"{x:.1f},{y:.1f},0.5" for x, y in seq), "wait:300"]
        elif "key" in a: out += ["key:desk=" + a["key"].replace("Control+", "ctrl+").replace("Shift+", "shift+")]
        elif "type" in a: out += ["typekeys:desk=" + a["type"]]
        elif "wait" in a: out += [f"wait:{a['wait']}"]
    return out + ["wait:500"]
def step(name, covers, web, native=None):
    S.append({"name": name, "covers": covers, "web": web, "native": native or native_of(web)})
row = lambda i: [167, 221 + 35 * i + 17]
step("open the notes panel", ["toggle-panel"], [{"click": "#toggle-sidebar"}])
step("open the page from the panel", ["open-page"], [{"click": '[data-note-id="1"]'}])
step("fold the Projects shelf", ["fold-shelf"], [{"at": [156, 461]}])
step("close the panel", ["toggle-panel"], [{"click": "#toggle-sidebar"}])
step("tick a task", ["tick-task"], [{"at": [470, 480]}, {"key": "Home"}, {"key": "ArrowRight"}, {"key": "ArrowRight"}, {"key": "ArrowRight"}, {"key": "Delete"}, {"type": "x"}])
step("type a paragraph", ["type-paragraph"], [{"at": [1030, 320]}, {"key": "End"}, {"key": "Enter"}, {"key": "Enter"}, {"type": "We leave on Friday morning."}])
step("type a heading", ["type-heading"], [{"key": "Enter"}, {"key": "Enter"}, {"type": "## Tide times"}])
step("rename in the title island", ["rename"], [{"click": "#island-title"}, {"click": "#note-title"}, {"key": "Control+a"}, {"type": "Lighthouse weekend"}, {"key": "Enter"}])
step("switch to Draw", ["write-draw"], [{"at": [478, 117]}])
step("draw a mark", ["draw-mark"], [{"drag": [[620, 650], [700, 690], [780, 650], [860, 700]]}])
step("back to Write", ["write-draw"], [{"at": [412, 117]}])
step("open the canvas", ["open-canvas"], [{"click": "#toggle-sidebar"}, {"click": '[data-note-id="2"]'}, {"click": "#toggle-sidebar"}])
step("a text box", ["canvas-text"], [{"at": [700, 600]}, {"type": "Compost"}, {"key": "Escape"}])
step("a sticky", ["canvas-sticky"], [{"click": '[aria-label="Sticky note"]'}, {"at": [860, 480]}, {"type": "Seeds"}, {"key": "Escape"}])
step("connect them", ["connect"], [{"key": "c"}, {"drag": [[720, 615], [860, 480]]}])
step("a pen stroke", ["canvas-stroke"], [{"click": '[aria-label="Pen"]'}, {"drag": [[560, 640], [600, 660], [650, 640], [700, 670]]}])
step("move a sticky", ["move-object"], [{"click": '[aria-label="Select"]'}, {"drag": [[600, 315], [680, 355]]}])
step("delete the text box", ["delete-object"], [{"at": [720, 615]}, {"key": "Delete"}])
step("undo", ["undo"], [{"click": "#undo"}])
step("redo", ["redo"], [{"click": "#redo"}])
step("zoom in with the island", ["zoom-island"], [{"click": "#zoom-in"}])
step("open the map", ["open-map"], [{"click": "#toggle-sidebar"}, {"click": '[data-note-id="3"]'}, {"click": "#toggle-sidebar"}])
step("add a child", ["map-child"], [{"key": "Tab"}, {"type": "Weather"}, {"key": "Enter"}])
step("add a sibling", ["map-sibling"], [{"key": "Enter"}, {"type": "Ending"}, {"key": "Enter"}])
step("rename an idea", ["map-rename"], [{"key": "F2"}, {"type": "Endings"}, {"key": "Enter"}])
step("search and open by keyboard", ["search-open-keyboard"], [{"click": "#search-button"}, {"type": "gar"}, {"key": "Enter"}])
step("switch skin in settings", ["skin-settings"], [{"click": "#island-title"}, {"click": "#top-properties"}, {"at": [1047, 320]}, {"key": "Escape"}])
step("quit and reopen", ["quit-reopen"], ["reload"])
json.dump({"steps": S}, open("docs/goals/79/steps.json", "w"), indent=1, ensure_ascii=False)
print(len(S))
