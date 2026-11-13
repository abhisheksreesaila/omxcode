"""Goal 68 M3's reference: a bag's topics read by the official Python readers, flattened by mojoui.bag's rules (its header),
and compared with what tests/bag_dump.mojo wrote. Run in the bagcheck environment:

    pixi run -e bagcheck python -I docs/goals/68/bagref.py BAG DUMP.jsonl [MESSAGES]

Values come from two official decoders each: MCAP messages through `mcap` + `mcap_ros2` (DecoderFactory) and through
`rosbags`' CDR deserializer; rosbag2 sqlite3 bags through `rosbags`' Reader. Field order and kinds come from `rosbags`'
parse of the schema the file carries. Prints one line per topic and a last line "BAGREF: <topics> topics, <n> messages,
<rows> rows, <fields> fields compared, <bad> differences".
"""
import json
import math
import struct
import sys
from pathlib import Path

from rosbags.interfaces import Nodetype
from rosbags.typesys import Stores, get_typestore, get_types_from_msg

BYTES = {"uint8", "int8", "byte", "char"}
INTS = {"bool", "byte", "char", "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64"}
FLOATS = {"float32", "float64"}


def bag_file(path: Path) -> Path:
    if path.is_dir():
        names = sorted(p for p in path.iterdir() if p.suffix in (".mcap", ".db3"))
        return names[0]
    return path


def canon(t: str) -> str:
    p = t.split("/")
    return f"{p[0]}/msg/{p[-1]}" if len(p) == 2 else t


class Flat:
    """mojoui.bag's column rules over rosbags' field definitions."""

    def __init__(self, store, root: str):
        self.store = store
        self.root = canon(root)
        fields = store.fielddefs[self.root][1]
        lists = [i for i, (_, d) in enumerate(fields) if d[0] == Nodetype.SEQUENCE and d[1][0][0] == Nodetype.NAME]
        self.explode = lists[0] if len(lists) == 1 and len(fields) <= 3 else -1
        self.columns, self.kinds = ["t_ns"], [0]
        self._plan(self.root, "", True)

    def _kind(self, base):
        return 1 if base in FLOATS else (2 if base in ("string",) else 0)

    def _plan(self, t, prefix, top):
        for k, (name, d) in enumerate(self.store.fielddefs[canon(t)][1]):
            n = prefix + name
            if top and k == self.explode:
                self.columns.append("item"), self.kinds.append(0)
                self._plan(d[1][0][1], n + ".", False)
            elif d[0] == Nodetype.BASE:
                self.columns.append(n), self.kinds.append(self._kind(d[1][0]))
            elif d[0] == Nodetype.NAME:
                self._plan(d[1], n + ".", False)
            elif d[0] == Nodetype.ARRAY:
                (et, ed), size = d[1]
                for i in range(size):
                    if et == Nodetype.NAME:
                        self._plan(ed, f"{n}.{i}.", False)
                    else:
                        self.columns.append(f"{n}.{i}"), self.kinds.append(self._kind(ed[0]))
            else:
                et, ed = d[1][0]
                if et == Nodetype.NAME:
                    self.columns.append(n + ".len"), self.kinds.append(0)
                elif ed[0] in BYTES:
                    self.columns.append(n + ".bytes"), self.kinds.append(0)
                else:
                    self.columns.append(n), self.kinds.append(2)

    def rows(self, t_ns, msg):
        base = [t_ns]
        items = []
        self._values(self.root, msg, base, True, items)
        if self.explode < 0:
            return [base]
        at = next(i for i, c in enumerate(self.columns) if c == "item")
        width = len(Flat._cols(self, self.store.fielddefs[self.root][1][self.explode][1][1][0][1])) + 1
        out = []
        for it in items:
            out.append(base[:at] + it + base[at:])
        return out

    def _cols(self, t):
        saved = self.columns, self.kinds
        self.columns, self.kinds = [], []
        self._plan(t, "", False)
        cols = self.columns
        self.columns, self.kinds = saved
        return cols

    def _base(self, base, v):
        if base in INTS:
            v = int(v)
            if base == "uint64" and v >= 1 << 63:
                v -= 1 << 64
            return v
        if base in FLOATS:
            return float(v)
        return v

    def _values(self, t, msg, out, top, items):
        for k, (name, d) in enumerate(self.store.fielddefs[canon(t)][1]):
            v = getattr(msg, name)
            if top and k == self.explode:
                et = d[1][0][1]
                width = len(self._cols(et))
                if len(v) == 0:
                    items.append([-1] + [None] * width)
                for i, e in enumerate(v):
                    row = [i]
                    self._values(et, e, row, False, [])
                    items.append(row)
            elif d[0] == Nodetype.BASE:
                out.append(self._base(d[1][0], v))
            elif d[0] == Nodetype.NAME:
                self._values(d[1], v, out, False, [])
            elif d[0] == Nodetype.ARRAY:
                et, ed = d[1][0]
                for e in v:
                    if et == Nodetype.NAME:
                        self._values(ed, e, out, False, [])
                    else:
                        out.append(self._base(ed[0], e))
            else:
                et, ed = d[1][0]
                if et == Nodetype.NAME or ed[0] in BYTES:
                    out.append(len(v))
                else:
                    out.append(("|" if ed[0] == "string" else " ").join(str(self._base(ed[0], e)) for e in v))


