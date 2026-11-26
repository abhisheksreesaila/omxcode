# mojoui.news: headlines for a topic as a card, from Google News' public RSS (no key; only the topic leaves the machine)
# (goal 72 M6, D-7262; omx-local's news.py).
#
#   self.http.send(Request.get(GOT, news_url("SpaceX")).header("User-Agent", "Mozilla/5.0 omx"))   # https: build with Flare
#   update(): if e.message == GOT and e.number == 200: var items = parse_headlines(e.text, 6)      # newest first
#   news_for_model(items)       # "1. Title (Source, 3 h ago)" lines: what the language model reads to say its gist
#   NewsCard("SpaceX", items)   # a card: each headline is a link (the host opens it), its source and age after it
#
# The reply is sent through mojoui.http like any request (the replies come back as an Event), so nothing waits on the
# network. parse_headlines reads <item> blocks: title (its " - Source" tail cut), link, source, pubDate (RFC 822), and
# decodes the entities an RSS title carries. `now` is wall_seconds() (mojoui.clock), so a fixed $MOJOUI_NOW gives fixed ages.

from mojoui.clock import wall_seconds
from mojoui.paragraph import Paragraph, Plain, Link, Run
from mojoui.view import View, Text, Card, HEADLINE, CAPTION

comptime NEWS_HOST = "https://news.google.com/rss/search?q="
comptime NEWS_TAIL = "&hl=en-US&gl=US&ceid=US:en"


struct Headline(Copyable, Movable):
    var title: String
    var source: String
    var url: String
    var at: Int  # seconds since the epoch (0: unknown)

    def __init__(out self, title: String, source: String, url: String, at: Int):
        self.title = title
        self.source = source
        self.url = url
        self.at = at


def url_encode(text: String) -> String:
    """Percent-encodes everything but letters, digits and - _ . ~ (a space is %20)."""
    var out = String("")
    var hex = "0123456789ABCDEF"
    for b in text.as_bytes():
        var c = Int(b)
        if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95 or c == 46 or c == 126:
            out += chr(c)
        else:
            out += "%" + String(hex[byte = c >> 4 : (c >> 4) + 1]) + String(hex[byte = c & 15 : (c & 15) + 1])
    return out^


def news_url(topic: String) -> String:
    return NEWS_HOST + url_encode(String(topic.strip())) + NEWS_TAIL


def unescape(text: String) -> String:
    """&amp; &lt; &gt; &quot; &apos; &#39; &#x27; and numeric references, decoded (a CDATA wrapper dropped)."""
    var t = text
    if t.startswith("<![CDATA[") and t.endswith("]]>"):
        var inner = String(t[byte = 9 : t.byte_length() - 3])
        t = inner^
    var out = List[UInt8]()
    var b = t.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        if b[i] == 38:  # &
            var j = i + 1
            while j < n and j - i < 10 and b[j] != 59:
                j += 1
            if j < n and b[j] == 59:
                var name = String(from_utf8_lossy=Span(b)[i + 1 : j])
                var rep = String("")
                if name == "amp":
                    rep = "&"
                elif name == "lt":
                    rep = "<"
                elif name == "gt":
                    rep = ">"
                elif name == "quot":
                    rep = '"'
                elif name == "apos":
                    rep = "'"
                elif name.startswith("#"):
                    var code = 0
                    var hex = name.startswith("#x") or name.startswith("#X")
                    var ok = name.byte_length() > (2 if hex else 1)
                    var d = name.as_bytes()
                    for k in range(2 if hex else 1, len(d)):
                        var c = Int(d[k])
                        var v = -1
                        if c >= 48 and c <= 57:
                            v = c - 48
                        elif hex and c >= 97 and c <= 102:
                            v = c - 87
                        elif hex and c >= 65 and c <= 70:
                            v = c - 55
                        if v < 0:
                            ok = False
                        else:
                            code = code * (16 if hex else 10) + v
                    if ok and code > 0 and code < 0x110000:
                        rep = chr(code)
                if rep != "":
                    for x in rep.as_bytes():
                        out.append(x)
                    i = j + 1
                    continue
        out.append(b[i])
        i += 1
    return String(from_utf8_lossy=Span(out))


def _between(text: String, open: String, close: String, from_at: Int) -> Tuple[String, Int]:
    """The text between `open` and `close` at or after from_at, and where it ended (-1 when there is none)."""
    var a = text.find(open, from_at)
    if a < 0:
        return (String(""), -1)
    var start = a + open.byte_length()
    var z = text.find(close, start)
    if z < 0:
        return (String(""), -1)
    return (String(text[byte = start : z]), z + close.byte_length())


