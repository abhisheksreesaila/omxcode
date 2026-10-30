# Runs a SQL query over CSV files on omxcore's engine (as table cards do: Sheet frames in a Catalog, tablecard.query_table)
# and prints the answer's rows tab-separated. tests/test_links.mojo builds it (scripts/mxbuild.sh: the engine is linked,
# which `mojo run` can't do) to check the join a key link implies against DuckDB.
#   build/links_join "SELECT … JOIN … ON …" shipments build/g41/links/shipments.csv detections build/g41/links/detections.csv
from std.sys import argv
from omxcore import Catalog
from mojoui.csvio import read_table, cell_text
from mojoui.sheet import Sheet
from mojoui.tablecard import query_table


def main() raises:
    var args = argv()
    var catalog = Catalog()
    var sheets = List[Sheet]()
    var k = 2
    while k + 1 < len(args):
        sheets.append(Sheet(read_table(String(args[k + 1])).table, False))
        catalog.add_frame(String(args[k]), sheets[len(sheets) - 1].frame)
        k += 2
    var t = query_table(catalog, String(args[1]))
    print("ROWS:", t.rows())
    for r in range(t.rows()):
        var line = String("")
        for c in range(t.columns()):
            line += ("\t" if c > 0 else "") + cell_text(t, c, r)
        print(line)
