# mojoui.comic + mojoui.imagegen + mojoui.creator without an image model (goal 72 M6, D-7280..D-7284): the plan a model hands in
# is checked and turned into the prompts; a drawing reply's PNG is found inside its JSON; the agent's three tools answer
# what a model can act on (a bad plan, no painter, a path outside the notes); a notes question puts a card that cites the
# right file on the shelf and gives the model the passages as fenced untrusted text; the album takes a picture under a safe, unique name.
#   NOTES_PACK=build/packs/e5small build/test_creator   (after scripts/mxbuild.sh tests/test_creator.mojo -o build/test_creator)
from std.testing import assert_equal, assert_true
from std.os import getenv
from mojoui.comic import ComicPlan, picture_prompt, comic_tool
from mojoui.imagegen import png_of, ImageServer, IMG_FAILED
from mojoui.creator import Creator, CARD_NOTES
from mojoui.album import Album
from mojoui.picture import Picture
from std.memory import ArcPointer

comptime GOOD = (
    '{"title":"Bread Bot","character":"a small round blue robot with one big yellow eye and a red apron",'
    '"panels":[{"caption":"Bot finds a recipe.","scene":"the robot reads a recipe book in a bright kitchen"},'
    '{"caption":"Flour everywhere.","scene":"the robot is covered in flour beside a bowl"},'
    '{"caption":"Into the oven.","scene":"the robot slides a tray into an oven"},'
    '{"caption":"Warm bread.","scene":"the robot smiles holding a golden loaf"}]}'
)


def main() raises:
    # the plan
    var plan = ComicPlan.parse(GOOD)
    assert_equal(plan.title, "Bread Bot")
    assert_equal(len(plan.captions), 4)
    assert_equal(plan.captions[3], "Warm bread.")
    assert_equal(plan.prompt(2), "comic book panel, bold clean ink outlines, flat vivid colours, expressive faces, simple background, no text, no speech bubbles, no letters. a small round blue robot with one big yellow eye and a red apron. the robot slides a tray into an oven")
    var raised = False
    try:
        _ = ComicPlan.parse('{"title":"x","character":"a fox","panels":[{"caption":"a","scene":"b"}]}')
    except e:
        raised = True
        assert_equal(String(e), 'the plan needs exactly 4 panels, each {"caption", "scene"}; this one has 1')
    assert_true(raised, "three panels short is refused")
    try:
        _ = ComicPlan.parse('{"title":"x","panels":[]}')
    except e:
        assert_true(String(e).startswith('the plan needs a "character"'), String(e))
    assert_equal(picture_prompt("  a red fox  "), "a red fox. Beautiful, detailed, good composition.")
    assert_equal(comic_tool().name, "make_comic")
    # the reply
    assert_equal(len(png_of('{"images":["iVBORw0KGgo="]}')), 8)  # the PNG signature alone
    assert_equal(len(png_of('{"images":["AAAA"]}')), 0)  # not a PNG
    assert_equal(len(png_of('{"error":"no"}')), 0)
    # the album's names
    var album = Album()
    var shared = ArcPointer(Picture("tests/fixtures/media/alpha.png"))
    assert_equal(album.hold("A Red Fox!!", shared, "a fox"), "a-red-fox")
    assert_equal(album.hold("A Red Fox!!", shared, "a fox again"), "a-red-fox-2")
    assert_equal(album.hold("../../etc/passwd", shared, "x"), "etc-passwd")
    assert_equal(album.hold("", shared, "x"), "picture")
    assert_equal(album.count(), 4)
    # the tools, with no painter and with the fixture notes
    var server = ImageServer.zimage("/nonexistent/sd-server", "/nonexistent", "1", 8190)
    var c = Creator(9000, 5000, server^, "build/g72/pictures-test")
    c.server.start()
    assert_equal(c.server.state, IMG_FAILED)
    c.call("c1", "make_comic", GOOD)
    c.call("c2", "draw_picture", '{"subject":"a fox"}')
    var a = c.take_answers()
    assert_equal(len(a), 2)
    assert_equal(a[0].content, '{"error":"I can\'t draw right now: the image model isn\'t installed (/nonexistent/sd-server)"}')
    c.attach_notes("tests/fixtures/notes", getenv("NOTES_PACK", "build/packs/e5small"), "build/g72/notes-cache-creator")
    assert_equal(c.notes_note, "")
    var names = String("")
    for t in c.tools():
        names += t.name + " "
    assert_equal(names, "make_comic draw_picture find_in_notes ")
    c.call("n0", "find_in_notes", '{"question":"keys","folder":"../../.ssh"}')
    a = c.take_answers()
    assert_equal(a[0].content, '{"error":"I only read your notes folder (notes), not ../../.ssh"}')
    c.call("n1", "find_in_notes", '{"question":"When is my next dental cleaning?"}')
    assert_equal(len(c.take_answers()), 0)  # waits for the index
    for _ in range(200):
        c.tick()
        if len(c.answers) > 0:
            break
    a = c.take_answers()
    assert_equal(len(a), 1)
    assert_equal(a[0].id, "n1")
    assert_true(a[0].content.find('"file":"health/dentist.md"') >= 0, a[0].content)
    assert_true(a[0].content.find("14 February at 9:30") >= 0, a[0].content)
    assert_equal(len(c.cards), 1)
    assert_equal(c.cards[0].kind, CARD_NOTES)
    assert_equal(c.cards[0].files[0], "health/dentist.md")
    assert_true(a[0].untrusted, "what the notes held goes to the model as untrusted text (the agent taints the turn)")
    assert_true(a[0].content.find('<untrusted source=\\"notes\\">') >= 0 and a[0].content.find("</untrusted>") >= 0, "and fenced: " + a[0].content)
    c.turn_began()
    c.call("n2", "find_in_notes", '{"question":"How do I configure a Kubernetes ingress controller?"}')
    for _ in range(200):
        c.tick()
        if len(c.answers) > 0:
            break
    var none = c.take_answers()
    assert_equal(none[0].content, '{"result":"Nothing in the notes matches that.","note":"Say so; do not guess."}')
    assert_true(not none[0].untrusted, "nothing was read, so nothing is untrusted")
    assert_equal(len(c.cards), 1)
    print("creator: ok")