def _tag(block: String, name: String) -> String:
    """The text inside <name …>…</name> of a block (attributes allowed on the opening tag; "" when absent)."""
    var a = block.find("<" + name)
    while a >= 0:
        var after = a + name.byte_length() + 1
        if after < block.byte_length() and (block.as_bytes()[after] == 62 or block.as_bytes()[after] == 32):
            var gt = block.find(">", after)
            if gt < 0:
                return String("")
            var z = block.find("</" + name + ">", gt)
            if z < 0:
                return String("")
            return String(block[byte = gt + 1 : z])
        a = block.find("<" + name, a + 1)
    return String("")


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    var yy = y - (1 if m <= 2 else 0)
    var era = yy // 400
    var yoe = yy - era * 400
    var doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def rfc822_seconds(text: String) -> Int:
    """"Wed, 18 Nov 2026 07:44:02 GMT" as seconds since the epoch (0 when it isn't that shape; the zone is taken as GMT)."""
    var parts = List[String]()
    for p in text.split(" "):
        if p.byte_length() > 0:
            parts.append(String(p))
    if len(parts) > 0 and parts[0].endswith(","):
        _ = parts.pop(0)
    if len(parts) < 4:
        return 0
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var m = 0
    for k in range(12):
        if parts[1].startswith(months[k]):
            m = k + 1
    var clock = List[Int]()
    for p in parts[3].split(":"):
        var v = 0
        for b in p.as_bytes():
            if Int(b) >= 48 and Int(b) <= 57:
                v = v * 10 + Int(b) - 48
        clock.append(v)
    var day = 0
    for b in parts[0].as_bytes():
        if Int(b) >= 48 and Int(b) <= 57:
            day = day * 10 + Int(b) - 48
    var year = 0
    for b in parts[2].as_bytes():
        if Int(b) >= 48 and Int(b) <= 57:
            year = year * 10 + Int(b) - 48
    if m == 0 or day == 0 or year < 1970 or len(clock) < 2:
        return 0
    return _days_from_civil(year, m, day) * 86400 + clock[0] * 3600 + clock[1] * 60 + (clock[2] if len(clock) > 2 else 0)


def ago(at: Int, now: Int) -> String:
    """"5 min ago", "3 h ago", "2 d ago" ("" when the time is unknown)."""
    if at <= 0:
        return String("")
    var s = max(now - at, 0)
    if s < 3600:
        return String(max(1, s // 60)) + " min ago"
    if s < 86400:
        return String(s // 3600) + " h ago"
    return String(s // 86400) + " d ago"


def parse_headlines(rss: String, n: Int = 6) -> List[Headline]:
    """The `n` newest items of a feed (items without a title or a link are skipped)."""
    var all = List[Headline]()
    var at = 0
    while True:
        var item = _between(rss, "<item>", "</item>", at)
        if item[1] < 0:
            break
        at = item[1]
        var title = unescape(String(_tag(item[0], "title").strip()))
        var source = unescape(String(_tag(item[0], "source").strip()))
        if source != "" and title.endswith(" - " + source):
            var cut = String(title[byte = : title.byte_length() - source.byte_length() - 3])
            title = cut^
        var link = unescape(String(_tag(item[0], "link").strip()))
        if title == "" or not link.startswith("http"):
            continue
        all.append(Headline(title, source, link, rfc822_seconds(String(_tag(item[0], "pubDate").strip()))))
    # newest first (an insertion sort: a feed has a hundred items, and the sort is stable)
    for i in range(1, len(all)):
        var k = i
        while k > 0 and all[k].at > all[k - 1].at:
            var swap = all[k].copy()
            all[k] = all[k - 1].copy()
            all[k - 1] = swap^
            k -= 1
    var out = List[Headline]()
    for i in range(min(n, len(all))):
        out.append(all[i].copy())
    return out^


def news_for_model(items: List[Headline]) -> String:
    """What the language model reads: a numbered line per headline with its source and age. It says the gist; the card
    shows the rest."""
    var now = Int(wall_seconds())
    var out = String("")
    for i in range(len(items)):
        var when = ago(items[i].at, now)
        out += String(i + 1) + ". " + items[i].title + " (" + items[i].source + (", " + when if when != "" else String("")) + ")\n"
    return out^


def NewsCard(topic: String, items: List[Headline]) -> View:
    """A card: "News: topic", then a line per headline, the title a link (tapped, the host opens the page), its source and
    how long ago after it."""
    var now = Int(wall_seconds())
    var rows = List[View]()
    rows.append(Text("News: " + topic, HEADLINE))
    if len(items) == 0:
        rows.append(Text("No headlines came back for that.", CAPTION))
    for ref h in items:
        var when = ago(h.at, now)
        var runs = List[Run]()
        runs.append(Link(h.title, h.url))
        runs.append(Plain("  " + h.source + (" · " + when if when != "" else String(""))))
        rows.append(Paragraph(runs^, role="news-item"))
    return Card(rows^).tag("news").fill()
