# The web host's upload check (goal 62 M7): reads a visitor's CSV or Parquet file with the reader the app uses
# (mojoui.csvio.read_table), in a process of its own, so a file that would crash the reader ends only this check and the
# server goes on for every other visitor. Prints the table's size and the memory its read took ("N rows, M columns,
# K KB once read": the web host refuses a table past its budget before the app reads it in the shared server, round 3);
# exits 1 (with the reason) when it isn't a table.
#   scripts/mxbuild.sh hosts/validate_main.mojo -o build/omxplorer/web/validate && build/omxplorer/web/validate file.csv
from mojoui.csvio import read_table
from mojoui.shared import arguments, exit_with


def status_kb(field: String) -> Int:
    """A line of /proc/self/status in KB (VmRSS: memory now; VmHWM: the most so far); 0 where there's none."""
    try:
        var text: String
        with open("/proc/self/status", "r") as f:
            text = f.read()
        for line in text.split("\n"):
            if line.startswith(field + ":"):
                var rest = String(String(line[byte = field.byte_length() + 1 :]).strip())
                return Int(String(rest.split(" ")[0]))
    except:
        pass
    return 0


def main():
    var args = arguments()
    if len(args) < 2:
        print("usage: validate <file.csv|file.parquet>")
        exit_with(2)
    try:
        var before = status_kb("VmRSS")
        var imp = read_table(args[1], whole=True)  # (every row group decoded here, not only a big file's first: goal 62's audit)
        var took = max(status_kb("VmHWM") - before, 0)
        print(String(imp.rows) + " rows, " + String(len(imp.columns)) + " columns, " + String(took) + " KB once read")
    except e:
        print("not a table: " + String(e))
        exit_with(1)
