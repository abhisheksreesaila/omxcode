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
