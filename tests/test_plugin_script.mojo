# Every model a script calls is a plugin (goal 68 M0): YOLOX (MAX pack, "detect"), ResNet-18 (MAX pack, "scene"),
# e5-small (MAX pack, classify()), OWLv2 (torch, from the Hub) and a decision model dropped into the plugins folder
# after this program was built. Prints "PLUGINS: <name kind runner>…" and "<label>: ok" per function.
#   OMX_PACKS=build/packs OMX_PLUGINS=<folders> SCRIPT_VIDEO=<video> MOMENTS=<csv> pixi run -e models build/g68/bin/test_plugin_script
from std.os import getenv
from omxcore import Catalog, Table, TEXT as MX_TEXT
from mojoui.models import ModelFunctions, frame_models
from mojoui.plugins import find_plugins
from mojoui.video import VideoSource
from mojoui.videoscript import VideoFunctions
from mojoui.script import run_script
from mojoui.sheet import Sheet
from mojoui.csvio import read_table


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def show(run_tables: Sheet, label: String):
    var cols = String("")
    for c in range(run_tables.columns()):
        cols += " " + run_tables.name(c)
    var first = String("")
    if run_tables.rows() > 0:
        for c in range(run_tables.columns()):
            first += " " + run_tables.plain_text(c, 0)
    print("  " + label + ": " + String(run_tables.rows()) + " rows," + cols + " | first:" + first)


def main() raises:
    var line = String("PLUGINS:")
    for p in find_plugins():
        line += " " + p.name + " " + p.kind + " " + p.runner + ("" if p.ok() else " (refused)")
    print(line)
    print("FRAME_MODELS: " + " ".join(frame_models()))
    var videos = VideoFunctions()
    var path = getenv("SCRIPT_VIDEO", "")
    var v = VideoSource(path)
    videos.add("cam", path, v.fps, v.frames)
    var fns = ModelFunctions(videos^)
    var catalog = Catalog()
    var imp = read_table(getenv("MOMENTS", ""))
    var moments = Sheet(imp.table, False)
    catalog.add_frame("moments", moments.frame)
    var owl = getenv("OWL", "")
    var late = getenv("LATE", "")
    for name in ["detect", "scene", owl]:
        if name == "":
            continue
        check(fns.has(name), "no function " + name)
        var run = run_script("boxes = " + name + "(cam, 0, 0.5);", catalog, fns)
        check(run.problem == "", name + ": " + run.problem)
        var s = Sheet(run.tables[0], False)
        show(s, name)
        check(s.rows() > 0, name + " found nothing")
        print("plugin-" + name + ": ok")
    # (classify(): the text embedder plugin (e5small, a MAX pack) over a text column)
    var kinds = Table.empty()
    var kc = kinds.add_column("kind", MX_TEXT)
    for k in ["a hallway", "a living room", "an entrance"]:
        kinds.append_text(kc, k)
    kinds.check()
    var ks = Sheet(kinds^.share(), False)
    catalog.add_frame("kinds", ks.frame)
    var cr = run_script("c = classify(moments, place, kinds, kind);", catalog, fns)
    check(cr.problem == "", "classify: " + cr.problem)
    var cs = Sheet(cr.tables[0], False)
    show(cs, "classify")
    var door = False
    for r in range(cs.rows()):
        door = door or (cs.plain_text(3, r) == "door" and cs.plain_text(0, r) == "an entrance")
    check(cs.rows() == 3 and door, "classify through the e5 plugin")
    print("plugin-classify: ok")
    check(fns.has(late), "the plugin dropped in after the build: " + late)
    var run = run_script("answers = " + late + "(moments);\nper = SELECT label, COUNT(*) AS n FROM answers GROUP BY label ORDER BY n DESC;", catalog, fns)
    check(run.problem == "", late + ": " + run.problem)
    var a = Sheet(run.tables[0], False)
    show(a, late)
    var per = Sheet(run.tables[1], False)
    show(per, "per label")
    check(a.rows() == moments.rows(), "an answer per row")
    print("plugin-late-drop: ok")
