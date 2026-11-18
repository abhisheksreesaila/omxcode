# mojoui.pointer (goal 77 M1): which parts a spoken clause names, and where in it; the AG-UI `point` event.
from std.testing import assert_equal, assert_true
from mojoui.pointer import Part, Hit, match_clause, names_for, point_event, parse_point, norm


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
    print("pointer: ok")
