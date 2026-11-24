from std.os import setenv
from mojoui.canvas import Surface, rgba
from mojoui.scene import Scene, SurfacePainter
from mojoui.png import encode_png
from webshell import WebShell
from mojoui.textedit import Pos

comptime W = 2304
comptime H = 1440

def shot(name: String, mut s: WebShell) raises:
    for _ in range(6):
        var sc = Scene(W, H, 1.6)
        s.paint(sc, 1440.0, 900.0, 1.6)
    var px = List[UInt32](length=W * H, fill=0xFFFFFFFF)
    var surf = Surface(Int(px.unsafe_ptr()), W, H, 1.6)
    var sp = SurfacePainter(surf^)
    s.paint(sp, 1440.0, 900.0, 1.6)
    var b = encode_png(px, W, H)
    with open("build/wrap/" + name + ".png", "w") as f:
        f.write_bytes(b)
    _ = len(px)
    with open("build/wrap/" + name + ".boxes.json", "w") as f:
        f.write(s.boxes.json())

def typed(mut s: WebShell, words: String):
    for c in words.graphemes():
        _ = s.key(String(c), 0)

def note(mut s: WebShell, title: String) raises:
    for k in range(len(s.notes)):
        if s.notes[k].title == title:
            s.open(s.notes[k].id)
            break

def main() raises:
    _ = setenv("OMX_CONFIG", "build/wrap/cfg2")
    _ = setenv("MOJOUI_SNAP", "0")
    for sk in ["paper", "night", "crayon"]:
        var s = WebShell("build/wrap/shots.db", String(sk))
        s.sidebar = True
        note(s, "Lighthouse trip")
        shot("page-sidebar" + (("-" + String(sk)) if sk != "paper" else ""), s)
    var s = WebShell("build/wrap/shots.db", "paper")
    s.sidebar = False
    note(s, "Lighthouse trip")
    shot("page", s)
    note(s, "Garden plan")
    shot("canvas", s)
    note(s, "Book mind map")
    shot("mindmap", s)
    s.open_search()
    for c in ["l", "i"]:
        _ = s.key(String(c), 0)
    shot("search", s)
    s.searching = False
    s.card_open = True
    s.card.title = "Book mind map"
    shot("island-card", s)
    s.card_open = False
    s.settings_open = True
    shot("settings", s)
