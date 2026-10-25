# Tiny Objective-C runtime helpers, so Mojo can drive AppKit and UIKit directly.
#
# Every Apple UI call is a message: objc_msgSend(object, selector, args...).
# Mojo can't declare one C symbol with several signatures in a module, so we
# look objc_msgSend's address up once per call and cast it to the exact C
# signature of that call: msg(button, "setTag:", 42), msg[Float64](view, "alpha").
#
# Apple Silicon only (arm64). There, a CGRect/NSRect (or edge insets) passed by
# value travels in four float registers, exactly like four Float64 arguments,
# so we pass rects as x, y, width, height. That would be wrong on Intel Macs.
#
# Pass Objective-C BOOLs as Int 1 or 0, not Mojo Bool, so the whole register is set.

from std.ffi import external_call
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc

comptime RTLD_DEFAULT = -2  # Apple's "search every loaded library" handle


def cls(name: String) -> Int:
    """Looks up an Objective-C class, e.g. cls("NSButton")."""
    var n = name
    return external_call["objc_getClass", Int](n.as_c_string_span())


def sel(name: String) -> Int:
    """Looks up a selector (method name), e.g. sel("setTitle:")."""
    var n = name
    return external_call["sel_registerName", Int](n.as_c_string_span())


def protocol(name: String) -> Int:
    var n = name
    return external_call["objc_getProtocol", Int](n.as_c_string_span())


def msg[T: RegisterPassable = Int, *A: AnyType](obj: Int, name: String, *args: *A) -> T:
    """Sends a message: [obj name:args...]. T is the C return type (default: an object/Int)."""
    var fn_name = String("objc_msgSend")
    var addr = external_call["dlsym", Int](RTLD_DEFAULT, fn_name.as_c_string_span())
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    var send = Pointer(to=raw).unsafe_bitcast[
        def(o: Int, s: Int, *a: *A) thin abi("C") -> T
    ]()[]
    return send(obj, sel(name), *args)


def new(class_name: String) -> Int:
    """[[Class alloc] init], e.g. new("NSStackView")."""
    return msg(cls(class_name), "new")


def ns_string(text: String) -> Int:
    """Makes an NSString from a Mojo String (UTF-8; no terminator needed)."""
    comptime UTF8 = 4  # NSUTF8StringEncoding
    var s = msg(cls("NSString"), "alloc")
    s = msg(s, "initWithBytes:length:encoding:", Int(text.unsafe_ptr()), text.byte_length(), UTF8)
    return msg(s, "autorelease")


def new_class(name: String, superclass: String) -> Int:
    """Creates (but doesn't register yet) a new Objective-C class at runtime."""
    var n = name
    return external_call["objc_allocateClassPair", Int](cls(superclass), n.as_c_string_span(), 0)


def add_method[F: AnyType](c: Int, selector: String, imp: F, types: String):
    """Adds a method whose body is a Mojo `abi("C")` function.

    `types` is the Objective-C type encoding, e.g. "v@:@" = returns void, takes (self, _cmd, id).
    """
    var t = types
    _ = external_call["class_addMethod", Int8](c, sel(selector), imp, t.as_c_string_span())


def add_protocol(c: Int, name: String):
    var p = protocol(name)
    if p == 0:  # never add a null entry; say so, since UIKit may then reject the class
        print("mojo-ui: Objective-C protocol not found:", name)
        return
    _ = external_call["class_addProtocol", Int8](c, p)


def register_class(c: Int):
    external_call["objc_registerClassPair", NoneType](c)


def pool_push() -> Int:
    return external_call["objc_autoreleasePoolPush", Int]()


def from_ns(ns: Int) -> String:
    """Copies an NSString into a Mojo String (via its UTF-8 bytes)."""
    if ns == 0:
        return ""
    var utf8 = msg(ns, "UTF8String")
    if utf8 == 0:
        return ""
    return String(unsafe_from_utf8_ptr=Pointer[Int8, MutUntrackedOrigin](unsafe_from_address=utf8))


def ns_data(bytes: List[UInt8]) -> Int:
    """An NSData copy of some bytes."""
    return msg(cls("NSData"), "dataWithBytes:length:", Int(bytes.unsafe_ptr()), len(bytes))


def constrain(view: Int, anchor: String, points: Float64):
    """Auto Layout: fix a view's width or height (anchor = "widthAnchor"/"heightAnchor")."""
    var c = msg(msg(view, anchor), "constraintEqualToConstant:", points)
    _ = msg(c, "setActive:", 1)


