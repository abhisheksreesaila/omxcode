"""The web host follows and frames http(s) only (D-576): a Paragraph link whose href is javascript:, data: or file: gets
no href (the browser can't follow it; a tap still reaches an app that listens), and a WebFrame of such a URL shows its
stand-in, not an iframe. web_url is the same rule as mojoui.embed.is_web_url (tests/test_embed.mojo).

    pixi run python tests/test_web_links.py      # prints "web_links: ok"
"""

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    spec = importlib.util.spec_from_file_location("mojoui_web", ROOT / "mojoui" / "hosts" / "web.py")
    web = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(web)
    from fasthtml.common import to_xml
    for ok in ["http://127.0.0.1:8888/lab", "https://example.com", "HTTPS://Example.com/a?b#c"]:
        assert web.web_url(ok) == ok, ok
    for bad in ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,x", "file:///etc/passwd", "", "http://", "https:///p",
                " http://a", "http://a b", "http://a\nb", "//example.com", "mailto:a@b", "vbscript:x"]:
        assert web.web_url(bad) is None, bad
    # a Paragraph's runs: flags, role, href, text for each
    n = {"options": ["l", "md-link", "javascript:alert(document.cookie)", "evil", "l", "md-link", "https://example.com/notes", "notes",
                     "l", "md-link", "data:text/html,<script>x</script>", "data"], "msg": 0}
    html = to_xml(web.paragraph_runs(n, 3, {}))
    assert "javascript:" not in html and "data:text" not in html, html
    assert 'href="https://example.com/notes"' in html, html
    assert html.count('data-refused="1"') == 2, html
    listening = to_xml(web.paragraph_runs(dict(n, msg=7), 3, {"hx-post": "/e/x"}))
    assert "javascript:" not in listening and listening.count("hx-post") == 3, listening  # (the app still hears the tap)
    # a WebFrame: an iframe only of an http(s) page
    from types import SimpleNamespace
    base = dict(text="", value=0, size=0, children=[], style=0, msg=0, options=[], hint="", msg2=0, pad_v=0, pad_h=0, w=0, h=0,
                min_w=0, max_w=0, grows=False, fills=False, align_items=0, justify_items=0, name="", tip="", role="", spacing=0)
    for url, framed in [("javascript:alert(1)", False), ("data:text/html,x", False), ("http://127.0.0.1:8888/doc/tree/q.ipynb", True)]:
        s = SimpleNamespace(nodes=[dict(base, kind=web.EMBED, text=url, value=1, children=[1]), dict(base, kind=web.TEXT, text="Opened in your browser")])
        html = to_xml(web.render_node(s, 0, "sid"))
        assert ("<iframe" in html) == framed and (url in html) == framed, html
        assert framed or ("Opened in your browser" in html and 'data-refused="1"' in html), html
        if framed:  # (goal 34: sandboxed by default, D-606)
            assert 'sandbox="allow-scripts allow-forms"' in html and "allow-same-origin" not in html, html
    # the sandbox: the default, what an app may add, allow-same-origin only for another origin, nothing else
    page = "http://127.0.0.1:5001"
    for asked, url, want in [("", "http://127.0.0.1:8888/lab", "allow-scripts allow-forms"),
                             ("allow-same-origin allow-downloads", "http://127.0.0.1:8888/lab", "allow-scripts allow-forms allow-downloads allow-same-origin"),
                             ("allow-same-origin", page + "/other", "allow-scripts allow-forms"),  # (our own origin: never)
                             ("allow-same-origin", page, "allow-scripts allow-forms"),
                             ("allow-top-navigation allow-popups-to-escape-sandbox allow-popups", "https://example.com", "allow-scripts allow-forms allow-popups")]:
        node = dict(base, kind=web.EMBED, text=url, value=1, options=[asked] if asked else [])
        got = web.frame_sandbox(node, page)
        assert got == want, (asked, url, got)
        s = SimpleNamespace(nodes=[dict(node, children=[1]), dict(base, kind=web.TEXT, text="stand-in")], origin=page)
        assert f'sandbox="{want}"' in to_xml(web.render_node(s, 0, "sid")), (asked, url)
    # the same origin, however it's spelled (D-616): a query or fragment right after the port, user info, the default
    # port written out, upper-case host, a trailing dot: allow-same-origin never goes to our own origin
    for url in [page + "?x", page + "#x", "http://user@127.0.0.1:5001/", "http://user:pw@127.0.0.1:5001/lab", "HTTP://127.0.0.1:5001/a",
                "http://127.0.0.1:5001./a", "http://localhost:5001/a"]:
        node = dict(base, kind=web.EMBED, text=url, value=1, options=["allow-same-origin"])
        assert "allow-same-origin" not in web.frame_sandbox(node, page), url
    for url, origin in [("http://example.com:80/a", "http://example.com"), ("https://example.com/a", "https://example.com:443"),
                        ("https://Example.COM/x", "https://example.com")]:
        node = dict(base, kind=web.EMBED, text=url, value=1, options=["allow-same-origin"])
        assert "allow-same-origin" not in web.frame_sandbox(node, origin), (url, origin)
    for url, origin in [("https://example.com/a", "http://example.com"), ("http://127.0.0.1:8888/lab", page), ("http://other.host:5001/", page)]:
        node = dict(base, kind=web.EMBED, text=url, value=1, options=["allow-same-origin"])
        assert "allow-same-origin" in web.frame_sandbox(node, origin), (url, origin)
    # unsure of our own origin (none known, or behind a proxy that rewrote it): never allow-same-origin
    node = dict(base, kind=web.EMBED, text="http://127.0.0.1:8888/lab", value=1, options=["allow-same-origin"])
    assert "allow-same-origin" not in web.frame_sandbox(node, ""), "no origin"
    assert web.page_origin("http", "127.0.0.1:5001", {}) == page
    assert web.page_origin("http", "127.0.0.1:5001", {"x-forwarded-host": "app.example.com"}) == ""
    assert web.page_origin("http", "127.0.0.1:5001", {"forwarded": "host=app.example.com;proto=https"}) == ""
    # the iframe's permissions: none unless the app asks (clipboard, fullscreen); anything else dropped (D-617)
    framed = dict(base, kind=web.EMBED, text="http://127.0.0.1:8888/lab", value=1, children=[1])
    s = SimpleNamespace(nodes=[framed, dict(base, kind=web.TEXT, text="s")], origin=page)
    assert " allow=" not in to_xml(web.render_node(s, 0, "sid")), "an iframe with permissions nobody asked for"
    s.nodes[0] = dict(framed, options=["", "clipboard-read clipboard-write camera"])
    html = to_xml(web.render_node(s, 0, "sid"))
    assert 'allow="clipboard-read; clipboard-write"' in html and "camera" not in html, html
    # names: a trailing newline isn't a word or a tag (fullmatch, D-618)
    assert not web.widget_tag("mx-counter\n") and not web.EVENT_NAME.fullmatch("click\n") and web.widget_tag("mx-counter")
    assert not web.event_name("click\n") and web.event_name("click")
    print("web_links: ok")


if __name__ == "__main__":
    main()
