# mojoui.notes (goal 72 M6, D-7284): the fixture notes (tests/fixtures/notes, copied from the prototype) searched by meaning
# with the e5-small pack in this process; the five questions of the prototype's M22 each find the right file first; a
# second index over the same folder takes its passages from the cache (nothing embedded); a folder that leaves the notes
# is refused; hidden files, big files and links are never read.
#   NOTES_PACK=build/packs/e5small build/test_notes   (after scripts/mxbuild.sh tests/test_notes.mojo -o build/test_notes)
from std.testing import assert_equal, assert_true
from std.os import getenv
from mojoui.notes import NotesIndex, resolve_inside, split_passages
from mojoui.process import output
from mojoui.clock import now_ns

comptime FIXTURE = "tests/fixtures/notes"
comptime CACHE = "build/g72/notes-cache"


def refused(root: String, sub: String) -> String:
    try:
        _ = resolve_inside(root, sub)
    except e:
        return String(e)
    return ""


def main() raises:
    var pack = getenv("NOTES_PACK", "build/packs/e5small")
    _ = output(["rm", "-rf", CACHE])
    # confinement first: no model needed
    assert_equal(refused(FIXTURE, "../../.ssh"), "I only read your notes folder (notes), not ../../.ssh")
    assert_equal(refused(FIXTURE, "/etc"), "there is no folder /etc in notes")
    assert_equal(refused(FIXTURE, "home/../../.."), "I only read your notes folder (notes), not home/../../..")
    assert_equal(refused(FIXTURE, "health"), "")
    assert_equal(refused(FIXTURE, ""), "")
    # a link pointing out of the folder, a hidden file and a big file are not read
    var tmp = "build/g72/notes-edge"
    _ = output(["rm", "-rf", tmp])
    _ = output(["mkdir", "-p", tmp + "/sub", tmp + "/.hidden"])
    _ = output(["sh", "-c", "echo 'the safe word is tangerine' > " + tmp + "/ok.md; echo 'secret' > " + tmp + "/.hidden/s.md; echo 'dot' > " + tmp + "/.dot.md; ln -s /etc/hostname " + tmp + "/link.md; ln -s /etc " + tmp + "/sub/out; head -c 1100000 /dev/zero | tr '\\0' 'a' > " + tmp + "/big.txt; echo 'a pdf' > " + tmp + "/x.pdf"])
    assert_equal(refused(tmp, "sub/out"), "I only read your notes folder (notes-edge), not sub/out")
    var edge = NotesIndex(tmp, pack)
    assert_equal(len(edge.files), 1)
    assert_equal(edge.files[0], "ok.md")
    # passages
    var ps = split_passages("one\n\ntwo two\n\n\n\nthree")
    assert_equal(len(ps), 1)
    assert_equal(ps[0], "one\n\ntwo two\n\nthree")
    # the fixture
    var t0 = now_ns()
    var notes = NotesIndex(FIXTURE, pack, CACHE)
    assert_equal(len(notes.files), 7)
    while not notes.step(8):
        pass
    var indexed_ms = (now_ns() - t0) // 1_000_000
    var made = notes.embedded
    assert_true(made >= 7, "passages embedded")
    var asks = ["When is my next dental cleaning?", "What tyre pressure did I write down for the front tyres?", "Who offered to narrate the onboarding video?",
                "What time do I land in Lisbon?", "How long should grandma's lentil soup simmer?"]
    var want = ["health/dentist.md", "home/car.md", "work/q1-ideas.md", "trips/lisbon.md", "recipes.txt"]
    var ms = 0
    for i in range(5):
        var t1 = now_ns()
        var hits = notes.search(asks[i], "", 4)
        ms += (now_ns() - t1) // 1_000_000
        var shown = String("")
        for h in hits:
            shown += h.file + " " + String(h.score)[byte=:5] + "; "
        print("  ", asks[i], "->", shown)
        assert_true(len(hits) > 0, "no hit for " + asks[i])
        assert_equal(hits[0].file, want[i])
    # an unrelated question finds nothing
    var none = notes.search("How do I configure a Kubernetes ingress controller?", "", 4)
    print("   unrelated ->", len(none), "hits")
    assert_equal(len(none), 0)
    # inside one subfolder only
    var only = notes.search("When is my next dental cleaning?", "home", 4)
    for h in only:
        assert_true(h.file.startswith("home/"), "a hit outside the folder asked: " + h.file)
    # the cache: a second index embeds nothing, and answers the same
    var again = NotesIndex(FIXTURE, pack, CACHE)
    assert_true(again.ready(), "a cached index is ready at once")
    assert_equal(again.embedded, 0)
    assert_equal(again.search(asks[3], "", 1)[0].file, "trips/lisbon.md")
    # a changed file is embedded again, alone
    _ = output(["rm", "-rf", "build/g72/notes-copy"])
    _ = output(["sh", "-c", "cp -r " + FIXTURE + " build/g72/notes-copy; echo 'Parking code is 4417.' >> build/g72/notes-copy/home/car.md"])
    var third = NotesIndex("build/g72/notes-copy", pack, CACHE)
    assert_equal(len(third.waiting), 7)  # (another folder: nothing of it is cached)
    while not third.step(8):
        pass
    var fourth = NotesIndex("build/g72/notes-copy", pack, CACHE)
    assert_equal(fourth.embedded, 0)
    _ = output(["sh", "-c", "printf '\\n\\nThe guest wifi password is blue-heron-42. It is printed on the router too.\\n' >> build/g72/notes-copy/home/garden.md"])
    var fifth = NotesIndex("build/g72/notes-copy", pack, CACHE)
    assert_equal(len(fifth.waiting), 1)
    while not fifth.step(8):
        pass
    var wifi = fifth.search("What is the guest wifi password?", "", 1)
    assert_true(len(wifi) == 1, "the new passage is found")
    assert_equal(wifi[0].file, "home/garden.md")
    assert_true(wifi[0].text.find("blue-heron-42") >= 0, wifi[0].text)
    # D-7308: a big folder never holds the UI thread. The fixtures fifty times over and a note of nearly a megabyte: every
    # index tick (step) stays under 16 ms, a search over all of it too, and a question's look at the folder (refresh) reads
    # nothing again when nothing changed, and only the new note when one was added.
    var big = "build/g72/notes-big"
    _ = output(["rm", "-rf", big])
    _ = output(["mkdir", "-p", big])
    for k in range(50):
        _ = output(["cp", "-r", FIXTURE, big + "/copy" + String(k)])
    var huge = String("")
    for i in range(3900):
        huge += "Paragraph " + String(i) + ": the quick brown fox jumps over the lazy dog while the committee discusses the quarterly budget, travel plans and lentil soup for Thursday afternoon.\n\n"
    with open(big + "/huge.md", "w") as f:
        f.write(huge)
    var idx = NotesIndex(big, pack, "")
    assert_equal(len(idx.files), 351)
    assert_true(huge.byte_length() > 600_000 and huge.byte_length() < 1_000_000, String(huge.byte_length()))
    var worst = 0.0
    var ticks = 0
    var t_all = now_ns()
    while True:
        var t_tick = now_ns()
        var done = idx.step(6)
        var took = Float64(now_ns() - t_tick) / 1e6
        worst = max(worst, took)
        ticks += 1
        if done:
            break
    print("   big folder:", idx.count(), "passages in", ticks, "ticks,", (now_ns() - t_all) // 1_000_000, "ms in all; the longest tick", worst, "ms")
    assert_true(idx.count() > 1500, "the huge note is in")
    assert_true(worst < 16.0, "an index tick took " + String(worst) + " ms")
    var t_s = now_ns()
    var big_hits = idx.search("When is my next dental cleaning?", "", 4)
    var big_search_ms = Float64(now_ns() - t_s) / 1e6
    print("   big folder: a search over", idx.count(), "passages took", big_search_ms, "ms")
    assert_true(big_search_ms < 16.0, "a search took " + String(big_search_ms) + " ms")
    assert_true(len(big_hits) > 0 and big_hits[0].file.endswith("health/dentist.md"), "the right note is first")
    # the look at the folder: throttled, then (when forced) free of work if nothing changed
    idx.refresh()
    assert_equal(idx.scans, 1)
    idx.scan_ns = 0
    var t_r = now_ns()
    idx.refresh()
    var look_ms = Float64(now_ns() - t_r) / 1e6
    print("   big folder: looking at 351 notes took", look_ms, "ms")
    assert_equal(idx.scans, 1)  # nothing changed: nothing rebuilt
    assert_true(look_ms < 50.0, "the look took " + String(look_ms) + " ms")
    var before = idx.count()
    with open(big + "/new-note.md", "w") as f:
        f.write("The locker code at the gym is 7731, written here so I stop forgetting it.")
    idx.scan_ns = 0
    idx.refresh()
    assert_equal(idx.scans, 2)
    assert_equal(len(idx.waiting), 1)  # only the new note waits
    assert_equal(idx.count(), before)  # and everything else is still there
    while not idx.step(6):
        pass
    var locker = idx.search("What is the gym locker code?", "", 1)
    assert_true(len(locker) == 1 and locker[0].file == "new-note.md", "the new note is found")
    _ = output(["rm", "-rf", big])
    print("notes: ok -", made, "passages in", indexed_ms, "ms (with the pack's load), 5 searches", ms, "ms in all")
