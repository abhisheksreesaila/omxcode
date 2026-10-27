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
    print("web_links: ok")


if __name__ == "__main__":
    main()
