# mojoui.route: where the app is, as a path ("/", "/keys", "/models/qwen2.5-0.5b/logs"). Route(path, on_change) puts it in
# the screen (nothing to see): the web keeps it in the URL's hash, so a link opens the app there, a change writes the URL
# and Back and Forward go through the app's own places (each sends on_change, event.text = the new path); on GTK and
# the Mac it's state the app keeps. A Router is the app's table of pages, by pattern; it reads a path into a Match (the
# page and its params), writes a Match back as a path, and gives each page's breadcrumb trail. It knows no app's pages.
#
#   var pages = Router("home").page("home", "/", ["My models"])
#                             .page("keys", "/keys", ["API keys"])
#                             .page("model", "/models/:name*/:tab(overview|logs)?", ["My models", ":name"])
#   view(): Route(self.path, on_change=ROUTE)            update(): ROUTE → self.path = pages.canonical(event.text)
#   var m = pages.parse(self.path)                       # m.page "model", m["name"] "org/qwen", m["tab"] "logs"
#
# Patterns, segment by segment: a literal (matched without case: "/KEYS" is /keys), ":name" (one segment, not empty),
# ":name*" (one or more segments joined by "/": a Hugging Face org/repo), ":name(a|b)" (one of these words), and a
# trailing "?" makes the last segment optional (its param is "" when absent; path_for leaves it out). %XX escapes are
# read as their bytes in params (bytes that aren't UTF-8 become U+FFFD) and written back by path_for.

from mojoui.view import View, Node, ROUTE, _one
from mojoui.http import utf8_lossy


def Route(path: String, on_change: Int) -> View:
    """The app's place: `path` ("/" home). On the web the URL's hash follows it and a new hash (a link, Back, Forward)
    sends `on_change` with event.text = the path ("/" for no hash)."""
    return _one(Node(ROUTE, path, on_change))


def hex_digit(c: Int) -> Int:
    if 48 <= c <= 57:
        return c - 48
    if 97 <= c <= 102:
        return c - 87
    if 65 <= c <= 70:
        return c - 55
    return -1


def unescape(s: String) -> String:
    """%XX escapes as their bytes (a URL's model name: %2F is a slash); a broken escape stays as it is; bytes that don't
    make UTF-8 become U+FFFD (a link is anyone's text: it never makes a String of bad UTF-8)."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        if Int(b[i]) == 37 and i + 2 < len(b) and hex_digit(Int(b[i + 1])) >= 0 and hex_digit(Int(b[i + 2])) >= 0:
            out.append(UInt8(hex_digit(Int(b[i + 1])) * 16 + hex_digit(Int(b[i + 2]))))
            i += 3
        else:
            out.append(b[i])
            i += 1
    return utf8_lossy(out)


def escape(s: String, slashes: Bool = True) -> String:
    """A param for a path: what encodeURIComponent escapes, but slashes stay slashes (`slashes`: a Hugging Face
    org/repo in a ":name*" param; False escapes them too, for a one-segment param)."""
    var digits = "0123456789ABCDEF"
    var out = String("")
    for c in s.as_bytes():
        var o = Int(c)
        var plain = (48 <= o <= 57) or (65 <= o <= 90) or (97 <= o <= 122) or o == 45 or o == 95 or o == 46 or o == 33 or o == 126 or o == 42 or o == 39 or o == 40 or o == 41 or (o == 47 and slashes)
        if plain:
            out += chr(o)
        else:
            out += "%" + String(digits[byte = o // 16]) + String(digits[byte = o % 16])
    return out


def segments(path: String) -> List[String]:
    """A path's segments: a leading "#" and "/" dropped, then split at "/" ("" and "/" have none)."""
    var p = String(path.strip())
    if p.startswith("#"):
        var rest = String(p[byte=1:])
        p = rest
    if p.startswith("/"):
        var rest = String(p[byte=1:])
        p = rest
    var out = List[String]()
    if p == "":
        return out^
    for part in p.split("/"):
        out.append(String(part))
    return out^