def same(kind, mine, ref, column):
    if ref is None:  # (an empty exploded list: mojoui.bag writes 0 / "")
        return mine in (0, "", {"f": 0})
    if kind == 1:
        bits = struct.unpack("<d", struct.pack("<q", mine["f"]))[0]
        return bits == ref or (math.isnan(bits) and math.isnan(ref))
    if kind == 2 and isinstance(ref, str) and " " in ref and not column.endswith("frame_id"):
        a, b = mine.split(" "), ref.split(" ")
        try:
            return len(a) == len(b) and all(float(x) == float(y) or (math.isnan(float(x)) and math.isnan(float(y))) for x, y in zip(a, b))
        except ValueError:
            return mine == ref
    if kind == 2 and isinstance(ref, str) and ref and all(c in "0123456789.-+e infa" for c in ref) and mine != ref:
        try:
            return float(mine) == float(ref)
        except ValueError:
            return False
    return mine == ref


def reference(path: Path, messages: int):
    """{topic: (Flat or "json", [rows of the first `messages` messages in log-time order], [rows from rosbags])}"""
    f = bag_file(path)
    out = {}
    store = get_typestore(Stores.EMPTY)
    if f.suffix == ".mcap":
        from mcap.reader import make_reader
        from mcap_ros2.decoder import DecoderFactory

        with open(f, "rb") as fh:
            r = make_reader(fh, decoder_factories=[DecoderFactory()])
            s = r.get_summary()
            for sc in s.schemas.values():
                if sc.encoding == "ros2msg":
                    store.register(get_types_from_msg(sc.data.decode(), canon(sc.name)))
            per = {}
            for schema, channel, msg in r.iter_messages(log_time_order=False):
                per.setdefault(channel.topic, []).append((msg.log_time, schema, channel, msg))
            dec = DecoderFactory()
            decoders = {}
            for topic, msgs in per.items():
                msgs.sort(key=lambda m: m[0])  # (stable: ties keep the file's order)
                msgs = msgs[:messages]
                schema, channel = msgs[0][1], msgs[0][2]
                if channel.message_encoding == "cdr":
                    flat = Flat(store, schema.name)
                    if schema.id not in decoders:
                        decoders[schema.id] = dec.decoder_for("cdr", schema)
                    rows_a, rows_b = [], []
                    for t, _, _, m in msgs:
                        rows_a += flat.rows(t, decoders[schema.id](m.data))
                        rows_b += flat.rows(t, store.deserialize_cdr(m.data, canon(schema.name)))
                    out[topic] = (flat, rows_a, rows_b, len(msgs))
                elif channel.message_encoding == "json":
                    keys = list(json.loads(msgs[0][3].data))
                    rows = []
                    for t, _, _, m in msgs:
                        d = json.loads(m.data)
                        rows.append([t] + [d.get(k) if not isinstance(d.get(k), bool) else int(d.get(k)) for k in keys])
                    out[topic] = ("json", rows, rows, len(msgs))
                else:
                    out[topic] = (channel.message_encoding, [], [], 0)
    else:
        from rosbags.rosbag2 import Reader

        with Reader(f.parent) as r:
            for c in r.connections:
                if c.msgdef.data:
                    store.register(get_types_from_msg(c.msgdef.data, c.msgtype))
            per = {}
            for c, t, raw in r.messages():
                per.setdefault(c.topic, []).append((t, c, raw))
            for topic, msgs in per.items():
                msgs.sort(key=lambda m: m[0])
                msgs = msgs[:messages]
                flat = Flat(store, msgs[0][1].msgtype)
                rows = []
                for t, c, raw in msgs:
                    rows += flat.rows(t, store.deserialize_cdr(raw, c.msgtype))
                out[topic] = (flat, rows, rows, len(msgs))
    return out


