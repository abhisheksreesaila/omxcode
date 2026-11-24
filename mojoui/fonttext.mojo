# mojoui.fonttext (goal 79 M1): text the way the browser draws it. Glyphs come from the platform's own font engine at
# device pixels (Linux: FreeType rasterizes, HarfBuzz shapes, fontconfig finds a face for what the chosen face lacks;
# the Mac: CoreText, mojoui/fonttext_mac.mojo), never from a pre-baked atlas that is scaled. The faces are the web
# app's own (fonts/, OFL): Bricolage Grotesque, Geist, Geist Mono, IBM Plex Sans/Mono, Source Serif 4, Instrument Serif,
# Caveat; the system's fonts fill in scripts and emoji those lack, as Chromium's fallback does.
#
#   var st = TextStyle("Geist", 400, False, 14)                 # family, weight, italic, size (layout px: CSS px)
#   var run = shape(st, "Quick note")                           # glyphs, positions and the width, in layout px
#   draw_run(surface, run, x_dev, baseline_dev, k, color)       # rasterized at k device px per layout px
#
# Layout follows Chromium on the same machine (D-7976): on Linux (D-7903) advances are taken at the layout size and
# rounded to whole layout pixels per glyph (it hints advances; no subpixel positioning), and each glyph lands on a whole
# device pixel; on the Mac advances stay unrounded, as Chrome there lays them out (D-7981). A
# zoomed canvas asks for its glyphs at the zoomed device size: re-rasterized, never a bitmap scaled.
#
# Everything lives in one FontEngine per process (mojoui.shared slot SLOT_FONTS): the libraries' functions by address
# (dlopen'd, D-1311's pattern), the loaded faces, the fallback choices and a glyph cache keyed by
# (face, instance, glyph, device size, subpixel x).

from std.ffi import external_call, c_int, c_char, c_uint
from std.sys import CompilationTarget
from std.memory import Pointer
from mojoui.clock import now_ns
from std.memory.alloc import alloc, Layout
from std.collections import Dict
from std.os import getenv
from mojoui.shared import get_shared, put_shared
from mojoui.canvas import Surface

comptime SLOT_FONTS = 230  # mojoui.shared slot: the process's FontEngine
comptime FT_LOAD_RENDER = 4
comptime FT_LOAD_NO_HINTING = 2
comptime FT_LOAD_TARGET_LIGHT = 65536
comptime FT_LOAD_COLOR = 1048576
comptime FT_FACE_FLAG_SCALABLE = 1
comptime FT_FACE_FLAG_COLOR = 1 << 14
comptime PIXEL_GRAY = 2
comptime PIXEL_BGRA = 7

comptime _M_CTFONT = 0
comptime _M_DESCR = 1
comptime _M_GLYPHS4CHARS = 2
comptime _M_FORSTRING = 3
comptime _M_COPYCG = 4
comptime _M_CTBYNAME = 5
comptime _M_TRAITS = 6
comptime _M_LINE = 7
comptime _M_RUNS = 8
comptime _M_RUNCOUNT = 9
comptime _M_RUNGLYPHS = 10
comptime _M_RUNPOS = 11
comptime _M_RUNADV = 12
comptime _M_RUNATTRS = 13
comptime _M_ADVANCES = 14
comptime _M_BOUNDS = 15
comptime _M_DRAW = 16
comptime _M_PSNAME = 17
comptime _M_CGPROV = 18
comptime _M_CGFONT = 19
comptime _M_UPEM = 20
comptime _M_ASC = 21
comptime _M_DESC = 22
comptime _M_GRAY = 23
comptime _M_RGB = 24
comptime _M_BITMAP = 25
comptime _M_GRAYFILL = 26
comptime _M_SMOOTH = 27
comptime _M_AA = 28
comptime _M_SUBPOS_OK = 29
comptime _M_SUBPOS = 30
comptime _M_CTXREL = 31
comptime _M_CFSTR = 32
comptime _M_ATTRSTR = 33
comptime _M_CFDICT = 34
comptime _M_DICTGET = 35
comptime _M_CFNUM = 36
comptime _M_ARRCOUNT = 37
comptime _M_ARRAT = 38
comptime _M_CFRELEASE = 39
comptime _M_CFGETCSTR = 40
comptime _M_LEADING = 41
comptime _M_RGBFILL = 42
comptime _M_CGTABLE = 43
comptime _M_DATAPTR = 44
comptime _M_DATALEN = 45

# alignment of a run at x
comptime ALIGN_LEFT = 0
comptime ALIGN_CENTER = 1
comptime ALIGN_RIGHT = 2


def _fn[T: ImplicitlyCopyable](addr: Int) -> T:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    return Pointer(to=raw).unsafe_bitcast[T]()[]


def _dlsym(handle: Int, name: String) -> Int:
    var n = name
    return external_call["dlsym", Int](handle, n.as_c_string_span())


def _peek_u8(addr: Int) -> Int:
    return Int(Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)[])


def _peek_u16(addr: Int) -> Int:
    return Int(Pointer[UInt16, MutUntrackedOrigin](unsafe_from_address=addr)[])


def _peek_i16(addr: Int) -> Int:
    return Int(Pointer[Int16, MutUntrackedOrigin](unsafe_from_address=addr)[])


def _peek_u32(addr: Int) -> Int:
    return Int(Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=addr)[])


def _peek_i32(addr: Int) -> Int:
    return Int(Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=addr)[])


def _peek_f32(addr: Int) -> Float64:
    return Float64(Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=addr)[])


def _peek(addr: Int) -> Int:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)[]


def _c_text(addr: Int) -> String:
    if addr == 0:
        return String("")
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


def _tag(s: String) -> UInt32:
    var b = s.as_bytes()
    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])


@fieldwise_init
struct TextStyle(ImplicitlyCopyable, Movable):
    """What a run of text is drawn in: a family (the web's font-family, first name), a weight (100–900), italic, and a
    size in layout px (CSS px). letter_spacing in layout px is added after every glyph (CSS letter-spacing)."""
    var family: String
    var weight: Int
    var italic: Bool
    var size: Float64
    var letter_spacing: Float64
    var exact: Bool  # advances unrounded (canvas and SVG text: measureText, <text>), else rounded as HTML text is

    def __init__(out self, family: String, weight: Int, italic: Bool, size: Float64):
        self.family = family
        self.weight = weight
        self.italic = italic
        self.size = size
        self.letter_spacing = 0
        self.exact = False


@fieldwise_init
struct Glyph(ImplicitlyCopyable, Movable):
    var face: Int  # index in FontEngine.faces
    var inst: Int  # index in FontEngine.insts (the face at this weight and optical size)
    var gid: Int
    var x: Float64  # pen position from the run's start, layout px
    var y: Float64  # offset up from the baseline, layout px
    var cluster: Int  # byte index of the text this glyph came from


struct Run(Copyable, Movable):
    """A shaped line: glyphs in visual order, positions in layout px."""
    var glyphs: List[Glyph]
    var width: Float64
    var ascent: Float64  # the primary face's, layout px (positive up)
    var descent: Float64  # positive down
    var size: Float64
    var missing: Int  # glyphs that came out as .notdef (no face had them)

    def __init__(out self):
        self.glyphs = List[Glyph]()
        self.width = 0
        self.ascent = 0
        self.descent = 0
        self.size = 0
        self.missing = 0


struct GlyphImage(Copyable, Movable):
    """One glyph rasterized: coverage (w·h bytes) or colour (w·h premultiplied RGBA words, 0xAABBGGRR), placed at
    (pen + left, baseline − top) in device px."""
    var w: Int
    var h: Int
    var left: Int
    var top: Int
    var color: Bool
    var cov: List[UInt8]
    var rgba: List[UInt32]

    def __init__(out self):
        self.w = 0
        self.h = 0
        self.left = 0
        self.top = 0
        self.color = False
        self.cov = List[UInt8]()
        self.rgba = List[UInt32]()


@fieldwise_init
struct _Axis(ImplicitlyCopyable, Movable):
    var tag: UInt32
    var lo: Float64
    var default: Float64
    var hi: Float64


struct _Face(Copyable, Movable):
    var path: String
    var index: Int
    var family: String
    var italic: Bool
    var weight: Int  # a static face's weight (0: variable in wght)
    var ft: Int
    var hb_face: Int
    var upem: Int
    var axes: List[_Axis]
    var color: Bool  # a colour bitmap face (emoji)
    var fixed: Bool  # bitmap strikes only (not scalable)
    var asc: Int  # hhea/OS2 ascender, font units (FreeType's)
    var desc: Int
    var apple_emoji: Bool  # (D-7998) Apple Color Emoji: its advances follow apple_emoji_advance
    var mono: Bool  # (D-7990) monospaced (the Mac: CoreText's monospace trait; its fallback cascades from Menlo)
    var trak: Trak  # (D-7989) its 'trak' table's normal track (the Mac; empty: none)
    var coords_set: Int  # the instance whose design coordinates FreeType has now (-1: none)
    var size_set: Int  # the 26.6 size FreeType has now

    def __init__(out self, path: String, index: Int, family: String, italic: Bool, weight: Int):
        self.path = path
        self.index = index
        self.family = family
        self.italic = italic
        self.weight = weight
        self.ft = 0
        self.hb_face = 0
        self.apple_emoji = False
        self.mono = False
        self.trak = Trak(List[Float64](), List[Int]())
        self.upem = 1000
        self.axes = List[_Axis]()
        self.color = False
        self.fixed = False
        self.asc = 0
        self.desc = 0
        self.coords_set = -1
        self.size_set = -1


@fieldwise_init
struct _Inst(ImplicitlyCopyable, Movable):
    var face: Int
    var wght: Float64
    var opsz: Float64
    var hb_font: Int


