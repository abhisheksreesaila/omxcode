# mojoui.hosts.agent_link's line buffer (goal 34b review, D-677): the link's bytes are kept as bytes until a line's
# newline arrives, so a UTF-8 character split across two reads decodes whole; a line that isn't UTF-8 (or holds a NUL)
# is refused as one line, never a crash, and the lines after it still read.
from std.testing import assert_equal, assert_true
from mojoui.hosts.agent_link import next_line, LINE_NONE, LINE_OK, LINE_BAD


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def main() raises:
    var buf = List[UInt8]()
    var whole = bytes_of('{"op":"set","value":"café"}\n')
    var cut = whole.index(0xC3) + 1  # (the read ends inside é: its first byte only)
    for k in range(cut):
        buf.append(whole[k])
    var got = next_line(buf)
    assert_equal(got[0], LINE_NONE)  # (no newline yet: nothing decoded)
    for k in range(cut, len(whole)):
        buf.append(whole[k])
    got = next_line(buf)
    assert_equal(got[0], LINE_OK)
    assert_equal(got[1], '{"op":"set","value":"café"}')
    assert_equal(len(buf), 0)
    # invalid UTF-8, then a NUL, then a good line: the first two are refused, the third reads
    buf.append(0x7B)
    buf.append(0xFF)
    buf.append(0xFE)
    buf.append(0x0A)
    buf.append(0x7B)
    buf.append(0x00)
    buf.append(0x7D)
    buf.append(0x0A)
    for b in bytes_of('{"op":"view"}\n'):
        buf.append(b)
    got = next_line(buf)
    assert_equal(got[0], LINE_BAD)
    got = next_line(buf)
    assert_equal(got[0], LINE_BAD)
    got = next_line(buf)
    assert_equal(got[0], LINE_OK)
    assert_equal(got[1], '{"op":"view"}')
    got = next_line(buf)
    assert_equal(got[0], LINE_NONE)
    assert_true(len(buf) == 0)
    print("agent_link: ok")
