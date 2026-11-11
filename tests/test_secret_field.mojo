# TextField.secret() (goal 64 polish, D-6507): a field masked as it is typed. The node carries FIELD_SECRET as its style,
# OutlinedField(secret=True) makes one, a plain field does not; turning a field secret (or back) builds its widget
# again (a host can't change GtkEntry's purpose or swap NSTextField for NSSecureTextField in place), while typing
# into a secret field is the same small text patch as any other field.
#   pixi run mojo run -I . tests/test_secret_field.mojo
from std.testing import assert_equal, assert_true, assert_false
from mojoui import *
from mojoui.view import FIELD, FIELD_SECRET
from mojoui.diff import SET_TEXT
from mojoui.fields import OutlinedField


def field_at(v: View) -> Int:
    for k in range(len(v.nodes)):
        if v.nodes[k].kind == FIELD:
            return k
    return -1


def screen(text: String, secret: Bool) -> View:
    return VStack(Text("API key"), OutlinedField(text, "API key Claude Code signs in with", 7, 8, icon="key-round", secret=secret))


def main() raises:
    var plain = TextField("abc", placeholder="Name", on_change=1)
    assert_true(plain.nodes[0].style != FIELD_SECRET)
    var masked = TextField("abc", placeholder="Key", on_change=1).secret()
    assert_equal(masked.nodes[0].style, FIELD_SECRET)
    assert_equal(masked.nodes[0].text, "abc")  # (the app keeps the text: only the host masks it)

    var a = screen("sk-1", True)
    var k = field_at(a)
    assert_equal(a.nodes[k].style, FIELD_SECRET)
    assert_equal(a.nodes[k].msg, 7)
    assert_equal(a.nodes[k].msg2, 8)
    assert_true(screen("", False).nodes[field_at(screen("", False))].style != FIELD_SECRET)

    # typing: one text patch, no rebuild
    var d = diff(a, screen("sk-12", True))
    assert_false(d.rebuild)
    assert_equal(len(d.patches), 1)
    assert_equal(d.patches[0].op, SET_TEXT)

    # secret or not is a different widget
    var e = diff(screen("sk-1", False), a)
    assert_true(e.rebuild)
    print("secret field: ok")
