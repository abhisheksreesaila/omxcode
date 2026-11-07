# The web host's upload check (goal 62 M7): reads a visitor's CSV or Parquet file with the reader the app uses
# (mojoui.csvio.read_table), in a process of its own, so a file that would crash the reader ends only this check and the
# server goes on for every other visitor. Prints the table's size; exits 1 (with the reason) when it isn't a table.
#   scripts/mxbuild.sh hosts/validate_main.mojo -o build/omxplorer/web/validate && build/omxplorer/web/validate file.csv
from mojoui.csvio import read_table
from mojoui.shared import arguments, exit_with


def main():
    var args = arguments()
    if len(args) < 2:
        print("usage: validate <file.csv|file.parquet>")
        exit_with(2)
    try:
        var imp = read_table(args[1], whole=True)  # (every row group decoded here, not only a big file's first: goal 62's audit)
        print(String(imp.rows) + " rows, " + String(len(imp.columns)) + " columns")
    except e:
        print("not a table: " + String(e))
        exit_with(1)
