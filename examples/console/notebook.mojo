# The model page's Notebook tab (blade-notebook.js): the generated notebook, read only. Chapters on the left, the
# markdown and code cells in the middle, the architecture on the right. GET /admin/learn/<name> once; Run in Jupyter
# POSTs /admin/learn/<name>/open and shows Jupyter's single-notebook view (an iframe on the web; the browser elsewhere).

from mojoui.view import View, Text, Button, VStack, HStack, Spacer, Scroll, PLAIN, SUBTLE, CENTER, START
from mojoui.json import Json, J_OBJECT
from mojoui.markdown import Markdown, chapters
from mojoui.codeblock import CodeText
from mojoui.chip import Badge, BADGE_OK
from mojoui.embed import WebFrame
from mojoui.panel import Card, CardHead, CardBody, CardFoot, CardColumn, Fact, FactText, FactGrid, TabBody, KEYS_MEDIUM
from mojoui.header import SubHeader
from mojoui.words import MonoLine, QuietText
from mojoui.buttons import SmallButton
from mojoui.document import MarkdownCell, CodeCell, Outline, SpecRows, SpecTitle, DocLayout
from data import Cell, ArchRow, json_value, compact, short_endpoint, Store
from msgs import NB_RUN, NB_CHAPTER
from mojoui.numformat import en_number


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
                self.facts.append(("Layers", en_number(j.real(j.get(p, "layers")))))
                self.facts.append(("Parameters", compact(j.real(j.get(p, "total"))) + " (from config)"))
                self.facts.append(("Embeddings", compact(j.real(j.get(p, "embeddings")))))
                self.facts.append(("Per layer", "attn " + compact(j.real(j.get(p, "attention_per_layer"))) + " · mlp " + compact(j.real(j.get(p, "mlp_per_layer")))))
                if j.real(j.get(p, "experts")) > 1:
                    self.facts.append(("Experts", en_number(j.real(j.get(p, "experts")))))
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
        return MarkdownCell(c.source)
    return CodeCell(String("[ ]") if c.count < 0 else "[" + String(c.count) + "]", c.source)


def notebook_view(nb: Notebook, st: Store, model: String, phone: Bool) -> View:
    var running = False
    var k = st.model(model)
    if k >= 0:
        running = st.models[k].state == "ready"
    var chip = Badge(("model running · " + short_endpoint(st.endpoint_now())) if running else "start it to run cells", BADGE_OK if running else 0, dot=True)
    var head = SubHeader(model + ((" · " + nb.path) if nb.path != "" else String("")),
                         [chip^, SmallButton("Saved view" if nb.jupyter else "Run in Jupyter", NB_RUN, "book-open" if nb.jupyter else "play")], compact=phone, status=True)
    var items: List[View] = []
    if nb.problem != "":
        items.append(QuietText(nb.problem + " Fix: jupyter lab " + (nb.path if nb.path != "" else String("<notebook>.ipynb"))))
    if nb.starting:
        items.append(QuietText("Starting Jupyter… the first start takes a few seconds."))
    if nb.jupyter:
        # (Jupyter is another origin than the console's and needs its own cookies: allow-same-origin, which the host grants
        # only for another origin; scripts and forms are the default sandbox, D-606)
        items.append(WebFrame(nb.embed, nb.opened, QuietText("Jupyter opened in your browser: " + nb.url), height=0, open_url=nb.url,
                              sandbox="allow-same-origin allow-downloads").fill().grow())
        return TabBody(head^, items^, compact=phone).grow()
    if not nb.loaded:
        items.append(Card([CardHead("Building the notebook" if nb.error == "" else "Could not build the notebook"),
                           CardBody([QuietText(nb.error if nb.error != "" else "Reading the model's config and card from Hugging Face the first time, then it is saved for next time.")]),
                           CardFoot("mxc learn " + model)]))
        return TabBody(head^, items^, compact=phone)
    # chapters
    var sources = List[String]()
    var md = List[Bool]()
    for c in nb.cells:
        sources.append(c.source)
        md.append(not c.code)
    var chs = chapters(sources, md)
    var titles = List[String]()
    var levels = List[Int]()
    for c in chs:
        titles.append(c.title)
        levels.append(c.level)
    var cells: List[View] = []
    for c in nb.cells:
        cells.append(cell_view(c))
    var facts: List[View] = [SpecTitle(nb.arch)]
    var fact_keys = List[String]()
    var fact_values: List[View] = []
    for f in nb.facts:
        fact_keys.append(f[0])
        fact_values.append(FactText(f[1]))
    if len(fact_keys) > 0:
        facts.append(FactGrid(fact_keys, fact_values^, end=True, tight=True))
    var keys = List[String]()
    var values = List[String]()
    for r in nb.rows:
        keys.append(r.field)
        values.append(r.value)
    facts.append(SpecRows(keys, values))
    var aside = CardColumn([Card([CardHead("Architecture"), CardBody(facts^), CardFoot("read from the model's config", note=True)]),
                                Card([CardHead("Kernel"), CardBody([QuietText(nb.kernel)]), CardFoot("Run in Jupyter above to execute cells", note=True)]),
                                Card([CardHead("File"), CardBody([MonoLine(nb.path)]), CardFoot("mxc learn " + model)])])
    items.append(DocLayout(Outline("Chapters", titles, levels, NB_CHAPTER), CardColumn(cells^), aside^, compact=phone))
    return TabBody(head^, items^, compact=phone, flush=True).grow()
