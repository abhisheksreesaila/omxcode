# mojoui.bag: ROS 2 bags read in Mojo, no ROS install (goal 68 M3). A robot's recording becomes tables: one per topic,
# a row per message (or per item of a message that is only a list, as TF's transforms), a time column first.
#
#   var bag = Bag.open("build/bags/r2b_galileo")              # a rosbag2 folder, a .mcap file or a .db3 (sqlite3) file
#   for t in bag.topics: t.name, t.type, t.encoding, t.count  # /chassis/imu sensor_msgs/msg/Imu cdr 880
#   var imu = bag.table(bag.find("/chassis/imu"))             # BagTable: t_ns, header.stamp.sec, …, linear_acceleration.z
#   imu.names, imu.rows, imu.float_at(c, r), imu.text_at(c, r)
#   var tables = bag.tables(wanted)                           # several topics in one pass over the file
#   bag.camera_frames(k, visitor)                             # a CompressedImage topic's JPEGs, for mojoui.avi (a video)
#
# Formats. MCAP (mcap.dev/spec): records are opcode + length + body; the summary at the end lists schemas, channels,
# chunk indexes and counts, so a topic's chunks are read and the others skipped; a file without a summary is walked
# from the start. Chunks are zstd or lz4 (frame format) through the system's libzstd / liblz4 (dlopen, called by
# address, as mojoui.sqlite), or stored plain. rosbag2 sqlite3 (.db3): topics, messages and (rosbag2 8+)
# message_definitions, read through mojoui.sqlite.
#
# Messages. CDR (XCDR1, little or big endian: what ROS 2's middlewares write) is decoded from the ros2msg schema the
# file carries (the message and every type it uses, "MSG: pkg/Type" sections), so a custom message reads like a
# standard one. JSON messages (a jsonschema channel) read their object's keys. Protobuf channels are listed, not read
# (the note says so). How a message becomes columns (the same rules docs/goals/68-check.py's reference applies):
#   - a number or bool: a column (integers, bools INT; float32/64 FLOAT); a string: TEXT
#   - a nested message: its fields, named with a dot (pose.position.x)
#   - a fixed array: one column per item (covariance.0 … covariance.35)
#   - a list of bytes (uint8/int8/byte/char, an image's data): its length (data.bytes)
#   - a list of other numbers: TEXT, the values with spaces between (CameraInfo's d); of strings: joined by "|"
#   - a list of messages: its length (name.len), except when the message is just that list (TF's transforms, at most
#     two other top-level fields): then a row per item, with an `item` column (its place; -1 for an empty list)
# Rows come in log-time order (a stable sort of the file's order).

from std.ffi import external_call, c_int, c_char
from std.memory import Pointer, bitcast
from std.os import listdir
from std.os.path import isdir, exists, getsize
from mojoui.sqlite import Database
from mojoui.avi import MjpegAvi
from omxcore import Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, INT as MX_INT
from mojoui.process import Process
from mojoui import libc
from mojoui.json import Json, J_OBJECT, J_STRING, J_NUMBER, J_BOOL

comptime BAG_INT = 0
comptime BAG_FLOAT = 1
comptime BAG_TEXT = 2

# ros2msg primitives (P_STRING and above have no fixed size)
comptime P_BOOL = 0
comptime P_BYTE = 1  # byte, char, uint8 (a "byte-like" for lists)
comptime P_INT8 = 2
comptime P_INT16 = 3
comptime P_UINT16 = 4
comptime P_INT32 = 5
comptime P_UINT32 = 6
comptime P_INT64 = 7
comptime P_UINT64 = 8
comptime P_FLOAT32 = 9
comptime P_FLOAT64 = 10
comptime P_STRING = 11
comptime P_MSG = -1


# ---------------------------------------------------------------------------------------------------------------- C


def _dlsym(handle: Int, name: String) -> Int:
    var n = name
    return external_call["dlsym", Int](handle, n.as_c_string_span())


def _fn[T: ImplicitlyCopyable](addr: Int) -> T:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    return Pointer(to=raw).unsafe_bitcast[T]()[]


def _open_lib(names: List[String]) raises -> Int:
    var dlopen = _dlsym(0, "dlopen")  # (RTLD_DEFAULT; dlopen itself looked up, as mojoui.sqlite does: D-1311)
    for name in names:
        var n = name
        var h = _fn[def(Int, c_int) thin abi("C") -> Int](dlopen)(Int(n.as_c_string_span().unsafe_ptr()), c_int(2))
        if h != 0:
            return h
    raise Error("bag: none of " + ", ".join(names) + " is installed")


comptime _ZSTD = def(Int, Int, Int, Int) thin abi("C") -> Int  # ZSTD_decompress(dst, cap, src, size) → size_t
comptime _ZSTD_ERR = def(Int) thin abi("C") -> c_int  # ZSTD_isError(code)
comptime _LZ4_NEW = def(Int, c_int) thin abi("C") -> Int  # LZ4F_createDecompressionContext(&ctx, version)
comptime _LZ4_DEC = def(Int, Int, Int, Int, Int, Int) thin abi("C") -> Int  # LZ4F_decompress(ctx, dst, &dn, src, &sn, opts)
comptime _LZ4_FREE = def(Int) thin abi("C") -> Int
comptime _LZ4_ERR = def(Int) thin abi("C") -> c_int  # LZ4F_isError


def decompress(kind: String, src: List[UInt8], start: Int, length: Int, size: Int) raises -> List[UInt8]:
    """length bytes of src from start, decompressed ("zstd", "lz4" frame, or "" stored) into exactly `size` bytes."""
    var out = List[UInt8](length=size, fill=0)
    if kind == "":
        if length != size:
            raise Error("bag: a stored chunk's length isn't its size")
        for i in range(size):
            out[i] = src[start + i]
        return out^
    if kind == "zstd":
        var h = _open_lib(["libzstd.so.1", "libzstd.so", "libzstd.dylib", "libzstd.1.dylib"])
        var n = _fn[_ZSTD](_dlsym(h, "ZSTD_decompress"))(Int(out.unsafe_ptr()), size, Int(src.unsafe_ptr()) + start, length)
        _ = len(src)
        if Int(_fn[_ZSTD_ERR](_dlsym(h, "ZSTD_isError"))(n)) != 0 or n != size:
            raise Error("bag: a zstd chunk didn't decompress to its size")
        return out^
    if kind == "lz4":
        var h = _open_lib(["liblz4.so.1", "liblz4.so", "liblz4.dylib", "liblz4.1.dylib"])
        var ctx = List[Int](length=1, fill=0)
        if Int(_fn[_LZ4_ERR](_dlsym(h, "LZ4F_isError"))(_fn[_LZ4_NEW](_dlsym(h, "LZ4F_createDecompressionContext"))(Int(ctx.unsafe_ptr()), c_int(100)))) != 0:
            raise Error("bag: lz4 has no context")
        var dec = _fn[_LZ4_DEC](_dlsym(h, "LZ4F_decompress"))
        var is_err = _fn[_LZ4_ERR](_dlsym(h, "LZ4F_isError"))
        var done = 0
        var used = 0
        var dn = List[Int](length=1, fill=0)
        var sn = List[Int](length=1, fill=0)
        var ok = True
        while used < length and done < size:
            dn[0] = size - done
            sn[0] = length - used
            var r = dec(ctx[0], Int(out.unsafe_ptr()) + done, Int(dn.unsafe_ptr()), Int(src.unsafe_ptr()) + start + used, Int(sn.unsafe_ptr()), 0)
            if Int(is_err(r)) != 0 or (dn[0] == 0 and sn[0] == 0):
                ok = False
                break
            done += dn[0]
            used += sn[0]
        _ = _fn[_LZ4_FREE](_dlsym(h, "LZ4F_freeDecompressionContext"))(ctx[0])
        _ = len(src)
        _ = len(dn)
        _ = len(sn)
        if not ok or done != size:
            raise Error("bag: an lz4 chunk didn't decompress to its size")
        return out^
    raise Error("bag: chunks compressed with '" + kind + "' can't be read (zstd, lz4 or none)")


