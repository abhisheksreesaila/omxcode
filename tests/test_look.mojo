# mojoui.personalize: the four whitelisted settings, a request read and checked (anything off the list refused with a
# sentence, all or nothing), "put it back", one look per person, kept in a JSON file per person ($MOJOUI_LOOK overrides the
# folder), and what the look means to an app (dark by the clock, the accent from the palette's own series, roomy tiles).
#   pixi run mojo run -I . tests/test_look.mojo

from std.testing import assert_equal, assert_true, assert_false
from std.os import setenv, makedirs
from std.os.path import exists, isdir
from mojoui.json import Json
from mojoui.personalize import (
    Personalize, LookPrefs, LookChange, look_values, look_labels, look_check, look_dir, is_profile_name, scheme_dark,
    accent_colour, accent_index, stage_most, is_night, look_knobs, personalize_tool, PERSONALIZE, PERSONALIZE_PARAMS, UNDO_MAX,
    KNOB_SCHEME, KNOB_ACCENT, KNOB_PRESENCE, KNOB_DENSITY, KNOB_UNDO,
)
from mojoui.theme import Palette
from mojoui.view import SEGMENTED, BUTTON
from themes.omxqua import counter_palette


def scratch(name: String) raises -> String:
    var d = String("build/test_look/") + name
    makedirs(d, exist_ok=True)
    for who in ["all", "a", "s", "m"]:
        var f = d + "/" + who + ".json"
        if exists(f) and not isdir(f):
            with open(f, "w") as h:
                h.write("")
    return d


def test_values_and_defaults() raises:
    var p = LookPrefs()
    assert_equal(p.json(), '{"scheme":"auto","accent":"default","presence":"orb","density":"compact"}')
    assert_true(p.is_default())
    assert_equal(len(look_values("accent")), 7)
    assert_equal(look_labels("scheme")[2], "Dark")
    assert_equal(look_labels("scheme")[3], "Night")
    assert_equal(look_check("scheme", "dark"), "")
    assert_true(look_check("accent", "#ff00ff").find("theme's own colours") >= 0)
    assert_true(look_check("font", "big").find("only change") >= 0)


def test_ask_sets_and_says() raises:
    var look = Personalize("t", dir="")
    var c = look.ask('{"set":{"presence":"mascot","scheme":"dark"}}')
    assert_true(c.ok)
    assert_true(c.moved())
    assert_equal(len(c.changed), 2)
    assert_equal(look.prefs.presence, "mascot")
    assert_equal(look.prefs.scheme, "dark")
    assert_true(c.message.find("the mascot instead of the orb") >= 0)
    var r = Json.parse(c.result())
    assert_true(r.flag(r.get(0, "ok")))
    assert_equal(r.size(r.get(0, "changed")), 2)
    assert_equal(r.text(r.get(r.get(0, "now"), "scheme")), "dark")
    # the same again: nothing moves, nothing to undo added
    var again = look.ask('{"set":{"scheme":"dark"}}')
    assert_true(again.ok)
    assert_false(again.moved())
    assert_equal(len(look.undos), 1)


def test_refusals_are_all_or_nothing() raises:
    var look = Personalize("t", dir="")
    var c = look.ask('{"set":{"scheme":"dark","accent":"hotpink"}}')
    assert_false(c.ok)
    assert_true(c.message.find("theme's own colours") >= 0)
    assert_equal(look.prefs.scheme, "auto")  # (the valid half didn't happen either)
    assert_false(look.ask('{"set":{"font":"comic sans"}}').ok)
    assert_false(look.ask('{"set":{"density":7}}').ok)
    assert_false(look.ask("make it pretty").ok)
    assert_false(look.ask('{"set":{}}').ok)
    var r = Json.parse(c.result())
    assert_false(r.flag(r.get(0, "ok")))
    assert_true(r.text(r.get(0, "refused")).find("hotpink") >= 0)
    assert_equal(look.serial, 1)  # (only the start's profile)


def test_synonyms_and_flat_requests() raises:
    var look = Personalize("t", dir="")
    assert_true(look.ask('{"set":{"density":"bigger","accent":"Purple"}}').ok)
    assert_equal(look.prefs.density, "roomy")
    assert_equal(look.prefs.accent, "violet")
    assert_true(look.ask('{"scheme":"night"}').ok)  # (a flat request: read as a set)
    assert_equal(look.prefs.scheme, "dark")


def test_undo_stack() raises:
    var look = Personalize("t", dir="")
    assert_false(look.undo().ok)  # (nothing to put back)
    _ = look.set("scheme", "dark")
    _ = look.set("accent", "blue")
    var c = look.ask('{"undo":true}')
    assert_true(c.ok)
    assert_true(c.undo)
    assert_equal(look.prefs.accent, "default")
    assert_equal(look.prefs.scheme, "dark")
    assert_true(c.message.startswith("Put back"))
    _ = look.undo()
    assert_true(look.prefs.is_default())
    assert_false(look.can_undo())
    for i in range(UNDO_MAX + 5):
        _ = look.set("scheme", "dark" if i % 2 == 0 else "light")
    assert_equal(len(look.undos), UNDO_MAX)


