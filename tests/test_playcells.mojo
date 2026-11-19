# Goal 78 M3: a column that plays in a card draws its cells as links (mojoui.datagrid.play_kind), and the Links
# error for "=" with an offset says an offset needs "~".
#   scripts/mxbuild.sh tests/test_playcells.mojo -o build/test_playcells && build/test_playcells
# Prints "kind: ok", "tip: ok", "offset: ok".
from std.testing import assert_equal, assert_true
from mojoui.datagrid import play_kind, play_tip, PLAY_NONE, PLAY_VIDEO, PLAY_AUDIO
from mojoui.links import parse_link, LINK_KEY, LINK_TIME


def main() raises:
    assert_equal(play_kind("clips/F00118.mp4", "video"), PLAY_VIDEO)
    assert_equal(play_kind("clips/F00118.MP4", "video"), PLAY_VIDEO)
    assert_equal(play_kind("voice/a1.wav", "video"), PLAY_AUDIO)
    assert_equal(play_kind("take.MP3", "player"), PLAY_AUDIO)
    assert_equal(play_kind("", "video"), PLAY_NONE)  # (an empty cell stays plain)
    assert_equal(play_kind("   ", "video"), PLAY_NONE)
    assert_equal(play_kind("clips/F00118.mp4", ""), PLAY_NONE)  # (a column that plays nowhere: plain text)
    print("kind: ok")
    assert_equal(play_tip("clip", "video"), "clip plays in video: click a cell to play it")
    print("tip: ok")
    var said = String("")
    try:
        _ = parse_link("fleet.t = video.t +1.2")
    except e:
        said = String(e)
    assert_true(said.find('an offset needs "~" (a time link)') >= 0, said)
    assert_true(said.find("fleet.t ~ video.t +1.2") >= 0, said)
    var key = parse_link("fleet.clip = video.file")
    assert_equal(key.kind, LINK_KEY)
    var time = parse_link("fleet.t ~ video.t +1.2")
    assert_equal(time.kind, LINK_TIME)
    print("offset: ok")
