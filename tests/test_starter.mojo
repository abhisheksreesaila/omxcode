# mojoui.starter and the shared files under it (goal 62 M1): a starter folder's story.json is read (its words, files,
# links, questions); share_starter reads its sheet and tables once for the process, and every later read_table of those
# paths gets the same rows without touching the files (they're moved away here, and still read); a file the process
# didn't share is read from disk as before; a story.json that names a file outside its folder is refused.
#   scripts/mxbuild.sh tests/test_starter.mojo -o build/test_starter && build/test_starter
from mojoui.libc import rename
from std.testing import assert_equal, assert_true, assert_false
from mojoui.shared import make_dir
from mojoui.csvio import read_table, shared_import
from mojoui.starter import Starter, share_starter


def write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def main() raises:
    var dir = String("build/test-starter")
    make_dir(dir)
    var runs = String("episode,lab,success\n")
    for i in range(500):
        runs += "E" + String(i) + "," + ("north" if i % 3 == 0 else "south") + "," + String(i % 2) + "\n"
    write(dir + "/runs.csv", runs)
    write(dir + "/log.csv", "episode,t,speed\nE1,0.0,1.5\nE1,0.1,1.7\nE2,0.0,0.4\n")
    write(dir + "/other.csv", "a,b\n1,2\n")
    write(dir + "/story.json", '{"title": "A test story", "start": "Start it", "lead": "500 runs", "credit": "Data: ours, CC-BY-4.0", '
          + '"sheet": "runs.csv", "tables": ["log.csv"], "links": ["runs.episode = log.episode"], "hero": "E7", '
          + '"questions": [{"name": "north", "question": "the runs up north", "sql": "SELECT * FROM runs WHERE lab = \'north\'"}]}')
    var s = Starter.read(dir)
    assert_equal(s.title, "A test story")
    assert_equal(s.start, "Start it")
    assert_equal(s.path(s.sheet), dir + "/runs.csv")
    assert_equal(len(s.tables), 1)
    assert_equal(s.links[0], "runs.episode = log.episode")
    assert_equal(s.hero, "E7")
    assert_equal(s.questions[0].name, "north")
    assert_true(s.questions[0].sql.startswith("SELECT * FROM runs"))
    assert_false(Bool(shared_import(dir + "/runs.csv")), "shared before share_starter")

    assert_equal(share_starter(dir), 2)
    _ = rename(dir + "/runs.csv", dir + "/runs.moved")  # (the shared files are gone from where they were: still read)
    _ = rename(dir + "/log.csv", dir + "/log.moved")
    var a = read_table(dir + "/runs.csv")
    assert_equal(a.rows, 500)
    assert_equal(a.table.rows(), 500)
    assert_equal(len(a.columns), 3)
    var b = read_table(dir + "/log.csv")
    assert_equal(b.rows, 3)
    var c = read_table(dir + "/other.csv")  # (not shared: read from disk)
    assert_equal(c.rows, 1)
    _ = rename(dir + "/runs.moved", dir + "/runs.csv")
    _ = rename(dir + "/log.moved", dir + "/log.csv")

    write(dir + "/story.json", '{"title": "Out", "sheet": "../../etc/passwd"}')
    var refused = False
    try:
        _ = Starter.read(dir)
    except:
        refused = True
    assert_true(refused, "a story.json naming a file outside its folder was read")
    assert_equal(share_starter(""), 0)
    print("test_starter: ok (story.json read; its sheet and table shared once and read without their files; others read from disk; outside paths refused)")
