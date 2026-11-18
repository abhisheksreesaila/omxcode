# mojoui.links completions (goal 73 M1): what the Links panel offers while a link is typed, like a query editor's
# autocomplete: card names, then the card's columns, then the operator, then the second end. A completion replaces
# only the word being typed; at most LINK_COMPLETIONS; an app's non-table cards (a video's file/t/frame) count too.
#   pixi run mojo run -I . tests/test_link_complete.mojo
from std.testing import assert_equal
from mojoui.app import Event
from mojoui.links import Links, LINKS_ADD, LINKS_PICK, LINK_COMPLETIONS
from mojoui.view import BUTTON


def texts(links: Links, draft: String) -> String:
    var out = List[String]()
    for c in links.complete(draft):
        out.append(c.text)
    return " | ".join(out)


def labels(links: Links, draft: String) -> String:
    var out = List[String]()
    for c in links.complete(draft):
        out.append(c.label)
    return " | ".join(out)


def tap(mut links: Links, k: Int):
    _ = links.update(Event(7600 + LINKS_PICK + k, "", 0))


def main() raises:
    var links = Links(7600)
    _ = links.know("fleet", ["episode", "clip", "lab", "outcome"])
    _ = links.know("telemetry", ["episode", "t", "joint_1"])
    links.know_card("clip.mp4", ["file", "t", "frame"])
    _ = links.know("Orders", ["order_id", "Parent", "partner"])

    # no dot yet: the cards whose names start with what's typed (any case), each as `name.`
    assert_equal(labels(links, ""), "fleet. | telemetry. | clip.mp4. | Orders.", "an empty draft offers every card")
    assert_equal(texts(links, "fl"), "fleet.", "fl -> fleet.")
    assert_equal(texts(links, "TEL"), "telemetry.", "any case")
    assert_equal(texts(links, "zzz"), "", "no card starts with zzz")

    # card. or card.par: that card's columns starting with it; the completion replaces only the word
    assert_equal(labels(links, "fleet."), "episode | clip | lab | outcome", "fleet. offers its columns")
    assert_equal(texts(links, "fleet.ep"), "fleet.episode ", "fleet.ep -> fleet.episode (and a space: the operator is next)")
    assert_equal(texts(links, "orders.PARE"), "Orders.Parent ", "any case; the card as the app spelled it")
    assert_equal(labels(links, "Orders.p"), "Parent | partner", "two columns start with p")
    assert_equal(texts(links, "fleet.zz"), "", "no such column")

    # a card whose name holds a dot: the longest known card the word starts with
    assert_equal(texts(links, "clip.mp"), "clip.mp4.", "clip.mp is the start of a card's name, not card clip + column mp")
    assert_equal(labels(links, "clip.mp4."), "file | t | frame", "a video's columns")
    assert_equal(texts(links, "clip.mp4.f"), "clip.mp4.file  | clip.mp4.frame ", "columns of a dotted card")

    # a whole end and a space: the operators; a typed prefix narrows them
    assert_equal(texts(links, "fleet.episode "), "fleet.episode =  | fleet.episode ~ ", "after a whole end: = and ~")
    assert_equal(texts(links, "fleet.episode ="), "fleet.episode = ", "a typed = is completed with its space")
    assert_equal(labels(links, "fleet.episode "), "= | ~", "the chips read = and ~")

    # after the operator: card names, then columns of the second end
    assert_equal(labels(links, "fleet.episode = "), "fleet. | telemetry. | clip.mp4. | Orders.", "the second end starts with cards")
    assert_equal(texts(links, "fleet.episode = te"), "fleet.episode = telemetry.", "te -> telemetry.")
    assert_equal(texts(links, "fleet.episode = telemetry."),
                 "fleet.episode = telemetry.episode | fleet.episode = telemetry.t | fleet.episode = telemetry.joint_1", "the second end's columns")
    assert_equal(texts(links, "fleet.episode = telemetry.ep"), "fleet.episode = telemetry.episode", "the whole link")
    assert_equal(texts(links, "fleet.t ~ clip.mp4.t"), "fleet.t ~ clip.mp4.t", "a time link's second end")
    assert_equal(texts(links, "fleet.t ~ clip.mp4.t +0"), "", "after the second end: the offset is free text")

    # at most 8
    var many = Links(0)
    var cols = List[String]()
    for i in range(12):
        cols.append("c" + String(i))
    _ = many.know("wide", cols)
    assert_equal(len(many.complete("wide.")), 8, "no more than 8")
    assert_equal(LINK_COMPLETIONS, 8, "the limit")

    # the panel: chips under the field, tagged for an agent; tapping one puts it into the draft
    links.draft = "fl"
    var field_and_chips = links.panel()[1].copy()
    var found = 0
    for node in field_and_chips.nodes:
        if node.name == "link-pick-0":
            found += 1
            assert_equal(node.kind, BUTTON, "a chip is a button")
    assert_equal(found, 1, "chip 0 stands under the field")
    assert_equal(links.update(Event(7600 + LINKS_PICK, "", 0)), True, "the chip is the panel's")
    assert_equal(links.draft, "fleet.", "tapping fl's first chip fills the draft")
    links.draft = "fleet.ep"
    tap(links, 0)
    assert_equal(links.draft, "fleet.episode ", "tapping a column")
    tap(links, 0)
    assert_equal(links.draft, "fleet.episode = ", "tapping =")
    tap(links, 1)
    assert_equal(links.draft, "fleet.episode = telemetry.", "the second chip: telemetry.")
    tap(links, 0)
    assert_equal(links.draft, "fleet.episode = telemetry.episode", "the whole link")
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.list()[0], "fleet.episode = telemetry.episode", "Return on a whole link links it")
    assert_equal(links.draft, "", "and clears the field")

    # Return on a draft that isn't a whole link takes the first completion instead of an error
    links.draft = "fl"
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.draft, "fleet.", "Return on fl")
    assert_equal(links.problem, "", "no error shown")
    links.draft = "fleet.episode = telemetry.ep"
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.draft, "fleet.episode = telemetry.episode", "Return on a half-typed end completes it")
    assert_equal(len(links), 1, "and adds nothing yet")
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(len(links), 1, "Return on the same link again adds nothing")
    assert_equal(links.problem != "", True, "an already-made link says so")
    links.problem = ""
    # a video card's half-typed column (its columns come from know_card, not a table's schema): Return completes, never links "fr"
    links.draft = "fleet.episode = clip.mp4.fr"
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.draft, "fleet.episode = clip.mp4.frame", "Return on a video card's half-typed column completes it")
    assert_equal(len(links), 1, "and links nothing")
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.list()[1], "fleet.episode = clip.mp4.frame", "Return on the whole column links it")
    _ = links.remove(1)
    links.draft = "orders.order_id = clip.mp4.code"  # (a video's analysis column, none of file/t/frame: links as typed)
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.list()[1], "orders.order_id = clip.mp4.code", "a column nothing completes links as typed")
    _ = links.remove(1)
    links.draft = "Orders.ORDER_ID = clip.mp4.FILE"  # (another case: the last word takes its card's own case; a column
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))  # named in a case its table doesn't have is refused, saying its columns)
    assert_equal(links.draft, "Orders.ORDER_ID = clip.mp4.file", "Return puts the word being typed in its card's own case")
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(len(links), 1, "ORDER_ID isn't Orders' column: nothing links")
    assert_equal(links.problem.find("order_id") >= 0, True, "and the error names the columns it has")
    links.problem = ""
    links.draft = "orders.order_id = clip.mp4.f"  # (a strict prefix of a video's column always completes: by design)
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.draft, "orders.order_id = clip.mp4.file", "a strict prefix of file/t/frame completes, never links")
    assert_equal(len(links), 1, "and links nothing")
    links.draft = ""  # (Return on an empty field offers the first card: nothing links)
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.draft, "fleet.", "Return on an empty field fills the first card's name")
    assert_equal(len(links), 1, "and links nothing")
    links.draft = "nonsense"
    _ = links.update(Event(7600 + LINKS_ADD, "", 0))
    assert_equal(links.problem != "", True, "nothing to complete: the error shows")
    print("link_complete: ok")
