# mojoui.route: the console's routes (routes.js parseRoute and hashFor), both ways; the Route view.
from std.testing import assert_equal, assert_true
from mojoui.view import ROUTE
from mojoui.route import Route, Place, parse_route, route_for, crumbs_for, unescape, escape


def main() raises:
    assert_true(parse_route("/models/qwen2.5-0.5b/logs") == Place("model", "qwen2.5-0.5b", "logs"))
    assert_true(parse_route("#/models/qwen2.5-0.5b/logs") == Place("model", "qwen2.5-0.5b", "logs"))  # (a hash reads too)
    assert_true(parse_route("/models/Qwen/Qwen2.5-0.5B/benchmark") == Place("model", "Qwen/Qwen2.5-0.5B", "benchmark"))
    assert_true(parse_route("/models/qwen") == Place("model", "qwen", "overview"))
    assert_true(parse_route("/models/org%2Fm%20x/notebook") == Place("model", "org/m x", "notebook"))
    assert_true(parse_route("/models/a//logs") == Place.home())
    assert_true(parse_route("/models") == Place.home())
    assert_true(parse_route("") == Place.home())
    assert_true(parse_route("/") == Place.home())
    assert_true(parse_route("#") == Place.home())
    assert_true(parse_route("/keys") == Place("keys", "", ""))
    assert_true(parse_route("/KEYS") == Place("keys", "", ""))
    assert_true(parse_route("/keys/extra") == Place.home())
    assert_true(parse_route("/add") == Place("add", "", ""))
    assert_true(parse_route("/nowhere") == Place.home())
    assert_equal(route_for(Place("model", "Qwen/Qwen2.5 0.5B", "logs")), "/models/Qwen/Qwen2.5%200.5B/logs")
    assert_equal(route_for(Place("model", "qwen", "")), "/models/qwen/overview")
    assert_equal(route_for(Place.home()), "/")
    assert_equal(route_for(Place("settings", "", "")), "/settings")
    for path in ["/", "/keys", "/models/qwen2.5-0.5b/logs", "/models/org/m/benchmark"]:
        assert_equal(route_for(parse_route(path)), path)  # round trip
    assert_equal(unescape("a%2fb%zz%4"), "a/b%zz%4")
    assert_equal(escape("a b/é"), "a%20b/%C3%A9")
    var c = crumbs_for(Place("model", "qwen", "logs"))
    assert_equal(len(c), 2)
    assert_equal(c[0], "My models")
    assert_equal(c[1], "qwen")
    assert_equal(crumbs_for(Place("keys", "", ""))[0], "API keys")
    assert_equal(crumbs_for(Place("add", "", ""))[1], "Add a model")
    assert_equal(crumbs_for(Place.home())[0], "My models")
    var v = Route("/keys", 12)
    assert_equal(v.nodes[0].kind, ROUTE)
    assert_equal(v.nodes[0].text, "/keys")
    assert_equal(v.nodes[0].msg, 12)
    print("route: ok")
