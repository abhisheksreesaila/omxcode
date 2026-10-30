# mojoui.regions: the window's regions as the framework's own shells name them (goal 41 M5): a test (or a screen reader's
# landmark list) asks "where is the sidebar, the toolbar, the sheet, the inspector, the status bar, each card?" and every
# host answers from the same rule, so no app tags its regions by hand.
#
#   The role tags the shells already set (and themes style through Look surfaces): sidebar (mojoui.sidebar, Rail),
#   toolbar and status-bar (mojoui.sheetchrome), inspector (mojoui.inspector). A Board is the sheet; each Board object
#   with a HEADLINE title is a card, named "card:<its title>" (a cell editor floating on the board is no card).
#
#   for r in regions(host.rt.shown): …  r.node, r.name, r.board (the Board a card sits on: clip it to that board's view)
#
# The web driver (scripts/drive.py, regions:) reads the same roles from the page's data-tag attributes: keep the two
# tables in step.

from mojoui.view import View, BOARD, TEXT, HEADLINE

comptime REGION_ROLES: List[String] = ["sidebar", "toolbar", "status-bar", "inspector"]


def region_of(role: String) -> String:
    """A role tag's region name ("status-bar" → "status"), "" for a tag that names no region."""
    if role == "status-bar":
        return "status"
    for r in materialize[REGION_ROLES]():
        if r == role:
            return role
    return ""


@fieldwise_init
struct Region(Copyable, Movable):
    var node: Int
    var name: String  # sidebar, toolbar, sheet, inspector, status, card:<title>
    var board: Int  # a card's Board node (-1: not a card)


def headline_in(v: View, i: Int) -> String:
    """The first HEADLINE text inside node i (depth first), "" when there's none."""
    ref n = v.nodes[i]
    if n.kind == TEXT and n.style == HEADLINE and n.text != "":
        return n.text
    for c in n.children:
        var t = headline_in(v, c)
        if t != "":
            return t
    return String("")


def regions(v: View) -> List[Region]:
    var out = List[Region]()
    for i in range(len(v.nodes)):
        ref n = v.nodes[i]
        var name = region_of(n.name)
        if name != "":
            out.append(Region(i, name, -1))
        if n.kind == BOARD:
            out.append(Region(i, "sheet", -1))
            for c in n.children:
                var title = headline_in(v, c)
                if title != "":
                    out.append(Region(c, "card:" + title, i))
    return out^
