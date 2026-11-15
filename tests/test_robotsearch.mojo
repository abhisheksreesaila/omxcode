# mojoui.robotsearch without the engine (goal 71 review round 2): the page's own bookkeeping, fed by hand.
#   - next_folder: an export of several datasets writes picks-N-<dataset>, so any entry that is picks-N or starts with
#     picks-N- takes N; picks-10 doesn't take 1
#   - land_hits: results like one clip keep its loop; results like the picks stop the old loop, and a loop asked for
#     while a job ran (want_loop) doesn't come back when the job lands
#   - picks toggle in order; the grid shows the sample before a search and the hits after; the sample is one episode a
#     task with the datasets taking turns
from std.testing import assert_equal, assert_true
from std.os import makedirs, getenv
from mojoui.robotsearch import RobotSearch
from mojoui.robotpool import PoolEpisode, Hit, Picture
from mojoui.clock import now_ns


def main() raises:
    var root = getenv("G71_OUT", "build/g71") + "/rs-test-" + String(now_ns())
    makedirs(root + "/picks-1-libero")
    makedirs(root + "/picks-1-svla_so100_sorting")
    makedirs(root + "/picks-10")
    var rs = RobotSearch(9000)
    rs.exports_dir = root
    assert_equal(rs.next_folder(), root + "/picks-2")
    makedirs(root + "/picks-2")
    assert_equal(rs.next_folder(), root + "/picks-3")

    # a pool by hand: two datasets, three tasks
    var eps: List[PoolEpisode] = [PoolEpisode("a/sim", 0, "open", "panda", 10.0), PoolEpisode("a/sim", 1, "open", "panda", 11.0),
                                  PoolEpisode("a/sim", 2, "close", "panda", 12.0), PoolEpisode("b/real", 0, "sort", "so100", 9.0)]
    for i in range(len(eps)):
        rs.by_key[eps[i].key()] = i
    rs.episodes = eps^
    rs.robots = ["panda", "so100"]
    rs.opened = True
    rs.make_sample()
    assert_equal(len(rs.sample), 3)                  # one a task
    assert_equal(rs.sample[1], "b/real:0")           # the datasets take turns
    assert_equal(len(rs.grid_keys()), 3)

    # one clip: its loop stays
    rs.loop = [Picture(), Picture()]
    rs.loop_key = "a/sim:0"
    var hits: List[Hit] = [Hit("a/sim:1", 1, 0.99), Hit("a/sim:2", 2, 0.5)]
    _ = rs.land_hits(hits, ["a/sim:0"], "a/sim:0", 0.1, "gpu", 4)
    assert_equal(rs.loop_key, "a/sim:0")
    assert_equal(rs.grid_keys()[0], "a/sim:1")
    # the picks: the old loop stops, and one asked for while a job ran doesn't come back
    rs.want_loop = "a/sim:2"
    _ = rs.land_hits(hits, ["a/sim:1", "b/real:0"], "", 0.1, "gpu", 4)
    assert_equal(len(rs.loop), 0)
    assert_true(not rs.playing(), "nothing plays for results like the picks")
    assert_equal(rs.loop_key, "")
    assert_equal(rs.want_loop, "")

    # picks toggle, in the order picked
    rs.toggle_pick("a/sim:2")
    rs.toggle_pick("b/real:0")
    rs.toggle_pick("a/sim:2")
    assert_equal(len(rs.picked), 1)
    assert_equal(rs.picked[0], "b/real:0")
    print("robotsearch: ok")
