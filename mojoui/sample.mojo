# mojoui.sample: the sample orders (mojoui.orders) generated straight into an MX frame table, row by row: no
# stand-in columns, no second copy.

from omxcore import Table, ColumnKind, INT as MX_INT, DECIMAL as MX_DECIMAL, TEXT as MX_TEXT, DATE as MX_DATE
from mojoui.orders import (order_row, DUPLICATES, DUP_ZIP, ZIP, CUSTOMER, REGION, PRODUCT, CARRIER, CUSTOMERS, REGIONS, PRODUCTS, CARRIERS)


def sample_table(rows: Int) raises -> Table:
    """The same rows as `order_columns(rows)`: rows - 412 orders, then 412 of them again (the double import, all at
    ZIP 94110, in both copies)."""
    var originals = max(rows - DUPLICATES, DUPLICATES)
    var names: List[String] = ["order", "day", "customer", "region", "product", "qty", "revenue", "cost", "freight", "carrier", "weight_g", "zip"]
    var kinds: List[ColumnKind] = [MX_INT, MX_DATE, MX_TEXT, MX_TEXT, MX_TEXT, MX_INT, MX_DECIMAL, MX_DECIMAL, MX_DECIMAL, MX_TEXT, MX_INT, MX_INT]
    var t = Table.empty()
    for k in range(12):
        var c = t.add_column(names[k], kinds[k], 2 if kinds[k] == MX_DECIMAL else 0)
        var words = List[String]()
        if k == CUSTOMER:
            words = materialize[CUSTOMERS]()
        elif k == REGION:
            words = materialize[REGIONS]()
        elif k == PRODUCT:
            words = materialize[PRODUCTS]()
        elif k == CARRIER:
            words = materialize[CARRIERS]()
        for w in words:
            _ = t.add_word(c, w)
    var start = originals - DUPLICATES * 7
    for i in range(originals + DUPLICATES):
        var src = i if i < originals else start + (i - originals) * 7
        var row = order_row(src)
        if src >= start and (src - start) % 7 == 0 and (src - start) // 7 < DUPLICATES:
            row[ZIP] = Int64(DUP_ZIP)  # (a double-imported order, the original and its copy)
        for k in range(12):
            t.append(k, row[k])
    return t^
