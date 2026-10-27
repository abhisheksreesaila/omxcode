# mojoui.route: a generic Router (patterns, params, crumbs from the app's table), unescape/escape, the Route view.
from std.testing import assert_equal, assert_true, assert_false
from mojoui.view import ROUTE
from mojoui.route import Route, Router, Match, match_pattern, fill, unescape, escape, segments


def pages() -> Router:
    """A table like an app's (the console's shape, but this test's own words)."""
    return (Router("home").page("home", "/", ["Start"])
            .page("keys", "/keys", ["Keys"])
            .page("new", "/new", ["Start", "New thing"])
            .page("item", "/items/:name*/:tab(info|logs|notes)?", ["Start", ":name", ":tab"])
            .page("user", "/users/:id", ["Users", ":id"]))


def main() raises:
    var r = pages()
    # parse: patterns, params, a rest param that takes slashes, a choice, an optional last segment
    assert_true(r.parse("/items/qwen2.5-0.5b/logs") == Match("item").with_param("name", "qwen2.5-0.5b").with_param("tab", "logs"))
    assert_true(r.parse("#/items/qwen2.5-0.5b/logs") == Match("item").with_param("name", "qwen2.5-0.5b").with_param("tab", "logs"))  # (a hash reads too)
    assert_true(r.parse("/items/Qwen/Qwen2.5-0.5B/notes") == Match("item").with_param("name", "Qwen/Qwen2.5-0.5B").with_param("tab", "notes"))
    assert_true(r.parse("/items/org/m") == Match("item").with_param("name", "org/m").with_param("tab", ""))  # (m isn't a tab)
    assert_true(r.parse("/items/qwen") == Match("item").with_param("name", "qwen").with_param("tab", ""))
    assert_true(r.parse("/items/org%2Fm%20x/notes") == Match("item").with_param("name", "org/m x").with_param("tab", "notes"))
    assert_equal(r.parse("/items/a//logs").page, "home")  # (an empty segment matches nothing)
    assert_equal(r.parse("/items").page, "home")
    for home in ["", "/", "#", "#/", "/nowhere", "/keys/extra"]:
        assert_equal(r.parse(home).page, "home", home)
    assert_equal(r.parse("/KEYS").page, "keys")  # (literals without case)
    assert_equal(r.parse("/users/7")["id"], "7")
    assert_equal(r.parse("/users/7")["nothing"], "")
    assert_equal(Router().parse("/x").page, "")  # (no fallback: no page)
    # path_for: params escaped (a rest param keeps its slashes, a one-segment param doesn't); the optional segment left out
    assert_equal(r.path_for(Match("item").with_param("name", "Qwen/Qwen2.5 0.5B").with_param("tab", "logs")), "/items/Qwen/Qwen2.5%200.5B/logs")
    assert_equal(r.path_for(Match("item").with_param("name", "qwen")), "/items/qwen")
    assert_equal(r.path_for(Match("item").with_param("name", "qwen").with_param("tab", "bogus")), "/")  # (not one of its choices)
    assert_equal(r.path_for(Match("user").with_param("id", "a/b")), "/users/a%2Fb")
    assert_equal(r.path_for(Match("item")), "/")  # (a needed param missing)
    assert_equal(r.path_for(Match("home")), "/")
    assert_equal(r.path_for(Match("keys")), "/keys")
    for path in ["/", "/keys", "/new", "/items/qwen2.5-0.5b/logs", "/items/org/m/info", "/items/a%0D%0Ab/notes", "/users/a%2Fb"]:
        assert_equal(r.canonical(path), path)  # round trip
    assert_equal(r.canonical("#"), "/")
    assert_equal(r.canonical("/KEYS"), "/keys")
    # crumbs: the app's words, params filled in
    var c = r.crumbs(r.parse("/items/qwen/logs"))
    assert_equal(len(c), 3)
    assert_equal(c[0], "Start")
    assert_equal(c[1], "qwen")
    assert_equal(c[2], "logs")
    assert_equal(r.crumbs(r.parse("/new"))[1], "New thing")
    assert_equal(r.crumbs(r.parse("/"))[0], "Start")
    assert_equal(len(Router().crumbs(Match("x"))), 0)
    # one pattern on its own; fill
    assert_true(match_pattern("/a/:b", "/a/c"))
    assert_false(match_pattern("/a/:b", "/a"))
    assert_equal(match_pattern("/a/:b", "/A/c", "p").value()["b"], "c")
    assert_equal(fill("/a/:b", Match("p").with_param("b", "x y")).value(), "/a/x%20y")
    assert_equal(len(segments("#/a//b")), 3)
    # escapes; a link's bytes that aren't UTF-8 never make a String of bad UTF-8 (U+FFFD instead)
    assert_equal(unescape("a%2fb%zz%4"), "a/b%zz%4")
    assert_equal(unescape("%C3%A9"), "é")
    assert_equal(unescape("a%FFb"), "a�b")
    assert_equal(unescape("%C3"), "�")
    assert_equal(unescape("%E2%82"), "��")
    var bad = r.parse("/items/x%C0%AF/logs")["name"]  # (an overlong "/": two bad bytes)
    assert_equal(bad, "x��")
    assert_equal(escape("a b/é"), "a%20b/%C3%A9")
    assert_equal(escape("a/b", slashes=False), "a%2Fb")
    var v = Route("/keys", 12)
    assert_equal(v.nodes[0].kind, ROUTE)
    assert_equal(v.nodes[0].text, "/keys")
    assert_equal(v.nodes[0].msg, 12)
    print("route: ok")
