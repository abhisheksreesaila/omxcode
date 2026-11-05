# mojoui.partialjson: JSON that is still arriving, made whole (goal 48 M1). An agent streams a tool call's arguments a
# few bytes at a time; to draw what it's building before it finishes, cut the text back to the last place it was valid
# and close what's open. A string still being written is kept (closed where it stops); a key without its value, a number
# or a literal still being written, and a trailing comma are dropped. Arrays named in `placeholder_keys` get one more
# item at their end while they're open: `placeholder` (a Skeleton, where the next components will come).
#
#   complete('{"ui":{"component":"Card","title":"Sal')          → '{"ui":{"component":"Card","title":"Sal"}}'
#   complete('{"a":[1,2', "children", '{"x":1}')                 → '{"a":[1,2]}'   (only "children" arrays get one)
#
# Linear in the text; never raises; "" when nothing whole has arrived yet (no '{' or '['), or it nests past MAX_LEVELS.


@fieldwise_init
struct Level(Copyable, Movable):
    var array: Bool
    var key: String  # an array: the key it's the value of; an object: the key being read or last read
    var items: Int  # values in it: whole ones, and the one still arriving


comptime MAX_LEVELS = 64  # deeper than any UI it is used for (genui: 8 levels): past it, nothing is shown (and the
                          # copies of the open levels kept at each whole value stay small: linear whatever comes)


def _closers(levels: List[Level], placeholder_key: String, placeholder: String) -> String:
    var out = String("")
    for k in range(len(levels) - 1, -1, -1):
        ref l = levels[k]
        if l.array:
            if placeholder.byte_length() > 0 and l.key == placeholder_key:
                out += ("," if l.items > 0 else "") + placeholder
            out += "]"
        else:
            out += "}"
    return out^


def complete(text: String, placeholder_key: String = "", placeholder: String = "") -> String:
    """`text`, a prefix of a JSON object or array, cut back to its last whole value and closed."""
    var b = text.as_bytes()
    var n = len(b)
    var levels = List[Level]()
    var safe = -1  # bytes of `text` that end at a whole value (or just after an opening bracket)
    var safe_levels = List[Level]()
    var in_string = False
    var string_is_key = False
    var string_start = 0
    var escape = False
    var expect_key = False  # in an object, the next string is a key
    var key = String("")
    var started = False
    var i = 0
    while i < n:
        var c = b[i]
        if in_string:
            if escape:
                escape = False
            elif c == 92:  # \
                escape = True
            elif c == 34:  # "
                in_string = False
                if string_is_key:
                    key = String(text[byte = string_start + 1 : i])
                    if len(levels) > 0:
                        levels[len(levels) - 1].key = key
                else:
                    if len(levels) > 0:
                        levels[len(levels) - 1].items += 1
                    safe = i + 1
                    safe_levels = levels.copy()
            i += 1
            continue
        if c == 34:
            in_string = True
            string_start = i
            string_is_key = expect_key
            expect_key = False
        elif c == 123 or c == 91:  # { [
            if len(levels) >= MAX_LEVELS:
                return ""
            var akey = levels[len(levels) - 1].key if len(levels) > 0 and not levels[len(levels) - 1].array else String("")
            if len(levels) > 0:
                levels[len(levels) - 1].items += 1  # (counted when it opens: a placeholder after a child still arriving needs its comma)
            levels.append(Level(c == 91, akey if c == 91 else String(""), 0))
            expect_key = c == 123
            started = True
            safe = i + 1
            safe_levels = levels.copy()
        elif c == 125 or c == 93:  # } ]
            if len(levels) == 0:
                break
            _ = levels.pop()
            expect_key = False
            safe = i + 1
            safe_levels = levels.copy()
            if len(levels) == 0:
                return String(text[byte = : i + 1])
        elif c == 44:  # ,
            expect_key = len(levels) > 0 and not levels[len(levels) - 1].array
        elif c == 58:  # :
            expect_key = False
        elif c == 32 or c == 10 or c == 13 or c == 9:
            pass
        else:  # a number or a literal: whole once the next delimiter comes
            var j = i
            while j < n and not (b[j] == 44 or b[j] == 125 or b[j] == 93 or b[j] == 32 or b[j] == 10 or b[j] == 13 or b[j] == 9):
                j += 1
            if j < n:
                if len(levels) > 0:
                    levels[len(levels) - 1].items += 1
                safe = j
                safe_levels = levels.copy()
            i = j
            continue
        i += 1
    if not started:
        return ""
    if in_string and not string_is_key:  # a value still being written: keep what has come
        var end = n
        if escape:
            end -= 1  # (a lone backslash)
        else:
            var k = n - 1  # (a \u escape without its four hex digits)
            while k > string_start and k > n - 6 and b[k] != 92:
                k -= 1
            if k > string_start and b[k] == 92 and k + 1 < n and b[k + 1] == 117 and n - k < 6:
                end = k
        if len(levels) > 0:
            levels[len(levels) - 1].items += 1
        return String(text[byte = : end]) + '"' + _closers(levels, placeholder_key, placeholder)
    if safe < 0:
        return ""
    return String(text[byte = : safe]) + _closers(safe_levels, placeholder_key, placeholder)