def fn_address[F: ImplicitlyCopyable & Deinitable](f: F) -> Int:
    """The machine address of a Mojo `abi("C")` function."""
    var copy = f
    return Pointer(to=copy).unsafe_bitcast[Int]()[]


def global_block[F: ImplicitlyCopyable & Deinitable](invoke: F, signature: String) -> Int:
    """An Objective-C block whose body is a Mojo `abi("C")` function.

    Built by hand as a *global* block (the kind the compiler emits for blocks that
    capture nothing): {isa, flags+reserved, invoke, descriptor} (32 bytes) with a descriptor
    {reserved, size, signature}. Copying a global block returns it unchanged, so
    APIs that keep the block (like UIAction's handler) are safe. It lives forever.
    `invoke` must take the block itself first, then the block's arguments.
    """
    comptime BLOCK_IS_GLOBAL = 1 << 28
    comptime BLOCK_HAS_SIGNATURE = 1 << 30
    var isa_name = String("_NSConcreteGlobalBlock")
    var isa = external_call["dlsym", Int](RTLD_DEFAULT, isa_name.as_c_string_span())
    var sig = unsafe_alloc[Int8](signature.byte_length() + 1)  # C string, kept forever
    for i in range(signature.byte_length()):
        sig.unsafe_offset(i).unsafe_write(Int8(signature.as_bytes()[i]))
    sig.unsafe_offset(signature.byte_length()).unsafe_write(Int8(0))
    var desc = unsafe_alloc[Int](3)
    desc.unsafe_write(0)  # reserved
    desc.unsafe_offset(1).unsafe_write(32)  # sizeof the block literal
    desc.unsafe_offset(2).unsafe_write(Int(sig))
    var block = unsafe_alloc[Int](4)
    block.unsafe_write(isa)
    block.unsafe_offset(1).unsafe_write(BLOCK_IS_GLOBAL | BLOCK_HAS_SIGNATURE)  # flags (low 32 bits), reserved = 0
    block.unsafe_offset(2).unsafe_write(fn_address(invoke))
    block.unsafe_offset(3).unsafe_write(Int(desc))
    return Int(block)


def data_block[F: ImplicitlyCopyable & Deinitable](invoke: F, signature: String, data: Int) -> Int:
    """Like global_block, plus one word of data stored right after the block header.

    The invoke function receives the block itself first, so it reads the data back
    with block_data(block). (A real compiler-made block keeps captured values in
    the same place.) It lives forever, so copying it is safe.
    """
    var base = global_block(invoke, signature)  # 32-byte header we copy, then extend
    var block = unsafe_alloc[Int](5)
    for k in range(4):
        block.unsafe_offset(k).unsafe_write(Pointer[Int, MutUntrackedOrigin](unsafe_from_address=base + 8 * k)[])
    block.unsafe_offset(4).unsafe_write(data)
    var desc = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=block.unsafe_offset(3)[])
    var new_desc = unsafe_alloc[Int](3)
    new_desc.unsafe_write(0)
    new_desc.unsafe_offset(1).unsafe_write(40)  # header + one captured word
    new_desc.unsafe_offset(2).unsafe_write(Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(desc) + 16)[])
    block.unsafe_offset(3).unsafe_write(Int(new_desc))
    return Int(block)


def block_data(block: Int) -> Int:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=block + 32)[]


def ns_array(items: List[String]) -> Int:
    """An NSArray of NSStrings."""
    var a = msg(cls("NSMutableArray"), "array")
    for s in items:
        _ = msg(a, "addObject:", ns_string(s))
    return a


def ns_number(n: Int) -> Int:
    return msg(cls("NSNumber"), "numberWithLong:", n)


def _date_part(text: String, k: Int, fallback: Int) -> Int:
    try:
        var parts = text.split("-")
        if len(parts) == 3:
            return Int(String(parts[k]))
    except:
        pass
    return fallback


def ns_date(text: String) -> Int:
    """An NSDate (noon, local time) from "YYYY-MM-DD"."""
    var c = msg(msg(cls("NSDateComponents"), "new"), "autorelease")
    _ = msg(c, "setYear:", _date_part(text, 0, 2000))
    _ = msg(c, "setMonth:", _date_part(text, 1, 1))
    _ = msg(c, "setDay:", _date_part(text, 2, 1))
    _ = msg(c, "setHour:", 12)
    return msg(msg(cls("NSCalendar"), "currentCalendar"), "dateFromComponents:", c)


