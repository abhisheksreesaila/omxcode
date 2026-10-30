# mojoui.texttable: words read off pages become rows (goal 41 M7). A generic rows type for anything that reads text with
# a place: OCR on a document's pages, later captions or signs read off video frames. One row per word: the page (or
# frame) it is on, the text, its box and how sure the reader was.
#
#   var t = TextTable()
#   t.add(0, "Exceptions", Box(54.6, 301.6, 39.5, 9.3), 0.93)     # page, text, box (page points for documents), confidence
#   t.write_csv("words.csv")                                         # page,text,x,y,w,h,confidence (text quoted when needed)
#   var back = TextTable.read_csv("words.csv")                       # the same rows
#   t.on_page(0)                                                     # the rows of one page (indices)
#
# VideoTable keeps integer pixel boxes and an integer code per row; words need a String and sub-point boxes, so they get
# their own table rather than a text column bolted on (D-1144). The CSV is the bridge: the sheet (omxcore) reads it like
# any other table, so words can be queried and linked (page = frame, confidence = value).

from mojoui.pdfsource import Box


def csv_field(s: String) -> String:
    """A CSV field: quoted (with doubled quotes) when it holds a comma, a quote or a line break."""
    if s.find(",") < 0 and s.find("\"") < 0 and s.find("\n") < 0 and s.find("\r") < 0:
        return s
    return "\"" + s.replace("\"", "\"\"") + "\""


def csv_split(line: String) -> List[String]:
    """One CSV line's fields (quotes understood; a line break inside quotes isn't: rows are one line each here)."""
    var out = List[String]()
    var cur = String("")
    var quoted = False
    var bytes = line.as_bytes()
    var i = 0
    var n = len(bytes)
    while i < n:
        var c = bytes[i]
        if quoted:
            if c == UInt8(34):
                if i + 1 < n and bytes[i + 1] == UInt8(34):
                    cur += "\""
                    i += 1
                else:
                    quoted = False
            else:
                var j = i
                while j < n and bytes[j] != UInt8(34):
                    j += 1
                cur += String(line[byte=i:j])
                i = j - 1
        elif c == UInt8(34):
            quoted = True
        elif c == UInt8(44):
            out.append(cur)
            cur = String("")
        else:
            var j = i
            while j < n and bytes[j] != UInt8(44) and bytes[j] != UInt8(34):
                j += 1
            cur += String(line[byte=i:j])
            i = j - 1
        i += 1
    out.append(cur)
    return out^


def fixed(v: Float64, digits: Int = 2) -> String:
    """v with `digits` decimals (rounded half away from zero), no exponent."""
    var k = 1
    for _ in range(digits):
        k *= 10
    var neg = v < 0
    var m = Int(abs(v) * Float64(k) + 0.5)
    var s = String(m // k)
    if digits > 0:
        var frac = String(m % k)
        while frac.byte_length() < digits:
            frac = "0" + frac
        s += "." + frac
    return ("-" + s) if neg and m > 0 else s


struct TextTable(Movable, Sized):
    """Words as columns: page[i], text[i], x/y/w/h[i] (the box; page points for documents), confidence[i] (0..1)."""

    var page: List[Int]
    var text: List[String]
    var x: List[Float64]
    var y: List[Float64]
    var w: List[Float64]
    var h: List[Float64]
    var confidence: List[Float64]
    var seconds: Float64  # the reading's wall time (0: not measured)

    def __init__(out self):
        self.page = List[Int]()
        self.text = List[String]()
        self.x = List[Float64]()
        self.y = List[Float64]()
        self.w = List[Float64]()
        self.h = List[Float64]()
        self.confidence = List[Float64]()
        self.seconds = 0

    def __len__(self) -> Int:
        return len(self.text)

    def rows(self) -> Int:
        return len(self.text)

    def copy(self) -> TextTable:
        var out = TextTable()
        out.page = self.page.copy()
        out.text = self.text.copy()
        out.x = self.x.copy()
        out.y = self.y.copy()
        out.w = self.w.copy()
        out.h = self.h.copy()
        out.confidence = self.confidence.copy()
        out.seconds = self.seconds
        return out^

    def add(mut self, page: Int, text: String, box: Box, confidence: Float64):
        self.page.append(page)
        self.text.append(text)
        self.x.append(box.x)
        self.y.append(box.y)
        self.w.append(box.w)
        self.h.append(box.h)
        self.confidence.append(confidence)

    def append(mut self, other: TextTable):
        for i in range(other.rows()):
            self.add(other.page[i], other.text[i], other.box(i), other.confidence[i])

    def box(self, i: Int) -> Box:
        return Box(self.x[i], self.y[i], self.w[i], self.h[i])

    def on_page(self, page: Int) -> List[Int]:
        var out = List[Int]()
        for i in range(self.rows()):
            if self.page[i] == page:
                out.append(i)
        return out^

    def pages(self) -> Int:
        """One more than the highest page with a row (0 when empty)."""
        var top = -1
        for p in self.page:
            top = max(top, p)
        return top + 1

    def words(self) -> String:
        """Every word, space separated, in row order (what a search reads)."""
        var out = String("")
        for i in range(self.rows()):
            if i > 0:
                out += " "
            out += self.text[i]
        return out

    def csv(self) -> String:
        var out = String("page,text,x,y,w,h,confidence\n")
        for i in range(self.rows()):
            out += String(self.page[i]) + "," + csv_field(self.text[i]) + "," + fixed(self.x[i]) + "," + fixed(self.y[i]) + ","
            out += fixed(self.w[i]) + "," + fixed(self.h[i]) + "," + fixed(self.confidence[i], 3) + "\n"
        return out

    def write_csv(self, path: String) raises:
        with open(path, "w") as f:
            f.write(self.csv())

    @staticmethod
    def read_csv(path: String) raises -> TextTable:
        """A table written by write_csv (columns found by name, so extra columns are ignored)."""
        var out = TextTable()
        var body: String
        with open(path, "r") as f:
            body = f.read()
        var lines = body.split("\n")
        if len(lines) == 0:
            return out^
        var head = csv_split(String(lines[0]))
        var col = List[Int](length=7, fill=-1)
        var names: List[String] = ["page", "text", "x", "y", "w", "h", "confidence"]
        for k in range(len(names)):
            for j in range(len(head)):
                if head[j] == names[k]:
                    col[k] = j
        for k in range(7):
            if col[k] < 0:
                raise Error("TextTable.read_csv: " + path + " has no column " + names[k])
        for li in range(1, len(lines)):
            var line = String(lines[li])
            if line.byte_length() == 0:
                continue
            var f = csv_split(line)
            out.add(Int(f[col[0]]), f[col[1]], Box(Float64(f[col[2]]), Float64(f[col[3]]), Float64(f[col[4]]), Float64(f[col[5]])),
                    Float64(f[col[6]]))
        return out^
