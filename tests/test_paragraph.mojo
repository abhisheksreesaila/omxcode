# mojoui.paragraph: runs in one node, escaping for Pango markup, a link's event (its index and href), roles' type.
from std.testing import assert_equal, assert_true, assert_false
from mojoui import PARAGRAPH, BODY, Event
from mojoui.paragraph import (
    Paragraph, Run, Plain, Bold, Italic, Code, Link, runs_of, link_href, escape_markup, pango_markup, run_attributes, RUN_FIELDS,
)
from mojoui.theme import Look, Surface, TypeScale, Controls, Segments, Shadow
from mojoui.canvas import rgba


def look() -> Look:
    var surfaces = List[Surface]()
    surfaces.append(Surface("md-code", rgba(11, 11, 13, 18), 4, 4, -1, -1, -1, 1, 5, 1, List[Shadow](), 0, 0, 0, -1, "Geist Mono", 12.5,
                            rgba(11, 11, 13), 0, 0, 0, 0, 0, False))
    surfaces.append(Surface("md-strong", 0, -1, -1, -1, -1, -1, -1, -1, -1, List[Shadow](), 0, 0, 0, -1, "", 14, rgba(11, 11, 13), 700, 0, 22.4, 0, 0, False))
    return Look(TypeScale("Geist", "Geist Mono", 14, 12, 17, 26, 11, False, 1.45), Look.none().controls.copy(), surfaces^, Segments.none())


def main() raises:
    # runs in one node: the plain words, the flags, roles and hrefs back
    var p = Paragraph([Plain("Use "), Code("mxc learn", "md-code"), Plain(" and "), Bold("read", "md-strong"), Plain(" "),
                       Italic("this"), Plain(""), Link("the docs", "https://example.com/")], role="md-p", on_link=42)
    assert_equal(len(p.nodes), 1)
    ref n = p.nodes[0]
    assert_equal(n.kind, PARAGRAPH)
    assert_equal(n.text, "Use mxc learn and read thisthe docs")
    assert_equal(n.name, "md-p")
    assert_equal(n.msg, 42)
    assert_equal(n.style, BODY)
    assert_equal(len(n.options), 7 * RUN_FIELDS)  # (the empty run is dropped)
    var runs = runs_of(n)
    assert_equal(len(runs), 7)
    assert_true(runs[1] == Code("mxc learn", "md-code"))
    assert_true(runs[3].bold and runs[3].role == "md-strong")
    assert_true(runs[5].italic and not runs[5].bold)
    assert_equal(runs[6].href, "https://example.com/")
    assert_equal(runs[6].flags(), "l")
    assert_equal(Run("x", True, True, True, "h").flags(), "bicl")
    # a link's event: the run's index and its href (what every host sends)
    assert_equal(link_href(n, 6), "https://example.com/")
    assert_equal(link_href(n, 0), "")
    assert_equal(link_href(n, 99), "")
    var e = Event(n.msg, link_href(n, 6), 6)
    assert_equal(e.message, 42)
    assert_equal(e.text, "https://example.com/")

    # escaping: markup-looking words stay words
    assert_equal(escape_markup("a < b & c > d"), "a &lt; b &amp; c &gt; d")
    assert_equal(escape_markup("<b>not bold</b>"), "&lt;b&gt;not bold&lt;/b&gt;")
    assert_equal(escape_markup("say \"hi\" it's"), "say &quot;hi&quot; it&#39;s")
    assert_equal(escape_markup("&amp;"), "&amp;amp;")
    assert_equal(escape_markup("naïve → ok"), "naïve → ok")
    var evil = Paragraph([Plain("<span foreground=\"red\">x</span> & "), Bold("<i>"), Link("<a href=\"1\">", "https://e.com/?a=1&b=<2>")], role="p")
    var m = pango_markup(evil.nodes[0], look())
    # (the words' "</span" keeps the browser's breaks: a word joiner after its "/", D-548)
    assert_equal(m, "&lt;span foreground=&quot;red&quot;&gt;x&lt;/\u2060span&gt; &amp; <span weight=\"bold\">&lt;i&gt;</span>"
                    + "<a href=\"2\"><span underline=\"single\">&lt;a href=&quot;1&quot;&gt;</span></a>")
    assert_false("<i>" in m)

    # roles' type in the markup: family and size, weight, ink, a fill with its alpha
    var lk = look()
    var code_attrs = run_attributes(Code("x", "md-code"), lk, "md-p")
    assert_true("font_desc=\"Geist Mono 12.5px\"" in code_attrs, code_attrs)
    assert_true("background=\"#0b0b0d\" bgalpha=\"7%\"" in code_attrs, code_attrs)
    assert_true("foreground=\"#0b0b0d\"" in code_attrs, code_attrs)
    assert_equal(run_attributes(Bold("x", "md-strong"), lk, "md-p"), " foreground=\"#0b0b0d\" font_desc=\"14px\" weight=\"700\"")
    assert_equal(run_attributes(Code("x"), lk, "md-p"), " font_desc=\"Geist Mono\"")  # (no role: the look's mono)
    assert_equal(run_attributes(Plain("x", "md-p"), lk, "md-p"), "")  # (the paragraph's own role: nothing to add)
    assert_equal(run_attributes(Plain("x", "nope"), lk, "md-p"), "")  # (a role the look doesn't know: the paragraph's type)
    assert_equal(run_attributes(Italic("x"), Look.none(), "p"), " style=\"italic\"")
    var led = Paragraph([Plain("$ "), Plain("mxc search <query>")], role="foot-text", lead=True)
    assert_equal(led.nodes[0].value, 1)  # (the first run a column of its own; the words still "$ mxc…" whole)
    assert_equal(led.nodes[0].text, "$ mxc search <query>")
    assert_equal(Paragraph([Plain("a")]).nodes[0].value, 0)
    print("paragraph: ok")