def date_text(date: Int) -> String:
    """ "YYYY-MM-DD" for an NSDate, in local time."""
    comptime YEAR_MONTH_DAY = 4 | 8 | 16  # NSCalendarUnitYear | Month | Day
    var c = msg(msg(cls("NSCalendar"), "currentCalendar"), "components:fromDate:", YEAR_MONTH_DAY, date)
    var y = msg(c, "year")
    var m = msg(c, "month")
    var d = msg(c, "day")
    return String(y) + "-" + ("0" if m < 10 else "") + String(m) + "-" + ("0" if d < 10 else "") + String(d)


def sf_symbol(name: String) -> String:
    """mojoui icon names → SF Symbols (Apple's own icon set)."""
    if name == "star": return "star.fill"
    if name == "trash": return "trash"
    if name == "copy": return "doc.on.doc"
    if name == "gear": return "gearshape"
    if name == "plus": return "plus"
    if name == "check": return "checkmark"
    if name == "calendar": return "calendar"
    if name == "search": return "magnifyingglass"
    if name == "heart": return "heart.fill"
    if name == "home": return "house"
    if name == "person": return "person"
    if name == "travel": return "airplane"
    if name == "food": return "fork.knife"
    if name == "fun": return "gamecontroller"
    if name == "chart": return "chart.bar"
    # the Lucide set (mojoui/icons_data.mojo), by meaning
    if name == "table": return "tablecells"
    if name == "pivot": return "tablecells.badge.ellipsis"
    if name == "chart-bar": return "chart.bar.xaxis"
    if name == "note": return "note.text"
    if name == "undo": return "arrow.uturn.backward"
    if name == "redo": return "arrow.uturn.forward"
    if name == "save": return "square.and.arrow.down"
    if name == "open": return "folder"
    if name == "close": return "xmark"
    if name == "sort": return "arrow.up.arrow.down"
    if name == "filter-off": return "line.3.horizontal.decrease.circle"
    if name == "row-plus": return "plus.rectangle"
    if name == "row-minus": return "minus.rectangle"
    if name == "view": return "eye"
    if name == "zoom": return "plus.magnifyingglass"
    if name == "category": return "square.grid.2x2"
    if name == "formula": return "function"
    if name == "comment": return "text.bubble"
    if name == "shape": return "square.on.circle"
    if name == "text": return "textformat"
    if name == "organise": return "slider.horizontal.3"
    if name == "format": return "paintbrush"
    if name == "share": return "square.and.arrow.up"
    if name == "import": return "square.and.arrow.down.on.square"
    if name == "database": return "cylinder"
    if name == "sample": return "sparkles"
    if name == "grid": return "square.grid.3x3"
    if name == "sheet": return "doc.text"
    if name == "file": return "doc"
    if name == "export": return "square.and.arrow.up.on.square"
    if name == "upload": return "arrow.up.doc"
    if name == "chevron": return "chevron.down"
    if name == "chevron-right": return "chevron.right"
    if name == "back": return "chevron.left"
    if name == "bold": return "bold"
    if name == "italic": return "italic"
    if name == "underline": return "underline"
    if name == "strikethrough": return "strikethrough"
    if name == "text-colour": return "character"
    if name == "fill": return "drop"
    if name == "align-left": return "text.alignleft"
    if name == "align-center": return "text.aligncenter"
    if name == "align-right": return "text.alignright"
    if name == "currency": return "dollarsign"
    if name == "percent": return "percent"
    if name == "decimals-less": return "arrow.left.to.line"
    if name == "decimals-more": return "arrow.right.to.line"
    if name == "clear-format": return "eraser"
    if name == "rename": return "pencil"
    if name == "copy": return "doc.on.doc"
    if name == "settings": return "gearshape"
    return "questionmark.square.dashed"


def prefer(view: Int, anchor: String, points: Float64):
    """A control's default size, as a *preferred* constraint (priority 480: above hugging (250), below the 500 at
    which a window keeps its size and the 495 that holds a scroll view's content to its width, so a default never
    widens a window or a panel: a divider's 280 pt ran an inspector's text past its edge, GitHub's Mac, 2026-10-23).
    Hosts only add it when the app hasn't sized the view itself."""
    var c = msg(msg(view, anchor), "constraintEqualToConstant:", points)
    _ = msg(c, "setPriority:", Float32(480))
    _ = msg(c, "setActive:", 1)
