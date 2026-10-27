# The console's places (routes.js parseRoute, hashFor, crumbsFor): its pages as a mojoui Router table, read into a Place
# (the page, the model, its tab). The words in the trail are the console's own; mojoui.route only matches and writes.

from mojoui.route import Router, Match

comptime TABS = "overview|benchmark|logs|notebook"


def console_routes() -> Router:
    return (Router("home").page("home", "/", ["My models"])
            .page("keys", "/keys", ["API keys"])
            .page("gateway", "/gateway", ["Gateway"])
            .page("security", "/security", ["Security"])
            .page("settings", "/settings", ["Settings"])
            .page("add", "/add", ["My models", "Add a model"])
            .page("model", "/models/:model*/:tab(" + TABS + ")?", ["My models", ":model"]))


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


def parse_route(path: String) -> Place:
    """"/models/org/m/logs" → Place("model", "org/m", "logs"); "/keys" → Place("keys"); anything unknown → home (a model
    without a tab is on its overview)."""
    var m = console_routes().parse(path)
    if m.page == "model":
        return Place("model", m["model"], m["tab"] if m["tab"] != "" else String("overview"))
    return Place(m.page, "", "")


def match_of(p: Place) -> Match:
    if p.page != "model":
        return Match(p.page if p.page != "" else String("home"))
    return Match("model").with_param("model", p.model).with_param("tab", p.tab if p.tab != "" else String("overview"))


def route_for(p: Place) -> String:
    """The path for a place (the console's hashFor without its "#")."""
    return console_routes().path_for(match_of(p))


def crumbs_for(p: Place) -> List[String]:
    """The trail for a place (the console's crumbsFor): My models first, the last where you are."""
    return console_routes().crumbs(match_of(p))