struct FontEngine(Movable):
    # FreeType
    var ft_lib: Int
    var FT_New_Face: Int
    var FT_Set_Char_Size: Int
    var FT_Select_Size: Int
    var FT_Set_Var_Design_Coordinates: Int
    var FT_Set_Transform: Int
    var FT_Load_Glyph: Int
    var FT_Get_Advance: Int
    var hb_font_get_glyph_h_advance: Int
    var adv_of: Dict[Int, Int]  # (inst, glyph) → FreeType's advance in font units (variations applied)
    # HarfBuzz
    var hb_blob_create_from_file: Int
    var hb_face_create: Int
    var hb_face_get_upem: Int
    var hb_font_create: Int
    var hb_font_set_scale: Int
    var hb_font_set_variations: Int
    var hb_font_get_nominal_glyph: Int
    var hb_buffer_create: Int
    var hb_buffer_clear_contents: Int
    var hb_buffer_add_utf8: Int
    var hb_buffer_guess_segment_properties: Int
    var hb_buffer_get_glyph_infos: Int
    var hb_buffer_get_glyph_positions: Int
    var hb_shape: Int
    var hb_ot_var_get_axis_infos: Int
    var hb_buf: Int
    # fontconfig
    var fc_config: Int
    var FcPatternCreate: Int
    var FcPatternDestroy: Int
    var FcCharSetCreate: Int
    var FcCharSetDestroy: Int
    var FcCharSetAddChar: Int
    var FcPatternAddCharSet: Int
    var FcPatternAddString: Int
    var FcConfigSubstitute: Int
    var FcDefaultSubstitute: Int
    var FcFontMatch: Int
    var FcPatternGetString: Int
    var FcPatternGetInteger: Int
    # state
    var faces: List[_Face]
    var insts: List[_Inst]
    var inst_of: Dict[String, Int]
    var declared: Dict[String, List[Int]]  # (D-8053) family + style → the weights declared of it, then its optical size (0: follows the text's size)
    var face_of_file: Dict[String, Int]
    var fallback: Dict[Int, Int]  # codepoint → face (-1: none has it)
    var emoji_face: Int
    var images: List[GlyphImage]
    var widths: Dict[String, Float64]  # (D-8007) measure()'s: widths by (style, text)
    var shapings: Int  # runs shaped so far (the caches answering keeps it still)
    var runs: Dict[String, Run]  # shaped runs by (style, text): text redrawn each frame is shaped once (D-7916)
    var image_of: Dict[Int, Int]
    var hint: Int  # FreeType load flags for hinting (D-7904)
    var kern_round: String  # FONTTEXT_KERN_ROUND, read once (not per glyph)
    var image_dev: List[Float64]  # per image: the exact device size it was rastered at (its key rounds to 1/64 px)
    var styles_seen: Dict[String, Bool]  # (D-8002) every text style shaped so far (glyphwarm keeps them; no text)
    var img_n: Int  # (diagnosis) glyph images rastered, the time in it (ns), runs shaped, the time in it (ns), so far
    var img_ns: Int
    var shape_n: Int
    var shape_ns: Int
    var trace: Bool  # FONTTEXT_TRACE=1: each CoreText run's font and advances (diagnosis)
    var debug: Bool  # FONTTEXT_DEBUG, read once
    # the Mac: CoreText, CoreGraphics, CoreFoundation (by address, dlopen'd as on Linux)
    var mac: List[Int]  # function addresses, by the _M_* indices below
    var k_font_attr: Int  # kCTFontAttributeName's value
    var k_var_attr: Int  # kCTFontVariationAttribute's value
    var k_track_attr: Int  # kCTTrackingAttribute's value (D-7989)
    var trak_on: Bool  # FONTTEXT_TRAK=0: no trak applied (A/B)
    var k_dict_keys: Int  # &kCFTypeDictionaryKeyCallBacks
    var k_dict_vals: Int
    var ct_fonts: Dict[String, Int]  # (instance, size) → CTFont
    var face_of_name: Dict[String, Int]  # a system face's PostScript name → its face
    var error: String

    def __init__(out self):
        self.ft_lib = 0
        self.FT_New_Face = 0
        self.FT_Set_Char_Size = 0
        self.FT_Select_Size = 0
        self.FT_Set_Var_Design_Coordinates = 0
        self.FT_Set_Transform = 0
        self.FT_Load_Glyph = 0
        self.FT_Get_Advance = 0
        self.hb_font_get_glyph_h_advance = 0
        self.adv_of = Dict[Int, Int]()
        self.hb_blob_create_from_file = 0
        self.hb_face_create = 0
        self.hb_face_get_upem = 0
        self.hb_font_create = 0
        self.hb_font_set_scale = 0
        self.hb_font_set_variations = 0
        self.hb_font_get_nominal_glyph = 0
        self.hb_buffer_create = 0
        self.hb_buffer_clear_contents = 0
        self.hb_buffer_add_utf8 = 0
        self.hb_buffer_guess_segment_properties = 0
        self.hb_buffer_get_glyph_infos = 0
        self.hb_buffer_get_glyph_positions = 0
        self.hb_shape = 0
        self.hb_ot_var_get_axis_infos = 0
        self.hb_buf = 0
        self.fc_config = 0
        self.FcPatternCreate = 0
        self.FcPatternDestroy = 0
        self.FcCharSetCreate = 0
        self.FcCharSetDestroy = 0
        self.FcCharSetAddChar = 0
        self.FcPatternAddCharSet = 0
        self.FcPatternAddString = 0
        self.FcConfigSubstitute = 0
        self.FcDefaultSubstitute = 0
        self.FcFontMatch = 0
        self.FcPatternGetString = 0
        self.FcPatternGetInteger = 0
        self.faces = List[_Face]()
        self.insts = List[_Inst]()
        self.inst_of = Dict[String, Int]()
        self.declared = Dict[String, List[Int]]()
        self.face_of_file = Dict[String, Int]()
        self.fallback = Dict[Int, Int]()
        self.emoji_face = -2
        self.images = List[GlyphImage]()
        self.widths = Dict[String, Float64]()
        self.shapings = 0
        self.runs = Dict[String, Run]()
        self.image_of = Dict[Int, Int]()
        var h = getenv("FONTTEXT_HINT", "light")
        self.hint = FT_LOAD_NO_HINTING if h == "none" else (0 if h == "full" else FT_LOAD_TARGET_LIGHT)
        # (D-7981, ruling A) each machine follows its own Chromium: on Linux advances rounded to whole layout px (D-7903),
        # on the Mac unrounded (Chrome there positions glyphs on subpixels, as CoreText does)
        self.kern_round = getenv("FONTTEXT_KERN_ROUND", "exact" if CompilationTarget.is_macos() else "D")
        self.trace = getenv("FONTTEXT_TRACE") == "1"
        self.image_dev = List[Float64]()
        self.styles_seen = Dict[String, Bool]()
        self.img_n = 0
        self.img_ns = 0
        self.shape_n = 0
        self.shape_ns = 0
        self.debug = getenv("FONTTEXT_DEBUG") != ""
        self.error = ""
        self.mac = List[Int]()
        self.k_font_attr = 0
        self.k_var_attr = 0
        self.k_track_attr = 0
        self.trak_on = getenv("FONTTEXT_TRAK") != "0"
        self.k_dict_keys = 0
        self.k_dict_vals = 0
        self.ct_fonts = Dict[String, Int]()
        self.face_of_name = Dict[String, Int]()

    # ------------------------------------------------ loading

    def load(mut self) -> Bool:
        comptime if CompilationTarget.is_macos():
            return self._mac_load()
        var anywhere = -2 if CompilationTarget.is_macos() else 0
        var dlopen = _dlsym(anywhere, "dlopen")
        if dlopen == 0:
            self.error = "no dlopen"
            return False
        var ft = self._open(dlopen, "libfreetype.so.6")
        var hb = self._open(dlopen, "libharfbuzz.so.0")
        var fc = self._open(dlopen, "libfontconfig.so.1")
        if ft == 0 or hb == 0 or fc == 0:
            self.error = "FreeType, HarfBuzz or fontconfig isn't installed"
            return False
        self.FT_New_Face = _dlsym(ft, "FT_New_Face")
        self.FT_Set_Char_Size = _dlsym(ft, "FT_Set_Char_Size")
        self.FT_Select_Size = _dlsym(ft, "FT_Select_Size")
        self.FT_Set_Var_Design_Coordinates = _dlsym(ft, "FT_Set_Var_Design_Coordinates")
        self.FT_Set_Transform = _dlsym(ft, "FT_Set_Transform")
        self.FT_Load_Glyph = _dlsym(ft, "FT_Load_Glyph")
        self.FT_Get_Advance = _dlsym(ft, "FT_Get_Advance")
        self.hb_font_get_glyph_h_advance = _dlsym(hb, "hb_font_get_glyph_h_advance")
        self.hb_blob_create_from_file = _dlsym(hb, "hb_blob_create_from_file")
        self.hb_face_create = _dlsym(hb, "hb_face_create")
        self.hb_face_get_upem = _dlsym(hb, "hb_face_get_upem")
        self.hb_font_create = _dlsym(hb, "hb_font_create")
        self.hb_font_set_scale = _dlsym(hb, "hb_font_set_scale")
        self.hb_font_set_variations = _dlsym(hb, "hb_font_set_variations")
        self.hb_font_get_nominal_glyph = _dlsym(hb, "hb_font_get_nominal_glyph")
        self.hb_buffer_create = _dlsym(hb, "hb_buffer_create")
        self.hb_buffer_clear_contents = _dlsym(hb, "hb_buffer_clear_contents")
        self.hb_buffer_add_utf8 = _dlsym(hb, "hb_buffer_add_utf8")
        self.hb_buffer_guess_segment_properties = _dlsym(hb, "hb_buffer_guess_segment_properties")
        self.hb_buffer_get_glyph_infos = _dlsym(hb, "hb_buffer_get_glyph_infos")
        self.hb_buffer_get_glyph_positions = _dlsym(hb, "hb_buffer_get_glyph_positions")
        self.hb_shape = _dlsym(hb, "hb_shape")
        self.hb_ot_var_get_axis_infos = _dlsym(hb, "hb_ot_var_get_axis_infos")
        self.FcPatternCreate = _dlsym(fc, "FcPatternCreate")
        self.FcPatternDestroy = _dlsym(fc, "FcPatternDestroy")
        self.FcCharSetCreate = _dlsym(fc, "FcCharSetCreate")
        self.FcCharSetDestroy = _dlsym(fc, "FcCharSetDestroy")
        self.FcCharSetAddChar = _dlsym(fc, "FcCharSetAddChar")
        self.FcPatternAddCharSet = _dlsym(fc, "FcPatternAddCharSet")
        self.FcPatternAddString = _dlsym(fc, "FcPatternAddString")
        self.FcConfigSubstitute = _dlsym(fc, "FcConfigSubstitute")
        self.FcDefaultSubstitute = _dlsym(fc, "FcDefaultSubstitute")
        self.FcFontMatch = _dlsym(fc, "FcFontMatch")
        self.FcPatternGetString = _dlsym(fc, "FcPatternGetString")
        self.FcPatternGetInteger = _dlsym(fc, "FcPatternGetInteger")
        if self.FT_Load_Glyph == 0 or self.hb_shape == 0 or self.FcFontMatch == 0:
            self.error = "a font library lacks a function"
            return False
        var lib = List[Int](length=1, fill=0)
        var rc = _fn[def(Int) thin abi("C") -> c_int](_dlsym(ft, "FT_Init_FreeType"))(Int(lib.unsafe_ptr()))
        _ = lib
        if rc != 0:
            self.error = "FT_Init_FreeType failed"
            return False
        self.ft_lib = lib[0]
        self.fc_config = _fn[def() thin abi("C") -> Int](_dlsym(fc, "FcInitLoadConfigAndFonts"))()
        self.hb_buf = _fn[def() thin abi("C") -> Int](self.hb_buffer_create)()
        var dir = fonts_dir()
        for row in _registry():
            var path = dir + "/" + row[2]
            var f = _Face(path, 0, row[0], row[1] == "italic", Int(atol(row[3])))
            _ = self._open_face(f^)
        return True

    def _open(self, dlopen: Int, name: String) -> Int:
        var n = name
        var h = _fn[def(Int, c_int) thin abi("C") -> Int](dlopen)(Int(n.as_c_string_span().ptr()), c_int(2))
        _ = n
        return h

    def _open_face(mut self, var f: _Face) -> Int:
        """Opens the file in FreeType and HarfBuzz; the face's index, or -1."""
        comptime if CompilationTarget.is_macos():
            return self._mac_open_face(f^)
        var key = f.path + "#" + String(f.index)
        if key in self.face_of_file and f.family == "":
            return self.face_of_file.get(key, -1)
        var out = List[Int](length=1, fill=0)
        var p = f.path
        if _fn[def(Int, Int, Int, Int) thin abi("C") -> c_int](self.FT_New_Face)(self.ft_lib, Int(p.as_c_string_span().ptr()), f.index, Int(out.unsafe_ptr())) != 0:
            _ = p
            _ = out
            return -1
        f.ft = out[0]
        var blob = _fn[def(Int) thin abi("C") -> Int](self.hb_blob_create_from_file)(Int(p.as_c_string_span().ptr()))
        _ = p
        f.hb_face = _fn[def(Int, c_uint) thin abi("C") -> Int](self.hb_face_create)(blob, c_uint(f.index))
        f.upem = Int(_fn[def(Int) thin abi("C") -> c_uint](self.hb_face_get_upem)(f.hb_face))
        var flags = _peek(f.ft + 16)
        f.color = (flags & FT_FACE_FLAG_COLOR) != 0
        f.fixed = (flags & FT_FACE_FLAG_SCALABLE) == 0
        f.asc = _peek_i16(f.ft + 138)
        f.desc = _peek_i16(f.ft + 140)
        # variation axes (wght, opsz, wdth…)
        var count = List[UInt32](length=1, fill=8)
        var infos = List[UInt32](length=8 * 8, fill=0)
        var total = Int(_fn[def(Int, c_uint, Int, Int) thin abi("C") -> c_uint](self.hb_ot_var_get_axis_infos)(f.hb_face, c_uint(0), Int(count.unsafe_ptr()), Int(infos.unsafe_ptr())))
        var base = Int(infos.unsafe_ptr())
        for i in range(min(total, Int(count[0]))):
            var a = base + i * 32
            f.axes.append(_Axis(UInt32(_peek_u32(a + 4)), _peek_f32(a + 16), _peek_f32(a + 20), _peek_f32(a + 24)))
        _ = count
        _ = infos
        self.faces.append(f^)
        var idx = len(self.faces) - 1
        self.face_of_file[key] = idx
        return idx

    # ------------------------------------------------ choosing faces

    def pick(mut self, family: String, weight: Int, italic: Bool) -> Int:
        """The registered face for a family, nearest in style and weight; -1 when the family isn't registered.
        "emoji" is the system's colour emoji face (fontconfig's choice: Noto Color Emoji here, as Chromium's)."""
        if family == "emoji":
            return self.system_face(0x1F600, True)
        if family.find(",") >= 0 or family.find('"') >= 0 or family.find("'") >= 0:  # (a CSS family list: '"Geist Mono", monospace')
            for part in family.split(","):
                var name = String(String(part).replace('"', "").replace("'", "").strip())
                var at = self.pick(name, weight, italic) if name != "" else -1
                if at >= 0:
                    return at
            return -1
        # (the generic families, where no face of that name is registered: this engine's own of that kind)
        if family == "monospace" or family == "ui-monospace":
            return self.pick("Geist Mono", weight, italic)
        if family == "serif" or family == "ui-serif":
            return self.pick("Source Serif 4", weight, italic)
        if family == "sans-serif" or family == "system-ui" or family == "ui-sans-serif":
            return self.pick("Geist", weight, italic)
        var best = -1
        var best_d = 1 << 30
        var slant = italic
        if italic and family in self.declared and family + "/italic" not in self.declared:
            slant = False  # (no italic of it was declared: its upright, as a page with font-synthesis off)
        for i in range(len(self.faces)):
            ref f = self.faces[i]
            if f.family != family:
                continue
            var d = (0 if f.italic == slant else 10000) + (0 if f.weight == 0 else abs(f.weight - weight))
            if d < best_d:
                best_d = d
                best = i
        return best

    def declare(mut self, family: String, italic: Bool, weights: List[Int], opsz: Int = 0):
        """(D-8053) Only these weights of a family exist, as when a page's @font-face rules load just them: text of another
        weight is drawn in the nearest by CSS's rule, whatever the variable file could do. opsz: the one optical size it was
        loaded at (0: the text's own size)."""
        var v = weights.copy()
        v.append(opsz)
        self.declared[family + ("/italic" if italic else "")] = v^

    def as_declared(self, face: Int, weight: Int, size: Float64) -> Tuple[Int, Float64]:
        """The weight and optical size a face is really drawn at (declare)."""
        ref f = self.faces[face]
        var key = f.family + ("/italic" if f.italic else "")
        try:
            if key in self.declared:
                ref v = self.declared[key]
                var n = len(v) - 1
                return (css_weight(weight, Span(v)[0:n]), Float64(v[n]) if v[n] > 0 else size)
        except:
            pass
        return (weight, size)

    def inst(mut self, face: Int, weight_in: Int, size_in: Float64) -> Int:
        """The face at a weight and (Chromium's automatic optical sizing: opsz = the size in CSS px) an optical size."""
        var d = self.as_declared(face, weight_in, size_in)
        var weight = d[0]
        var size = d[1]
        comptime if CompilationTarget.is_macos():
            return self._mac_inst(face, weight, size)
        ref f = self.faces[face]
        var wght = Float64(weight)
        var opsz = 0.0
        var has_w = False
        for a in f.axes:
            if a.tag == _tag("wght"):
                has_w = True
                wght = max(a.lo, min(a.hi, wght))
            if a.tag == _tag("opsz"):
                opsz = max(a.lo, min(a.hi, size))
                var force = getenv("FONTTEXT_OPSZ", "")
                if force != "":
                    opsz = max(a.lo, min(a.hi, Float64(atol(force))))
        if not has_w:
            wght = 0
        var key = String(face) + ":" + String(Int(wght)) + ":" + String(Int(opsz * 4))
        if key in self.inst_of:
            return self.inst_of.get(key, 0)
        var font = _fn[def(Int) thin abi("C") -> Int](self.hb_font_create)(f.hb_face)
        _fn[def(Int, c_int, c_int) thin abi("C") -> NoneType](self.hb_font_set_scale)(font, c_int(f.upem), c_int(f.upem))
        var vars = List[UInt32]()
        for a in f.axes:
            var v = a.default
            if a.tag == _tag("wght"):
                v = wght
            elif a.tag == _tag("opsz"):
                v = opsz
            vars.append(a.tag)
            var fv = Float32(v)
            vars.append(Pointer(to=fv).unsafe_bitcast[UInt32]()[])
        if len(f.axes) > 0:
            _fn[def(Int, Int, c_uint) thin abi("C") -> NoneType](self.hb_font_set_variations)(font, Int(vars.unsafe_ptr()), c_uint(len(f.axes)))
            _ = vars
        self.insts.append(_Inst(face, wght, opsz, font))
        self.inst_of[key] = len(self.insts) - 1
        return len(self.insts) - 1

    def has(mut self, inst: Int, cp: Int) -> Bool:
        comptime if CompilationTarget.is_macos():
            return self._mac_has(inst, cp)
        var g = List[UInt32](length=1, fill=0)
        var ok = _fn[def(Int, c_uint, Int) thin abi("C") -> c_int](self.hb_font_get_nominal_glyph)(self.insts[inst].hb_font, c_uint(cp), Int(g.unsafe_ptr())) != 0
        _ = g
        return ok

    def system_face(mut self, cp: Int, emoji: Bool, mono: Bool = False) -> Int:
        """fontconfig's face for a codepoint the chosen face lacks (or the emoji face); cached; -1 if none. mono: the
        chosen face is monospaced (the Mac cascades from Menlo then, as Chrome there does, D-7990)."""
        comptime if CompilationTarget.is_macos():
            return self._mac_system_face(cp, emoji, mono)
        var key = -1 if emoji else cp
        if key in self.fallback:
            return self.fallback.get(key, -1)
        var pat = _fn[def() thin abi("C") -> Int](self.FcPatternCreate)()
        var cs = 0
        if emoji:
            var fam = String("family")
            var em = String("emoji")
            _ = _fn[def(Int, Int, Int) thin abi("C") -> c_int](self.FcPatternAddString)(pat, Int(fam.as_c_string_span().ptr()), Int(em.as_c_string_span().ptr()))
            _ = fam
            _ = em
        else:
            cs = _fn[def() thin abi("C") -> Int](self.FcCharSetCreate)()
            _ = _fn[def(Int, c_uint) thin abi("C") -> c_int](self.FcCharSetAddChar)(cs, c_uint(cp))
            var name = String("charset")
            _ = _fn[def(Int, Int, Int) thin abi("C") -> c_int](self.FcPatternAddCharSet)(pat, Int(name.as_c_string_span().ptr()), cs)
            _ = name
        _ = _fn[def(Int, Int, c_int) thin abi("C") -> c_int](self.FcConfigSubstitute)(self.fc_config, pat, c_int(0))
        _fn[def(Int) thin abi("C") -> NoneType](self.FcDefaultSubstitute)(pat)
        var res = List[Int](length=1, fill=0)
        var m = _fn[def(Int, Int, Int) thin abi("C") -> Int](self.FcFontMatch)(self.fc_config, pat, Int(res.unsafe_ptr()))
        _ = res
        var idx = -1
        if m != 0:
            var sp = List[Int](length=1, fill=0)
            var ip = List[Int](length=1, fill=0)
            var file = String("file")
            var index = String("index")
            if _fn[def(Int, Int, c_int, Int) thin abi("C") -> c_int](self.FcPatternGetString)(m, Int(file.as_c_string_span().ptr()), c_int(0), Int(sp.unsafe_ptr())) == 0:
                _ = _fn[def(Int, Int, c_int, Int) thin abi("C") -> c_int](self.FcPatternGetInteger)(m, Int(index.as_c_string_span().ptr()), c_int(0), Int(ip.unsafe_ptr()))
                _ = index
                _ = file
                var path = _c_text(sp[0])
                var fi = Int(Int32(truncate_i32(ip[0])))
                var key2 = path + "#" + String(fi)
                if key2 in self.face_of_file:
                    idx = self.face_of_file.get(key2, -1)
                else:
                    idx = self._open_face(_Face(path, fi, "", False, 400))
            _fn[def(Int) thin abi("C") -> NoneType](self.FcPatternDestroy)(m)
        _fn[def(Int) thin abi("C") -> NoneType](self.FcPatternDestroy)(pat)
        if cs != 0:
            _fn[def(Int) thin abi("C") -> NoneType](self.FcCharSetDestroy)(cs)
        if idx >= 0 and not emoji:
            var probe = self.inst(idx, 400, 16)
            if not self.has(probe, cp):
                idx = -1
        self.fallback[key] = idx
        return idx

    # ------------------------------------------------ keeping and warming glyph images (D-8002, mojoui.glyphwarm)

    def glyph_lines(self, most: Int) -> List[String]:
        """The glyph images rastered so far, one line each (at most `most`, oldest first): glyph id, device size,
        x offset, the instance's weight and optical size, its face (a file and index, or a system face's name). Glyph ids
        only: nothing says what text they were drawn for."""
        var names = Dict[Int, String]()
        for e in self.face_of_name.items():
            names[e.value] = e.key
        var out = List[String]()
        for e in self.image_of.items():
            if len(out) >= most:
                break
            var k = e.key >> 2
            var gid = (k >> 16) & 0xFFFFF
            var inst = k >> 36
            if inst < 0 or inst >= len(self.insts):
                continue
            var fi = self.insts[inst].face
            var face = ("n:" + names.get(fi, "")) if self.faces[fi].path == "" else ("p:" + String(self.faces[fi].index) + ":" + self.faces[fi].path)
            if face == "n:":
                continue
            out.append("G\t" + String(gid) + "\t" + String(self.image_dev[e.value]) + "\t" + String(e.key & 3) + "\t" + String(self.insts[inst].wght) + "\t" + String(self.insts[inst].opsz) + "\t" + face)
        return out^

    def warm_line(mut self, line: String) -> Bool:
        """A line of glyph_lines (its image rastered now, if its face is here and it isn't yet) or a style's ("S …", a run
        shaped in it, its faces ready). True when that did work."""
        var f = line.split("\t")
        try:
            if len(f) >= 5 and String(f[0]) == "S":
                var st = TextStyle(String(f[4]), Int(String(f[1])), String(f[2]) == "1", Float64(String(f[3])))
                _ = self.shape(st, "Hamburgefonstiv 0123456789")
                return True
            if len(f) >= 7 and String(f[0]) == "A":  # (eight characters of printable ASCII in a style, at a device scale)
                var st = TextStyle(String(f[4]), Int(String(f[1])), String(f[2]) == "1", Float64(String(f[3])))
                var c0 = Int(String(f[6]))
                var text = String("")
                for c in range(c0, min(c0 + 8, 127)):
                    text += chr(c)
                var n1 = len(self.images)
                var r = self.shape(st, text)
                for ref g in r.glyphs:
                    _ = self.image(g.inst, g.gid, st.size * Float64(String(f[5])), 0)
                return len(self.images) > n1
            if len(f) < 7 or String(f[0]) != "G":
                return False
            var face = -1
            var id = String(f[6])
            if id.startswith("n:"):
                var name = String(id[byte=2:id.byte_length()])
                face = self.face_of_name.get(name, -1)
                comptime if CompilationTarget.is_macos():
                    if face < 0:
                        var font = _fn[def(Int, Float64, Int) thin abi("C") -> Int](self._m(_M_CTBYNAME))(self._cfstr(name), 16.0, 0)
                        if font != 0:
                            face = self._face_from_ctfont(font, name == "AppleColorEmoji")
            else:
                var at = String(id[byte=2:id.byte_length()])
                var c = at.find(":")
                var index = Int(String(at[byte=0:c]))
                var path = String(at[byte=c + 1:at.byte_length()])
                face = self.face_of_file.get(path + "#" + String(index), -1)
                comptime if not CompilationTarget.is_macos():
                    if face < 0:
                        face = self._open_face(_Face(path, index, "", False, 400))
            if face < 0:
                return False
            var wght = Float64(String(f[4]))
            var opsz = Float64(String(f[5]))
            var n0 = len(self.images)
            var inst = self.inst(face, Int(wght) if wght > 0 else 400, opsz if opsz > 0 else 16.0)
            _ = self.image(inst, Int(String(f[1])), Float64(String(f[2])), Int(String(f[3])))
            return len(self.images) > n0
        except:
            return False

    # ------------------------------------------------ shaping

    def shape(mut self, st: TextStyle, text: String) -> Run:
        self.shapings += 1
        var run = Run()
        run.size = st.size
        var primary = self.pick(st.family, st.weight, st.italic)
        if primary < 0:
            primary = self.pick("Geist", st.weight, st.italic)
        if primary < 0:
            return run^
        var pinst = self.inst(primary, st.weight, st.size)
        ref pf = self.faces[primary]
        run.ascent = Float64(pf.asc) * st.size / Float64(pf.upem)
        run.descent = Float64(-pf.desc) * st.size / Float64(pf.upem)
        # one face per codepoint: the chosen face if it has it, the emoji face for emoji, else the system's choice;
        # marks, joiners and selectors stay with what they follow
        var cps = List[Int]()
        var offs = List[Int]()
        var off = 0
        for c in text.codepoints():
            cps.append(Int(c.to_u32()))
            offs.append(off)
            off += c.utf8_byte_length()
        var n = len(cps)
        var inst_at = List[Int](length=n, fill=pinst)
        for i in range(n):
            var cp = cps[i]
            var nxt = cps[i + 1] if i + 1 < n else 0
            if i > 0 and _follows(cp):
                inst_at[i] = inst_at[i - 1]
                continue
            if _is_emoji(cp, nxt):
                var ef = self.system_face(cp, True)
                if ef >= 0:
                    inst_at[i] = self.inst(ef, 400, st.size)
                    continue
            if self.has(pinst, cp) or cp == 0x20 or cp == 0x0A:
                continue
            var sf = self.system_face(cp, False, self.faces[primary].mono)
            if sf >= 0:
                inst_at[i] = self.inst(sf, st.weight, st.size)
        # shape each stretch of one face, with the whole text as context
        var pen = 0.0
        var i = 0
        var tp = text.as_bytes()
        while i < n:
            var j = i + 1
            while j < n and inst_at[j] == inst_at[i]:
                j += 1
            var inst = inst_at[i]
            var start = offs[i]
            var end = offs[j] if j < n else text.byte_length()
            pen = self._shape_part(run, inst, text, start, end - start, st, pen)
            i = j
        run.width = pen
        return run^

    def _shape_part(mut self, mut run: Run, inst: Int, text: String, start: Int, length: Int, st: TextStyle, pen0: Float64) -> Float64:
        comptime if CompilationTarget.is_macos():
            var t_sh = Int(now_ns())
            var r = self._mac_shape_part(run, inst, text, start, length, st, pen0)
            self.shape_n += 1
            self.shape_ns += Int(now_ns()) - t_sh
            return r
        var buf = self.hb_buf
        _fn[def(Int) thin abi("C") -> NoneType](self.hb_buffer_clear_contents)(buf)
        _fn[def(Int, Int, c_int, c_uint, c_int) thin abi("C") -> NoneType](self.hb_buffer_add_utf8)(
            buf, Int(text.unsafe_ptr()), c_int(text.byte_length()), c_uint(start), c_int(length))
        _fn[def(Int) thin abi("C") -> NoneType](self.hb_buffer_guess_segment_properties)(buf)
        var hb_font = self.insts[inst].hb_font
        var face = self.insts[inst].face
        _fn[def(Int, Int, Int, c_uint) thin abi("C") -> NoneType](self.hb_shape)(hb_font, buf, 0, c_uint(0))
        var count = List[UInt32](length=1, fill=0)
        var infos = _fn[def(Int, Int) thin abi("C") -> Int](self.hb_buffer_get_glyph_infos)(buf, Int(count.unsafe_ptr()))
        var poss = _fn[def(Int, Int) thin abi("C") -> Int](self.hb_buffer_get_glyph_positions)(buf, Int(count.unsafe_ptr()))
        var k = st.size / Float64(self.faces[face].upem)
        var pen = pen0
        for g in range(Int(count[0])):
            var gid = _peek_u32(infos + g * 20)
            var cl = _peek_u32(infos + g * 20 + 8)
            var xa = Float64(_peek_i32(poss + g * 20))
            var xo = Float64(_peek_i32(poss + g * 20 + 8))
            var yo = Float64(_peek_i32(poss + g * 20 + 12))
            if gid == 0:
                run.missing += 1
            run.glyphs.append(Glyph(face, inst, gid, pen + xo * k, yo * k, cl))
            # D-7903/D-7905: Chromium takes each advance from Skia (FreeType, variations applied) rounded to whole
            # layout px; HarfBuzz adds GPOS kerning on top (the part of its advance beyond its own glyph advance)
            var base = Float64(Int(_fn[def(Int, c_uint) thin abi("C") -> Int32](self.hb_font_get_glyph_h_advance)(hb_font, c_uint(gid))))
            var kern = (xa - base) * k
            var fa = Float64(self.advance_units(inst, gid)) * k
            var adv = Float64(Int(fa + 0.5)) if fa > 0 else 0.0
            var mode = self.kern_round.copy()
            if st.exact:
                adv = fa
                mode = "exact"
            if mode == "B":
                adv = Float64(Int(fa + kern + 0.5)) if fa + kern > 0 else 0.0
                kern = 0
            elif mode == "C":
                adv = adv + Float64(Int(kern + 0.5)) if kern >= 0 else adv - Float64(Int(-kern + 0.5))
                kern = 0
            elif mode == "D":
                var t = adv + kern
                adv = Float64(Int(t + 0.5)) if t >= 0 else -Float64(Int(-t + 0.5))
                kern = 0
            pen += adv + kern + st.letter_spacing
        return pen

    # ------------------------------------------------ rasterizing

    def _use(mut self, inst: Int):
        """FreeType's face set to this instance's design coordinates (one FT_Face per file, shared by its instances)."""
        ref ins = self.insts[inst]
        var fi = ins.face
        if self.faces[fi].coords_set == inst or len(self.faces[fi].axes) == 0:
            return
        var coords = List[Int]()
        for a in self.faces[fi].axes:
            var v = a.default
            if a.tag == _tag("wght"):
                v = ins.wght
            elif a.tag == _tag("opsz"):
                v = ins.opsz
            coords.append(Int(v * 65536.0))
        _ = _fn[def(Int, c_uint, Int) thin abi("C") -> c_int](self.FT_Set_Var_Design_Coordinates)(self.faces[fi].ft, c_uint(len(coords)), Int(coords.unsafe_ptr()))
        _ = coords
        self.faces[fi].coords_set = inst
        self.faces[fi].size_set = -1

    def advance_units(mut self, inst: Int, gid: Int) -> Int:
        """FreeType's advance of a glyph in font units with the instance's variations (what Skia hands Chromium's
        HarfBuzz: HVAR or gvar's phantom points, which HarfBuzz's own functions miss for some faces, D-7905)."""
        comptime if CompilationTarget.is_macos():
            return self._mac_advance_units(inst, gid)
        var key = inst * 1048576 + gid
        if key in self.adv_of:
            return self.adv_of.get(key, 0)
        self._use(inst)
        var a = List[Int](length=1, fill=0)
        _ = _fn[def(Int, c_uint, Int32, Int) thin abi("C") -> c_int](self.FT_Get_Advance)(self.faces[self.insts[inst].face].ft, c_uint(gid), Int32(1), Int(a.unsafe_ptr()))  # FT_LOAD_NO_SCALE
        var v = a[0]
        _ = a
        self.adv_of[key] = v
        return v

    def image(mut self, inst: Int, gid: Int, size_dev: Float64, subx: Int) -> Int:
        """The glyph at a device size (and a quarter-pixel x offset), rasterized once and cached; its index in images."""
        comptime if CompilationTarget.is_macos():
            return self._mac_image(inst, gid, size_dev, subx)
        var s64 = Int(size_dev * 64 + 0.5)
        var key = (((inst * 1048576 + gid) * 65536 + s64) << 2) | (subx & 3)
        if key in self.image_of:
            return self.image_of.get(key, 0)
        ref ins = self.insts[inst]
        var fi = ins.face
        var img = GlyphImage()
        var ft = self.faces[fi].ft
        if self.faces[fi].fixed:
            _ = _fn[def(Int, c_int) thin abi("C") -> c_int](self.FT_Select_Size)(ft, c_int(0))
        else:
            self._use(inst)
            if self.faces[fi].size_set != s64:
                var rs = _fn[def(Int, Int, Int, c_uint, c_uint) thin abi("C") -> c_int](self.FT_Set_Char_Size)(ft, 0, s64, c_uint(72), c_uint(72))
                if self.debug:
                    print("size", rs, s64)
                self.faces[fi].size_set = s64
        var delta = List[Int](length=2, fill=0)
        delta[0] = subx * 16
        _fn[def(Int, Int, Int) thin abi("C") -> NoneType](self.FT_Set_Transform)(ft, 0, Int(delta.unsafe_ptr()))
        _ = delta
        var flags = FT_LOAD_RENDER | (FT_LOAD_COLOR if self.faces[fi].color else self.hint)
        var rc = Int(_fn[def(Int, c_uint, Int32) thin abi("C") -> c_int](self.FT_Load_Glyph)(ft, c_uint(gid), Int32(flags)))
        if self.debug:
            print("FT_Load_Glyph", gid, rc, "slot", _peek(ft + 152), "rows", _peek_u32(_peek(ft + 152) + 152), "w", _peek_u32(_peek(ft + 152) + 156), "mode", _peek_u8(_peek(ft + 152) + 178))
        if rc == 0:
            var slot = _peek(ft + 152)
            var bm = slot + 152
            var rows = _peek_u32(bm)
            var width = _peek_u32(bm + 4)
            var pitch = _peek_i32(bm + 8)
            var buffer = _peek(bm + 16)
            var mode = _peek_u8(bm + 26)
            img.left = _peek_i32(slot + 192)
            img.top = _peek_i32(slot + 196)
            if mode == PIXEL_BGRA:
                # a colour bitmap at the strike's size: scaled to the asked size (as Chromium scales emoji)
                var ppem = _peek_u16(_peek(ft + 160) + 24)
                var sc = size_dev / Float64(ppem) if ppem > 0 else 1.0
                img = _scaled_bgra(buffer, Int(width), Int(rows), pitch, img.left, img.top, sc)
            elif buffer != 0:
                img.w = width
                img.h = rows
                img.cov = List[UInt8](capacity=width * rows)
                for y in range(rows):
                    var row = buffer + y * pitch
                    for x in range(width):
                        img.cov.append(UInt8(_peek_u8(row + x)))
        _fn[def(Int, Int, Int) thin abi("C") -> NoneType](self.FT_Set_Transform)(ft, 0, 0)
        self.images.append(img^)
        self.image_dev.append(size_dev)
        self.image_of[key] = len(self.images) - 1
        return len(self.images) - 1


    # ------------------------------------------------ the Mac: CoreText (goal 79 M1)

    def _m(self, i: Int) -> Int:
        return self.mac[i]

    def _mac_load(mut self) -> Bool:
        var dlopen = _dlsym(-2, "dlopen")
        var ct = self._open(dlopen, "/System/Library/Frameworks/CoreText.framework/CoreText")
        var cg = self._open(dlopen, "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        var cf = self._open(dlopen, "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        if ct == 0 or cg == 0 or cf == 0:
            self.error = "CoreText, CoreGraphics or CoreFoundation didn't load"
            return False
        var names: List[String] = [
            "CTFontCreateWithGraphicsFont", "CTFontDescriptorCreateWithAttributes", "CTFontGetGlyphsForCharacters", "CTFontCreateForString",
            "CTFontCopyGraphicsFont", "CTFontCreateWithName", "CTFontGetSymbolicTraits", "CTLineCreateWithAttributedString",
            "CTLineGetGlyphRuns", "CTRunGetGlyphCount", "CTRunGetGlyphs", "CTRunGetPositions", "CTRunGetAdvances", "CTRunGetAttributes",
            "CTFontGetAdvancesForGlyphs", "CTFontGetBoundingRectsForGlyphs", "CTFontDrawGlyphs", "CTFontCopyPostScriptName",
            "CGDataProviderCreateWithFilename", "CGFontCreateWithDataProvider", "CGFontGetUnitsPerEm", "CGFontGetAscent", "CGFontGetDescent",
            "CGColorSpaceCreateDeviceGray", "CGColorSpaceCreateDeviceRGB", "CGBitmapContextCreate", "CGContextSetGrayFillColor",
            "CGContextSetShouldSmoothFonts", "CGContextSetShouldAntialias", "CGContextSetAllowsFontSubpixelPositioning",
            "CGContextSetShouldSubpixelPositionFonts", "CGContextRelease", "CFStringCreateWithBytes", "CFAttributedStringCreate",
            "CFDictionaryCreate", "CFDictionaryGetValue", "CFNumberCreate", "CFArrayGetCount", "CFArrayGetValueAtIndex", "CFRelease",
            "CFStringGetCString", "CGFontGetLeading", "CGContextSetRGBFillColor", "CGFontCopyTableForTag", "CFDataGetBytePtr", "CFDataGetLength",
        ]
        for n in names:
            var lib = ct if n.startswith("CT") else (cg if n.startswith("CG") else cf)
            var a = _dlsym(lib, n)
            if a == 0:
                self.error = "missing " + n
                return False
            self.mac.append(a)
        self.k_font_attr = _peek(_dlsym(ct, "kCTFontAttributeName"))
        self.k_var_attr = _peek(_dlsym(ct, "kCTFontVariationAttribute"))
        var ta = _dlsym(ct, "kCTTrackingAttribute")
        self.k_track_attr = _peek(ta) if ta != 0 else 0
        self.k_dict_keys = _dlsym(cf, "kCFTypeDictionaryKeyCallBacks")
        self.k_dict_vals = _dlsym(cf, "kCFTypeDictionaryValueCallBacks")
        var dir = fonts_dir()
        for row in _registry():
            var path = dir + "/" + row[2]
            _ = self._mac_open_face(_Face(path, 0, row[0], row[1] == "italic", Int(atol(row[3]))))
        return True

    def _cfstr(self, s: String) -> Int:
        var t = s
        var r = _fn[def(Int, Int, Int, UInt32, UInt8) thin abi("C") -> Int](self._m(_M_CFSTR))(0, Int(t.unsafe_ptr()), t.byte_length(), UInt32(0x08000100), UInt8(0))
        _ = t
        return r

    def _cfnum_f(self, v: Float64) -> Int:
        var b = List[Float64](length=1, fill=v)
        var r = _fn[def(Int, Int, Int) thin abi("C") -> Int](self._m(_M_CFNUM))(0, 13, Int(b.unsafe_ptr()))  # kCFNumberDoubleType
        _ = b
        return r

    def _cfnum_i(self, v: Int) -> Int:
        var b = List[Int32](length=1, fill=Int32(v))
        var r = _fn[def(Int, Int, Int) thin abi("C") -> Int](self._m(_M_CFNUM))(0, 3, Int(b.unsafe_ptr()))  # kCFNumberSInt32Type
        _ = b
        return r

    def _cfdict(self, keys: List[Int], vals: List[Int]) -> Int:
        var r = _fn[def(Int, Int, Int, Int, Int, Int) thin abi("C") -> Int](self._m(_M_CFDICT))(0, Int(keys.unsafe_ptr()), Int(vals.unsafe_ptr()), len(keys), self.k_dict_keys, self.k_dict_vals)
        _ = keys
        _ = vals
        return r

    def _release(self, x: Int):
        if x != 0:
            _fn[def(Int) thin abi("C") -> NoneType](self._m(_M_CFRELEASE))(x)

    def _mac_open_face(mut self, var f: _Face) -> Int:
        var key = f.path + "#" + String(f.index)
        if f.path != "" and key in self.face_of_file:
            return self.face_of_file.get(key, -1)
        if f.ft == 0:  # (a file: a system face arrives with its CGFont already made)
            var p = f.path
            var prov = _fn[def(Int) thin abi("C") -> Int](self._m(_M_CGPROV))(Int(p.as_c_string_span().ptr()))
            _ = p
            if prov == 0:
                return -1
            f.ft = _fn[def(Int) thin abi("C") -> Int](self._m(_M_CGFONT))(prov)
            if f.ft == 0:
                return -1
            f.axes = read_fvar(f.path)
            f.color = has_table(f.path, "sbix") or has_table(f.path, "CBDT") or has_table(f.path, "COLR")
        f.upem = Int(_fn[def(Int) thin abi("C") -> c_int](self._m(_M_UPEM))(f.ft))
        var ctf = _fn[def(Int, Float64, Int, Int) thin abi("C") -> Int](self._m(_M_CTFONT))(f.ft, 16.0, 0, 0)
        if ctf != 0:  # (kCTFontTraitMonoSpace, 1 << 10)
            f.mono = (Int(_fn[def(Int) thin abi("C") -> UInt32](self._m(_M_TRAITS))(ctf)) & (1 << 10)) != 0
            self._release(ctf)
        var td = _fn[def(Int, UInt32) thin abi("C") -> Int](self._m(_M_CGTABLE))(f.ft, _tag("trak"))
        if td != 0:  # (D-7989) the face's tracking, as HarfBuzz reads it for Chrome
            var n = _fn[def(Int) thin abi("C") -> Int](self._m(_M_DATALEN))(td)
            var ptr = _fn[def(Int) thin abi("C") -> Int](self._m(_M_DATAPTR))(td)
            var bytes = List[UInt8](capacity=n)
            for q in range(n):
                bytes.append(Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=ptr + q)[])
            f.trak = parse_trak(bytes, 0)
            self._release(td)
        f.asc = Int(_fn[def(Int) thin abi("C") -> c_int](self._m(_M_ASC))(f.ft))
        f.desc = Int(_fn[def(Int) thin abi("C") -> c_int](self._m(_M_DESC))(f.ft))
        self.faces.append(f^)
        var idx = len(self.faces) - 1
        if self.faces[idx].path != "":
            self.face_of_file[key] = idx
        return idx

    def _mac_inst(mut self, face: Int, weight: Int, size: Float64) -> Int:
        ref f = self.faces[face]
        var wght = Float64(weight)
        var opsz = 0.0
        var has_w = False
        for a in f.axes:
            if a.tag == _tag("wght"):
                has_w = True
                wght = max(a.lo, min(a.hi, wght))
            if a.tag == _tag("opsz"):
                opsz = max(a.lo, min(a.hi, size))
        if not has_w:
            wght = 0
        var key = String(face) + ":" + String(Int(wght)) + ":" + String(Int(opsz * 4))
        if key in self.inst_of:
            return self.inst_of.get(key, 0)
        self.insts.append(_Inst(face, wght, opsz, 0))
        self.inst_of[key] = len(self.insts) - 1
        return len(self.insts) - 1

    def ct_font(mut self, inst: Int, size: Float64) -> Int:
        """The instance's CTFont at a size (its variations applied), made once."""
        var key = String(inst) + "@" + String(Int(size * 64 + 0.5))
        if key in self.ct_fonts:
            return self.ct_fonts.get(key, 0)
        var fi = self.insts[inst].face
        var desc = 0
        if len(self.faces[fi].axes) > 0:
            var keys = List[Int]()
            var vals = List[Int]()
            for a in self.faces[fi].axes:
                var v = a.default
                if a.tag == _tag("wght"):
                    v = self.insts[inst].wght
                elif a.tag == _tag("opsz"):
                    v = self.insts[inst].opsz
                keys.append(self._cfnum_i(Int(a.tag)))
                vals.append(self._cfnum_f(v))
            var vd = self._cfdict(keys, vals)
            var ak = List[Int](length=1, fill=self.k_var_attr)
            var av = List[Int](length=1, fill=vd)
            var attrs = self._cfdict(ak, av)
            desc = _fn[def(Int) thin abi("C") -> Int](self._m(_M_DESCR))(attrs)
        var font = _fn[def(Int, Float64, Int, Int) thin abi("C") -> Int](self._m(_M_CTFONT))(self.faces[fi].ft, size, 0, desc)
        self.ct_fonts[key] = font
        return font

    def _utf16(self, cp: Int) -> List[UInt16]:
        var out = List[UInt16]()
        if cp >= 0x10000:
            var v = cp - 0x10000
            out.append(UInt16(0xD800 + (v >> 10)))
            out.append(UInt16(0xDC00 + (v & 0x3FF)))
        else:
            out.append(UInt16(cp))
        return out^

    def _mac_has(mut self, inst: Int, cp: Int) -> Bool:
        var u = self._utf16(cp)
        var g = List[UInt16](length=len(u), fill=0)
        var ok = _fn[def(Int, Int, Int, Int) thin abi("C") -> UInt8](self._m(_M_GLYPHS4CHARS))(self.ct_font(inst, 16), Int(u.unsafe_ptr()), Int(g.unsafe_ptr()), len(u)) != 0
        var nonzero = g[0] != 0
        _ = u
        _ = g
        return ok and nonzero

    def _face_from_ctfont(mut self, font: Int, emoji: Bool) -> Int:
        var name = self._cf_text(_fn[def(Int) thin abi("C") -> Int](self._m(_M_PSNAME))(font))
        if name in self.face_of_name:
            return self.face_of_name.get(name, -1)
        var f = _Face("", 0, "", False, 400)
        f.ft = _fn[def(Int, Int) thin abi("C") -> Int](self._m(_M_COPYCG))(font, 0)
        f.color = emoji or (Int(_fn[def(Int) thin abi("C") -> UInt32](self._m(_M_TRAITS))(font)) & (1 << 13)) != 0
        f.apple_emoji = name == "AppleColorEmoji"
        var idx = self._mac_open_face(f^)
        self.face_of_name[name] = idx
        return idx

    def _cf_text(self, cfs: Int) -> String:
        if cfs == 0:
            return ""
        var buf = List[UInt8](length=512, fill=0)
        _ = _fn[def(Int, Int, Int, UInt32) thin abi("C") -> UInt8](self._m(_M_CFGETCSTR))(cfs, Int(buf.unsafe_ptr()), 511, UInt32(0x08000100))
        var n = 0
        while n < 511 and buf[n] != 0:
            n += 1
        return String(from_utf8_lossy=Span(buf)[:n])

    def _mac_system_face(mut self, cp: Int, emoji: Bool, mono: Bool = False) -> Int:
        var key = -1 if emoji else (cp * 2 + (1 if mono else 0))
        if key in self.fallback:
            return self.fallback.get(key, -1)
        var idx = -1
        if emoji:
            var n = self._cfstr("AppleColorEmoji")
            var font = _fn[def(Int, Float64, Int) thin abi("C") -> Int](self._m(_M_CTBYNAME))(n, 16.0, 0)
            if font != 0:
                idx = self._face_from_ctfont(font, True)
        else:
            # (D-7981) Chrome on the Mac falls back to PingFang SC for Han ideographs and CJK punctuation with no language
            # given (measured: 世、， 36.69 device px at 18 px ×2, as PingFang SC; kana from the cascade, 36.0)
            if (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x3000 and cp <= 0x303F) or (cp >= 0xFF00 and cp <= 0xFFEF):
                var pn = self._cfstr("PingFangSC-Regular")
                var pf = _fn[def(Int, Float64, Int) thin abi("C") -> Int](self._m(_M_CTBYNAME))(pn, 16.0, 0)
                if pf != 0:
                    var pidx = self._face_from_ctfont(pf, False)
                    if pidx >= 0 and self._mac_has(self.inst(pidx, 400, 16), cp):
                        self.fallback[key] = pidx
                        return pidx
            # (D-7990) Chrome on the Mac falls back by the primary's kind: a monospaced web face cascades from Menlo
            # (measured: ⌥ ⌘ in Geist Mono → Menlo, 6.625 px at 11 px), a proportional one from the system's (Lucida
            # Grande for ⌥ ⌘)
            var base = self.pick("Geist", 400, False)
            if mono:
                var mn = self._cfstr("Menlo-Regular")
                var mf = _fn[def(Int, Float64, Int) thin abi("C") -> Int](self._m(_M_CTBYNAME))(mn, 16.0, 0)
                if mf != 0:
                    var midx = self._face_from_ctfont(mf, False)
                    if midx >= 0 and self._mac_has(self.inst(midx, 400, 16), cp):
                        self.fallback[key] = midx
                        return midx
            var s = String(chr(cp))
            var cfs = self._cfstr(s)
            var u = self._utf16(cp)
            var font = _fn[def(Int, Int, Int, Int) thin abi("C") -> Int](self._m(_M_FORSTRING))(self.ct_font(self.inst(base, 400, 16), 16), cfs, 0, len(u))
            if font != 0:
                idx = self._face_from_ctfont(font, False)
                if idx >= 0 and not self._mac_has(self.inst(idx, 400, 16), cp):
                    idx = -1
        self.fallback[key] = idx
        return idx

    def _mac_advance_units(mut self, inst: Int, gid: Int) -> Int:
        var key = inst * 1048576 + gid
        if key in self.adv_of:
            return self.adv_of.get(key, 0)
        var upem = Float64(self.faces[self.insts[inst].face].upem)
        var g = List[UInt16](length=1, fill=UInt16(gid))
        var adv = List[Float64](length=2, fill=0)
        _ = _fn[def(Int, UInt32, Int, Int, Int) thin abi("C") -> Float64](self._m(_M_ADVANCES))(self.ct_font(inst, upem), UInt32(0), Int(g.unsafe_ptr()), Int(adv.unsafe_ptr()), 1)
        var v = Int(adv[0] + 0.5)
        _ = g
        self.adv_of[key] = v
        return v

    def _mac_shape_part(mut self, mut run: Run, inst: Int, text: String, start: Int, length: Int, st: TextStyle, pen0: Float64) -> Float64:
        """A stretch of one face shaped by CoreText (CTLine: kerning, ligatures, marks), its advances taken as Chrome on the
        Mac takes them (D-7981: unrounded); FONTTEXT_KERN_ROUND=D gives Linux Chromium's rule (D-7905: the face's own
        advance rounded, plus the kerning CoreText adds, rounded again)."""
        var part = String(text[byte=start:start + length])
        var cfs = self._cfstr(part)
        var font = self.ct_font(inst, st.size)
        var ak = List[Int](length=1, fill=self.k_font_attr)
        var av = List[Int](length=1, fill=font)
        var zero = 0
        if self.trak_on and self.k_track_attr != 0:  # (D-7989) CoreText's own tracking off: the face's trak is added below, as HarfBuzz adds it
            zero = self._cfnum_f(0.0)
            ak.append(self.k_track_attr)
            av.append(zero)
        var attrs = self._cfdict(ak, av)
        var astr = _fn[def(Int, Int, Int) thin abi("C") -> Int](self._m(_M_ATTRSTR))(0, cfs, attrs)
        var line = _fn[def(Int) thin abi("C") -> Int](self._m(_M_LINE))(astr)
        var runs = _fn[def(Int) thin abi("C") -> Int](self._m(_M_RUNS))(line)
        var nr = _fn[def(Int) thin abi("C") -> Int](self._m(_M_ARRCOUNT))(runs)
        var face = self.insts[inst].face
        var k = st.size / Float64(self.faces[face].upem)
        var pen = pen0
        for ri in range(nr):
            var r = _fn[def(Int, Int) thin abi("C") -> Int](self._m(_M_ARRAT))(runs, ri)
            var n = _fn[def(Int) thin abi("C") -> Int](self._m(_M_RUNCOUNT))(r)
            var glyphs = List[UInt16](length=n, fill=0)
            var pos = List[Float64](length=2 * n, fill=0)
            var adv = List[Float64](length=2 * n, fill=0)
            _fn[def(Int, Int, Int, Int) thin abi("C") -> NoneType](self._m(_M_RUNGLYPHS))(r, 0, 0, Int(glyphs.unsafe_ptr()))
            _fn[def(Int, Int, Int, Int) thin abi("C") -> NoneType](self._m(_M_RUNPOS))(r, 0, 0, Int(pos.unsafe_ptr()))
            _fn[def(Int, Int, Int, Int) thin abi("C") -> NoneType](self._m(_M_RUNADV))(r, 0, 0, Int(adv.unsafe_ptr()))
            # the run's own font (CoreText may substitute): its face, as fallback does on Linux
            var rinst = inst
            var rattrs = _fn[def(Int) thin abi("C") -> Int](self._m(_M_RUNATTRS))(r)
            var rfont = _fn[def(Int, Int) thin abi("C") -> Int](self._m(_M_DICTGET))(rattrs, self.k_font_attr)
            if rfont != 0 and rfont != font:
                rinst = self.inst(self._face_from_ctfont(rfont, False), st.weight, st.size)
            var rk = st.size / Float64(self.faces[self.insts[rinst].face].upem)
            if self.trace:  # (FONTTEXT_TRACE=1, diagnosis: the run's font as CoreText chose it and its advances)
                var line_t = String("FONTTEXT RUN: ") + self._cf_text(_fn[def(Int) thin abi("C") -> Int](self._m(_M_PSNAME))(rfont if rfont != 0 else font))
                line_t += " asked " + self._cf_text(_fn[def(Int) thin abi("C") -> Int](self._m(_M_PSNAME))(font)) + " size " + String(st.size) + " n " + String(n) + " adv"
                for g in range(n):
                    line_t += " " + String(adv[2 * g]) + "/" + String(Float64(self._mac_advance_units(rinst, Int(glyphs[g]))) * rk)
                print(line_t, flush=True)
            var unrounded = 0.0
            var apple = self.faces[self.insts[rinst].face].apple_emoji
            ref rtk = self.faces[self.insts[rinst].face].trak
            # (a colour bitmap face takes no trak: Chrome's emoji advances don't follow that table, D-7989, D-7998)
            var track = trak_units(rtk, st.size) * rk if self.trak_on and not rtk.empty() and not self.faces[self.insts[rinst].face].color else 0.0
            for g in range(n):
                var gid = Int(glyphs[g])
                if gid == 0:
                    run.missing += 1
                var xo = pos[2 * g] - unrounded
                run.glyphs.append(Glyph(self.insts[rinst].face, rinst, gid, pen + xo + track / 2, -pos[2 * g + 1], 0))
                var fa = Float64(self._mac_advance_units(rinst, gid)) * rk
                var kern = adv[2 * g] - fa
                var a = fa + kern
                if not st.exact and self.kern_round != "exact":  # (D-7981: on the Mac, Chrome's advances aren't rounded)
                    var ar = Float64(Int(fa + 0.5)) if fa > 0 else 0.0
                    var t = ar + kern
                    a = Float64(Int(t + 0.5)) if t >= 0 else -Float64(Int(-t + 0.5))
                unrounded += adv[2 * g]
                if apple and adv[2 * g] > 0:  # (D-7998; a mark or joiner without an advance keeps none)
                    a = apple_emoji_advance(st.size)
                pen += a + track + st.letter_spacing
            _ = glyphs
            _ = pos
            _ = adv
        self._release(line)
        self._release(astr)
        self._release(attrs)
        self._release(zero)
        self._release(cfs)
        _ = ak
        _ = av
        _ = k
        return pen

    def _mac_image(mut self, inst: Int, gid: Int, size_dev: Float64, subx: Int) -> Int:
        var s64 = Int(size_dev * 64 + 0.5)
        var key = (((inst * 1048576 + gid) * 65536 + s64) << 2) | (subx & 3)
        if key in self.image_of:
            return self.image_of.get(key, 0)
        var t_img = Int(now_ns())
        var img = GlyphImage()
        var font = self.ct_font(inst, size_dev)
        var color = self.faces[self.insts[inst].face].color
        var g = List[UInt16](length=1, fill=UInt16(gid))
        var rect = List[Float64](length=4, fill=0)
        _ = _fn[def(Int, UInt32, Int, Int, Int) thin abi("C") -> Float64](self._m(_M_BOUNDS))(font, UInt32(0), Int(g.unsafe_ptr()), Int(rect.unsafe_ptr()), 1)
        if rect[2] > 0 and rect[3] > 0:
            var x0 = Int(rect[0] + Float64(subx) / 4 + 1e6) - 1000000 - 1
            var y0 = Int(rect[1] + 1e6) - 1000000 - 1
            var x1 = Int(rect[0] + rect[2] + Float64(subx) / 4 + 1e6) - 1000000 + 2
            var y1 = Int(rect[1] + rect[3] + 1e6) - 1000000 + 2
            var w = x1 - x0
            var h = y1 - y0
            img.w = w
            img.h = h
            img.left = x0
            img.top = y1
            img.color = color
            var bpp = 4 if color else 1
            var buf = List[UInt8](length=w * h * bpp, fill=0)
            var cs = _fn[def() thin abi("C") -> Int](self._m(_M_RGB if color else _M_GRAY))()
            var info = 1 if color else 0  # kCGImageAlphaPremultipliedLast | none
            var ctx = _fn[def(Int, Int, Int, Int, Int, Int, UInt32) thin abi("C") -> Int](self._m(_M_BITMAP))(Int(buf.unsafe_ptr()), w, h, 8, w * bpp, cs, UInt32(info))
            if ctx != 0:
                _fn[def(Int, UInt8) thin abi("C") -> NoneType](self._m(_M_AA))(ctx, UInt8(1))
                _fn[def(Int, UInt8) thin abi("C") -> NoneType](self._m(_M_SMOOTH))(ctx, UInt8(0))
                _fn[def(Int, UInt8) thin abi("C") -> NoneType](self._m(_M_SUBPOS_OK))(ctx, UInt8(1))
                _fn[def(Int, UInt8) thin abi("C") -> NoneType](self._m(_M_SUBPOS))(ctx, UInt8(1))
                if color:
                    _fn[def(Int, Float64, Float64, Float64, Float64) thin abi("C") -> NoneType](self._m(_M_RGBFILL))(ctx, 0, 0, 0, 1)
                else:
                    _fn[def(Int, Float64, Float64) thin abi("C") -> NoneType](self._m(_M_GRAYFILL))(ctx, 1, 1)
                var p = List[Float64](length=2, fill=0)
                p[0] = -Float64(x0) + Float64(subx) / 4
                p[1] = -Float64(y0)
                _fn[def(Int, Int, Int, Int, Int) thin abi("C") -> NoneType](self._m(_M_DRAW))(font, Int(g.unsafe_ptr()), Int(p.unsafe_ptr()), 1, ctx)
                _ = p
                _fn[def(Int) thin abi("C") -> NoneType](self._m(_M_CTXREL))(ctx)
            self._release(cs)
            if color:
                img.rgba = List[UInt32](capacity=w * h)
                for i in range(w * h):
                    img.rgba.append(UInt32(buf[4 * i]) | (UInt32(buf[4 * i + 1]) << 8) | (UInt32(buf[4 * i + 2]) << 16) | (UInt32(buf[4 * i + 3]) << 24))
            else:
                img.cov = buf^
        _ = g
        _ = rect
        self.images.append(img^)
        self.image_dev.append(size_dev)
        self.image_of[key] = len(self.images) - 1
        self.img_n += 1
        self.img_ns += Int(now_ns()) - t_img
        return len(self.images) - 1

    def _mac_metrics(mut self, st: TextStyle) -> LineMetrics:
        var fi = self.pick(st.family, st.weight, st.italic)
        if fi < 0:
            fi = self.pick("Geist", st.weight, st.italic)
        if fi < 0:
            return LineMetrics(Int(st.size * 0.9 + 0.5), Int(st.size * 0.25 + 0.5), 0)
        var k = st.size / Float64(self.faces[fi].upem)
        var asc = Float64(self.faces[fi].asc) * k
        var desc = -Float64(self.faces[fi].desc) * k
        var gap = Float64(Int(_fn[def(Int) thin abi("C") -> c_int](self._m(_M_LEADING))(self.faces[fi].ft))) * k
        return LineMetrics(Int(asc + 0.5), Int(desc + 0.5), max(0.0, gap))


