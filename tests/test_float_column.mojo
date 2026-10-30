# A FLOAT column (MX frame 321870f, F-157: a CSV column with more than 4 decimal places, a Parquet DOUBLE) shows its
# numbers, not the float64's bits: in the Import step, in a cell and in the editor; its kind is "Number".
#   scripts/mxbuild.sh tests/test_float_column.mojo -o build/test_float_column && build/test_float_column
from std.testing import assert_equal
from mojoui.csvio import read_csv, kind_name
from mojoui.sheet import Sheet, FLOAT

comptime CSV = "build/test_float_column.csv"


def main() raises:
    with open(CSV, "w") as f:
        f.write("item,price,rate\nA,1.50,0.123456\nB,2.25,1.5\nC,3.00,\n")
    var imp = read_csv(CSV)
    assert_equal(imp.columns[2].kind, FLOAT)
    assert_equal(kind_name(imp.columns[2].kind), "Number")
    assert_equal(imp.columns[2].sample[0], "0.123456")
    var s = Sheet(imp.table, False)
    assert_equal(s.format_value(2, s.value(2, 0)), "0.123456")
    assert_equal(s.plain_text(2, 1), "1.5")
    assert_equal(s.display(2, 0), "0.123456")  # (the cell itself, as the grid draws it)
    assert_equal(s.grid_text(2, 1), "1.5")
    assert_equal(s.plain_text(2, 2), "")
    assert_equal(s.format_value(1, s.value(1, 1)), "2.25")
    print("FLOAT COLUMN TESTS PASSED")
