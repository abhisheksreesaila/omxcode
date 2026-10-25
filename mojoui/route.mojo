# mojoui.route: where the app is, as a path ("/", "/keys", "/models/qwen2.5-0.5b/logs"). Route(path, on_change) puts it in
# the screen (nothing to see): the web keeps it in the URL's hash, so a link opens the app there, a change writes the URL
# and Back and Forward go through the app's own places (each sends on_change, event.text = the new path); on GTK and
# the Mac it's state the app keeps. Place reads and writes the console's routes (its routes.js: parseRoute, hashFor).
#
#   view(): Route(self.path, on_change=ROUTE)            update(): ROUTE → self.path = event.text
#   var p = parse_route(self.path)                       # p.page "model", p.model "qwen2.5-0.5b", p.tab "logs"

from mojoui.view import View, Node, ROUTE, _one

comptime TABS: List[String] = ["overview", "benchmark", "logs", "notebook"]
comptime PLACES: List[String] = ["keys", "gateway", "security", "settings", "add"]


def Route(path: String, on_change: Int) -> View:
    """The app's place: `path` ("/" home). On the web the URL's hash follows it and a new hash (a link, Back, Forward)
    sends `on_change` with event.text = the path ("/" for no hash)."""
    return _one(Node(ROUTE, path, on_change))


@fieldwise_init
struct Place(Copyable, Movable, Equatable):
    var page: String  # "home", "model", "keys", "gateway", "security", "settings", "add"
    var model: String  # the model's name ("model" only)
    var tab: String  # overview, benchmark, logs, notebook ("model" only)

    def __eq__(self, other: Self) -> Bool:
        return self.page == other.page and self.model == other.model and self.tab == other.tab

    @staticmethod
    def home() -> Place:
        return Place("home", "", "")


def hex_digit(c: Int) -> Int:
    if 48 <= c <= 57:
        return c - 48
    if 97 <= c <= 102:
        return c - 87
    if 65 <= c <= 70:
        return c - 55
    return -1


def unescape(s: String) -> String:
    """%XX escapes as their bytes (a URL's model name: %2F is a slash); a broken escape stays as it is."""
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
    return String(unsafe_from_utf8=out)


def escape(s: String) -> String:
    """A name for a path: what encodeURIComponent escapes, but slashes stay slashes (a Hugging Face org/repo)."""
    var digits = "0123456789ABCDEF"
    var out = String("")
    for c in s.as_bytes():
        var o = Int(c)
        var plain = (48 <= o <= 57) or (65 <= o <= 90) or (97 <= o <= 122) or o == 45 or o == 95 or o == 46 or o == 33 or o == 126 or o == 42 or o == 39 or o == 40 or o == 41 or o == 47
        if plain:
            out += chr(o)
        else:
            out += "%" + String(digits[byte = o // 16]) + String(digits[byte = o % 16])
    return out


def parse_route(path: String) -> Place:
    """"/models/org/m/logs" → Place("model", "org/m", "logs"); "/keys" → Place("keys"); anything unknown → home.
    (A leading "#" is dropped, so a hash reads too; a model without a tab is on its overview.)"""
    var p = String(path.strip())
    if p.startswith("#"):
        var rest = String(p[byte=1:])
        p = rest
    if p.startswith("/"):
        var rest = String(p[byte=1:])
        p = rest
    if p == "":
        return Place.home()
    var parts = List[String]()
    for part in p.split("/"):
        parts.append(String(part))
    var head = parts[0].lower()
    if head == "models":
        var rest = List[String]()
        for k in range(1, len(parts)):
            rest.append(parts[k])
        if len(rest) == 0:
            return Place.home()
        var tab = String("overview")
        var upto = len(rest)
        if len(rest) > 1:
            for t in materialize[TABS]():
                if rest[len(rest) - 1] == t:
                    tab = t
                    upto = len(rest) - 1
        var name = String("")
        for k in range(upto):
            if rest[k] == "":
                return Place.home()
            name += ("/" if k > 0 else "") + rest[k]
        return Place("model", unescape(name), tab)
    for place in materialize[PLACES]():
        if head == place:
            return Place(place, "", "") if len(parts) == 1 else Place.home()
    return Place.home()


def route_for(p: Place) -> String:
    """The path for a place (the console's hashFor without its "#")."""
    if p.page == "home" or p.page == "":
        return "/"
    if p.page != "model":
        return "/" + p.page
    return "/models/" + escape(p.model) + "/" + (p.tab if p.tab != "" else String("overview"))


def crumbs_for(p: Place) -> List[String]:
    """The trail for a place (the console's crumbsFor): My models first, the last where you are."""
    var names: List[String] = ["keys", "gateway", "security", "settings", "add"]
    var titles: List[String] = ["API keys", "Gateway", "Security", "Settings", "Add a model"]
    if p.page == "model":
        return ["My models", p.model]
    for k in range(len(names)):
        if p.page == names[k]:
            if names[k] == "add":
                return ["My models", titles[k]]
            return [titles[k]]
    return ["My models"]
