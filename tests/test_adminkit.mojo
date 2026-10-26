# mojoui.adminkit and mojoui.clock.wall_seconds: each piece wears its role, taps send their messages (a dimmed button
# sends nothing, an armed one says so), the roles a theme gets cover every tag the pieces set, and the wall clock holds
# still at $MOJOUI_NOW.
from std.testing import assert_equal, assert_true
from std.os import setenv, unsetenv
from mojoui import BUTTON, TEXT
from mojoui.view import View, NO_MSG
from mojoui.adminkit import (CopyFoot, StateMark, ActionButton, EndpointRow, SecretBox, WarnBox, ToneSquare, admin_roles, QUIET, GOOD, WARN, BAD,
    TONAL, FILL, TEXT as TEXT_LOOK, DANGER)
from mojoui.clock import wall_seconds
from mojoui.pagekit import card_roles
from themes.omxqua import omxqua_palette


def tags(v: View) -> List[String]:
    var out = List[String]()
    for n in v.nodes:
        if n.name != "":
            out.append(n.name)
    return out^


def button(v: View, title: String) -> Int:
    for k in range(len(v.nodes)):
        if v.nodes[k].kind == BUTTON and v.nodes[k].text == title:
            return k
    return -1


def main() raises:
    var p = omxqua_palette(False)
    var roles = List[String]()
    for s in admin_roles(p, "Geist Mono", 0xFF0D0B0B, 0xFFE7E4E4) + card_roles(p, "Geist Mono"):  # (card-foot: pagekit's)
        roles.append(s.role)
    # a card foot's copy button sends its message; the line keeps its $
    var foot = CopyFoot("mxc status", 6210)
    assert_equal(foot.nodes[0].name, "card-foot")
    assert_equal(foot.nodes[button(foot, "copy")].msg, 6210)
    assert_equal(foot.nodes[foot.nodes[0].children[0]].text, "$ mxc status")
    assert_equal(CopyFoot("kept here", 1, note=True).nodes[1].text, "↳ kept here")
    # buttons: a look per role; dimmed ones send nothing; armed is the danger look's
    var rev = ActionButton("Revoke", 6100, "trash-2", DANGER)
    assert_equal(rev.nodes[0].name, "act-danger")
    assert_equal(rev.nodes[0].msg, 6100)
    assert_equal(ActionButton("Click again to revoke", 6100, "trash-2", DANGER, armed=True).nodes[0].name, "act-danger-armed")
    var off = ActionButton("Revoke", 6101, "trash-2", DANGER, off=True)
    assert_equal(off.nodes[0].name, "act-danger-off")
    assert_equal(off.nodes[0].msg, NO_MSG)
    assert_equal(ActionButton("Rotate", 1, "rotate-cw", TONAL, armed=True).nodes[0].name, "act-tonal")  # (only danger shows armed)
    # states and squares in their tones
    var st = StateMark("200", BAD, mono=True)
    assert_equal(tags(st)[0], "mark-dot-bad")
    assert_equal(tags(st)[1], "mark-mono-bad")
    assert_equal(ToneSquare("lock", GOOD).nodes[0].name, "tone-square-good")
    # an endpoint row: the tag in capitals, the value, Copy
    var ep = EndpointRow("https · lan", "https://box.local:8443/v1", "Copy", 6403)
    assert_equal(ep.nodes[ep.nodes[0].children[0]].text, "HTTPS · LAN")
    assert_true(button(ep, "Copy") >= 0)
    assert_equal(ep.nodes[button(ep, "Copy")].msg, 6403)
    assert_equal(len(EndpointRow("ca", "—", "", 0).nodes[0].children), 2)  # (nothing to copy: no button)
    # every tag set has a role
    var views: List[View] = [foot.copy(), rev.copy(), off.copy(), st.copy(), StateMark("off"), StateMark("working", WARN), StateMark("active", GOOD),
                             ToneSquare("unlock", WARN), ToneSquare("x"), ep.copy(), SecretBox("mst-abc"), WarnBox([StateMark("x")]),
                             ActionButton("Create key", 1, "plus", FILL), ActionButton("Cancel", 2, "", TEXT_LOOK), ActionButton("Restart", 3, "refresh-cw", TONAL, off=True),
                             ActionButton("Go", 4, "", FILL, off=True), ActionButton("Hide", 5, "", TEXT_LOOK, off=True)]
    for v in views:
        for t in tags(v):
            var known = False
            for r in roles:
                if r == t:
                    known = True
            assert_true(known, "no role for tag " + t)
    # the wall clock: held at $MOJOUI_NOW, else the system's
    _ = setenv("MOJOUI_NOW", "1792964194.376")
    assert_equal(wall_seconds(), 1792964194.376)
    _ = unsetenv("MOJOUI_NOW")
    assert_true(wall_seconds() > 1.7e9)
    print("adminkit: ok")
