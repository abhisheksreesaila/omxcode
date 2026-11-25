# The text a JSON Canvas board was read from, kept with it (review 3, MUST 5): where each node and edge is in it, so a save
# writes back what wasn't edited as it was: node kinds and keys this program knows nothing of, edge labels and sides, the
# order, the other top-level members, every number as spelled (mojoui.objectlayer.export_json_canvas).
from mojoui.jsonedit import members, elements, find_member
from mojoui.shared import serial


struct CanvasSource(Copyable, Movable):
    var ok: Bool
    var id: Int  # (a serial: an object knows which source it came from)
    var text: String
    var ns: List[Int]  # node i's text [ns, ne)
    var ne: List[Int]
    var es: List[Int]  # edge i's
    var ee: List[Int]
    var nodes_at: Int  # the "nodes" array's value [nodes_at, nodes_end), the "edges" one (-1: the document has none)
    var nodes_end: Int
    var edges_at: Int
    var edges_end: Int
    var columns: Int  # the page grid the text says (0: not looked up yet)
    var rows: Int

    def __init__(out self):
        self.ok = False
        self.id = 0
        self.text = ""
        self.ns = List[Int]()
        self.ne = List[Int]()
        self.es = List[Int]()
        self.ee = List[Int]()
        self.nodes_at = -1
        self.nodes_end = -1
        self.edges_at = -1
        self.edges_end = -1
        self.columns = 0
        self.rows = 0

    @staticmethod
    def of(text: String) -> CanvasSource:
        """The source of a canvas document's text (not ok when it has no "nodes" array)."""
        var out = CanvasSource()
        try:
            var ms = members(text, 0, text.byte_length())
            var n = find_member(ms, "nodes")
            var e = find_member(ms, "edges")
            if n < 0:
                return out^
            for s in elements(text, ms[n].start, ms[n].end):
                out.ns.append(s.start)
                out.ne.append(s.end)
            out.nodes_at = ms[n].start
            out.nodes_end = ms[n].end
            if e >= 0 and text.as_bytes()[ms[e].start] == 91:
                for s in elements(text, ms[e].start, ms[e].end):
                    out.es.append(s.start)
                    out.ee.append(s.end)
                out.edges_at = ms[e].start
                out.edges_end = ms[e].end
            elif e >= 0:  # (an "edges" that isn't an array: replaced only when there is an edge to write)
                out.edges_at = ms[e].start
                out.edges_end = ms[e].end
        except:
            return CanvasSource()
        out.text = text
        out.id = serial()
        out.ok = True
        return out^

    def node(self, i: Int) -> String:
        return String(self.text[byte=self.ns[i]:self.ne[i]])

    def edge(self, i: Int) -> String:
        return String(self.text[byte=self.es[i]:self.ee[i]])


def undecorated(text: String) -> String:
    """The document without the names of the pictures an app derives from its own objects ("file": "media/", 64 hex digits and
    .svg, of a node that isn't an image): what a person made, the same before and after a web app has put them in. Text without any
    comes back as it is."""
    var key = String('"file":')
    var b = text.as_bytes()
    var n = len(b)
    var out = String("")
    var at = 0  # (copied up to here)
    var i = 0
    while True:
        var f = text.find(key, i)
        if f < 0:
            break
        var q = f + key.byte_length()
        while q < n and (b[q] == 32 or b[q] == 10 or b[q] == 13 or b[q] == 9):
            q += 1
        i = q
        if q >= n or b[q] != 34:
            continue
        var h = q + 1  # (where the name's digits begin)
        if h + 6 <= n and b[h] == 109 and b[h + 1] == 101 and b[h + 2] == 100 and b[h + 3] == 105 and b[h + 4] == 97 and b[h + 5] == 47:  # media/
            h += 6
        if h + 69 > n:
            continue
        var hexes = True
        for k in range(h, h + 64):
            var c = Int(b[k])
            if not (48 <= c <= 57 or 97 <= c <= 102):
                hexes = False
                break
        if not hexes or String(text[byte = h + 64 : h + 69]) != '.svg"':
            continue
        # (whose node it is: its pn's type comes right after it, as both apps write it; an image's file is the person's)
        var end = h + 69
        var rest = String(text[byte = end : min(n, end + 40)])
        if rest.replace(" ", "").startswith(',"pn":{"type":"image"') or not rest.replace(" ", "").startswith(',"pn":{"type":'):
            continue
        out += String(text[byte=at:q]) + '""'
        at = end
        i = at
    if at == 0:
        return text
    out += String(text[byte=at:n])
    return out^
