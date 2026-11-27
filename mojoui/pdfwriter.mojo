# mojoui.pdfwriter (goal 82 M4): a vector PDF from anything that paints through a Painter. Shapes stay paths, text stays text (each
# glyph drawn from its font's own outline at the weight asked for, with a ToUnicode map: a reader finds and copies the words),
# pictures are compressed images. No browser, no print-to-PDF of pixels: what the app draws on screen, drawn again on paper.
#
#   var pdf = PdfPainter()
#   pdf.page(645, 810)                    # a page in points; what follows is drawn on it in layout px (0.75 pt each)
#   look.paint_obj(pdf, layer, i) …       # any Painter code
#   pdf.save("/tmp/note.pdf")             # raises when it can't be written
#
# How: one Type 3 font per face instance (up to 255 glyphs each, more fonts as needed): its glyphs' procedures are the outlines
# mojoui.fonttext reads (FreeType on Linux, CoreText on the Mac), so a variable face prints at the weight the screen shows.
# Colour: DeviceRGB; alpha through ExtGState. Painter calls a PDF can't mean (layers kept as tiles, kept ops) do nothing; a
# layer's transform is a `cm`. Shadows are left out (paper has none); a colour glyph (emoji) has no outline and is left out.

from std.collections import Dict
from mojoui.scene import Painter, KeptOps
from mojoui.bitmap import Bitmap, make_bitmap
from mojoui.fonttext import TextStyle, shape, run_x, engine, ALIGN_LEFT
from mojoui.text import Font
from mojoui.zlibc import zlib_compress
from mojoui.clock import now_ns

comptime PT_PER_PX = 0.75  # CSS: 96 px to the inch, PDF: 72 points


def _num(v: Float64) -> String:
    """A number as PDF writes it: at most 3 decimals, no exponent."""
    var neg = v < 0
    var a = -v if neg else v
    var whole = Int(a)
    var frac = Int((a - Float64(whole)) * 1000 + 0.5)
    if frac >= 1000:
        whole += 1
        frac -= 1000
    var out = ("-" if neg and (whole > 0 or frac > 0) else "") + String(whole)
    if frac > 0:
        var f = String(frac)
        while f.byte_length() < 3:
            f = "0" + f
        while f.endswith("0"):
            var shorter = String(f[byte=0:f.byte_length() - 1])
            f = shorter
        out += "." + f
    return out^


def _rgb(c: UInt32) -> String:
    return _num(Float64(Int(c & 0xFF)) / 255.0) + " " + _num(Float64(Int((c >> 8) & 0xFF)) / 255.0) + " " + _num(Float64(Int((c >> 16) & 0xFF)) / 255.0)


def _hex4(v: Int) -> String:
    var d = "0123456789ABCDEF"
    var out = String("")
    for sh in [12, 8, 4, 0]:
        var n = (v >> sh) & 0xF
        out += String(d[byte=n:n + 1])
    return out^


def _utf16_hex(text: String) -> String:
    var out = String("")
    for c in text.codepoints():
        var cp = Int(c.to_u32())
        if cp >= 0x10000:
            var v = cp - 0x10000
            out += _hex4(0xD800 + (v >> 10)) + _hex4(0xDC00 + (v & 0x3FF))
        else:
            out += _hex4(cp)
    return out^


struct _T3(Movable):
    """A Type 3 font: one face instance's glyphs (code 1..255 → glyph id), their widths, outlines and words."""
    var inst: Int
    var upem: Int
    var gids: List[Int]
    var code_of: Dict[Int, Int]
    var widths: List[Float64]
    var procs: List[String]
    var words: List[String]

    def __init__(out self, inst: Int, upem: Int):
        self.inst = inst
        self.upem = upem
        self.gids = List[Int]()
        self.code_of = Dict[Int, Int]()
        self.widths = List[Float64]()
        self.procs = List[String]()
        self.words = List[String]()