def truncate_i32(v: Int) -> Int:
    var x = v & 0xFFFFFFFF
    return x - (1 << 32) if x >= (1 << 31) else x


def atol(s: String) -> Int:
    var n = 0
    for c in s.codepoints():
        var d = Int(c.to_u32()) - 48
        if d < 0 or d > 9:
            break
        n = n * 10 + d
    return n


def _scaled_bgra(buffer: Int, w: Int, h: Int, pitch: Int, left: Int, top: Int, sc: Float64) -> GlyphImage:
    """A BGRA strike scaled by sc with a box filter (premultiplied RGBA words out)."""
    var img = GlyphImage()
    img.color = True
    var ow = max(1, Int(Float64(w) * sc + 0.5))
    var oh = max(1, Int(Float64(h) * sc + 0.5))
    img.w = ow
    img.h = oh
    img.left = Int(Float64(left) * sc + 0.5) if left >= 0 else -Int(-Float64(left) * sc + 0.5)
    img.top = Int(Float64(top) * sc + 0.5)
    img.rgba = List[UInt32](capacity=ow * oh)
    for oy in range(oh):
        var y0 = Float64(oy) / sc
        var y1 = min(Float64(h), Float64(oy + 1) / sc)
        for ox in range(ow):
            var x0 = Float64(ox) / sc
            var x1 = min(Float64(w), Float64(ox + 1) / sc)
            var r = 0.0
            var g = 0.0
            var b = 0.0
            var a = 0.0
            var area = 0.0
            var yy = Int(y0)
            while Float64(yy) < y1 and yy < h:
                var wy = min(y1, Float64(yy + 1)) - max(y0, Float64(yy))
                var xx = Int(x0)
                while Float64(xx) < x1 and xx < w:
                    var wx = min(x1, Float64(xx + 1)) - max(x0, Float64(xx))
                    var p = buffer + yy * pitch + xx * 4
                    var wgt = wx * wy
                    b += Float64(_peek_u8(p)) * wgt
                    g += Float64(_peek_u8(p + 1)) * wgt
                    r += Float64(_peek_u8(p + 2)) * wgt
                    a += Float64(_peek_u8(p + 3)) * wgt
                    area += wgt
                    xx += 1
                yy += 1
            if area > 0:
                r /= area
                g /= area
                b /= area
                a /= area
            img.rgba.append(UInt32(Int(r + 0.5)) | (UInt32(Int(g + 0.5)) << 8) | (UInt32(Int(b + 0.5)) << 16) | (UInt32(Int(a + 0.5)) << 24))
    return img^


