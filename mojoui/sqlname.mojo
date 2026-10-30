# mojoui.sqlname: a card's name as SQL reads it (no omxcore, so code that only names tables, like mojoui.links, can use it
# where the engine isn't linked). mojoui.tablecard re-exports it.


def sql_name(name: String) -> String:
    """A table's name as SQL reads it: the last part after " · " (a card titled "warehouse.mp4 · detections" is
    `detections`), lower case, every run of other characters one "_"; "t" + it when it starts with a digit."""
    var base = name
    var dot = name.rfind(" · ")
    if dot >= 0:
        base = String(name[byte = dot + len(String(" · ").as_bytes()) :])
    var out = String()
    var gap = False
    for b in base.lower().as_bytes():
        var ok = (b >= UInt8(97) and b <= UInt8(122)) or (b >= UInt8(48) and b <= UInt8(57))
        if ok:
            if gap and out.byte_length() > 0:
                out += "_"
            out += chr(Int(b))
            gap = False
        else:
            gap = True
    if out.byte_length() == 0:
        return String("t")
    var first = out.as_bytes()[0]
    if first >= UInt8(48) and first <= UInt8(57):
        return "t" + out
    return out^