def main():
    bag, dump = Path(sys.argv[1]), Path(sys.argv[2])
    messages = int(sys.argv[3]) if len(sys.argv) > 3 else 1000
    ref = reference(bag, messages)
    mine = {}
    cur = None
    for line in dump.read_text().splitlines():
        v = json.loads(line)
        if isinstance(v, dict):
            cur = v["topic"]
            mine[cur] = (v, [])
        else:
            mine[cur][1].append(v)
    n_topics = n_msgs = n_rows = n_fields = bad = 0
    for topic, (flat, rows_a, rows_b, n_m) in sorted(ref.items()):
        head, rows = mine.get(topic, (None, []))
        if head is None:
            print(f"  {topic}: missing from mojoui.bag's dump")
            bad += 1
            continue
        if isinstance(flat, str) and flat != "json":
            print(f"  {topic}: {flat}, not read (both sides): {head['note']}")
            continue
        if flat == "json":
            columns, kinds = head["columns"], head["kinds"]
        else:
            columns, kinds = flat.columns, flat.kinds
            if columns != head["columns"] or kinds != head["kinds"]:
                diff = [(a, b) for a, b in zip(columns, head["columns"]) if a != b][:3]
                print(f"  {topic}: columns differ {len(columns)} vs {len(head['columns'])} {diff} kinds {kinds == head['kinds']}")
                bad += 1
                continue
        if rows_a != rows_b:
            print(f"  {topic}: the two official decoders disagree")
            bad += 1
        here = 0
        for i, ref_row in enumerate(rows_a):
            if i >= len(rows):
                print(f"  {topic}: mojoui.bag has {len(rows)} rows, the reference {len(rows_a)}")
                bad += 1
                break
            for c, (m, r) in enumerate(zip(rows[i], ref_row)):
                n_fields += 1
                if not same(kinds[c] if flat != "json" else (1 if isinstance(r, float) else (0 if isinstance(r, int) else 2)), m, r, columns[c]):
                    if bad < 12:
                        print(f"  {topic} row {i} {columns[c]}: mojoui.bag {m!r}, reference {r!r}")
                    bad += 1
                    here += 1
        n_topics += 1
        n_msgs += n_m
        n_rows += len(rows_a)
        print(f"  {topic}: {len(rows_a)} rows, {len(columns)} columns, {here} differences")
    print(f"BAGREF: {n_topics} topics, {n_msgs} messages, {n_rows} rows, {n_fields} fields compared, {bad} differences")


if __name__ == "__main__":
    main()
