# mojoui.files.file_argument: the file a window was started with (`omxplorer path/to/file.csv`, the launcher entry's %f)
# is the first command-line word after the program's name that ends in one of the app's suffixes and names a file;
# a Python host's own words (web.py, its build folder) and missing files are never it.
#   pixi run mojo run -I . tests/test_file_argument.mojo
from std.testing import assert_equal
from std.os import makedirs
from mojoui.files import file_argument_in


def words(*ws: String) -> List[String]:
    var out = List[String]()
    for w in ws:
        out.append(String(w))
    return out^


def main() raises:
    var dir = "build/test-file-argument"
    makedirs(dir, exist_ok=True)
    var csv = dir + "/orders.csv"
    with open(csv, "w") as f:
        f.write("a,b\n1,2\n")
    var kinds = words(".csv", ".parquet", ".omx")
    assert_equal(file_argument_in(words("omxplorer", csv), kinds), csv, "the launcher's argument")
    assert_equal(file_argument_in(words("omxplorer"), kinds), "", "no argument: the Start screen")
    assert_equal(file_argument_in(words("omxplorer", dir + "/missing.csv"), kinds), "", "a missing file is not opened")
    assert_equal(file_argument_in(words("python", "mojoui/hosts/web.py", "build/omxplorer/web"), kinds), "", "the web host's words")
    assert_equal(file_argument_in(words("omxplorer", "--flag", csv), kinds), csv, "the first matching word")
    assert_equal(file_argument_in(words(csv), kinds), "", "the program's own name is never the file")
    var upper = dir + "/RUNS.CSV"
    with open(upper, "w") as f:
        f.write("a\n1\n")
    assert_equal(file_argument_in(words("omxplorer", upper), kinds), upper, "suffixes match in any case")
    print("file_argument: ok")
