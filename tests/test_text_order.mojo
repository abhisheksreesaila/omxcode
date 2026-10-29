# Text order as the owner settled it (goal 23 M2, MX frame's rule everywhere): sorting a text column puts its words in
# alphabetical order ignoring case, bytes breaking ties ("Apple" < "apple"), on a sheet in memory and streamed; largest
# first is the reverse.
#   scripts/mxbuild.sh tests/test_text_order.mojo -o build/test_text_order && build/test_text_order
from std.testing import assert_equal
from omxcore import Table, write_parquet, scan_parquet, UNCOMPRESSED, TEXT as MX_TEXT
from mojoui.sheet import Sheet

comptime PATH = "build/test_text_order.parquet"


def words_in_order(s: Sheet, descending: Bool) raises -> String:
    var out = String("")
    var last = String("")
    for row in s.permutation(0, descending):
        var w = s.display(0, row)
        if w != last:  # (each word once: four rows of it in a row)
            out += ("|" if out != "" else "") + w
            last = w
    return out^


def main() raises:
    var t = Table.empty()
    var c = t.add_column("name", MX_TEXT)
    for w in ["banana", "Zebra", "apple", "Apple", "cherry", "Banana"]:
        _ = t.add_word(c, w)
    for k in range(24):  # (four rows of each word: row groups of 8 hold every word but not all of them)
        t.append(c, Int64(k % 6))
    t.check()
    write_parquet(PATH, t, "", UNCOMPRESSED, 8)
    var whole = Sheet(t^.share(), False)
    var streamed = Sheet(scan_parquet(PATH))
    for k in range(2):
        ref s = whole if k == 0 else streamed
        assert_equal(words_in_order(s, False), "Apple|apple|Banana|banana|cherry|Zebra")
        assert_equal(words_in_order(s, True), "Zebra|cherry|banana|Banana|apple|Apple")
    print("TEXT ORDER: case ignored, bytes break ties, in memory and streamed")
    print("TEXT ORDER TESTS PASSED")
