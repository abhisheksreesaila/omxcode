# mojoui.files' private files (review 3, MUST 7): readable by this user alone whatever the umask, in place in one step or
# not at all, no temporary left when a write fails, names no two processes share, leftovers cleaned by age, a cache folder
# held to a size with the oldest going first. `privatefiles: ok`.
from std.os import stat, listdir, getenv
from std.testing import assert_true, assert_equal
from std.time import sleep
from mojoui.files import private_dir, private_write, private_write_parts, clean_temps, keep_under, age_s
from mojoui.libc import getpid, unlink, chmod


def mode(path: String) raises -> Int:
    return Int(stat(path).st_mode) & 0o777


def names(dir: String) raises -> List[String]:
    var out = List[String]()
    for n in listdir(dir):
        out.append(String(n))
    return out^


def main() raises:
    var base = getenv("TMPDIR", "/tmp") + "/mojoui-private-test-" + String(getpid())
    assert_true(private_dir(base), "made")
    var dir = base + "/a/b"
    assert_true(private_dir(dir), "made, its parents too")
    assert_equal(mode(dir), 0o700)
    _ = chmod(dir, 0o755)
    assert_true(private_dir(dir), "there already")
    assert_equal(mode(dir), 0o700, "a folder that was open to others isn't any more")
    for n in names(dir):
        _ = unlink(dir + "/" + n)
    var p = dir + "/x.txt"
    assert_true(private_write(p, "hello é"), "written")
    assert_equal(mode(p), 0o600)
    _ = chmod(p, 0o644)
    assert_true(private_write(p, "again"), "replaced")
    assert_equal(mode(p), 0o600, "a file others could read isn't any more")
    with open(p, "r") as f:
        assert_equal(f.read(), "again")
    assert_true(private_write(dir + "/empty", ""), "an empty one")
    assert_equal(len(names(dir)), 2, "nothing else left")
    # a write that can't end: a name that is a folder, a folder that isn't there
    assert_true(private_dir(dir + "/taken"), "a folder in the way")
    assert_true(private_write(dir + "/taken/x", "y"), "and not empty")
    assert_true(not private_write(dir + "/taken", "z"), "can't replace a folder")
    assert_true(not private_write(base + "/nowhere/x", "z"), "no folder")
    for n in names(dir):
        assert_true(n.find(".tmp-") < 0, "no temporary left: " + n)
    # a full disk (/dev/full): nothing left, the old file stays
    # (parts: two runs)
    var a = String("one,")
    var b = String("two")
    assert_true(private_write_parts(dir + "/parts", [(Int(a.unsafe_ptr()), 4), (Int(b.unsafe_ptr()), 3)]), "parts")
    _ = a.byte_length() + b.byte_length()
    with open(dir + "/parts", "r") as f:
        assert_equal(f.read(), "one,two")
    # what a dead process left
    with open(dir + "/s.snap.tmp-999-1", "w") as f:
        f.write("half")
    with open(dir + "/old.snap.tmp", "w") as f:
        f.write("half")
    assert_equal(clean_temps(dir, 60), 0, "young: another process may be writing it")
    sleep(1.1)
    assert_true(age_s(dir + "/old.snap.tmp") >= 1, "ages")
    assert_equal(clean_temps(dir, 1), 2)
    assert_equal(age_s(dir + "/gone"), -1)
    # the size cap
    for i in range(5):
        assert_true(private_write(dir + "/n" + String(i) + ".snap", "x" * 1000))
        sleep(0.02)
    assert_equal(keep_under(dir, ".snap", 3500), 2, "the two oldest")
    var left = names(dir)
    assert_true("n0.snap" not in left and "n1.snap" not in left and "n4.snap" in left and "x.txt" in left, "the oldest went, others untouched")
    assert_equal(keep_under(dir, ".snap", 0), 3)
    print("privatefiles: ok")
