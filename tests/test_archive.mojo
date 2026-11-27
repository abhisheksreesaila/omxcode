# mojoui.archive (goal 82 M3): ZIP read and write and folder sets. A ZIP Python's zipfile deflated is read whole (its
# hidden and climbing names left out); a zip bomb stops at the size it declares; what zip_bytes writes, Python's zipfile and
# read_zip read back byte for byte (the check runs Python on it: tests/test_archive_py.py); write_folder never overwrites.
# archive: ok
from std.testing import assert_true, assert_equal
from std.os import makedirs, getenv
from mojoui.archive import FileSet, Limits, read_zip, zip_bytes, read_folder, write_folder, safe_relative, crc32
from mojoui.files import remove_tree, file_exists


def bytes_of(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def safe_paths() raises:
    assert_equal(safe_relative("a/b.md"), "a/b.md")
    assert_equal(safe_relative("a\\b.md"), "a/b.md")
    for bad in ["/etc/passwd", "../x", "a/../../x", "a//b", ".obsidian/app.json", "a/.git/x", "C:/x", "a/", ""]:
        assert_equal(safe_relative(bad), "", "unsafe: " + bad)
    print("  safe paths: ok", flush=True)


def python_zip() raises:
    var z = read_zip(bytes_of("tests/fixtures/archive/py_deflate.zip"))
    assert_equal(len(z), 4, "the canvas, the note, big.txt, stored.bin")
    var c = z.find("Vault/Ideas.canvas")
    assert_true(c >= 0 and z.files[c].text().find("héllo") >= 0, "a deflated canvas")
    var m = z.find("Vault/Ünïcode note.md")
    assert_true(m >= 0 and z.files[m].text() == "# Title\n\nwords ✓\n", "a UTF-8 name and text")
    var b = z.find("big.txt")
    assert_true(b >= 0 and len(z.files[b].data) == 400000, "400 KB from a few hundred bytes")
    var s = z.find("stored.bin")
    assert_true(s >= 0 and len(z.files[s].data) == 256 and z.files[s].data[255] == 255, "a stored entry")
    assert_equal(len(z.skipped), 2, "../escape.md and the hidden .obsidian file left out")
    print("  python's zip: ok (skipped: " + String(len(z.skipped)) + ")", flush=True)


def limits() raises:
    var raised = False
    try:
        _ = read_zip(bytes_of("tests/fixtures/archive/bomb.zip"))
    except e:
        raised = String(e).find("damaged") >= 0 or String(e).find("allowed") >= 0
    assert_true(raised, "a bomb that says 1000 bytes and holds 400 KB raises")
    raised = False
    try:
        _ = read_zip(bytes_of("tests/fixtures/archive/py_deflate.zip"), Limits(total_bytes=1000))
    except e:
        raised = String(e).find("limit") >= 0
    assert_true(raised, "more than the total raises before anything is inflated")
    var small = read_zip(bytes_of("tests/fixtures/archive/py_deflate.zip"), Limits(file_bytes=1000))
    assert_true(small.find("big.txt") < 0 and small.find("Vault/Ideas.canvas") >= 0, "a file over the limit is left out, the rest read")
    raised = False
    try:
        var junk = List[UInt8](length=100, fill=7)
        _ = read_zip(junk)
    except e:
        raised = String(e).find("not a ZIP") >= 0
    assert_true(raised, "not a zip")
    print("  limits: ok", flush=True)


def round_trip() raises:
    var s = FileSet()
    s.add_text("Notes/a.md", "# A\n\nwörds\n")
    var png = List[UInt8]()
    for i in range(5000):
        png.append(UInt8((i * 31) % 256))
    s.add("attachments/x.png", png.copy())
    s.add_text("Notes/Sub folder/b.canvas", '{"nodes":[],"edges":[]}')
    var z = zip_bytes(s)
    var back = read_zip(z)
    assert_equal(len(back), 3)
    for ref f in s.files:
        var k = back.find(f.path)
        assert_true(k >= 0 and back.files[k].data == f.data, "the same bytes: " + f.path)
    var out = getenv("ARCHIVE_OUT", "build/test_archive")
    remove_tree(out)
    makedirs(out, exist_ok=True)
    with open(out + "/made.zip", "w") as f:
        f.write_bytes(Span(z))
    assert_equal(write_folder(s, out + "/folder"), 3)
    var again = read_folder(out + "/folder")
    assert_equal(len(again), 3)
    for ref f in s.files:
        var k = again.find(f.path)
        assert_true(k >= 0 and again.files[k].data == f.data, "the folder has the same bytes: " + f.path)
    var refused = False
    try:
        _ = write_folder(s, out + "/folder")
    except e:
        refused = String(e).find("overwrite") >= 0
    assert_true(refused, "an export into a folder that has its files refuses")
    with open(out + "/folder/.hidden", "w") as f:
        f.write("x")
    assert_equal(len(read_folder(out + "/folder")), 3, "a hidden file isn't read")
    assert_equal(Int(crc32(List[UInt8](length=0, fill=0))), 0)
    print("  round trip: ok", flush=True)


def main() raises:
    safe_paths()
    python_zip()
    limits()
    round_trip()
    print("archive: ok", flush=True)