def test_per_person() raises:
    var look = Personalize("t", dir="")
    _ = look.set("presence", "mascot")
    assert_true(look.use_profile("a"))
    assert_equal(look.prefs.presence, "orb")  # (A's own look: the defaults)
    _ = look.set("density", "roomy")
    _ = look.use_profile("all")
    assert_equal(look.prefs.presence, "mascot")
    assert_equal(look.prefs.density, "compact")
    _ = look.use_profile("A")
    assert_equal(look.prefs.density, "roomy")
    assert_true(look.can_undo())  # (A's undo stack came back with A)
    assert_false(look.use_profile("../etc"))
    assert_false(is_profile_name("a/b"))
    assert_false(is_profile_name(""))
    assert_true(is_profile_name("m"))


def test_saved_per_person() raises:
    var d = scratch("files")
    var look = Personalize("t", dir=d)
    _ = look.set("scheme", "dark")
    _ = look.use_profile("s")
    _ = look.set("accent", "teal")
    _ = look.set("presence", "mascot")
    assert_true(exists(d + "/all.json"))
    assert_true(exists(d + "/s.json"))
    var again = Personalize("t", dir=d)  # (a new run: read back from the files)
    assert_equal(again.prefs.scheme, "dark")
    _ = again.use_profile("s")
    assert_equal(again.prefs.accent, "teal")
    assert_equal(again.prefs.presence, "mascot")
    _ = again.undo()  # (the undo stack was saved too)
    assert_equal(again.prefs.presence, "orb")
    # a hand-edited file can't smuggle in a value off the list
    with open(d + "/m.json", "w") as f:
        f.write('{"scheme":"dark","accent":"#123456","presence":"robot","density":"roomy","undo":[{"scheme":"neon"}]}')
    _ = again.use_profile("m")
    assert_equal(again.prefs.scheme, "dark")
    assert_equal(again.prefs.accent, "default")
    assert_equal(again.prefs.presence, "orb")
    assert_equal(again.prefs.density, "roomy")
    with open(d + "/a.json", "w") as f:
        f.write("{not json")
    _ = again.use_profile("a")
    assert_true(again.prefs.is_default())


def test_look_dir_env() raises:
    _ = setenv("MOJOUI_LOOK", "build/test_look/env", True)
    assert_equal(look_dir("omx"), "build/test_look/env")
    var look = Personalize("omx")
    assert_equal(look.dir, "build/test_look/env")
    _ = setenv("MOJOUI_LOOK", "", True)
    _ = setenv("XDG_DATA_HOME", "/tmp/xdg-test", True)
    assert_equal(look_dir("omx"), "/tmp/xdg-test/mojoui/look/omx")


def test_reading_a_look() raises:
    var p = LookPrefs()
    assert_false(scheme_dark(p, False, 11))
    assert_false(scheme_dark(p, False, 21))  # (auto follows the system only: never the clock)
    assert_false(scheme_dark(p, False, 3))
    assert_true(scheme_dark(p, True, 11))  # (auto: the system's dark)
    p.scheme = "night"  # (opt-in: dark from 19:00 to 7:00 by the clock, else as the system is)
    assert_true(scheme_dark(p, False, 19))
    assert_true(scheme_dark(p, False, 6))
    assert_false(scheme_dark(p, False, 7))
    assert_false(scheme_dark(p, False, 18))
    assert_true(scheme_dark(p, True, 12))
    assert_true(is_night(23))
    assert_false(is_night(12))
    p.scheme = "light"
    assert_false(scheme_dark(p, True, 23))
    p.scheme = "dark"
    assert_true(scheme_dark(p, False, 12))
    var pal = counter_palette(False)
    assert_equal(accent_colour(pal, "default"), pal.accent)
    assert_equal(accent_colour(pal, "blue"), pal.series[1])
    assert_equal(accent_colour(pal, "gold"), pal.series[5])
    assert_equal(accent_index("violet"), 0)
    assert_equal(accent_index("default"), -1)
    for a in look_values("accent"):  # (every accent is a colour of the palette: its own accent or one of its series)
        var c = accent_colour(pal, a)
        var found = c == pal.accent
        for s in pal.series:
            found = found or s == c
        assert_true(found)
    p.density = "roomy"
    assert_equal(stage_most(p, 6), 4)
    assert_equal(stage_most(p, 3), 3)
    p.density = "compact"
    assert_equal(stage_most(p, 6), 6)