def _follows(cp: Int) -> Bool:
    """Codepoints that belong to what comes before them: combining marks, joiners, variation selectors, skin tones,
    Indic and other spacing/non-spacing marks (ranges, not the full Unicode table)."""
    if cp == 0x200D or cp == 0x200C or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0x1F3FB and cp <= 0x1F3FF) or (cp >= 0xE0020 and cp <= 0xE007F):
        return True
    if (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or (cp >= 0x20D0 and cp <= 0x20FF):
        return True
    if cp >= 0x0900 and cp <= 0x0DFF:  # Devanagari … Sinhala: vowel signs and viramas
        var lo = cp & 0x7F
        return (lo >= 0x3A and lo <= 0x4F) or (lo >= 0x00 and lo <= 0x03) or (lo >= 0x51 and lo <= 0x57) or lo == 0x62 or lo == 0x63
    if cp >= 0x064B and cp <= 0x065F:  # Arabic harakat
        return True
    if cp >= 0x3099 and cp <= 0x309A:
        return True
    return False


def _is_emoji(cp: Int, nxt: Int) -> Bool:
    """Emoji presentation: asked for by U+FE0F, or the default for these blocks (Chromium sends them to the emoji face)."""
    if nxt == 0xFE0F:
        return True
    if nxt >= 0x1F3FB and nxt <= 0x1F3FF:
        return True
    return (cp >= 0x1F300 and cp <= 0x1F5FF) or (cp >= 0x1F600 and cp <= 0x1F64F) or (cp >= 0x1F680 and cp <= 0x1F6FF) or (
        cp >= 0x1F900 and cp <= 0x1FAFF) or (cp >= 0x1F1E6 and cp <= 0x1F1FF)


def css_weight(want: Int, have: Span[Int, _]) -> Int:
    """CSS font matching (css-fonts-4 §5.2): 400–500 look up to 500, then down, then up; lighter looks down first, heavier up."""
    var below = -1
    var above = -1
    var to500 = -1
    for w in have:
        if w == want:
            return want
        if w < want and w > below:
            below = w
        if w > want and (above < 0 or w < above):
            above = w
        if want >= 400 and want <= 500 and w > want and w <= 500 and (to500 < 0 or w < to500):
            to500 = w
    if want >= 400 and want <= 500:
        return to500 if to500 >= 0 else (below if below >= 0 else (above if above >= 0 else want))
    if want < 400:
        return below if below >= 0 else (above if above >= 0 else want)
    return above if above >= 0 else (below if below >= 0 else want)


def declare_face(family: String, italic: Bool, weights: List[Int], opsz: Int = 0):
    """FontEngine.declare on the process's engine (call it while the app starts)."""
    engine()[].declare(family, italic, weights, opsz)


def _registry() -> List[List[String]]:
    """The web app's faces: family, style, file under fonts/, weight of a static file (0: variable). The same table
    as docs/goals/79/ref.mjs's FACES."""
    var r = List[List[String]]()
    r.append(["Geist", "normal", "geist/Geist[wght].ttf", "0"])
    r.append(["Geist", "italic", "geist/Geist-Italic[wght].ttf", "0"])
    r.append(["Geist Mono", "normal", "geistmono/GeistMono[wght].ttf", "0"])
    r.append(["Bricolage Grotesque", "normal", "bricolagegrotesque/BricolageGrotesque[opsz,wdth,wght].ttf", "0"])
    r.append(["IBM Plex Sans", "normal", "ibmplexsans/IBMPlexSans[wdth,wght].ttf", "0"])
    r.append(["IBM Plex Sans", "italic", "ibmplexsans/IBMPlexSans-Italic[wdth,wght].ttf", "0"])
    r.append(["IBM Plex Mono", "normal", "ibmplexmono/IBMPlexMono-Regular.ttf", "400"])
    r.append(["IBM Plex Mono", "normal", "ibmplexmono/IBMPlexMono-Medium.ttf", "500"])
    r.append(["IBM Plex Mono", "normal", "ibmplexmono/IBMPlexMono-SemiBold.ttf", "600"])
    r.append(["Source Serif 4", "normal", "sourceserif4/SourceSerif4[opsz,wght].ttf", "0"])
    r.append(["Source Serif 4", "italic", "sourceserif4/SourceSerif4-Italic[opsz,wght].ttf", "0"])
    r.append(["Instrument Serif", "normal", "instrumentserif/InstrumentSerif-Regular.ttf", "400"])
    r.append(["Instrument Serif", "italic", "instrumentserif/InstrumentSerif-Italic.ttf", "400"])
    r.append(["Caveat", "normal", "caveat/Caveat[wght].ttf", "0"])
    r.append(["Literata", "normal", "literata/Literata[opsz,wght].ttf", "0"])
    r.append(["Literata", "italic", "literata/Literata-Italic[opsz,wght].ttf", "0"])
    r.append(["Figtree", "normal", "figtree/Figtree[wght].ttf", "0"])
    r.append(["Figtree", "italic", "figtree/Figtree-Italic[wght].ttf", "0"])
    return r^


def _exe_dir() -> String:
    var buf = List[UInt8](length=4096, fill=0)
    var p = String("/proc/self/exe")
    var n = Int(external_call["readlink", Int](p.as_c_string_span().ptr(), buf.unsafe_ptr(), 4095))
    if n <= 0:
        return "."
    var s = String(from_utf8_lossy=Span(buf)[:n])
    var cut = s.rfind("/")
    return String(s[byte=:cut]) if cut > 0 else "."


def _exists(path: String) -> Bool:
    var p = path
    return external_call["access", c_int](p.as_c_string_span().ptr(), c_int(0)) == 0


def fonts_dir() -> String:
    """MOJOUI_FONTS, else fonts/ next to the program, else the checkout's fonts/ (build/<app>/<platform>/ → ../../..),
    else ./fonts."""
    var env = getenv("MOJOUI_FONTS", "")
    if env != "":
        return env
    var exe = _exe_dir()
    for cand in [exe + "/fonts", exe + "/../../../fonts", exe + "/../Resources/fonts", String("fonts")]:
        if _exists(cand + "/geist/OFL.txt"):
            return cand
    return "fonts"


def engine() -> Pointer[FontEngine, MutUntrackedOrigin]:
    """The process's FontEngine, made and loaded on first use."""
    var have = get_shared(SLOT_FONTS)
    if have != 0:
        return Pointer[FontEngine, MutUntrackedOrigin](unsafe_from_address=have)
    var allocation = alloc(Layout[FontEngine].single())
    var p = allocation^.unsafe_leak()
    p.unsafe_write(FontEngine())
    var addr = Int(p)
    var e = Pointer[FontEngine, MutUntrackedOrigin](unsafe_from_address=addr)
    if not e[].load():
        print("fonttext: " + e[].error)
    put_shared(SLOT_FONTS, addr)
    return e


def _run_key(st: TextStyle, text: String) -> String:
    return st.family + "|" + String(st.weight) + ("i" if st.italic else "") + "|" + String(st.size) + "|" + String(st.letter_spacing) + ("x" if st.exact else "") + "|" + text


def shape(st: TextStyle, text: String) -> Run:
    """The shaped run, from the process's cache when this style and text were shaped before (bounded: cleared at 8,192
    entries)."""
    var e = engine()
    var key = _run_key(st, text)
    var hit = e[].runs.get(key)
    if hit:
        return hit.value().copy()
    var r = e[].shape(st, text)
    var sk = String(st.weight) + "\t" + ("1" if st.italic else "0") + "\t" + String(st.size) + "\t" + st.family
    if sk not in e[].styles_seen and len(e[].styles_seen) < 512:
        e[].styles_seen[sk] = True
    if len(e[].runs) >= 8192:
        e[].runs = Dict[String, Run]()
    e[].runs[key] = r.copy()
    return r^


def measure(st: TextStyle, text: String) -> Float64:
    """The width of `text` in layout px: from the run cache when it was shaped, else from a cache of widths (D-8007: a
    panel measures its labels every time it is drawn, and shaping one is 10 µs to 1 ms); bounded, cleared at 32,768
    widths. A width is only kept, not the run: a wrap tries thousands of texts it never draws."""
    var e = engine()
    var key = _run_key(st, text)
    var w = e[].widths.get(key, -1.0)
    if w >= 0:
        return w
    try:
        if key in e[].runs:
            return e[].runs[key].width
    except:
        pass
    w = e[].shape(st, text).width
    if len(e[].widths) >= 32768:
        e[].widths = Dict[String, Float64]()
    e[].widths[key] = w
    return w


def _blend_cov(d: UInt32, color: UInt32, cov: Int) -> UInt32:
    var a = cov * Int((color >> 24) & 0xFF)  # 0..65025
    if a <= 0:
        return d
    var ia = 65025 - a
    var r = (Int(color & 0xFF) * a + Int(d & 0xFF) * ia + 32512) // 65025
    var g = (Int((color >> 8) & 0xFF) * a + Int((d >> 8) & 0xFF) * ia + 32512) // 65025
    var b = (Int((color >> 16) & 0xFF) * a + Int((d >> 16) & 0xFF) * ia + 32512) // 65025
    return UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (d & 0xFF000000)


def _blend_rgba(d: UInt32, s: UInt32, alpha: Int) -> UInt32:
    """A premultiplied colour pixel over d, times alpha (0–255)."""
    var sa = Int((s >> 24) & 0xFF) * alpha // 255
    if sa <= 0:
        return d
    var ia = 255 - sa
    var r = (Int(s & 0xFF) * alpha // 255) + (Int(d & 0xFF) * ia + 127) // 255
    var g = (Int((s >> 8) & 0xFF) * alpha // 255) + (Int((d >> 8) & 0xFF) * ia + 127) // 255
    var b = (Int((s >> 16) & 0xFF) * alpha // 255) + (Int((d >> 16) & 0xFF) * ia + 127) // 255
    return UInt32(min(r, 255)) | (UInt32(min(g, 255)) << 8) | (UInt32(min(b, 255)) << 16) | (d & 0xFF000000)


@fieldwise_init
struct Clip(ImplicitlyCopyable, Movable):
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int


def draw_run(mut s: Surface, run: Run, x: Float64, baseline: Float64, k: Float64, color: UInt32, clip: Clip):
    """The run into pixels: x, baseline in device px, k device px per layout px; each glyph on a whole device pixel."""
    var e = engine()
    var size_dev = run.size * k
    var by = Int(baseline + 0.5) if baseline >= 0 else Int(baseline - 0.5)
    for g in run.glyphs:
        var gx = x + g.x * k
        var px = Int(gx + 0.5) if gx >= 0 else Int(gx - 0.5)
        var py = by - (Int(g.y * k + 0.5) if g.y >= 0 else Int(g.y * k - 0.5))
        var ii = e[].image(g.inst, g.gid, size_dev, 0)
        ref img = e[].images[ii]
        if img.w == 0:
            continue
        var ox = px + img.left
        var oy = py - img.top
        var x0 = max(ox, clip.x0, 0)
        var y0 = max(oy, clip.y0, 0)
        var x1 = min(ox + img.w, clip.x1, s.width)
        var y1 = min(oy + img.h, clip.y1, s.height)
        if x0 >= x1 or y0 >= y1:
            continue
        var pix = s.pixels()
        for yy in range(y0, y1):
            var row = yy * s.width
            var irow = (yy - oy) * img.w - ox
            for xx in range(x0, x1):
                var q = pix.unsafe_offset(row + xx)
                if img.color:
                    q[] = _blend_rgba(q[], img.rgba[irow + xx], Int((color >> 24) & 0xFF))
                else:
                    var c = Int(img.cov[irow + xx])
                    if c > 0:
                        q[] = _blend_cov(q[], color, c)


def run_x(run: Run, x: Float64, align: Int) -> Float64:
    """Where a run starts so that it sits at x with this alignment (layout px)."""
    if align == ALIGN_CENTER:
        return x - run.width / 2
    if align == ALIGN_RIGHT:
        return x - run.width
    return x


@fieldwise_init
struct LineMetrics(ImplicitlyCopyable, Movable):
    """A face's vertical metrics at a size, as Blink keeps them: ascent and descent rounded to whole px, the line gap."""
    var ascent: Int
    var descent: Int
    var gap: Float64

    def normal_height(self) -> Float64:
        """line-height: normal."""
        return Float64(self.ascent + self.descent) + self.gap


def line_metrics(st: TextStyle) -> LineMetrics:
    var e = engine()
    comptime if CompilationTarget.is_macos():
        return e[]._mac_metrics(st)
    var fi = e[].pick(st.family, st.weight, st.italic)
    if fi < 0:
        fi = e[].pick("Geist", st.weight, st.italic)
    if fi < 0:
        return LineMetrics(Int(st.size * 0.9 + 0.5), Int(st.size * 0.25 + 0.5), 0)
    var inst = e[].inst(fi, st.weight, st.size)
    e[]._use(inst)  # (FreeType applies MVAR's metric deltas for the instance: Literata's ascent moves with opsz)
    var ft = e[].faces[fi].ft
    if e[].faces[fi].fixed:  # (a bitmap face, Noto Color Emoji: FreeType's outline metrics are 0 for it; its strike's, scaled, as Skia)
        _ = _fn[def(Int, c_int) thin abi("C") -> c_int](e[].FT_Select_Size)(ft, c_int(0))
        var sz = _peek(ft + 160)
        var ppem = Float64(_peek_u16(sz + 24))
        if ppem > 0:
            var up = Float64(_peek(sz + 48)) / 64 * st.size / ppem
            var down = -Float64(_peek(sz + 56)) / 64 * st.size / ppem
            return LineMetrics(Int(up + 0.5), Int(down + 0.5), 0)
    var k = st.size / Float64(e[].faces[fi].upem)
    var asc = Float64(_peek_i16(ft + 138)) * k
    var desc = -Float64(_peek_i16(ft + 140)) * k
    var height = Float64(_peek_i16(ft + 142)) * k  # FT_Face.height: ascender − descender + line gap
    return LineMetrics(Int(asc + 0.5), Int(desc + 0.5), max(0.0, height - asc - desc))


def baseline_in(top: Float64, line_height: Float64, st: TextStyle) -> Float64:
    """Where the baseline of a line of `st` text sits in a line box of this height starting at top (CSS: half the leading
    above, floored as Blink lays it out; checked against the reference's text boxes)."""
    var m = line_metrics(st)
    var lead = line_height - Float64(m.ascent + m.descent)
    var half = lead / 2
    var h = Float64(Int(half)) if half >= 0 else -Float64(Int(-half + 0.999999))
    return top + h + Float64(m.ascent)



def _read_file(path: String) -> List[UInt8]:
    try:
        with open(path, "r") as f:
            return f.read_bytes()
    except:
        return List[UInt8]()


def _be16(b: List[UInt8], at: Int) -> Int:
    return (Int(b[at]) << 8) | Int(b[at + 1])


def _be32(b: List[UInt8], at: Int) -> Int:
    return (Int(b[at]) << 24) | (Int(b[at + 1]) << 16) | (Int(b[at + 2]) << 8) | Int(b[at + 3])


def _table(b: List[UInt8], tag: String) -> Int:
    """Where an sfnt table starts in the file (-1: none)."""
    if len(b) < 12:
        return -1
    var want = Int(_tag(tag))
    var n = _be16(b, 4)
    for i in range(n):
        var rec = 12 + 16 * i
        if rec + 16 > len(b):
            break
        if _be32(b, rec) == want:
            return _be32(b, rec + 8)
    return -1


def has_table(path: String, tag: String) -> Bool:
    return _table(_read_file(path), tag) >= 0


def read_fvar(path: String) -> List[_Axis]:
    """A variable font's axes (tag, min, default, max) from its fvar table, read from the file (the Mac's CoreText path:
    the same axes HarfBuzz reports on Linux)."""
    var out = List[_Axis]()
    var b = _read_file(path)
    var t = _table(b, "fvar")
    if t < 0:
        return out^
    var axes_at = t + _be16(b, t + 4)
    var count = _be16(b, t + 8)
    var size = _be16(b, t + 10)
    for i in range(count):
        var a = axes_at + i * size
        var mn = Float64(_be32(b, a + 4) - ((1 << 32) if _be32(b, a + 4) >= (1 << 31) else 0)) / 65536.0
        var df = Float64(_be32(b, a + 8) - ((1 << 32) if _be32(b, a + 8) >= (1 << 31) else 0)) / 65536.0
        var mx = Float64(_be32(b, a + 12) - ((1 << 32) if _be32(b, a + 12) >= (1 << 31) else 0)) / 65536.0
        out.append(_Axis(UInt32(_be32(b, a)), mn, df, mx))
    return out^


def apple_emoji_advance(size: Float64) -> Float64:
    """(D-7998) What Apple Color Emoji advances in Chrome on the Mac at a font size (layout px): 5/4 of the size below
    16, half the size + 12 from 16 to 24, the size from there on, rounded half up to a whole px. Agrees with Chrome 158
    at every whole size measured (10–40 px, docs/goals/79/emoji-chrome-mac.json, tests/test_emojiadvance); sizes between
    whole ones and outside 10–40 aren't measured yet."""
    var a = 1.25 * size if size < 16 else (0.5 * size + 12 if size < 24 else size)
    return Float64(Int(a + 0.5))


@fieldwise_init
struct Trak(Copyable, Movable):
    """(D-7989) A face's AAT 'trak' table, its normal track (value 0): font units added to every glyph's advance at a
    size, by size. Apple's system faces carry one (PingFang, Apple Color Emoji); Chrome on the Mac applies it through
    HarfBuzz at the CSS size, CoreText's CTLine doesn't (or not the same), so the Mac's widths follow it here."""
    var sizes: List[Float64]
    var values: List[Int]

    def empty(self) -> Bool:
        return len(self.values) == 0


def parse_trak(b: List[UInt8], t: Int) -> Trak:
    """The normal track of a 'trak' table starting at byte t of b (empty: none, or not a horizontal one)."""
    var none = Trak(List[Float64](), List[Int]())
    if t < 0 or t + 12 > len(b):
        return none^
    var ho = _be16(b, t + 6)
    if ho == 0 or t + ho + 8 > len(b):
        return none^
    var td = t + ho
    var nt = _be16(b, td)
    var ns = _be16(b, td + 2)
    var so = t + _be32(b, td + 4)
    if ns == 0 or nt == 0 or so + 4 * ns > len(b) or td + 8 + 8 * nt > len(b):
        return none^
    var pick = 0  # (the track whose value is 0, "normal"; else the first)
    for k in range(nt):
        if _be32(b, td + 8 + 8 * k) == 0:
            pick = k
            break
    var vo = t + _be16(b, td + 8 + 8 * pick + 6)
    if vo + 2 * ns > len(b):
        return none^
    var sizes = List[Float64]()
    var values = List[Int]()
    for i in range(ns):
        var s = _be32(b, so + 4 * i)
        sizes.append(Float64(s - (1 << 32) if s >= (1 << 31) else s) / 65536.0)
        var v = _be16(b, vo + 2 * i)
        values.append(v - 65536 if v >= 32768 else v)
    return Trak(sizes^, values^)


def trak_units(tk: Trak, ptem: Float64) -> Float64:
    """The tracking at size ptem in font units, as HarfBuzz computes it (hb-aat-layout-trak-table): below the first
    size the first value, past the last the last, between two sizes linear in the size."""
    var n = len(tk.values)
    if n == 0:
        return 0.0
    if n == 1:
        return Float64(tk.values[0])
    var i = 0
    while i < n and tk.sizes[i] < ptem:
        i += 1
    if i == 0:
        return Float64(tk.values[0])
    if i == n:
        return Float64(tk.values[n - 1])
    var s0 = tk.sizes[i - 1]
    var s1 = tk.sizes[i]
    var t = 0.0 if s0 == s1 else (ptem - s0) / (s1 - s0)
    return t * Float64(tk.values[i]) + (1.0 - t) * Float64(tk.values[i - 1])
