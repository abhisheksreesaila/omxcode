# Text on canvases: anti-aliased glyphs from atlases baked from Inter and JetBrains Mono (mojoui/font_data.mojo,
# made by scripts/bake_font.py). The same pixels on every platform.
#
#   var font = Font()                                   # once (decodes the atlases)
#   font.draw(surface, "Revenue", x, baseline, 13 * surface.scale, rgba(36, 36, 36))
#   var w = font.measure("Revenue", 13 * surface.scale)

from mojoui.canvas import Surface
from mojoui.font_data import (
    REGULAR_SIZE, REGULAR_ASCENT, REGULAR_DESCENT, REGULAR_WIDTH, REGULAR_HEIGHT, REGULAR_TABLE, REGULAR_ATLAS,
    MEDIUM_SIZE, MEDIUM_ASCENT, MEDIUM_DESCENT, MEDIUM_WIDTH, MEDIUM_HEIGHT, MEDIUM_TABLE, MEDIUM_ATLAS,
    MONO_SIZE, MONO_ASCENT, MONO_DESCENT, MONO_WIDTH, MONO_HEIGHT, MONO_TABLE, MONO_ATLAS,
    MONO_BOLD_SIZE, MONO_BOLD_ASCENT, MONO_BOLD_DESCENT, MONO_BOLD_WIDTH, MONO_BOLD_HEIGHT, MONO_BOLD_TABLE, MONO_BOLD_ATLAS,
    DISPLAY_SIZE, DISPLAY_ASCENT, DISPLAY_DESCENT, DISPLAY_WIDTH, DISPLAY_HEIGHT, DISPLAY_TABLE, DISPLAY_ATLAS,
)

comptime REGULAR = 0
comptime MEDIUM = 1
comptime MONO = 2  # JetBrains Mono (figures and code)
comptime MONO_BOLD = 3
comptime LEFT = 0
comptime CENTRE = 1
comptime RIGHT = 2


