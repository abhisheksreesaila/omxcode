# mojoui.news (goal 72 M6): a feed becomes headlines with their sources, newest first, and a card of links.
#   pixi run mojo build -I . -I vendor tests/test_news.mojo -o build/test_news && build/test_news
from std.os import setenv
from std.testing import assert_equal, assert_true
from mojoui.news import news_url, parse_headlines, news_for_model, NewsCard, unescape, rfc822_seconds, ago, url_encode
from mojoui.view import PARAGRAPH, TEXT
from mojoui.paragraph import runs_of

comptime FEED = (
    '<?xml version="1.0"?><rss><channel><title>"SpaceX" - Google News</title>'
    "<item><title>Older story &amp; more - Reuters</title><link>https://news.example/a</link><pubDate>Wed, 18 Nov 2026 04:44:02 GMT</pubDate>"
    "<source url=\"https://reuters.com\">Reuters</source></item>"
    "<item><title>NASA to cover the departure - NASA (.gov)</title><link>https://news.example/b?x=1&amp;y=2</link>"
    "<pubDate>Wed, 18 Nov 2026 07:44:02 GMT</pubDate><source url=\"https://nasa.gov\">NASA (.gov)</source></item>"
    "<item><title>No link here</title></item>"
    "<item><title>Quotes &#39;and&#39; &quot;marks&quot; - BBC</title><link>https://news.example/c</link><source>BBC</source></item>"
    "</channel></rss>"
)


def main() raises:
    assert_equal(news_url("Linux kernel"), "https://news.google.com/rss/search?q=Linux%20kernel&hl=en-US&gl=US&ceid=US:en")
    assert_equal(url_encode("a&b"), "a%26b")
    assert_equal(unescape("Tom &amp; Jerry &lt;3 &#x41;&#66;"), "Tom & Jerry <3 AB")
    assert_equal(rfc822_seconds("Wed, 18 Nov 2026 07:44:02 GMT"), 1794987842)
    assert_equal(rfc822_seconds("garbage"), 0)
    assert_equal(ago(1794987842 - 120, 1794987842), "2 min ago")
    assert_equal(ago(1794987842 - 3 * 3600 - 5, 1794987842), "3 h ago")
    assert_equal(ago(1794987842 - 2 * 86400, 1794987842), "2 d ago")
    assert_equal(ago(0, 5), "")

    var items = parse_headlines(FEED, 6)
    assert_equal(len(items), 3)  # the item with no link is skipped
    assert_equal(items[0].title, "NASA to cover the departure")  # the newest first, its " - Source" tail cut
    assert_equal(items[0].source, "NASA (.gov)")
    assert_equal(items[0].url, "https://news.example/b?x=1&y=2")
    assert_equal(items[0].at, 1794987842)
    assert_equal(items[1].title, "Older story & more")
    assert_equal(items[2].title, "Quotes 'and' \"marks\"")  # no date: last
    assert_equal(items[2].source, "BBC")
    assert_equal(len(parse_headlines(FEED, 2)), 2)

    _ = setenv("MOJOUI_NOW", String(1794987842 + 7200), True)  # two hours after the newest
    assert_equal(news_for_model(items), "1. NASA to cover the departure (NASA (.gov), 2 h ago)\n2. Older story & more (Reuters, 5 h ago)\n3. Quotes 'and' \"marks\" (BBC)\n")

    var card = NewsCard("SpaceX", items)
    var links = 0
    var title = String("")
    var first_runs = String("")
    for ref n in card.nodes:
        if n.kind == TEXT and title == "":
            title = n.text
        if n.kind == PARAGRAPH:
            links += 1
            if first_runs == "":
                for r in runs_of(n):
                    first_runs += "[" + r.text + "|" + r.href + "]"
    assert_equal(title, "News: SpaceX")
    assert_equal(links, 3)
    assert_equal(first_runs, "[NASA to cover the departure|https://news.example/b?x=1&y=2][  NASA (.gov) · 2 h ago|]")
    print("news: ok")
