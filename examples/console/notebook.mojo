# The model page's Notebook tab (blade-notebook.js): the generated notebook, read only. Chapters on the left, the
# markdown and code cells in the middle, the architecture on the right. GET /admin/learn/<name> once; Run in Jupyter
# POSTs /admin/learn/<name>/open and shows Jupyter's single-notebook view (an iframe on the web; the browser elsewhere).

from mojoui.view import View, Text, Button, VStack, HStack, Spacer, Scroll, PLAIN, SUBTLE, CENTER, START
from mojoui.json import Json, J_OBJECT
from mojoui.markdown import Markdown, chapters
from mojoui.codeblock import CodeText
from mojoui.chip import Badge, BADGE_OK
from mojoui.embed import WebFrame
from mojoui.pagekit import MonoLine, BareCard, CardHead, CardBody, CardFoot, FlatButton, Fact, FactText, GroupHead, QuietText, SmallButton
from data import Cell, ArchRow, json_value, compact, fmt, short_endpoint, Store
from msgs import NB_RUN, NB_CHAPTER


struct Notebook(Copyable, Movable):
    var model: String  # the model it was read for
    var loaded: Bool
    var error: String
    var path: String
    var cells: List[Cell]
    var arch: String
    var facts: List[Tuple[String, String]]
    var rows: List[ArchRow]
    var kernel: String
    var jupyter: Bool  # showing Jupyter instead of the saved view
    var url: String  # Jupyter's lab view (the browser opens it)
    var embed: String  # its single-notebook view (the iframe)
    var opened: Int  # how many times Jupyter was opened (WebFrame's version)
    var starting: Bool
    var problem: String

    def __init__(out self):
        self.model = ""
        self.loaded = False
        self.error = ""
        self.path = ""
        self.cells = List[Cell]()
        self.arch = ""
        self.facts = List[Tuple[String, String]]()
        self.rows = List[ArchRow]()
        self.kernel = ""
        self.jupyter = False
        self.url = ""
        self.embed = ""
        self.opened = 0
        self.starting = False
        self.problem = ""

    def read(mut self, text: String) raises:
        var j = Json.parse(text)
        self.loaded = True
        self.path = j.text(j.get(0, "path"))
        var cells = List[Cell]()
        var cs = j.get(0, "cells")
        for k in range(j.size(cs)):
            var c = j.at(cs, k)
            var count = j.get(c, "execution_count")
            cells.append(Cell(j.text(j.get(c, "type")) == "code", j.text(j.get(c, "source")), j.number(count) if j.kind(count) == 2 else -1, List[String]()))
        self.cells = cells^
        var a = j.get(0, "architecture")
        self.facts = List[Tuple[String, String]]()
        self.rows = List[ArchRow]()
        if j.kind(a) == J_OBJECT:
            self.arch = j.text(j.get(a, "architecture"), "unknown architecture")
            var p = j.get(a, "parameters")
            if j.kind(p) == J_OBJECT:
                self.facts.append(("Layers", fmt(j.real(j.get(p, "layers")))))
                self.facts.append(("Parameters", compact(j.real(j.get(p, "total"))) + " (from config)"))
                self.facts.append(("Embeddings", compact(j.real(j.get(p, "embeddings")))))
                self.facts.append(("Per layer", "attn " + compact(j.real(j.get(p, "attention_per_layer"))) + " · mlp " + compact(j.real(j.get(p, "mlp_per_layer")))))
                if j.real(j.get(p, "experts")) > 1:
                    self.facts.append(("Experts", fmt(j.real(j.get(p, "experts")))))
            var st = j.get(a, "safetensors_total")
            if j.real(st) > 0:
                self.facts.append(("Weights", compact(j.real(st)) + " (safetensors)"))
            var rows = j.get(a, "rows")
            for k in range(j.size(rows)):
                var r = j.at(rows, k)
                self.rows.append(ArchRow(j.text(j.get(r, "field")), json_value(j, j.get(r, "value"))))
        var ks = j.get(0, "kernelspec")
        var name = j.text(j.get(ks, "display_name"), j.text(j.get(ks, "name")))
        self.kernel = (name + " · saved outputs only, nothing runs here") if name != "" else String("saved outputs only, nothing runs here")

    def read_open(mut self, text: String) raises:
        var j = Json.parse(text)
        self.url = j.text(j.get(0, "url"))
        self.embed = j.text(j.get(0, "embed_url"))
        if not self.url.startswith("http://127.0.0.1") or "/doc/tree/" not in self.embed:
            self.problem = "Jupyter returned a link that is not on this machine (http://127.0.0.1), so it was not opened"
            return
        self.opened += 1
        self.jupyter = True