struct _Image(Movable):
    var w: Int
    var h: Int
    var rgb: List[UInt8]
    var alpha: List[UInt8]  # empty: opaque

    def __init__(out self, w: Int, h: Int, var rgb: List[UInt8], var alpha: List[UInt8]):
        self.w = w
        self.h = h
        self.rgb = rgb^
        self.alpha = alpha^


struct PdfPainter(Painter, Movable):
    var pages: List[String]  # content streams
    var sizes: List[Float64]  # w, h per page (points)
    var fonts: List[_T3]
    var font_now: Dict[Int, Int]  # instance → its font that still has room
    var images: List[_Image]
    var image_of: Dict[UInt64, Int]  # a bitmap's hash → its image
    var alphas: List[Int]  # alpha (0..1000) per ExtGState
    var used_fonts: List[List[Int]]  # per page
    var used_images: List[List[Int]]
    var used_alphas: List[List[Int]]
    var cur: String
    var in_layer: Bool  # a layer's q is open
    var clips: Int  # clips pushed in this layer
    var words: List[String]  # every run drawn (tests read what the PDF should hold)

    def __init__(out self):
        self.pages = List[String]()
        self.sizes = List[Float64]()
        self.fonts = List[_T3]()
        self.font_now = Dict[Int, Int]()
        self.images = List[_Image]()
        self.image_of = Dict[UInt64, Int]()
        self.alphas = List[Int]()
        self.used_fonts = List[List[Int]]()
        self.used_images = List[List[Int]]()
        self.used_alphas = List[List[Int]]()
        self.cur = ""
        self.in_layer = False
        self.clips = 0
        self.words = List[String]()

    # ---------------------------------------------------------------- pages

    def page(mut self, w_pt: Float64, h_pt: Float64):
        """A new page w × h points; drawing goes to it in layout px (PT_PER_PX each), y down from its top."""
        self._end_page()
        self.sizes.append(w_pt)
        self.sizes.append(h_pt)
        self.used_fonts.append(List[Int]())
        self.used_images.append(List[Int]())
        self.used_alphas.append(List[Int]())
        self.cur = _num(PT_PER_PX) + " 0 0 " + _num(-PT_PER_PX) + " 0 " + _num(h_pt) + " cm\n"
        self.in_layer = False
        self.clips = 0

    def _end_page(mut self):
        if len(self.sizes) // 2 > len(self.pages):
            self._close_layer()
            self.pages.append(self.cur)
            self.cur = ""

    def _close_layer(mut self):
        while self.clips > 0:
            self.cur += "Q\n"
            self.clips -= 1
        if self.in_layer:
            self.cur += "Q\n"
            self.in_layer = False

    def _page_i(self) -> Int:
        return len(self.sizes) // 2 - 1

    def _fill(mut self, color: UInt32):
        var a = Int((color >> 24) & 0xFF)
        self.cur += _rgb(color) + " rg\n"
        self._alpha(a)

    def _stroke_color(mut self, color: UInt32):
        var a = Int((color >> 24) & 0xFF)
        self.cur += _rgb(color) + " RG\n"
        self._alpha(a)

    def _alpha(mut self, a8: Int):
        var milli = (a8 * 1000 + 127) // 255
        var k = -1
        for i in range(len(self.alphas)):
            if self.alphas[i] == milli:
                k = i
        if k < 0:
            self.alphas.append(milli)
            k = len(self.alphas) - 1
        var pi = self._page_i()
        if pi >= 0 and not (k in self.used_alphas[pi]):
            self.used_alphas[pi].append(k)
        self.cur += "/A" + String(k) + " gs\n"

    # ---------------------------------------------------------------- Painter

    def width(self) -> Int:
        return Int(self.sizes[len(self.sizes) - 2] / PT_PER_PX) if len(self.sizes) >= 2 else 0

    def height(self) -> Int:
        return Int(self.sizes[len(self.sizes) - 1] / PT_PER_PX) if len(self.sizes) >= 2 else 0

    def scale(self) -> Float64:
        return 1.0

    def still(self) -> Bool:
        return True

    def set_again(mut self):
        pass

    def time_ns(self) -> Int:
        return Int(now_ns())

    def begin_layer(mut self, key: String):
        self._close_layer()

    def layer_version(mut self, version: Int):
        pass

    def layer_transform(mut self, dx: Float64, dy: Float64, k: Float64):
        self._close_layer()
        self.cur += "q " + _num(k) + " 0 0 " + _num(k) + " " + _num(dx) + " " + _num(dy) + " cm\n"
        self.in_layer = True

    def layer_tiles(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        pass

    def layer_damage(mut self, since: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        pass

    def layer_ops_version(mut self, v: Int):
        pass

    def ops_mark(self) -> Int:
        return -1

    def ops_capture(mut self, from_op: Int) -> KeptOps:
        return KeptOps()

    def ops_replay_range(mut self, kept: KeptOps, a: Int, b: Int) -> Bool:
        return False

    def ops_replay(mut self, kept: KeptOps) -> Bool:
        return False

    def layer_snapshot(mut self, path: String, tag: String, hold: Bool, note: String):
        pass

    def push_clip(mut self, x: Float64, y: Float64, w: Float64, h: Float64):
        self.cur += "q " + _num(x) + " " + _num(y) + " " + _num(w) + " " + _num(h) + " re W n\n"
        self.clips += 1

    def pop_clip(mut self):
        if self.clips > 0:
            self.cur += "Q\n"
            self.clips -= 1

    def image(mut self, pixels: List[UInt32], pw: Int, ph: Int, x: Float64, y: Float64, w: Float64, h: Float64, smooth: Bool = True):
        if pw <= 0 or ph <= 0 or len(pixels) < pw * ph:
            return
        self.bitmap(make_bitmap(pixels.copy(), pw, ph), x, y, w, h, smooth)

    def bitmap(mut self, b: Bitmap, x: Float64, y: Float64, w: Float64, h: Float64, smooth: Bool = True):
        var key = b[].hash
        var k = self.image_of.get(key, -1)
        if k < 0:
            var n = b[].w * b[].h
            var rgb = List[UInt8](capacity=n * 3)
            var alpha = List[UInt8]()
            ref px = b[].levels[0]
            for i in range(n):
                var p = px[i]
                rgb.append(UInt8(p & 0xFF))
                rgb.append(UInt8((p >> 8) & 0xFF))
                rgb.append(UInt8((p >> 16) & 0xFF))
            if not b[].opaque:
                alpha = List[UInt8](capacity=n)
                for i in range(n):
                    alpha.append(UInt8((px[i] >> 24) & 0xFF))
            self.images.append(_Image(b[].w, b[].h, rgb^, alpha^))
            k = len(self.images) - 1
            self.image_of[key] = k
        var pi = self._page_i()
        if pi >= 0 and not (k in self.used_images[pi]):
            self.used_images[pi].append(k)
        self.cur += "q /A" + String(self._alpha_index(1000)) + " gs " + _num(w) + " 0 0 " + _num(-h) + " " + _num(x) + " " + _num(y + h) + " cm /I" + String(k) + " Do Q\n"

    def _alpha_index(mut self, milli: Int) -> Int:
        for i in range(len(self.alphas)):
            if self.alphas[i] == milli:
                var pi = self._page_i()
                if pi >= 0 and not (i in self.used_alphas[pi]):
                    self.used_alphas[pi].append(i)
                return i
        self.alphas.append(milli)
        var pi = self._page_i()
        if pi >= 0:
            self.used_alphas[pi].append(len(self.alphas) - 1)
        return len(self.alphas) - 1

    def note(mut self, meaning: String):
        pass

    def fill(mut self, color: UInt32):
        self._fill(color)
        self.cur += "-100000 -100000 200000 200000 re f\n"

    def _round_rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, tl: Float64, tr: Float64, br: Float64, bl: Float64):
        comptime K = 0.5522847498
        var m = min(w, h) / 2
        var a = min(tl, m)
        var b = min(tr, m)
        var c = min(br, m)
        var d = min(bl, m)
        var s = _num(x + a) + " " + _num(y) + " m\n"
        s += _num(x + w - b) + " " + _num(y) + " l\n"
        if b > 0:
            s += _num(x + w - b + b * K) + " " + _num(y) + " " + _num(x + w) + " " + _num(y + b - b * K) + " " + _num(x + w) + " " + _num(y + b) + " c\n"
        s += _num(x + w) + " " + _num(y + h - c) + " l\n"
        if c > 0:
            s += _num(x + w) + " " + _num(y + h - c + c * K) + " " + _num(x + w - c + c * K) + " " + _num(y + h) + " " + _num(x + w - c) + " " + _num(y + h) + " c\n"
        s += _num(x + d) + " " + _num(y + h) + " l\n"
        if d > 0:
            s += _num(x + d - d * K) + " " + _num(y + h) + " " + _num(x) + " " + _num(y + h - d + d * K) + " " + _num(x) + " " + _num(y + h - d) + " c\n"
        s += _num(x) + " " + _num(y + a) + " l\n"
        if a > 0:
            s += _num(x) + " " + _num(y + a - a * K) + " " + _num(x + a - a * K) + " " + _num(y) + " " + _num(x + a) + " " + _num(y) + " c\n"
        self.cur += s + "h f\n"

    def rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64):
        if (color >> 24) == 0 or w <= 0 or h <= 0:
            return
        self._fill(color)
        if radius <= 0:
            self.cur += _num(x) + " " + _num(y) + " " + _num(w) + " " + _num(h) + " re f\n"
        else:
            self._round_rect(x, y, w, h, radius, radius, radius, radius)

    def shadow(mut self, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, blur: Float64, color: UInt32):
        pass

    def rect_hole(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64, hole: Float64):
        self.rect(x, y, w, h, color, radius)

    def rect_hole_corner(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64, hole: Float64, br: Float64):
        self.rect_corner(x, y, w, h, color, radius, br)

    def rect_corner(mut self, x: Float64, y: Float64, w: Float64, h: Float64, color: UInt32, radius: Float64, br: Float64):
        if (color >> 24) == 0:
            return
        self._fill(color)
        self._round_rect(x, y, w, h, radius, radius, br, radius)

    def line(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, color: UInt32):
        if (color >> 24) == 0:
            return
        self._stroke_color(color)
        self.cur += "0 J " + _num(width) + " w " + _num(x0) + " " + _num(y0) + " m " + _num(x1) + " " + _num(y1) + " l S\n"

    def circle(mut self, x: Float64, y: Float64, radius: Float64, color: UInt32):
        if (color >> 24) == 0 or radius <= 0:
            return
        self._fill(color)
        self._round_rect(x - radius, y - radius, 2 * radius, 2 * radius, radius, radius, radius, radius)

    def polygon(mut self, pts: List[Float64], color: UInt32):
        if len(pts) < 6 or (color >> 24) == 0:
            return
        self._fill(color)
        var s = _num(pts[0]) + " " + _num(pts[1]) + " m\n"
        for i in range(2, len(pts) - 1, 2):
            s += _num(pts[i]) + " " + _num(pts[i + 1]) + " l\n"
        self.cur += s + "h f\n"

    def stroke(mut self, pts: List[Float64], width: Float64, color: UInt32):
        if len(pts) < 2 or (color >> 24) == 0:
            return
        self._stroke_color(color)
        var s = "1 J 1 j " + _num(width) + " w " + _num(pts[0]) + " " + _num(pts[1]) + " m\n"
        if len(pts) == 2:
            s += _num(pts[0]) + " " + _num(pts[1]) + " l\n"
        for i in range(2, len(pts) - 1, 2):
            s += _num(pts[i]) + " " + _num(pts[i + 1]) + " l\n"
        self.cur += s + "S\n"

    def text(mut self, font: Font, text: String, x: Float64, baseline: Float64, size: Float64, color: UInt32, weight: Int, align: Int,
             slant: Float64):
        self.run(TextStyle("Geist", weight, slant != 0, size), text, x, baseline, color, align)

    def run(mut self, st: TextStyle, text: String, x: Float64, baseline: Float64, color: UInt32, align: Int):
        if text == "" or (color >> 24) == 0:
            return
        var r = shape(st, text)
        var x0 = run_x(r, x, align)
        self.words.append(text)
        var e = engine()
        var tb = text.as_bytes()
        self._fill(color)
        var s = String("BT\n")
        var last_font = -1
        for gi in range(len(r.glyphs)):
            ref g = r.glyphs[gi]
            # the words this glyph stands for: from its cluster to the next cluster after it (a ligature's whole letters)
            var a = g.cluster
            var b = len(tb)
            for gj in range(len(r.glyphs)):
                var c = r.glyphs[gj].cluster
                if c > a and c < b:
                    b = c
            var words = String(text[byte=a:b]) if a >= 0 and a < b and b <= len(tb) else String("")
            var fc = self._code(g.inst, g.gid, words)
            if fc[0] != last_font:
                s += "/F" + String(fc[0]) + " " + _num(r.size) + " Tf\n"
                last_font = fc[0]
            s += "1 0 0 -1 " + _num(x0 + g.x) + " " + _num(baseline - g.y) + " Tm <" + String(_hex4(fc[1])[byte=2:]) + "> Tj\n"
        _ = e
        self.cur += s + "ET\n"

    def _code(mut self, inst: Int, gid: Int, words: String) -> Tuple[Int, Int]:
        """The font and code that draw glyph `gid` of instance `inst` (added, with its outline, the first time)."""
        var e = engine()
        var f = self.font_now.get(inst, -1)
        if f >= 0:
            var c = self.fonts[f].code_of.get(gid, -1)
            if c >= 0:
                return (f, c)
            # (the same glyph may be in an older, full font of this instance)
        for k in range(len(self.fonts)):
            if self.fonts[k].inst == inst:
                var c = self.fonts[k].code_of.get(gid, -1)
                if c >= 0:
                    return (k, c)
        if f < 0 or len(self.fonts[f].gids) >= 255:
            var upem = e[].faces[e[].insts[inst].face].upem
            self.fonts.append(_T3(inst, upem))
            f = len(self.fonts) - 1
            self.font_now[inst] = f
        ref t = self.fonts[f]
        var code = len(t.gids) + 1
        t.gids.append(gid)
        t.code_of[gid] = code
        var adv = Float64(e[].advance_units(inst, gid))
        t.widths.append(adv)
        t.words.append(words)
        var ol = e[].glyph_outline(inst, gid)
        var x0 = 0.0
        var y0 = 0.0
        var x1 = 0.0
        var y1 = 0.0
        var path = String("")
        var i = 0
        var first = True
        while i < len(ol):
            var op = Int(ol[i])
            var n = 2 if op == 0 or op == 1 else (6 if op == 2 else 0)
            for q in range(0, n, 2):
                var px = ol[i + 1 + q]
                var py = ol[i + 2 + q]
                if first:
                    x0 = px
                    x1 = px
                    y0 = py
                    y1 = py
                    first = False
                x0 = min(x0, px)
                x1 = max(x1, px)
                y0 = min(y0, py)
                y1 = max(y1, py)
            if op == 0:
                path += _num(ol[i + 1]) + " " + _num(ol[i + 2]) + " m\n"
            elif op == 1:
                path += _num(ol[i + 1]) + " " + _num(ol[i + 2]) + " l\n"
            elif op == 2:
                path += _num(ol[i + 1]) + " " + _num(ol[i + 2]) + " " + _num(ol[i + 3]) + " " + _num(ol[i + 4]) + " " + _num(ol[i + 5]) + " " + _num(ol[i + 6]) + " c\n"
            else:
                path += "h\n"
            i += 1 + n
        t.procs.append(_num(adv) + " 0 " + _num(x0) + " " + _num(y0) + " " + _num(x1) + " " + _num(y1) + " d1\n" + (path + "f\n" if path != "" else String("")))
        var pi = self._page_i()
        if pi >= 0 and not (f in self.used_fonts[pi]):
            self.used_fonts[pi].append(f)
        return (f, code)

    # ---------------------------------------------------------------- the file

    def bytes(mut self) -> List[UInt8]:
        """The whole PDF."""
        self._end_page()
        var objs = List[List[UInt8]]()  # object n is objs[n - 1]
        var npages = len(self.pages)
        # 1 catalog, 2 pages; then per page: page, content; then fonts (font, tounicode, procs...), images, extgstates
        objs.append(List[UInt8]())
        objs.append(List[UInt8]())
        var font_obj = List[Int]()
        var font_start = 3 + 2 * npages
        var next = font_start
        var proc_obj = List[List[Int]]()
        for t_i in range(len(self.fonts)):
            font_obj.append(next)
            next += 2  # font, ToUnicode
            var ps = List[Int]()
            for _ in range(len(self.fonts[t_i].gids)):
                ps.append(next)
                next += 1
            proc_obj.append(ps^)
        var img_obj = List[Int]()
        for i_i in range(len(self.images)):
            img_obj.append(next)
            next += 2 if len(self.images[i_i].alpha) > 0 else 1
        var gs_obj = next
        var total = gs_obj + len(self.alphas) - 1
        for _ in range(total - 2):
            objs.append(List[UInt8]())
        # pages
        var kids = String("")
        for p in range(npages):
            var pobj = 3 + 2 * p
            kids += String(pobj) + " 0 R "
            var res = "<< /ProcSet [/PDF /Text /ImageB /ImageC /ImageI]"
            if len(self.used_fonts[p]) > 0:
                res += " /Font <<"
                for f in self.used_fonts[p]:
                    res += " /F" + String(f) + " " + String(font_obj[f]) + " 0 R"
                res += " >>"
            if len(self.used_images[p]) > 0:
                res += " /XObject <<"
                for k in self.used_images[p]:
                    res += " /I" + String(k) + " " + String(img_obj[k]) + " 0 R"
                res += " >>"
            if len(self.used_alphas[p]) > 0:
                res += " /ExtGState <<"
                for k in self.used_alphas[p]:
                    res += " /A" + String(k) + " " + String(gs_obj + k) + " 0 R"
                res += " >>"
            res += " >>"
            objs[pobj - 1] = _ascii("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + _num(self.sizes[2 * p]) + " " + _num(self.sizes[2 * p + 1]) + "] /Resources " + res
                                   + " /Contents " + String(pobj + 1) + " 0 R >>")
            objs[pobj] = _stream(self.pages[p].as_bytes(), "")
        objs[0] = _ascii("<< /Type /Catalog /Pages 2 0 R >>")
        objs[1] = _ascii("<< /Type /Pages /Kids [" + kids + "] /Count " + String(npages) + " >>")
        for fi in range(len(self.fonts)):
            ref t = self.fonts[fi]
            var n = len(t.gids)
            var procs = String("")
            var diffs = String("[1")
            var widths = String("[")
            for c in range(n):
                procs += " /g" + String(c + 1) + " " + String(proc_obj[fi][c]) + " 0 R"
                diffs += " /g" + String(c + 1)
                widths += " " + _num(t.widths[c])
                objs[proc_obj[fi][c] - 1] = _stream(t.procs[c].as_bytes(), "")
            var sc = 1.0 / Float64(t.upem)
            objs[font_obj[fi] - 1] = _ascii("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 0 0] /FontMatrix [" + _num6(sc) + " 0 0 " + _num6(sc) + " 0 0] /CharProcs <<" + procs
                                         + " >> /Encoding << /Type /Encoding /Differences " + diffs + "] >> /FirstChar 1 /LastChar " + String(n) + " /Widths " + widths
                                         + "] /Resources << >> /ToUnicode " + String(font_obj[fi] + 1) + " 0 R >>")
            var cmap = String("/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def /CMapName /Adobe-Identity-UCS def /CMapType 2 def 1 begincodespacerange <01> <FF> endcodespacerange\n")
            var lines = List[String]()
            for c in range(n):
                if t.words[c] != "":
                    lines.append("<" + String(_hex4(c + 1)[byte=2:]) + "> <" + _utf16_hex(t.words[c]) + ">")
            var at = 0
            while at < len(lines):
                var m = min(100, len(lines) - at)
                cmap += String(m) + " beginbfchar\n"
                for q in range(at, at + m):
                    cmap += lines[q] + "\n"
                cmap += "endbfchar\n"
                at += m
            cmap += "endcmap CMapName currentdict /CMap defineresource pop end end\n"
            objs[font_obj[fi]] = _stream(cmap.as_bytes(), "")
        for k in range(len(self.images)):
            ref im = self.images[k]
            var smask = String("")
            if len(im.alpha) > 0:
                smask = " /SMask " + String(img_obj[k] + 1) + " 0 R"
                objs[img_obj[k]] = _stream(Span(im.alpha), "/Type /XObject /Subtype /Image /Width " + String(im.w) + " /Height " + String(im.h) + " /ColorSpace /DeviceGray /BitsPerComponent 8")
            objs[img_obj[k] - 1] = _stream(Span(im.rgb), "/Type /XObject /Subtype /Image /Width " + String(im.w) + " /Height " + String(im.h) + " /ColorSpace /DeviceRGB /BitsPerComponent 8" + smask)
        for k in range(len(self.alphas)):
            var a = _num(Float64(self.alphas[k]) / 1000.0)
            objs[gs_obj + k - 1] = _ascii("<< /Type /ExtGState /ca " + a + " /CA " + a + " >>")
        var out = List[UInt8]()
        _put(out, "%PDF-1.4\n")
        for b in [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]:  # (a comment of high bytes: the file is binary)
            out.append(UInt8(b))
        var offsets = List[Int]()
        for n in range(len(objs)):
            offsets.append(len(out))
            _put(out, String(n + 1) + " 0 obj\n")
            for b in objs[n]:
                out.append(b)
            _put(out, "\nendobj\n")
        var xref = len(out)
        _put(out, "xref\n0 " + String(len(objs) + 1) + "\n0000000000 65535 f \n")
        for o in offsets:
            var s = String(o)
            while s.byte_length() < 10:
                s = "0" + s
            _put(out, s + " 00000 n \n")
        _put(out, "trailer\n<< /Size " + String(len(objs) + 1) + " /Root 1 0 R >>\nstartxref\n" + String(xref) + "\n%%EOF\n")
        return out^

    def save(mut self, path: String) raises:
        var b = self.bytes()
        with open(path, "w") as f:
            f.write_bytes(Span(b))


def _num6(v: Float64) -> String:
    """A small number with six decimals (a font matrix's 1/2048)."""
    var a = Int(v * 1_000_000 + 0.5)
    var s = String(a)
    while s.byte_length() < 7:
        s = "0" + s
    return String(s[byte=0:s.byte_length() - 6]) + "." + String(s[byte=s.byte_length() - 6:])


def _put(mut out: List[UInt8], s: String):
    for b in s.as_bytes():
        out.append(b)


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    for b in s.as_bytes():
        out.append(b)
    return out^


def _stream(data: Span[UInt8, _], dict_entries: String) -> List[UInt8]:
    """A stream object's body: Flate-compressed when the system has zlib."""
    var raw = List[UInt8](capacity=len(data))
    for b in data:
        raw.append(b)
    var z = zlib_compress(raw, 6)
    var out = List[UInt8]()
    if len(z) > 0:
        _put(out, "<< " + dict_entries + " /Length " + String(len(z)) + " /Filter /FlateDecode >>\nstream\n")
        for b in z:
            out.append(b)
    else:
        _put(out, "<< " + dict_entries + " /Length " + String(len(raw)) + " >>\nstream\n")
        for b in raw:
            out.append(b)
    _put(out, "\nendstream")
    return out^