def base64_decode(text: String) -> List[UInt8]:
    var out = List[UInt8](capacity=text.byte_length() * 3 // 4)
    var bits = 0
    var count = 0
    for b in text.as_bytes():
        var c = Int(b)
        var v: Int
        if 65 <= c <= 90:
            v = c - 65
        elif 97 <= c <= 122:
            v = c - 71
        elif 48 <= c <= 57:
            v = c + 4
        elif c == 43:
            v = 62
        elif c == 47:
            v = 63
        else:
            continue  # padding
        bits = (bits << 6) | v
        count += 6
        if count >= 8:
            count -= 8
            out.append(UInt8((bits >> count) & 0xFF))
    return out^


@fieldwise_init
struct Glyph(Copyable, Movable):
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var left: Int  # from the pen position to the glyph's left edge
    var top: Int  # from the baseline to the glyph's top (negative: above)
    var advance: Float64


def base_letter(code: Int) -> Int:
    """The unaccented ASCII letter of a Latin-1 or Latin Extended-A letter (é → e, Ç → C, ł → l), 0 if none."""
    if code >= 0xC0 and code <= 0xFF:
        var map = String("AAAAAAACEEEEIIIIDNOOOOO*OUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty")
        var c = Int(map.as_bytes()[code - 0xC0])
        return 0 if c == 42 or c == 47 else c
    if code >= 0x100 and code <= 0x17F:
        var ext = String("AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiJjJjKkkLlLlLlLlLlNnNnNnnNnOoOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs")
        var i = code - 0x100
        return Int(ext.as_bytes()[i]) if i < ext.byte_length() else 0
    return 0


struct Face(Movable):
    """One baked font at one pixel size."""

    var size: Float64
    var ascent: Float64
    var descent: Float64
    var width: Int
    var atlas: List[UInt8]
    var codes: List[Int]
    var glyphs: List[Glyph]
    var ascii: List[Int]  # glyph index for codepoints 0–127 (-1: none)

    def __init__(out self, size: Int, ascent: Int, descent: Int, width: Int, table: String, atlas: String):
        self.size = Float64(size)
        self.ascent = Float64(ascent)
        self.descent = Float64(descent)
        self.width = width
        self.atlas = base64_decode(atlas)
        self.codes = List[Int]()
        self.glyphs = List[Glyph]()
        self.ascii = List[Int](length=128, fill=-1)
        for entry in table.split(";"):
            var f = String(entry).split(",")
            try:
                var code = Int(String(f[0]))
                if code < 128:
                    self.ascii[code] = len(self.glyphs)
                self.codes.append(code)
                self.glyphs.append(Glyph(Int(String(f[1])), Int(String(f[2])), Int(String(f[3])), Int(String(f[4])),
                                         Int(String(f[5])), Int(String(f[6])), Float64(Int(String(f[7]))) / 64.0))
            except:
                pass

    def find(self, code: Int) -> Int:
        if code < 128:
            return self.ascii[code]
        for k in range(len(self.codes)):
            if self.codes[k] == code:
                return k
        var plain = base_letter(code)  # (an accented letter the atlas lacks: its letter, so "Belém" never reads "Belm")
        return self.ascii[plain] if plain > 0 else -1

    def coverage(self, x: Float64, y: Float64) -> Float64:
        """Bilinear coverage (0–1) at a point in atlas pixels."""
        var x0 = Int(x - 0.5) if x >= 0.5 else -1
        var y0 = Int(y - 0.5) if y >= 0.5 else -1
        var fx = x - 0.5 - Float64(x0)
        var fy = y - 0.5 - Float64(y0)
        var a = self.at(x0, y0)
        var b = self.at(x0 + 1, y0)
        var c = self.at(x0, y0 + 1)
        var d = self.at(x0 + 1, y0 + 1)
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy

    def at(self, x: Int, y: Int) -> Float64:
        if x < 0 or y < 0 or x >= self.width:
            return 0
        var i = y * self.width + x
        if i >= len(self.atlas):
            return 0
        return Float64(Int(self.atlas[i])) / 255.0

    def measure(self, text: String, size: Float64) -> Float64:
        var s = size / self.size
        var w = 0.0
        for c in text.codepoints():
            var g = self.find(Int(c.to_u32()))
            if g >= 0:
                w += self.glyphs[g].advance * s
        return w

    def draw(self, mut surface: Surface, text: String, x: Float64, baseline: Float64, size: Float64, color: UInt32, slant: Float64 = 0):
        """slant: each pixel row above the baseline moves right by this much of its height (0.2: italic)."""
        var s = size / self.size
        var pen = x
        var r = Float64(Int(color & 0xFF))
        var gr = Float64(Int((color >> 8) & 0xFF))
        var b = Float64(Int((color >> 16) & 0xFF))
        var alpha = Float64(Int((color >> 24) & 0xFF)) / 255.0
        var p = surface.pixels()
        var sub = 2 if s < 0.75 else 1  # supersample when shrinking, so thin strokes stay smooth
        for c in text.codepoints():
            var gi = self.find(Int(c.to_u32()))
            if gi < 0:
                continue
            ref g = self.glyphs[gi]
            var left = pen + Float64(g.left) * s
            var top = baseline + Float64(g.top) * s
            var lean_top = slant * (baseline - top)  # (the glyph's top row moves furthest; below the baseline, left)
            var lean_bottom = slant * (baseline - top - Float64(g.h) * s)
            var x0 = max(Int(left + min(lean_bottom, 0.0)), 0)
            var y0 = max(Int(top), 0)
            var x1 = min(Int(left + Float64(g.w) * s + max(lean_top, 0.0)) + 1, surface.width)
            var y1 = min(Int(top + Float64(g.h) * s) + 1, surface.height)
            for py in range(y0, y1):
                var row_left = left + slant * (baseline - Float64(py) - 0.5)
                for px in range(x0, x1):
                    var cov = 0.0
                    for sy in range(sub):
                        for sx in range(sub):
                            var ax = (Float64(px) + (Float64(sx) + 0.5) / Float64(sub) - row_left) / s
                            var ay = (Float64(py) + (Float64(sy) + 0.5) / Float64(sub) - top) / s
                            if ax >= 0.0 and ax < Float64(g.w) and ay >= 0.0 and ay < Float64(g.h):
                                cov += self.coverage(Float64(g.x) + ax, Float64(g.y) + ay)
                    cov = cov / Float64(sub * sub) * alpha
                    if cov <= 0.003:
                        continue
                    var i = py * surface.width + px
                    var d = p.unsafe_offset(i)[]
                    var dr = Float64(Int(d & 0xFF))
                    var dg = Float64(Int((d >> 8) & 0xFF))
                    var db = Float64(Int((d >> 16) & 0xFF))
                    var nr = UInt32(Int(r * cov + dr * (1 - cov) + 0.5))
                    var ng = UInt32(Int(gr * cov + dg * (1 - cov) + 0.5))
                    var nb = UInt32(Int(b * cov + db * (1 - cov) + 0.5))
                    p.unsafe_offset(i)[] = nr | (ng << 8) | (nb << 16) | (d & 0xFF000000)
            pen += g.advance * s


struct Font(Movable):
    """Inter: Regular and Medium for labels, a large SemiBold for big numbers; JetBrains Mono regular and bold."""

    var regular: Face
    var medium: Face
    var display: Face
    var mono: Face
    var mono_bold: Face

    def __init__(out self):
        self.regular = Face(REGULAR_SIZE, REGULAR_ASCENT, REGULAR_DESCENT, REGULAR_WIDTH, REGULAR_TABLE, REGULAR_ATLAS)
        self.medium = Face(MEDIUM_SIZE, MEDIUM_ASCENT, MEDIUM_DESCENT, MEDIUM_WIDTH, MEDIUM_TABLE, MEDIUM_ATLAS)
        self.display = Face(DISPLAY_SIZE, DISPLAY_ASCENT, DISPLAY_DESCENT, DISPLAY_WIDTH, DISPLAY_TABLE, DISPLAY_ATLAS)
        self.mono = Face(MONO_SIZE, MONO_ASCENT, MONO_DESCENT, MONO_WIDTH, MONO_TABLE, MONO_ATLAS)
        self.mono_bold = Face(MONO_BOLD_SIZE, MONO_BOLD_ASCENT, MONO_BOLD_DESCENT, MONO_BOLD_WIDTH, MONO_BOLD_TABLE, MONO_BOLD_ATLAS)

    def pick(self, weight: Int, size: Float64, text: String) -> Int:
        """Which face draws `text` at `size` px: 2 = the big one (large numbers, if it has every glyph);
        3, 4 = JetBrains Mono regular and bold."""
        if weight == MONO:
            return 3
        if weight == MONO_BOLD:
            return 4
        if weight == MEDIUM and size > 34:
            var all_there = True
            for c in text.codepoints():
                if self.display.find(Int(c.to_u32())) < 0:
                    all_there = False
            if all_there:
                return 2
        return 1 if weight == MEDIUM else 0

    def measure(self, text: String, size: Float64, weight: Int = REGULAR) -> Float64:
        """The width of `text` at `size` px."""
        var k = self.pick(weight, size, text)
        if k == 2:
            return self.display.measure(text, size)
        if k == 3:
            return self.mono.measure(text, size)
        if k == 4:
            return self.mono_bold.measure(text, size)
        return self.medium.measure(text, size) if k == 1 else self.regular.measure(text, size)

    def ascent(self, size: Float64) -> Float64:
        return self.regular.ascent * size / self.regular.size

    def draw(
        self, mut surface: Surface, text: String, x: Float64, baseline: Float64, size: Float64, color: UInt32,
        weight: Int = REGULAR, align: Int = LEFT, slant: Float64 = 0,
    ):
        """Draws `text` with its baseline at `baseline` (pixels), starting at x (or centred on / ending at x)."""
        var pen = x
        if align != LEFT:
            var w = self.measure(text, size, weight)
            pen -= w / 2 if align == CENTRE else w
        var k = self.pick(weight, size, text)
        if k == 2:
            self.display.draw(surface, text, pen, baseline, size, color, slant)
        elif k == 3:
            self.mono.draw(surface, text, pen, baseline, size, color, slant)
        elif k == 4:
            self.mono_bold.draw(surface, text, pen, baseline, size, color, slant)
        elif k == 1:
            self.medium.draw(surface, text, pen, baseline, size, color, slant)
        else:
            self.regular.draw(surface, text, pen, baseline, size, color, slant)