def test_knobs() raises:
    var look = Personalize("t", dir="")
    var v = look_knobs(look.prefs, 300, look.can_undo())
    var segs = 0
    var undo = False
    for n in v.nodes:
        if n.kind == SEGMENTED:
            segs += 1
        if n.kind == BUTTON and n.msg == 300 + KNOB_UNDO:
            undo = True
    assert_equal(segs, 4)
    assert_false(undo)  # (nothing to put back yet: no button)
    assert_true(look.knob(2, KNOB_SCHEME).moved())
    assert_equal(look.prefs.scheme, "dark")
    assert_true(look.knob(1, KNOB_PRESENCE).moved())
    assert_true(look.knob(1, KNOB_DENSITY).moved())
    assert_true(look.knob(3, KNOB_ACCENT).moved())
    assert_equal(look.prefs.accent, "teal")
    assert_false(look.knob(9, KNOB_ACCENT).ok)
    var after = look_knobs(look.prefs, 300, look.can_undo())
    var found = False
    for n in after.nodes:
        if n.kind == BUTTON and n.msg == 300 + KNOB_UNDO:
            found = True
    assert_true(found)
    assert_true(look.knob(0, KNOB_UNDO).moved())
    assert_equal(look.prefs.accent, "default")


def test_night_by_asking() raises:
    var look = Personalize("t", dir="")
    var c = look.ask('{"set":{"scheme":"dark at night"}}')
    assert_true(c.ok)
    assert_equal(look.prefs.scheme, "night")
    assert_true(c.message.find("dark at night") >= 0)
    assert_true(look.ask('{"set":{"scheme":"system"}}').ok)
    assert_equal(look.prefs.scheme, "auto")


def test_profile_names() raises:
    var look = Personalize("t", dir="")
    _ = look.set("scheme", "dark")
    assert_false(look.use_profile("../x"))
    assert_false(look.use_profile(""))
    assert_false(look.use_profile("abcdefghijklmnopqrstuvwxy"))  # (25 bytes: over the 24 a name may have)
    assert_false(look.use_profile("a b"))
    assert_true(look.use_profile("abcdefghijklmnopqrstuvwx"))  # (24: the longest allowed)
    _ = look.use_profile("all")
    assert_equal(look.prefs.scheme, "dark")  # (a refused name changed nothing)
    assert_equal(look.profile, "all")


def test_corrupt_file_is_defaults() raises:
    var d = scratch("corrupt")
    for text in ["{not json", "", "[1, 2]", '{"scheme": 7, "undo": "x"}', "null"]:
        with open(d + "/s.json", "w") as f:
            f.write(text)
        var look = Personalize("t", dir=d)
        _ = look.use_profile("s")
        assert_true(look.prefs.is_default())
        assert_false(look.can_undo())
        assert_true(look.set("accent", "red").ok)  # (and the next change writes a good file)
        var again = Personalize("t", dir=d)
        _ = again.use_profile("s")
        assert_equal(again.prefs.accent, "red")


def test_failed_save_leaves_no_tmp() raises:
    var d = scratch("nosave")
    makedirs(d + "/m.json", exist_ok=True)  # (a folder where the file should go: the rename fails)
    var look = Personalize("t", dir=d)
    _ = look.use_profile("m")
    var c = look.set("density", "roomy")
    assert_true(c.ok)  # (the change holds for this run)
    assert_true(look.error != "")
    assert_false(exists(d + "/m.json.tmp"))


def test_group_is_one_undo() raises:
    var look = Personalize("t", dir="")
    look.begin_group()  # (one agent turn: two calls)
    _ = look.ask('{"set":{"presence":"mascot"}}')
    _ = look.ask('{"set":{"scheme":"dark"}}')
    look.end_group()
    assert_equal(len(look.undos), 1)
    var c = look.undo()  # ("put it back": the whole request)
    assert_true(c.ok)
    assert_true(look.prefs.is_default())
    assert_equal(len(c.changed), 2)
    _ = look.set("accent", "red")  # (outside a group: one step each)
    _ = look.set("density", "roomy")
    assert_equal(len(look.undos), 2)


def test_tool() raises:
    var t = personalize_tool()
    assert_equal(t.name, PERSONALIZE)
    var j = Json.parse(PERSONALIZE_PARAMS)
    var props = j.get(j.get(j.get(0, "properties"), "set"), "properties")
    assert_equal(j.size(j.get(j.get(props, "accent"), "enum")), len(look_values("accent")))
    assert_equal(j.size(j.get(j.get(props, "density"), "enum")), 2)
    assert_equal(j.size(j.get(j.get(props, "scheme"), "enum")), len(look_values("scheme")))


def main() raises:
    test_values_and_defaults()
    test_ask_sets_and_says()
    test_refusals_are_all_or_nothing()
    test_synonyms_and_flat_requests()
    test_undo_stack()
    test_per_person()
    test_saved_per_person()
    test_look_dir_env()
    test_reading_a_look()
    test_knobs()
    test_night_by_asking()
    test_profile_names()
    test_corrupt_file_is_defaults()
    test_failed_save_leaves_no_tmp()
    test_group_is_one_undo()
    test_tool()
    print("test_look: 16 tests passed")
