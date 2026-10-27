# examples/console/places.mojo: the console's routes (routes.js parseRoute, hashFor, crumbsFor) on mojoui's Router.
# Build with -I examples/console (scripts/check.py M5).
from std.testing import assert_equal, assert_true
from places import Place, parse_route, route_for, crumbs_for


def main() raises:
    assert_true(parse_route("/models/qwen2.5-0.5b/logs") == Place("model", "qwen2.5-0.5b", "logs"))
    assert_true(parse_route("#/models/qwen2.5-0.5b/logs") == Place("model", "qwen2.5-0.5b", "logs"))
    assert_true(parse_route("/models/Qwen/Qwen2.5-0.5B/benchmark") == Place("model", "Qwen/Qwen2.5-0.5B", "benchmark"))
    assert_true(parse_route("/models/qwen") == Place("model", "qwen", "overview"))
    assert_true(parse_route("/models/org/m") == Place("model", "org/m", "overview"))
    assert_true(parse_route("/models/org%2Fm%20x/notebook") == Place("model", "org/m x", "notebook"))
    assert_true(parse_route("/models/x%0d%0aX-Forged:%201/logs") == Place("model", "x\r\nX-Forged: 1", "logs"))  # (read as written; the console escapes it again in every request)
    for home in ["/models/a//logs", "/models", "", "/", "#", "/keys/extra", "/nowhere"]:
        assert_true(parse_route(home) == Place.home(), home)
    assert_true(parse_route("/keys") == Place("keys", "", ""))
    assert_true(parse_route("/KEYS") == Place("keys", "", ""))
    assert_true(parse_route("/add") == Place("add", "", ""))
    assert_equal(route_for(Place("model", "Qwen/Qwen2.5 0.5B", "logs")), "/models/Qwen/Qwen2.5%200.5B/logs")
    assert_equal(route_for(Place("model", "qwen", "")), "/models/qwen/overview")
    assert_equal(route_for(Place.home()), "/")
    assert_equal(route_for(Place("settings", "", "")), "/settings")
    for path in ["/", "/keys", "/gateway", "/security", "/add", "/models/qwen2.5-0.5b/logs", "/models/org/m/benchmark"]:
        assert_equal(route_for(parse_route(path)), path)  # round trip
    var c = crumbs_for(Place("model", "qwen", "logs"))
    assert_equal(len(c), 2)
    assert_equal(c[0], "My models")
    assert_equal(c[1], "qwen")
    assert_equal(crumbs_for(Place("keys", "", ""))[0], "API keys")
    assert_equal(crumbs_for(Place("add", "", ""))[1], "Add a model")
    assert_equal(crumbs_for(Place.home())[0], "My models")
    print("console_places: ok")
