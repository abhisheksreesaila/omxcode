# mojoui.embed: a web page inside the screen (the console's Notebook: Run in Jupyter). The web shows the page in an
# iframe; GTK and the Mac, which have no browser view, open it in the person's browser once per version and show
# `instead` where the page would be. GTK runs `xdg-open <url>`, or the command in $MOJOUI_OPENER (a check's stand-in).
#
#   WebFrame(url, version=self.opened, instead=Text("Opened in your browser"), height=640).fill()
#   (open_url: what the browser opens instead of `url`, when the framed page and the full page differ: Jupyter's
#   single-notebook view in the frame, its lab view in a browser tab)

from mojoui.view import View, Node, EMBED, _container


def WebFrame(url: String, version: Int, instead: View, height: Int = 600, open_url: String = "") -> View:
    """The page at `url`, `height` points high. A new `version` (counting from 1) opens it again where it opens in the
    browser (`open_url` if given, else `url`); 0 shows `instead` and opens nothing."""
    var items: List[View] = [instead.copy()]
    return _container(Node(EMBED, url, value=version, size=height, hint=open_url), items)


def is_web_url(url: String) -> Bool:
    """http:// or https:// (in any case) with a host, and no space or control character in it: the only links and pages
    a host opens in the browser or frames (D-576). Anything else (javascript:, data:, file:, an app's own scheme) is
    refused; goal 34 adds a sandbox for more."""
    var low = url.lower()
    var at = 7 if low.startswith("http://") else (8 if low.startswith("https://") else 0)
    if at == 0 or url.byte_length() <= at:
        return False
    var first = Int(url.as_bytes()[at])
    if first == 47 or first == 63 or first == 35:  # (/ ? #: no host)
        return False
    for b in url.as_bytes():
        if Int(b) <= 32 or Int(b) == 127:
            return False
    return True