def cell_view(c: Cell) -> View:
    if not c.code:
        return BareCard([VStack(Markdown(c.source, line_chars=86), spacing=0).align(START).padding(16, 18).fill()]).fill()
    var n = String("[ ]") if c.count < 0 else "[" + String(c.count) + "]"
    return BareCard([HStack(MonoLine(n).width(36), CodeText(c.source).grow(), spacing=8).align(START).padding(12, 14).fill()]).fill()


def notebook_view(nb: Notebook, st: Store, model: String, phone: Bool, height: Int) -> View:
    var running = False
    var k = st.model(model)
    if k >= 0:
        running = st.models[k].state == "ready"
    var chip = Badge(("model running · " + short_endpoint(st.endpoint_now())) if running else "start it to run cells", BADGE_OK if running else 0, dot=True)
    var head = HStack(MonoLine(model + ((" · " + nb.path) if nb.path != "" else String(""))), Spacer(), chip,
                      SmallButton("Saved view" if nb.jupyter else "Run in Jupyter", NB_RUN, "book-open" if nb.jupyter else "play"),
                      spacing=10).align(CENTER).fill()
    var items: List[View] = [head^]
    if nb.problem != "":
        items.append(QuietText(nb.problem + " Fix: jupyter lab " + (nb.path if nb.path != "" else String("<notebook>.ipynb"))))
    if nb.starting:
        items.append(QuietText("Starting Jupyter… the first start takes a few seconds."))
    if nb.jupyter:
        items.append(WebFrame(nb.embed, nb.opened, QuietText("Jupyter opened in your browser: " + nb.url), height=height, open_url=nb.url).fill())
        return VStack(items^, spacing=12).align(START).padding(10, 18).fill()
    if not nb.loaded:
        items.append(BareCard([CardHead("Building the notebook" if nb.error == "" else "Could not build the notebook"),
                               CardBody([QuietText(nb.error if nb.error != "" else "Reading the model's config and card from Hugging Face the first time, then it is saved for next time.")]),
                               CardFoot("mxc learn " + model)]).fill())
        return VStack(items^, spacing=12).align(START).padding(10, 18).fill()
    # chapters
    var sources = List[String]()
    var md = List[Bool]()
    for c in nb.cells:
        sources.append(c.source)
        md.append(not c.code)
    var chs = chapters(sources, md)
    var toc: List[View] = [GroupHead("Chapters")]
    for i in range(len(chs)):
        toc.append(HStack(MonoLine(String(i + 1)).width(18), Button(chs[i].title, NB_CHAPTER + i, SUBTLE).align(START).grow().tag("chapter-" + String(chs[i].level)),
                          spacing=6).align(CENTER).fill())
    var cells: List[View] = []
    for c in nb.cells:
        cells.append(cell_view(c))
    var facts: List[View] = [MonoLine(nb.arch).tag("arch-name")]
    for f in nb.facts:
        facts.append(Fact(f[0], FactText(f[1]), key_width=88))
    var rows: List[View] = []
    for r in nb.rows:
        rows.append(HStack(MonoLine(r.field).width(120), MonoLine(r.value), spacing=10).align(START).justify(START).fill().tag("arch-row"))
    facts.append(VStack(rows^, spacing=6).align(START).fill())
    var side = VStack(BareCard([CardHead("Architecture"), CardBody(facts^), CardFoot("read from the model's config", note=True)]).fill(),
                      BareCard([CardHead("Kernel"), CardBody([QuietText(nb.kernel)]), CardFoot("Run in Jupyter above to execute cells", note=True)]).fill(),
                      BareCard([CardHead("File"), CardBody([MonoLine(nb.path)]), CardFoot("mxc learn " + model)]).fill(),
                      spacing=14).align(START)
    if phone:
        items.append(VStack(cells^, spacing=12).align(START).fill())
        items.append(side^.fill())
        return VStack(items^, spacing=12).align(START).padding(10, 12).fill()
    var body = HStack(VStack(toc^, spacing=4).align(START).width(190),
                      Scroll(VStack(cells^, spacing=12).align(START).fill(), height=height).grow(),
                      side^.width(284), spacing=20).align(START).fill()
    items.append(body^)
    return VStack(items^, spacing=12).align(START).padding(10, 18).fill()