struct Match(Copyable, Movable, Equatable):
    """A path read by a Router: its page's name ("" when nothing matched and the router has no fallback) and its params."""

    var page: String
    var names: List[String]
    var values: List[String]

    def __init__(out self, page: String):
        self.page = page
        self.names = List[String]()
        self.values = List[String]()

    def with_param(var self, name: String, value: String) -> Self:
        """This match with `name` set to `value` (to build a place to go to: Match("model").with_param("name", n))."""
        self.set(name, value)
        return self^

    def set(mut self, name: String, value: String):
        for i in range(len(self.names)):
            if self.names[i] == name:
                self.values[i] = value
                return
        self.names.append(name)
        self.values.append(value)

    def __getitem__(self, name: String) -> String:
        """The param's value ("" when the match has none)."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                return self.values[i]
        return ""

    def __eq__(self, other: Self) -> Bool:
        if self.page != other.page or len(self.names) != len(other.names):
            return False
        for i in range(len(self.names)):
            if other[self.names[i]] != self.values[i]:
                return False
        return True


@fieldwise_init
struct Seg(Copyable, Movable):
    """One segment of a pattern."""

    var literal: String  # a literal's words ("" for a param)
    var param: String  # a param's name
    var rest: Bool  # ":name*": one or more segments
    var choices: List[String]  # ":name(a|b)": one of these (empty: any)
    var optional: Bool  # a trailing "?"


def parse_pattern(pattern: String) -> List[Seg]:
    var out = List[Seg]()
    for s in segments(pattern):
        var t = s
        var optional = t.endswith("?")
        if optional:
            var cut = String(t[byte = : t.byte_length() - 1])
            t = cut
        if not t.startswith(":"):
            out.append(Seg(t.lower(), "", False, List[String](), optional))
            continue
        var name = String(t[byte=1:])
        var choices = List[String]()
        var open = name.find("(")
        if open >= 0 and name.endswith(")"):
            for c in String(name[byte = open + 1 : name.byte_length() - 1]).split("|"):
                choices.append(String(c))
            var head = String(name[byte = : open])
            name = head
        var rest = name.endswith("*")
        if rest:
            var bare = String(name[byte = : name.byte_length() - 1])
            name = bare
        out.append(Seg("", name, rest, choices^, optional))
    return out^


def fits(seg: Seg, part: String) -> Bool:
    if part == "":
        return False
    if seg.param == "":
        return part.lower() == seg.literal
    if len(seg.choices) == 0:
        return True
    for c in seg.choices:
        if part == c:
            return True
    return False


def match_from(segs: List[Seg], si: Int, parts: List[String], pi: Int, mut m: Match) -> Bool:
    """Do segs[si:] match parts[pi:]? Params land in `m` (backtracking over a ":name*" segment's length)."""
    if si == len(segs):
        return pi == len(parts)
    ref seg = segs[si]
    if pi == len(parts):
        if seg.optional and si == len(segs) - 1:
            if seg.param != "":
                m.set(seg.param, "")
            return True
        return False
    if not seg.rest:
        if not fits(seg, parts[pi]):
            return False
        var saved = m.copy()
        if seg.param != "":
            m.set(seg.param, unescape(parts[pi]))
        if match_from(segs, si + 1, parts, pi + 1, m):
            return True
        m = saved^
        return False
    var upto = pi + 1
    while upto <= len(parts):  # (the shortest run the rest of the pattern still matches: "/models/org/m/logs" is org/m and logs)
        var ok = True
        var joined = String("")
        for k in range(pi, upto):
            if parts[k] == "":
                ok = False
                break
            joined += ("/" if k > pi else "") + parts[k]
        if ok:
            var saved = m.copy()
            m.set(seg.param, unescape(joined))
            if match_from(segs, si + 1, parts, upto, m):
                return True
            m = saved^
        upto += 1
    return False


def match_pattern(pattern: String, path: String, page: String = "") -> Optional[Match]:
    """`path` read by one `pattern` (None: it doesn't match); the Match is named `page`."""
    var m = Match(page)
    if match_from(parse_pattern(pattern), 0, segments(path), 0, m):
        return m^
    return None


def fill(pattern: String, m: Match) -> Optional[String]:
    """The path `pattern` gives `m`'s params (None: a param it needs is missing or isn't one of its choices)."""
    var segs = parse_pattern(pattern)
    var out = String("")
    for i in range(len(segs)):
        ref seg = segs[i]
        if seg.param == "":
            out += "/" + seg.literal
            continue
        var v = m[seg.param]
        if v == "":
            if seg.optional and i == len(segs) - 1:
                continue
            return None
        if len(seg.choices) > 0:
            var known = False
            for c in seg.choices:
                known = known or c == v
            if not known:
                return None
        out += "/" + escape(v, slashes=seg.rest)
    return out if out != "" else String("/")


@fieldwise_init
struct Page(Copyable, Movable):
    """One page of a Router: its name, its pattern, its breadcrumb trail (":param" is that param's value)."""

    var name: String
    var pattern: String
    var crumbs: List[String]


struct Router(Copyable, Movable):
    """An app's pages, tried in order: parse a path, write a match back as a path, a page's crumbs. Anything unmatched is
    the `fallback` page (its params empty)."""

    var pages: List[Page]
    var fallback: String

    def __init__(out self, fallback: String = ""):
        self.pages = List[Page]()
        self.fallback = fallback

    def page(var self, name: String, pattern: String, var crumbs: List[String] = List[String]()) -> Self:
        self.pages.append(Page(name, pattern, crumbs^))
        return self^

    def parse(self, path: String) -> Match:
        for p in self.pages:
            var m = match_pattern(p.pattern, path, p.name)
            if m:
                return m.value().copy()
        return Match(self.fallback)

    def path_for(self, m: Match) -> String:
        """The path of the first of `m`'s page's patterns its params fill ("/" when none does)."""
        for p in self.pages:
            if p.name == m.page:
                var path = fill(p.pattern, m)
                if path:
                    return path.value()
        return "/"

    def canonical(self, path: String) -> String:
        """`path` as path_for writes it ("#" alone is "/", "/KEYS" is "/keys", an unknown path is the fallback's)."""
        return self.path_for(self.parse(path))

    def crumbs(self, m: Match) -> List[String]:
        """`m`'s page's trail, its ":param"s filled (the first page by that name)."""
        var out = List[String]()
        for p in self.pages:
            if p.name == m.page:
                for c in p.crumbs:
                    out.append(m[String(c[byte=1:])] if c.startswith(":") else c)
                return out^
        return out^
