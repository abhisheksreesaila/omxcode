# mojoui.pointer (goal 77 M1): which parts a spoken clause names, and where in it; the AG-UI `point` event.
from std.testing import assert_equal, assert_true
from mojoui.pointer import Part, Hit, Pointer, match_clause, names_for, point_event, parse_point, norm, area_part, part_name, fitted_rect


def word_parts() -> List[Part]:
    return [
        Part("card1", "word", ["ephemeral"], False, True),
        Part("card1", "meaning", ["means", "meaning", "definition", "is when", "is a", "is an", "is the"], True, False),
        Part("card1", "example", ["for example", "example", "for instance", "as in", "you might say"], True, False),
        Part("card1", "sounds", ["pronounced", "sounds like"], True, False),
    ]


def hit_parts(hits: List[Hit]) -> String:
    var out = String("")
    for h in hits:
        out += (" " if out != "" else "") + h.part
    return out


def main() raises:
    assert_equal(norm("Ephemeral, (adj.)!"), " ephemeral adj ")
    assert_equal(norm("   "), " ")
    var parts = word_parts()
    # the word itself, then a cue for the meaning in the same clause: both, in the order spoken
    var a = match_clause("Ephemeral means lasting a very short time.", parts)
    assert_equal(hit_parts(a), "word meaning")
    assert_equal(a[0].at, 1.0 / 43.0)  # " ephemeral means lasting a very short time " is 43 bytes; the word starts at byte 1
    assert_true(a[1].at > a[0].at and a[1].at < 0.3)
    # an example clause
    assert_equal(hit_parts(match_clause("For example, you might say the weather was ephemeral.", parts)), "example word")
    # names beat cues: a clause naming a strong (non-weak, non-cue) part ignores the cue words
    var stops: List[Part] = [Part("card2", "belem", ["belem tower", "belem"], False, False), Part("card2", "meaning", ["is a"], True, False)]
    assert_equal(hit_parts(match_clause("Belem tower is a short walk away.", stops)), "belem")
    # no part named: nothing
    assert_equal(len(match_clause("Anyway, that is all.", parts)), 0)
    assert_equal(len(match_clause("", parts)), 0)
    # a name is found only as a whole word
    assert_equal(len(match_clause("Counterexamples are fun.", [Part("c", "example", ["example"], True, False)])), 0)
    # each part once, longest name first
    assert_equal(hit_parts(match_clause("The meaning, I mean the definition, is clear.", parts)), "meaning")
    var one: List[String] = ["The Alfama Quarter"]
    # distinctive names
    var labels: List[String] = ["Belem Tower", "Jeronimos Monastery", "Tower Bridge"]
    var names = names_for("Belem Tower", labels)
    assert_equal(len(names), 2)  # the label and "belem" ("tower" is generic and shared)
    assert_equal(names[1], "belem")
    assert_equal(names_for("The Alfama Quarter", one)[1], "alfama")
    assert_equal(names_for("The Alfama Quarter", one)[2], "Alfama Quarter")
    # the event
    assert_equal(point_event("card1", "meaning", 420), '{"type":"CUSTOM","name":"point","value":{"card":"card1","part":"meaning","at_ms":420}}')
    var back = parse_point(point_event("card1", "meaning", 420))
    assert_true(Bool(back))
    assert_equal(back.value().part, "meaning")
    assert_equal(back.value().card, "card1")
    assert_equal(back.value().at, 0.42)
    assert_true(not Bool(parse_point('{"type":"CUSTOM","name":"suggestions","value":[]}')))
    # a part that is a box in a picture (a camera card's banana): found in its picture's view, the picture drawn fitted and centred
    assert_equal(part_name("Water Bottle"), "water-bottle")
    var banana = area_part("look1", "banana", ["banana"], "look1.picture", 50.0, 0.0, 100.0, 50.0, 200, 100)
    assert_equal(banana.tag(), "look1.banana")
    var r = fitted_rect([10.0, 20.0, 400.0, 100.0], banana.area)  # (200x100 in 400x100: scale 1, 100 points of margin each side)
    assert_equal(r[0], 160.0)
    assert_equal(r[1], 20.0)
    assert_equal(r[2], 50.0)
    assert_equal(r[3], 50.0)
    var tall = fitted_rect([0.0, 0.0, 100.0, 300.0], banana.area)  # (200x100 in 100x300: scale 0.5, centred vertically)
    assert_equal(tall[0], 25.0)
    assert_equal(tall[1], 125.0)
    assert_equal(len(fitted_rect(List[Float64](), banana.area)), 0)  # (the picture's view isn't on screen)
    var ring = Pointer()
    var known: List[Part] = [banana.copy(), Part("card1", "word", ["ephemeral"], False, True)]
    ring.know(known)
    assert_equal(len(ring.areas), 1)  # (only the boxes: a view part is found by its own tag)
    assert_equal(len(ring.where("look1.banana")), 0)  # (no host here: nothing on screen)
    # a clause naming the box's label points at it
    assert_equal(hit_parts(match_clause("The banana is on the left of the counter.", known)), "banana")
    print("pointer: ok")
