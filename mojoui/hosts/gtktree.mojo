# A GTK widget tree as words, for the "patched screen = fresh screen" test (goal 81, M1: the treedump: step): every
# readable property of every widget under one (as GObject lists them; objects, boxed pointers and moment-to-moment state
# left out), what the properties don't say (a text view's words, a picture's pixels, a list's rows, places in a grid or a
# fixed) and the size each widget asks for. Two windows showing the same screen give the same words.
from std.ffi import external_call, c_int, c_uint, c_char
from std.memory import Pointer

comptime MOMENT = [  # (state of the moment, or of the window, not of the screen)
    "has-focus", "is-focus", "has-default", "scale-factor", "cursor-position", "selection-bound", "state-flags", "name", "can-undo", "can-redo",
    "estimated-size", "mapped", "transition-running", "im-module", "position", "activates-default", "popup-shown", "css-name",
]


def _int(addr: Int) -> Int:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)[]


def _u32(addr: Int) -> UInt32:
    return Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=addr)[]


def _str(addr: Int) -> String:
    if addr == 0:
        return ""
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


def type_name(obj: Int) -> String:
    return _str(external_call["g_type_name_from_instance", Int](obj))


def is_a(obj: Int, name: String) -> Bool:
    var n = name
    var t = external_call["g_type_from_name", Int](n.as_c_string_span())
    return t != 0 and external_call["g_type_check_instance_is_a", c_int](obj, t) != 0


def _properties(obj: Int) -> String:
    var count = List[c_uint](length=2, fill=0)
    var specs = external_call["g_object_class_list_properties", Int](_int(obj), Int(count.unsafe_ptr()))
    var words = List[String]()
    var skip = materialize[MOMENT]()
    for k in range(Int(count[0])):
        var spec = _int(specs + 8 * k)
        var name = _str(_int(spec + 8))
        var flags = _u32(spec + 16)
        var kind = _int(spec + 24)
        if flags & 1 == 0 or name in skip or external_call["g_type_is_a", c_int](kind, Int(80)) != 0:  # (unreadable, the moment's, an object)
            continue
        var v = List[Int](length=3, fill=0)  # a GValue
        _ = external_call["g_value_init", Int](Int(v.unsafe_ptr()), kind)
        external_call["g_object_get_property", NoneType](obj, _int(spec + 8), Int(v.unsafe_ptr()))
        var raw = external_call["g_strdup_value_contents", Int](Int(v.unsafe_ptr()))
        var text = _str(raw)
        external_call["g_free", NoneType](raw)
        external_call["g_value_unset", NoneType](Int(v.unsafe_ptr()))
        _ = len(v)  # (kept alive past the call: a pointer as an Int isn't a use)
        if name == "css-classes":  # (a set: their order says nothing)
            var classes = List[String]()
            for c in text.removeprefix("[").removesuffix("]").split(", "):
                classes.append(String(c))
            sort(classes)
            text = String(",").join(classes)
        if text.find("0x") < 0:
            words.append(name + "=" + text.replace("\n", "\\n"))
    external_call["g_free", NoneType](specs)
    _ = len(count)
    sort(words)
    return String(" ").join(words)


def _more(w: Int, kind: String) -> String:
    var out = String("")
    if kind == "GtkTextView":
        var buffer = external_call["gtk_text_view_get_buffer", Int](w)
        var start = List[Int](length=16, fill=0)
        var end = List[Int](length=16, fill=0)
        external_call["gtk_text_buffer_get_bounds", NoneType](buffer, Int(start.unsafe_ptr()), Int(end.unsafe_ptr()))
        var raw = external_call["gtk_text_buffer_get_text", Int](buffer, Int(start.unsafe_ptr()), Int(end.unsafe_ptr()), c_int(0))
        out += " words='" + _str(raw).replace("\n", "\\n") + "'"
        external_call["g_free", NoneType](raw)
        _ = len(start)
        _ = len(end)
    elif kind == "GtkPicture":
        var tex = external_call["gtk_picture_get_paintable", Int](w)
        if tex != 0 and is_a(tex, "GdkTexture"):
            var tw = Int(external_call["gdk_texture_get_width", c_int](tex))
            var th = Int(external_call["gdk_texture_get_height", c_int](tex))
            var px = List[UInt32](length=tw * th, fill=0)
            external_call["gdk_texture_download", NoneType](tex, Int(px.unsafe_ptr()), Int(tw * 4))
            var h = UInt64(14695981039346656037)
            for p in px:
                h = (h ^ UInt64(p)) * 1099511628211
            out += " picture=" + String(tw) + "x" + String(th) + "/" + String(h)
    elif kind == "GtkListView":
        out += " rows=" + String(external_call["g_list_model_get_n_items", c_uint](external_call["gtk_list_view_get_model", Int](w)))
    var parent = external_call["gtk_widget_get_parent", Int](w)
    if parent != 0:
        var pk = type_name(parent)
        if pk == "GtkFixed":
            var xy = List[Float64](length=2, fill=0)
            external_call["gtk_fixed_get_child_position", NoneType](parent, w, Int(xy.unsafe_ptr()), Int(xy.unsafe_ptr()) + 8)
            _ = len(xy)
            out += " place=" + String(xy[0]) + "," + String(xy[1])
        elif pk == "GtkGrid":
            var q = List[c_int](length=4, fill=0)
            var p = Int(q.unsafe_ptr())
            external_call["gtk_grid_query_child", NoneType](parent, w, p, p + 4, p + 8, p + 12)
            _ = len(q)
            out += " cell=" + String(q[0]) + "," + String(q[1]) + "," + String(q[2]) + "," + String(q[3])
    var m = List[c_int](length=4, fill=0)
    var mp = Int(m.unsafe_ptr())
    external_call["gtk_widget_measure", NoneType](w, c_int(0), c_int(-1), mp, mp + 4, Int(0), Int(0))
    external_call["gtk_widget_measure", NoneType](w, c_int(1), c_int(-1), mp + 8, mp + 12, Int(0), Int(0))
    _ = len(m)
    return out + " asks=" + String(m[0]) + "/" + String(m[1]) + "x" + String(m[2]) + "/" + String(m[3])


def _walk(w: Int, depth: Int, mut out: String):
    var kind = type_name(w)
    if kind == "GtkPopover" or kind == "GtkPopoverMenu" or kind == "GtkMagnifier":  # (built when they open)
        return
    out += " " * depth + kind + " " + _properties(w) + _more(w, kind) + "\n"
    if kind == "GtkCalendar" or kind == "GtkTextView" or kind == "GtkText" or kind == "GtkListView" or kind == "GtkScrollbar":  # (their insides are theirs)
        return
    var c = external_call["gtk_widget_get_first_child", Int](w)
    while c != 0:
        _walk(c, depth + 1, out)
        c = external_call["gtk_widget_get_next_sibling", Int](c)


def tree_words(widget: Int) -> String:
    """The widget and everything in it, a line each, indented by depth."""
    var out = String("")
    _walk(widget, 0, out)
    return out