# ---------------------------------------------------------------------------------------------------------- bytes


def u16le(b: List[UInt8], p: Int) -> Int:
    return Int(b[p]) | (Int(b[p + 1]) << 8)


def u32le(b: List[UInt8], p: Int) -> Int:
    return Int(b[p]) | (Int(b[p + 1]) << 8) | (Int(b[p + 2]) << 16) | (Int(b[p + 3]) << 24)


def u64le(b: List[UInt8], p: Int) -> Int:
    var v = UInt64(0)
    for i in range(8):
        v |= UInt64(b[p + i]) << UInt64(8 * i)
    return Int(Int64(v))


def _str(b: List[UInt8], p: Int, n: Int) -> String:
    var s = List[UInt8](capacity=n)
    for i in range(n):
        s.append(b[p + i])
    return String(from_utf8_lossy=Span(s))


struct _Rec(Movable):
    """A cursor over an MCAP record's body: reads in order, little endian."""
    var p: Int
    var end: Int

    def __init__(out self, p: Int, end: Int):
        self.p = p
        self.end = end

    def u16(mut self, b: List[UInt8]) raises -> Int:
        self._need(2)
        self.p += 2
        return u16le(b, self.p - 2)

    def u32(mut self, b: List[UInt8]) raises -> Int:
        self._need(4)
        self.p += 4
        return u32le(b, self.p - 4)

    def u64(mut self, b: List[UInt8]) raises -> Int:
        self._need(8)
        self.p += 8
        return u64le(b, self.p - 8)

    def text(mut self, b: List[UInt8]) raises -> String:
        var n = self.u32(b)
        self._need(n)
        self.p += n
        return _str(b, self.p - n, n)

    def _need(self, n: Int) raises:
        if n < 0 or self.p + n > self.end:
            raise Error("bag: a record ends early (a damaged or cut file)")


# -------------------------------------------------------------------------------------------------------- schemas


@fieldwise_init
struct _Field(Copyable, Movable):
    var name: String
    var prim: Int  # P_*, or P_MSG
    var type_name: String  # the message type's full name when prim == P_MSG ("pkg/Type")
    var type: Int  # its index in MsgTypes (resolved)
    var arr: Int  # 0: one value; n > 0: a fixed array of n; -1: a list (bounded or not)


@fieldwise_init
struct _Type(Copyable, Movable):
    var name: String  # pkg/Type
    var fields: List[_Field]


def _canon(name: String, pkg: String) -> String:
    """A type name as pkg/Type: "pkg/msg/Type" → "pkg/Type", "Type" → its package's, "Header" → std_msgs/Header."""
    var parts = name.split("/")
    if len(parts) == 3:
        return String(parts[0]) + "/" + String(parts[2])
    if len(parts) == 2:
        return name
    if name == "Header":
        return "std_msgs/Header"
    return pkg + "/" + name


def _prim(t: String) -> Int:
    if t == "bool":
        return P_BOOL
    if t == "byte" or t == "char" or t == "uint8":
        return P_BYTE
    if t == "int8":
        return P_INT8
    if t == "int16":
        return P_INT16
    if t == "uint16":
        return P_UINT16
    if t == "int32":
        return P_INT32
    if t == "uint32":
        return P_UINT32
    if t == "int64":
        return P_INT64
    if t == "uint64":
        return P_UINT64
    if t == "float32":
        return P_FLOAT32
    if t == "float64":
        return P_FLOAT64
    if t == "string" or t.startswith("string<="):
        return P_STRING
    return P_MSG


struct MsgTypes(Movable):
    """A message type and every type it uses, parsed from the ros2msg text a bag carries."""
    var types: List[_Type]

    def __init__(out self, root: String, text: String) raises:
        self.types = List[_Type]()
        var name = _canon(root, "")
        var pkg = String(name.split("/")[0])
        var fields = List[_Field]()
        for raw in text.split("\n"):
            var whole = String(raw)
            var hash = whole.find("#")
            var line = String(whole[byte=:hash].strip()) if hash >= 0 else String(whole.strip())
            if line == "":
                continue
            if line.startswith("=="):
                self.types.append(_Type(name, fields^))
                fields = List[_Field]()
                name = ""
                continue
            if line.startswith("MSG:"):
                name = _canon(String(line[byte=4:].strip()), "")
                pkg = String(name.split("/")[0])
                continue
            var words = List[String]()
            for w in line.split(" "):
                if String(w.strip()) != "":
                    words.append(String(w.strip()))
            if len(words) < 2 or "=" in words[1] or (len(words) > 2 and words[2].startswith("=")):
                continue  # (a constant: NAME=value)
            var spelled = words[0]
            var t = spelled
            var arr = 0
            var b = spelled.find("[")
            if b >= 0:
                var inside = String(spelled[byte = b + 1 : spelled.byte_length() - 1])
                t = String(spelled[byte=:b])
                if inside == "" or inside.startswith("<="):
                    arr = -1
                else:
                    arr = Int(inside)
            var p = _prim(t)
            if t == "wstring" or t.startswith("wstring<="):
                raise Error("bag: wstring fields can't be read yet (" + name + "." + words[1] + ")")
            fields.append(_Field(words[1], p, _canon(t, pkg) if p == P_MSG else "", -1, arr))
        if name != "":
            self.types.append(_Type(name, fields^))
        self._builtins()
        for i in range(len(self.types)):
            for j in range(len(self.types[i].fields)):
                if self.types[i].fields[j].prim == P_MSG:
                    var k = self.find(self.types[i].fields[j].type_name)
                    if k < 0:
                        raise Error("bag: the schema of " + root + " doesn't define " + self.types[i].fields[j].type_name)
                    self.types[i].fields[j].type = k

    def _builtins(mut self):
        """builtin_interfaces' Time and Duration, when a schema leaves them out."""
        for n in ["builtin_interfaces/Time", "builtin_interfaces/Duration"]:
            if self.find(n) < 0:
                var f = List[_Field]()
                f.append(_Field("sec", P_INT32, "", -1, 0))
                f.append(_Field("nanosec", P_UINT32, "", -1, 0))
                self.types.append(_Type(n, f^))

    def find(self, name: String) -> Int:
        for i in range(len(self.types)):
            if self.types[i].name == name:
                return i
        return -1


# ------------------------------------------------------------------------------------------------------- tables


struct BagTable(Movable):
    """One topic's messages as columns: t_ns (the message's log time) first, then the message's fields."""
    var topic: String
    var type: String
    var names: List[String]
    var kinds: List[Int]  # BAG_INT, BAG_FLOAT, BAG_TEXT
    var slot: List[Int]  # the column's index in ints, floats or texts
    var ints: List[List[Int64]]
    var floats: List[List[Float64]]
    var texts: List[List[String]]
    var rows: Int
    var note: String  # why a topic has no columns (protobuf), "" otherwise
    var explode: Int  # the top-level field read as a row per item (-1: none)

    def __init__(out self, topic: String, type: String):
        self.topic = topic
        self.type = type
        self.names = List[String]()
        self.kinds = List[Int]()
        self.slot = List[Int]()
        self.ints = List[List[Int64]]()
        self.floats = List[List[Float64]]()
        self.texts = List[List[String]]()
        self.rows = 0
        self.note = ""
        self.explode = -1

    def add(mut self, name: String, kind: Int):
        self.names.append(name)
        self.kinds.append(kind)
        if kind == BAG_INT:
            self.slot.append(len(self.ints))
            self.ints.append(List[Int64]())
        elif kind == BAG_FLOAT:
            self.slot.append(len(self.floats))
            self.floats.append(List[Float64]())
        else:
            self.slot.append(len(self.texts))
            self.texts.append(List[String]())

    def columns(self) -> Int:
        return len(self.names)

    def index(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def int_at(self, c: Int, r: Int) -> Int64:
        if self.kinds[c] == BAG_INT:
            return self.ints[self.slot[c]][r]
        if self.kinds[c] == BAG_FLOAT:
            return Int64(Int(self.floats[self.slot[c]][r]))
        return 0

    def float_at(self, c: Int, r: Int) -> Float64:
        if self.kinds[c] == BAG_FLOAT:
            return self.floats[self.slot[c]][r]
        if self.kinds[c] == BAG_INT:
            return Float64(self.ints[self.slot[c]][r])
        return 0.0

    def text_at(self, c: Int, r: Int) -> String:
        if self.kinds[c] == BAG_TEXT:
            return self.texts[self.slot[c]][r]
        if self.kinds[c] == BAG_INT:
            return String(self.ints[self.slot[c]][r])
        return String(self.floats[self.slot[c]][r])

    def _push(mut self, row: _Row):
        for c in range(len(self.names)):
            var s = self.slot[c]
            if self.kinds[c] == BAG_INT:
                self.ints[s].append(row.i[c])
            elif self.kinds[c] == BAG_FLOAT:
                self.floats[s].append(row.f[c])
            else:
                self.texts[s].append(row.t[c])
        self.rows += 1

    def sort_by_time(mut self):
        """Rows in t_ns order, ties kept in the file's order (a stable merge sort of the row numbers)."""
        if self.rows < 2 or len(self.names) == 0:
            return
        var t = self.ints[self.slot[0]].copy()
        var sorted = True
        for r in range(1, self.rows):
            if t[r] < t[r - 1]:
                sorted = False
                break
        if sorted:
            return
        var order = List[Int](capacity=self.rows)
        for r in range(self.rows):
            order.append(r)
        var tmp = List[Int](length=self.rows, fill=0)
        var width = 1
        while width < self.rows:
            var lo = 0
            while lo < self.rows:
                var mid = min(lo + width, self.rows)
                var hi = min(lo + 2 * width, self.rows)
                var a = lo
                var b = mid
                var k = lo
                while a < mid and b < hi:
                    if t[order[b]] < t[order[a]]:
                        tmp[k] = order[b]
                        b += 1
                    else:
                        tmp[k] = order[a]
                        a += 1
                    k += 1
                while a < mid:
                    tmp[k] = order[a]
                    a += 1
                    k += 1
                while b < hi:
                    tmp[k] = order[b]
                    b += 1
                    k += 1
                lo = hi
            for i in range(self.rows):
                order[i] = tmp[i]
            width *= 2
        for s in range(len(self.ints)):
            var col = List[Int64](capacity=self.rows)
            for r in range(self.rows):
                col.append(self.ints[s][order[r]])
            self.ints[s] = col^
        for s in range(len(self.floats)):
            var col = List[Float64](capacity=self.rows)
            for r in range(self.rows):
                col.append(self.floats[s][order[r]])
            self.floats[s] = col^
        for s in range(len(self.texts)):
            var col = List[String](capacity=self.rows)
            for r in range(self.rows):
                col.append(self.texts[s][order[r]])
            self.texts[s] = col^


struct _Row(Copyable, Movable):
    """One row's values by column (only the slot of the column's kind is meaningful)."""
    var i: List[Int64]
    var f: List[Float64]
    var t: List[String]

    def __init__(out self, n: Int):
        self.i = List[Int64](length=n, fill=0)
        self.f = List[Float64](length=n, fill=0.0)
        self.t = List[String](length=n, fill=String(""))


def _is_bytes(p: Int) -> Bool:
    return p == P_BYTE or p == P_INT8


def _kind(p: Int) -> Int:
    if p == P_FLOAT32 or p == P_FLOAT64:
        return BAG_FLOAT
    if p == P_STRING:
        return BAG_TEXT
    return BAG_INT


def _plan(types: MsgTypes, t: Int, prefix: String, mut table: BagTable, top: Bool):
    """table's columns for type t's fields, in the order the decoder fills them (the rules in the header)."""
    for k in range(len(types.types[t].fields)):
        var f = types.types[t].fields[k].copy()
        var name = prefix + f.name
        if top and k == table.explode:
            table.add("item", BAG_INT)
            _plan(types, f.type, name + ".", table, False)
        elif f.arr == 0:
            if f.prim == P_MSG:
                _plan(types, f.type, name + ".", table, False)
            else:
                table.add(name, _kind(f.prim))
        elif f.arr > 0:
            for i in range(f.arr):
                if f.prim == P_MSG:
                    _plan(types, f.type, name + "." + String(i) + ".", table, False)
                else:
                    table.add(name + "." + String(i), _kind(f.prim))
        elif f.prim == P_MSG:
            table.add(name + ".len", BAG_INT)
        elif _is_bytes(f.prim):
            table.add(name + ".bytes", BAG_INT)
        else:
            table.add(name, BAG_TEXT)


def _explode_field(types: MsgTypes, t: Int) -> Int:
    """The top-level list of messages read as a row per item: when it is the only one and at most two other fields
    sit beside it (TFMessage, MarkerArray, DiagnosticArray); -1 otherwise."""
    var found = -1
    var lists = 0
    for k in range(len(types.types[t].fields)):
        var f = types.types[t].fields[k].copy()
        if f.prim == P_MSG and f.arr == -1:
            lists += 1
            found = k
    if lists == 1 and len(types.types[t].fields) <= 3:
        return found
    return -1


struct _Cdr(Movable):
    """A cursor over one CDR message (XCDR1): alignment counts from the end of the 4-byte encapsulation header."""
    var p: Int
    var end: Int
    var big: Bool

    def __init__(out self, b: List[UInt8], start: Int, end: Int) raises:
        if end - start < 4:
            raise Error("bag: a CDR message shorter than its header")
        var id = Int(b[start + 1]) | (Int(b[start]) << 8)
        if id != 0 and id != 1:
            raise Error("bag: CDR encapsulation " + String(id) + " (XCDR2 or a parameter list) can't be read yet")
        self.big = id == 0
        self.p = start + 4
        self.end = end

    def align(mut self, b: List[UInt8], n: Int, origin: Int):
        var off = self.p - origin
        var r = off % n
        if r != 0:
            self.p += n - r

    def raw(mut self, b: List[UInt8], n: Int) raises -> UInt64:
        if self.p + n > self.end:
            raise Error("bag: a CDR message ends early")
        var v = UInt64(0)
        for i in range(n):
            var byte = UInt64(b[self.p + i])
            if self.big:
                v = (v << 8) | byte
            else:
                v |= byte << UInt64(8 * i)
        self.p += n
        return v


struct _Decoder(Movable):
    var types: MsgTypes
    var root: Int
    var explode: Int
    var origin: Int

    def __init__(out self, var types: MsgTypes, root: Int, explode: Int):
        self.types = types^
        self.root = root
        self.explode = explode
        self.origin = 0

    def _prim(mut self, b: List[UInt8], mut cur: _Cdr, p: Int, mut row: _Row, c: Int) raises:
        if p == P_STRING:
            cur.align(b, 4, self.origin)
            var n = Int(cur.raw(b, 4))
            if cur.p + n > cur.end:
                raise Error("bag: a CDR string runs past its message")
            row.t[c] = _str(b, cur.p, max(n - 1, 0))  # (the length counts the closing NUL)
            cur.p += n
            return
        if p == P_FLOAT64:
            cur.align(b, 8, self.origin)
            row.f[c] = bitcast[DType.float64, 1](SIMD[DType.uint64, 1](cur.raw(b, 8)))[0]
            return
        if p == P_FLOAT32:
            cur.align(b, 4, self.origin)
            row.f[c] = Float64(bitcast[DType.float32, 1](SIMD[DType.uint32, 1](UInt32(cur.raw(b, 4))))[0])
            return
        var size = _size(p)
        cur.align(b, size, self.origin)
        var v = cur.raw(b, size)
        row.i[c] = _signed(v, p)

    def _number_text(mut self, b: List[UInt8], mut cur: _Cdr, p: Int) raises -> String:
        var one = _Row(1)
        self._prim(b, cur, p, one, 0)
        if p == P_STRING:
            return one.t[0]
        if p == P_FLOAT32 or p == P_FLOAT64:
            return String(one.f[0])
        return String(one.i[0])

    def fields(mut self, b: List[UInt8], mut cur: _Cdr, t: Int, mut row: _Row, mut c: Int, top: Bool, mut items: List[_Row], mut item_c: Int) raises:
        """Decode type t's fields into row from column c on (c advances as _plan's columns do)."""
        var n = len(self.types.types[t].fields)
        for k in range(n):
            var f = self.types.types[t].fields[k].copy()
            if top and k == self.explode:
                cur.align(b, 4, self.origin)
                var count = Int(cur.raw(b, 4))
                var start_c = c + 1  # (after `item`)
                item_c = c
                var end_c = start_c
                for i in range(count):
                    var r = _Row(len(row.i))
                    var cc = start_c
                    var none = List[_Row]()
                    var ic = 0
                    self.fields(b, cur, f.type, r, cc, False, none, ic)
                    r.i[c] = Int64(i)
                    end_c = cc
                    items.append(r^)
                if count == 0:
                    var r = _Row(len(row.i))
                    var cc = start_c
                    _skip_plan(self.types, f.type, cc)
                    end_c = cc
                    r.i[c] = -1
                    items.append(r^)
                c = end_c
            elif f.arr == 0:
                if f.prim == P_MSG:
                    var none = List[_Row]()
                    var ic = 0
                    self.fields(b, cur, f.type, row, c, False, none, ic)
                else:
                    self._prim(b, cur, f.prim, row, c)
                    c += 1
            elif f.arr > 0:
                for _ in range(f.arr):
                    if f.prim == P_MSG:
                        var none = List[_Row]()
                        var ic = 0
                        self.fields(b, cur, f.type, row, c, False, none, ic)
                    else:
                        self._prim(b, cur, f.prim, row, c)
                        c += 1
            else:
                cur.align(b, 4, self.origin)
                var count = Int(cur.raw(b, 4))
                if f.prim == P_MSG:
                    var scratch = _Row(_cols_of(self.types, f.type))
                    for _ in range(count):
                        var sc = 0
                        var none = List[_Row]()
                        var ic = 0
                        self.fields(b, cur, f.type, scratch, sc, False, none, ic)
                    row.i[c] = Int64(count)
                elif _is_bytes(f.prim):
                    if cur.p + count > cur.end:
                        raise Error("bag: a CDR byte list runs past its message")
                    cur.p += count
                    row.i[c] = Int64(count)
                else:
                    var out = String("")
                    for i in range(count):
                        if i > 0:
                            out += "|" if f.prim == P_STRING else " "
                        out += self._number_text(b, cur, f.prim)
                    row.t[c] = out
                c += 1


def _skip_plan(types: MsgTypes, t: Int, mut c: Int):
    """Advance c past type t's columns (an empty exploded list's columns stay 0 / "")."""
    var scratch = BagTable("", "")
    _plan(types, t, "", scratch, False)
    c += scratch.columns()


def _size(p: Int) -> Int:
    if p == P_BOOL or p == P_BYTE or p == P_INT8:
        return 1
    if p == P_INT16 or p == P_UINT16:
        return 2
    if p == P_INT32 or p == P_UINT32 or p == P_FLOAT32:
        return 4
    return 8


def _signed(v: UInt64, p: Int) -> Int64:
    if p == P_INT8 and v >= 0x80:
        return Int64(v) - 0x100
    if p == P_INT16 and v >= 0x8000:
        return Int64(v) - 0x10000
    if p == P_INT32 and v >= 0x80000000:
        return Int64(v) - 0x100000000
    return Int64(v)  # (uint64 keeps its bits)


# ---------------------------------------------------------------------------------------------------------- bags


@fieldwise_init
struct BagTopic(Copyable, Movable):
    var name: String
    var type: String  # sensor_msgs/msg/Imu
    var encoding: String  # the messages': cdr, json, protobuf
    var schema: String  # the definition the file carries
    var schema_encoding: String  # ros2msg, jsonschema, protobuf
    var count: Int
    var id: Int  # the MCAP channel's / the sqlite topic's id

    def is_camera(self) -> Bool:
        return self.type == "sensor_msgs/msg/CompressedImage" or self.type == "sensor_msgs/CompressedImage"


@fieldwise_init
struct _Chunk(Copyable, Movable):
    var offset: Int  # the Chunk record's start in the file
    var length: Int  # the whole record
    var channels: List[Int]  # the channel ids it holds (empty: unknown)


trait BagVisitor:
    def message(mut self, topic: Int, log_time: Int, b: List[UInt8], start: Int, end: Int) raises:
        ...


struct Bag(Movable):
    var path: String  # the file read (.mcap or .db3)
    var format: String  # "mcap" or "sqlite3"
    var topics: List[BagTopic]
    var start_ns: Int
    var end_ns: Int
    var chunks: List[_Chunk]  # MCAP: from the chunk index (empty: walk the file)
    var data_end: Int  # MCAP: where the data section ends (the summary's start, or the file's end)

    def __init__(out self, path: String, format: String):
        self.path = path
        self.format = format
        self.topics = List[BagTopic]()
        self.start_ns = 0
        self.end_ns = 0
        self.chunks = List[_Chunk]()
        self.data_end = 0

    @staticmethod
    def open(path: String) raises -> Bag:
        """A rosbag2 folder (its first .mcap or .db3), an .mcap file or a .db3 file."""
        var file = path
        if isdir(path):
            var names = List[String]()
            for n in listdir(path):
                var s = String(n)
                if s.endswith(".mcap") or s.endswith(".db3"):
                    names.append(s)
            sort(names)
            if len(names) == 0:
                raise Error(path + " holds no .mcap or .db3 file: not a ROS 2 bag")
            file = String(path.rstrip("/")) + "/" + names[0]
        if not exists(file):
            raise Error(file + ": no such file")
        if file.endswith(".db3"):
            return _open_sqlite(file)
        return _open_mcap(file)

    def find(self, topic: String) -> Int:
        for i in range(len(self.topics)):
            if self.topics[i].name == topic:
                return i
        return -1

    def duration_s(self) -> Float64:
        return Float64(self.end_ns - self.start_ns) / 1e9

    def scan[V: BagVisitor](self, wanted: List[Bool], mut v: V) raises:
        """Every message of the wanted topics (by index) to v, in the file's order."""
        if self.format == "sqlite3":
            _scan_sqlite(self, wanted, v)
        else:
            _scan_mcap(self, wanted, v)

    def table(self, k: Int, limit: Int = -1) raises -> BagTable:
        var w = List[Int]()
        w.append(k)
        var out = self.tables(w, limit)
        return out.pop(0)

    def tables(self, topics: List[Int], limit: Int = -1) raises -> List[BagTable]:
        """The topics' tables, read in one pass; limit > 0 keeps each topic's first `limit` messages (in log time)."""
        var t = _Tables(self, topics, limit)
        var wanted = List[Bool](length=len(self.topics), fill=False)
        for k in topics:
            if t.decoders_ok[t.at[k]]:
                wanted[k] = True
        self.scan(wanted, t)
        var out = List[BagTable]()
        for i in range(len(t.out)):
            t.out[i].sort_by_time()
            if limit > 0 and t.out[i].rows > limit:
                _cut(t.out[i], limit)
        for i in range(len(t.out)):
            out.append(t.out.pop(0))
        return out^


def _cut(mut t: BagTable, n: Int):
    for s in range(len(t.ints)):
        while len(t.ints[s]) > n:
            _ = t.ints[s].pop()
    for s in range(len(t.floats)):
        while len(t.floats[s]) > n:
            _ = t.floats[s].pop()
    for s in range(len(t.texts)):
        while len(t.texts[s]) > n:
            _ = t.texts[s].pop()
    t.rows = n


struct _Tables(BagVisitor, Movable):
    """The visitor that decodes messages into BagTables."""
    var out: List[BagTable]
    var at: List[Int]  # topic index → its place in out (-1: not wanted)
    var decoders: List[_Decoder]
    var decoders_ok: List[Bool]
    var json_keys: List[List[String]]
    var encodings: List[String]
    var seen: List[Int]
    var limit: Int

    def __init__(out self, bag: Bag, topics: List[Int], limit: Int) raises:
        self.out = List[BagTable]()
        self.at = List[Int](length=len(bag.topics), fill=-1)
        self.decoders = List[_Decoder]()
        self.decoders_ok = List[Bool]()
        self.json_keys = List[List[String]]()
        self.encodings = List[String]()
        self.seen = List[Int]()
        self.limit = limit
        for k in topics:
            var tp = bag.topics[k].copy()
            self.at[k] = len(self.out)
            var table = BagTable(tp.name, tp.type)
            table.add("t_ns", BAG_INT)
            var ok = False
            var dec = _Decoder(MsgTypes("x/Empty", ""), 0, -1)
            if tp.encoding == "cdr" and tp.schema_encoding == "ros2msg":
                var types = MsgTypes(tp.type, tp.schema)
                var root = types.find(_canon(tp.type, ""))
                if root < 0:
                    raise Error("bag: " + tp.name + "'s schema doesn't define " + tp.type)
                table.explode = _explode_field(types, root)
                _plan(types, root, "", table, True)
                dec = _Decoder(types^, root, table.explode)
                ok = True
            elif tp.encoding == "json":
                ok = True  # (columns from the first message's keys)
            else:
                table.note = tp.encoding + " messages aren't read yet (" + tp.type + ")"
            self.out.append(table^)
            self.decoders.append(dec^)
            self.decoders_ok.append(ok)
            self.json_keys.append(List[String]())
            self.encodings.append(tp.encoding)
            self.seen.append(0)

    def message(mut self, topic: Int, log_time: Int, b: List[UInt8], start: Int, end: Int) raises:
        var i = self.at[topic]
        if i < 0 or not self.decoders_ok[i]:
            return
        self.seen[i] += 1
        if self.encodings[i] == "json":
            self._json(i, log_time, b, start, end)
            return
        var n = self.out[i].columns()
        var row = _Row(n)
        row.i[0] = Int64(log_time)
        var cur = _Cdr(b, start, end)
        self.decoders[i].origin = start + 4
        var c = 1
        var items = List[_Row]()
        var item_c = 0
        self.decoders[i].fields(b, cur, self.decoders[i].root, row, c, True, items, item_c)
        if self.out[i].explode < 0:
            self.out[i]._push(row)
            return
        # (a row per item: the message's own fields, then the item's columns)
        var first = item_c
        var last = item_c + 1 + _cols_of(self.decoders[i].types, self.decoders[i].types.types[self.decoders[i].root].fields[self.out[i].explode].type)
        for it in items:
            var r = row.copy()
            for c2 in range(first, last):
                r.i[c2] = it.i[c2]
                r.f[c2] = it.f[c2]
                r.t[c2] = it.t[c2]
            self.out[i]._push(r)

    def _json(mut self, i: Int, log_time: Int, b: List[UInt8], start: Int, end: Int) raises:
        var j = Json.parse(_str(b, start, end - start))
        if j.kind(0) != J_OBJECT:
            raise Error("bag: a JSON message that isn't an object (" + self.out[i].topic + ")")
        if len(self.json_keys[i]) == 0:
            for k in range(j.size(0)):
                var key = j.key(0, k)
                var node = j.get(0, key)
                self.json_keys[i].append(key)
                var kd = j.kind(node)
                self.out[i].add(key, BAG_FLOAT if kd == J_NUMBER else (BAG_INT if kd == J_BOOL else BAG_TEXT))
        var row = _Row(self.out[i].columns())
        row.i[0] = Int64(log_time)
        for c in range(len(self.json_keys[i])):
            var node = j.get(0, self.json_keys[i][c])
            var col = c + 1
            if node < 0:
                continue
            var kd = self.out[i].kinds[col]
            if kd == BAG_FLOAT:
                row.f[col] = j.real(node)
            elif kd == BAG_INT:
                row.i[col] = 1 if j.flag(node) else 0
            else:
                row.t[col] = j.text(node) if j.kind(node) == J_STRING else j.dump(node)
        self.out[i]._push(row)


def _cols_of(types: MsgTypes, t: Int) -> Int:
    var c = 0
    _skip_plan(types, t, c)
    return c


# ----------------------------------------------------------------------------------------------------------- MCAP

comptime _MAGIC_LEN = 8


comptime _OPEN = def(Int, c_int) thin abi("C") -> c_int  # open(path, flags)
comptime _PREAD = def(c_int, Int, Int, Int) thin abi("C") -> Int  # pread(fd, buf, n, offset)
comptime _CLOSE = def(c_int) thin abi("C") -> c_int


struct _File(Movable):
    """A file read at offsets (pread, looked up by address: the standard library's seek and omxcore's parquet declare
    lseek two ways, and a program may declare a C function only once)."""
    var fd: c_int
    var path: String

    def __init__(out self, path: String) raises:
        self.path = path
        var p = path
        self.fd = _fn[_OPEN](_dlsym(0, "open"))(Int(p.as_c_string_span().unsafe_ptr()), c_int(0))
        if Int(self.fd) < 0:
            raise Error(path + ": can't be opened")

    def read(self, offset: Int, n: Int) raises -> List[UInt8]:
        """n bytes from offset (fewer at the file's end)."""
        var out = List[UInt8](length=max(n, 0), fill=0)
        var done = 0
        var pread = _fn[_PREAD](_dlsym(0, "pread"))
        while done < n:
            var got = pread(self.fd, Int(out.unsafe_ptr()) + done, n - done, offset + done)
            if got <= 0:
                break
            done += got
        while len(out) > done:
            _ = out.pop()
        return out^

    def __deinit__(deinit self):
        _ = _fn[_CLOSE](_dlsym(0, "close"))(self.fd)


def _read_at(path: String, offset: Int, n: Int) raises -> List[UInt8]:
    var f = _File(path)
    var b = f.read(offset, n)
    if len(b) != n:
        raise Error(path + ": the file ends early (a cut download?)")
    return b^


def _is_magic(b: List[UInt8], p: Int) -> Bool:
    return len(b) >= p + 8 and b[p] == 0x89 and b[p + 1] == 0x4D and b[p + 2] == 0x43 and b[p + 3] == 0x41 and b[p + 4] == 0x50 and b[p + 5] == 0x30 and b[p + 6] == 0x0D and b[p + 7] == 0x0A


def _open_mcap(path: String) raises -> Bag:
    var size = Int(getsize(path))
    if size < 8 + 9 + 20 + 8 or not _is_magic(_read_at(path, 0, 8), 0):
        raise Error(path + " isn't an MCAP file (no magic at its start)")
    var bag = Bag(path, "mcap")
    var schemas_id = List[Int]()
    var schemas = List[List[String]]()  # name, encoding, text
    var tail = _read_at(path, size - 37, 37)
    var summary_start = 0
    if _is_magic(tail, 29) and tail[0] == 0x02:
        summary_start = u64le(tail, 9)
    var counts_id = List[Int]()
    var counts = List[Int]()
    var channels = List[BagTopic]()
    var chan_schema = List[Int]()
    if summary_start > 0:
        bag.data_end = summary_start
        var s = _read_at(path, summary_start, size - 37 - summary_start)
        var p = 0
        while p + 9 <= len(s):
            var op = Int(s[p])
            var n = u64le(s, p + 1)
            var r = _Rec(p + 9, p + 9 + n)
            if r.end > len(s):
                raise Error(path + ": its summary ends early")
            if op == 0x03:
                _schema(s, r, schemas_id, schemas)
            elif op == 0x04:
                _channel(s, r, channels, chan_schema)
            elif op == 0x08:
                var t0 = r.u64(s)
                var t1 = r.u64(s)
                var off = r.u64(s)
                var length = r.u64(s)
                var mlen = r.u32(s)
                var ids = List[Int]()
                var q = _Rec(r.p, r.p + mlen)
                while q.p < q.end:
                    ids.append(q.u16(s))
                    _ = q.u64(s)
                bag.chunks.append(_Chunk(off, length, ids^))
                if bag.start_ns == 0 or t0 < bag.start_ns:
                    bag.start_ns = t0
                bag.end_ns = max(bag.end_ns, t1)
            elif op == 0x0B:
                _ = r.u64(s)
                _ = r.u16(s)
                _ = r.u32(s)
                _ = r.u32(s)
                _ = r.u32(s)
                _ = r.u32(s)
                var t0 = r.u64(s)
                var t1 = r.u64(s)
                bag.start_ns = t0
                bag.end_ns = t1
                var mlen = r.u32(s)
                var q = _Rec(r.p, r.p + mlen)
                while q.p < q.end:
                    counts_id.append(q.u16(s))
                    counts.append(q.u64(s))
            p += 9 + n
        sort_chunks(bag.chunks)
    else:
        bag.data_end = size
    if len(channels) == 0 or len(counts) == 0:
        # (no summary, or one without channels or counts: walk the data section)
        var walk = _Walk()
        _walk_mcap(path, 8, bag.data_end, walk)
        channels = walk.channels.copy()
        chan_schema = walk.chan_schema.copy()
        schemas_id = walk.schemas_id.copy()
        schemas = walk.schemas.copy()
        counts_id = walk.counts_id.copy()
        counts = walk.counts.copy()
        bag.start_ns = walk.t0
        bag.end_ns = walk.t1
        bag.chunks = List[_Chunk]()
    for i in range(len(channels)):
        var tp = channels[i].copy()
        for j in range(len(schemas_id)):
            if schemas_id[j] == chan_schema[i]:
                tp.type = schemas[j][0]
                tp.schema_encoding = schemas[j][1]
                tp.schema = schemas[j][2]
        for j in range(len(counts_id)):
            if counts_id[j] == tp.id:
                tp.count = counts[j]
        bag.topics.append(tp^)
    return bag^


def sort_chunks(mut chunks: List[_Chunk]):
    """By file offset (insertion sort: an index is nearly in order already)."""
    for i in range(1, len(chunks)):
        var j = i
        while j > 0 and chunks[j - 1].offset > chunks[j].offset:
            chunks.swap_elements(j - 1, j)
            j -= 1


def _schema(b: List[UInt8], mut r: _Rec, mut ids: List[Int], mut schemas: List[List[String]]) raises:
    var id = r.u16(b)
    var name = r.text(b)
    var enc = r.text(b)
    var text = r.text(b)  # (the data: ros2msg text, a jsonschema, …)
    for i in ids:
        if i == id:
            return
    ids.append(id)
    var s = List[String]()
    s.append(name)
    s.append(enc)
    s.append(text)
    schemas.append(s^)


def _channel(b: List[UInt8], mut r: _Rec, mut channels: List[BagTopic], mut chan_schema: List[Int]) raises:
    var id = r.u16(b)
    var schema = r.u16(b)
    var topic = r.text(b)
    var enc = r.text(b)
    for c in channels:
        if c.id == id:
            return
    channels.append(BagTopic(topic, "", enc, "", "", 0, id))
    chan_schema.append(schema)


struct _Walk(Movable):
    var channels: List[BagTopic]
    var chan_schema: List[Int]
    var schemas_id: List[Int]
    var schemas: List[List[String]]
    var counts_id: List[Int]
    var counts: List[Int]
    var t0: Int
    var t1: Int

    def __init__(out self):
        self.channels = List[BagTopic]()
        self.chan_schema = List[Int]()
        self.schemas_id = List[Int]()
        self.schemas = List[List[String]]()
        self.counts_id = List[Int]()
        self.counts = List[Int]()
        self.t0 = 0
        self.t1 = 0

    def records(mut self, b: List[UInt8], start: Int, end: Int) raises:
        var p = start
        while p + 9 <= end:
            var op = Int(b[p])
            var n = u64le(b, p + 1)
            var r = _Rec(p + 9, p + 9 + n)
            if r.end > end:
                raise Error("bag: a record runs past its chunk")
            if op == 0x03:
                _schema(b, r, self.schemas_id, self.schemas)
            elif op == 0x04:
                _channel(b, r, self.channels, self.chan_schema)
            elif op == 0x05:
                var ch = r.u16(b)
                _ = r.u32(b)
                var t = r.u64(b)
                if self.t0 == 0 or t < self.t0:
                    self.t0 = t
                self.t1 = max(self.t1, t)
                var found = False
                for i in range(len(self.counts_id)):
                    if self.counts_id[i] == ch:
                        self.counts[i] += 1
                        found = True
                        break
                if not found:
                    self.counts_id.append(ch)
                    self.counts.append(1)
            p += 9 + n


def _chunk_records(b: List[UInt8], var r: _Rec) raises -> List[UInt8]:
    """A Chunk record's records, decompressed."""
    _ = r.u64(b)  # message_start_time
    _ = r.u64(b)  # message_end_time
    var size = r.u64(b)
    _ = r.u32(b)  # uncompressed_crc
    var comp = r.text(b)
    var n = r.u64(b)
    r._need(n)
    return decompress(comp, b, r.p, n, size)


def _walk_mcap(path: String, start: Int, end: Int, mut walk: _Walk) raises:
    """The data section's records, read in turn (schemas, channels, counts and times; chunks opened)."""
    var f = _File(path)
    var p = start
    while p + 9 <= end:
        var head = f.read(p, 9)
        if len(head) < 9:
            break
        var op = Int(head[0])
        var n = u64le(head, 1)
        if op == 0x0F or op == 0x02:  # DataEnd, Footer
            break
        if op == 0x03 or op == 0x04 or op == 0x05 or op == 0x06:
            var body = f.read(p + 9, n)
            if len(body) != n:
                raise Error(path + ": the file ends inside a record (a cut download?)")
            if op == 0x06:
                var inner = _chunk_records(body, _Rec(0, n))
                walk.records(inner, 0, len(inner))
            else:
                var whole = List[UInt8](capacity=9 + n)
                whole.extend(head.copy())
                whole.extend(body^)
                walk.records(whole, 0, len(whole))
        p += 9 + n


def _visit_records[V: BagVisitor](bag: Bag, b: List[UInt8], start: Int, end: Int, wanted: List[Bool], ids: List[Int], mut v: V) raises:
    var p = start
    while p + 9 <= end:
        var op = Int(b[p])
        var n = u64le(b, p + 1)
        if op == 0x05:
            var ch = u16le(b, p + 9)
            var k = -1
            for i in range(len(ids)):
                if ids[i] == ch:
                    k = i
                    break
            if k >= 0 and wanted[k]:
                var t = u64le(b, p + 9 + 6)
                v.message(k, t, b, p + 9 + 22, p + 9 + n)
        p += 9 + n


def _scan_mcap[V: BagVisitor](bag: Bag, wanted: List[Bool], mut v: V) raises:
    var ids = List[Int]()
    var want_ids = List[Int]()
    for i in range(len(bag.topics)):
        ids.append(bag.topics[i].id)
        if wanted[i]:
            want_ids.append(bag.topics[i].id)
    var f = _File(bag.path)
    if len(bag.chunks) > 0:
        for c in bag.chunks:
            var any = len(c.channels) == 0
            for id in c.channels:
                any = any or (id in want_ids)
            if not any:
                continue
            var rec = f.read(c.offset, c.length)
            if len(rec) != c.length or Int(rec[0]) != 0x06:
                raise Error(bag.path + ": its chunk index points at something that isn't a chunk")
            var inner = _chunk_records(rec, _Rec(9, c.length))
            _visit_records(bag, inner, 0, len(inner), wanted, ids, v)
        return
    var p = 8
    while p + 9 <= bag.data_end:
        var head = f.read(p, 9)
        if len(head) < 9:
            break
        var op = Int(head[0])
        var n = u64le(head, 1)
        if op == 0x0F or op == 0x02:
            break
        if op == 0x05 or op == 0x06:
            var body = f.read(p + 9, n)
            if len(body) != n:
                raise Error(bag.path + ": the file ends inside a record (a cut download?)")
            if op == 0x06:
                var inner = _chunk_records(body, _Rec(0, n))
                _visit_records(bag, inner, 0, len(inner), wanted, ids, v)
            else:
                var whole = List[UInt8](capacity=9 + n)
                whole.extend(head.copy())
                whole.extend(body^)
                _visit_records(bag, whole, 0, len(whole), wanted, ids, v)
        p += 9 + n


# -------------------------------------------------------------------------------------------------------- sqlite3


def _open_sqlite(path: String) raises -> Bag:
    var bag = Bag(path, "sqlite3")
    var db = Database(path)
    var has_defs = False
    var q0 = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'message_definitions'")
    while q0.step():
        has_defs = True
    var q = db.prepare("SELECT t.id, t.name, t.type, t.serialization_format, (SELECT count(*) FROM messages m WHERE m.topic_id = t.id) FROM topics t ORDER BY t.id")
    while q.step():
        bag.topics.append(BagTopic(q.text(1), q.text(2), q.text(3), "", "", q.int(4), q.int(0)))
    if has_defs:
        for i in range(len(bag.topics)):
            var d = db.prepare("SELECT encoding, encoded_message_definition FROM message_definitions WHERE topic_type = ?")
            d.bind(1, bag.topics[i].type)
            while d.step():
                bag.topics[i].schema_encoding = d.text(0)
                bag.topics[i].schema = d.text(1)
    var t = db.prepare("SELECT min(timestamp), max(timestamp) FROM messages")
    while t.step():
        bag.start_ns = t.int(0)
        bag.end_ns = t.int(1)
    return bag^


def _scan_sqlite[V: BagVisitor](bag: Bag, wanted: List[Bool], mut v: V) raises:
    var db = Database(bag.path)
    for k in range(len(bag.topics)):
        if not wanted[k]:
            continue
        if bag.topics[k].schema == "":
            raise Error(bag.path + ": " + bag.topics[k].name + " has no message definition in the file (a rosbag2 before version 8): it can't be decoded without ROS")
        var q = db.prepare("SELECT timestamp, data FROM messages WHERE topic_id = ? ORDER BY id")
        q.bind(1, bag.topics[k].id)
        while q.step():
            var data = q.blob(1)
            v.message(k, q.int(0), data, 0, len(data))


# --------------------------------------------------------------------------------------------------------- cameras


struct CameraVideo(Movable):
    """A camera topic written as a video (mojoui.avi): the file, its frames' log times (frame i shows times_ns[i])."""
    var path: String
    var times_ns: List[Int]
    var width: Int
    var height: Int
    var fps: Float64  # the frames' average rate (the file plays at it; times_ns are exact)

    def __init__(out self, path: String):
        self.path = path
        self.times_ns = List[Int]()
        self.width = 0
        self.height = 0
        self.fps = 0.0


struct _Camera(BagVisitor, Movable):
    var avi: MjpegAvi
    var stream: List[UInt8]  # H.264 / H.265 access units, one after another (Annex B, as ROS 2's compressed images carry them)
    var times: List[Int]
    var formats: String

    def __init__(out self):
        self.avi = MjpegAvi()
        self.stream = List[UInt8]()
        self.times = List[Int]()
        self.formats = ""

    def message(mut self, topic: Int, log_time: Int, b: List[UInt8], start: Int, end: Int) raises:
        # sensor_msgs/CompressedImage: header (stamp: int32, uint32; frame_id: string), format: string, data: uint8[]
        var cur = _Cdr(b, start, end)
        var o = start + 4
        cur.align(b, 4, o)
        _ = cur.raw(b, 8)
        for field in range(2):
            cur.align(b, 4, o)
            var n = Int(cur.raw(b, 4))
            if self.formats == "" and field == 1:
                self.formats = _str(b, cur.p, max(n - 1, 0))
            cur.p += n
        cur.align(b, 4, o)
        var n = Int(cur.raw(b, 4))
        if cur.p + n > end:
            raise Error("bag: a picture runs past its message")
        if self.formats == "h264" or self.formats == "h265" or self.formats == "hevc":
            for i in range(cur.p, cur.p + n):
                self.stream.append(b[i])
        elif "jpeg" in self.formats:
            self.avi.add(b, cur.p, cur.p + n)
        else:
            raise Error("bag: pictures in '" + self.formats + "' can't become a video yet (JPEG, H.264 and H.265 can)")
        self.times.append(log_time)


def camera_video(bag: Bag, k: Int, path: String) raises -> CameraVideo:
    """Topic k's JPEG pictures copied into a Motion JPEG AVI at path (no re-encoding), in log-time order."""
    if not bag.topics[k].is_camera():
        raise Error(bag.topics[k].name + " isn't a camera topic (sensor_msgs/CompressedImage)")
    var wanted = List[Bool](length=len(bag.topics), fill=False)
    wanted[k] = True
    var cam = _Camera()
    bag.scan(wanted, cam)
    var out = CameraVideo(path)
    if len(cam.times) == 0:
        raise Error(bag.topics[k].name + " has no pictures")
    for i in range(1, len(cam.times)):
        if cam.times[i] < cam.times[i - 1]:
            raise Error(bag.topics[k].name + ": pictures out of time order (can't be a video yet)")
    var span = Float64(cam.times[len(cam.times) - 1] - cam.times[0]) / 1e9
    out.fps = Float64(len(cam.times) - 1) / span if span > 0 else 1.0
    # (the file's name says what it holds: JPEGs make an .avi, H.264/H.265 an .mp4, whatever path asked for)
    if path.endswith(".avi") or path.endswith(".mp4"):
        var stem = String(path[byte = : path.byte_length() - 4])
        out.path = stem + (".avi" if cam.avi.count() > 0 else ".mp4")
    var dest = out.path
    if cam.avi.count() > 0:
        cam.avi.write(dest, out.fps)
        out.width = cam.avi.width
        out.height = cam.avi.height
    else:
        # (H.264/H.265: the stream as it is, put in an .mp4 by ffmpeg without re-encoding; mojoui.video reads it)
        var raw = dest + "." + cam.formats
        with open(raw, "w") as f:
            f.write_bytes(Span(cam.stream))
        var p = Process.start(["ffmpeg", "-y", "-loglevel", "error", "-r", String(out.fps), "-f", "hevc" if cam.formats != "h264" else "h264",
                               "-i", raw, "-c", "copy", "-f", "mp4", dest], log=dest + ".log")
        while p.running():
            _ = libc.usleep(20_000)
        _ = libc.unlink(raw)
        if p.exit_code() != 0:
            var said = String("")
            try:
                said = open(dest + ".log", "r").read()  # (not Process.log_tail: its seek clashes with omxcore's lseek in one program)
            except:
                pass
            raise Error(bag.topics[k].name + ": ffmpeg couldn't put its " + cam.formats + " pictures in a video: " + said)
    out.times_ns = cam.times.copy()
    return out^


# ---------------------------------------------------------------------------------------------------- to the sheet


def sheet_table(t: BagTable, start_ns: Int, scale: Int = 6) raises -> Table:
    """A topic's table for the sheet (omxcore): t (seconds from the bag's start, to the ms) first, then the columns
    (floats as DECIMAL with `scale` places, integers INT, text TEXT); t_ns kept last for exact joins."""
    var out = Table.empty()
    var c_t = out.add_column("t", MX_DECIMAL, 3)
    var cols = List[Int]()
    for c in range(1, t.columns()):
        cols.append(out.add_column(t.names[c], MX_DECIMAL if t.kinds[c] == BAG_FLOAT else (MX_TEXT if t.kinds[c] == BAG_TEXT else MX_INT), scale if t.kinds[c] == BAG_FLOAT else 0))
    var c_ns = out.add_column("t_ns", MX_INT)
    var p = 1
    for _ in range(scale):
        p *= 10
    var ts = t.ints[t.slot[0]].copy()
    for r in range(t.rows):
        out.append(c_t, Int64((Int(ts[r]) - start_ns + 500_000) // 1_000_000))
        for c in range(1, t.columns()):
            var s = t.slot[c]
            if t.kinds[c] == BAG_FLOAT:
                var v = t.floats[s][r]
                if v != v or v > 9e12 or v < -9e12:
                    out.append(cols[c - 1], 0)  # (NaN or out of range: 0; the bag's own table keeps the value)
                else:
                    out.append(cols[c - 1], Int64(Int(v * Float64(p) + (0.5 if v >= 0 else -0.5))))
            elif t.kinds[c] == BAG_INT:
                out.append(cols[c - 1], t.ints[s][r])
            else:
                out.append_text(cols[c - 1], t.texts[s][r])
        out.append(c_ns, ts[r])
    out.check()
    return out^
