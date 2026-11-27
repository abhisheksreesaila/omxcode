# mojoui.archive: a set of files read from or written to a ZIP archive or a folder (goal 82 M3). What an app's import
# and export of "a folder or a zip of files" needs: an Obsidian vault, a Markdown export, a backup with its pictures.
#
#   var files = read_zip(bytes)              # FileSet: relative paths and their bytes (stored and deflated entries)
#   var files = read_folder("/path/vault")   # the same from a folder (dot files and symlinks left out)
#   files.add_text("Notes/a.md", "# A\n"); files.add("attachments/x.png", png)
#   var zip = zip_bytes(files)               # a ZIP any unzip reads (stored entries, UTF-8 names, CRC-32)
#   _ = write_folder(files, "/path/out")     # refuses before writing anything if one of its files is already there
#
# Untrusted input (an archive from anywhere) is read safely: a name that is absolute, climbs out (".."), or has a part
# beginning with a dot is left out (safe_relative); a file over Limits.file_bytes is left out; more than Limits.files
# files or Limits.total_bytes in all raises before anything is inflated; a deflated entry makes no more bytes than it
# says it holds (a zip bomb stops there); a CRC that doesn't match raises. ZIP64, encryption and methods other than
# stored (0) and deflate (8): an entry like that is left out. The limits are Personal Note's vault import's (vault.py).
# Writing: entries are stored, not compressed (pictures are compressed already; every reader takes stored entries);
# times are 1980-01-01 so the same files make the same bytes.

from std.os import makedirs
from std.os.path import isdir
from mojoui.files import file_exists
from mojoui.pngread import inflate_raw
from mojoui.watch import list_dir


struct Limits(Copyable, Movable):
    var file_bytes: Int
    var total_bytes: Int
    var files: Int

    def __init__(out self, file_bytes: Int = 20 * 1024 * 1024, total_bytes: Int = 200 * 1024 * 1024, files: Int = 20_000):
        self.file_bytes = file_bytes
        self.total_bytes = total_bytes
        self.files = files


struct ArchiveFile(Copyable, Movable):
    var path: String  # relative, "/" between parts
    var data: List[UInt8]

    def __init__(out self, path: String, var data: List[UInt8]):
        self.path = path
        self.data = data^

    def text(self) -> String:
        """Its bytes as UTF-8 (a byte-order mark dropped; bytes that aren't UTF-8 read as U+FFFD)."""
        var start = 3 if len(self.data) >= 3 and self.data[0] == 0xEF and self.data[1] == 0xBB and self.data[2] == 0xBF else 0
        return String(from_utf8_lossy=Span(self.data)[start:])

    def is_utf8(self) -> Bool:
        try:
            _ = String(from_utf8=Span(self.data))
            return True
        except:
            return False


struct FileSet(Movable, Sized):
    """Files by relative path, in the order they were added; a path added again replaces the earlier one."""
    var files: List[ArchiveFile]
    var skipped: List[String]  # what a read left out, and why ("name: why")

    def __init__(out self):
        self.files = List[ArchiveFile]()
        self.skipped = List[String]()

    def __len__(self) -> Int:
        return len(self.files)

    def find(self, path: String) -> Int:
        for i in range(len(self.files)):
            if self.files[i].path == path:
                return i
        return -1

    def add(mut self, path: String, var data: List[UInt8]):
        var at = self.find(path)
        if at >= 0:
            self.files[at].data = data^
        else:
            self.files.append(ArchiveFile(path, data^))

    def add_text(mut self, path: String, text: String):
        var b = List[UInt8](capacity=text.byte_length())
        for c in text.as_bytes():
            b.append(c)
        self.add(path, b^)

    def total(self) -> Int:
        var n = 0
        for ref f in self.files:
            n += len(f.data)
        return n


def safe_relative(name: String) -> String:
    """`name` as a relative path that stays inside where it is unpacked ("/" between parts, backslashes taken as "/"), or ""
    when it isn't one: absolute, a drive ("C:"), "..", an empty part, or a part beginning with a dot (a hidden file, the
    web's rule)."""
    var n = name.replace("\\", "/")
    if n.startswith("/") or n == "":
        return ""
    var parts = n.split("/")
    var out = String("")
    for k in range(len(parts)):
        var p = String(parts[k])
        if p == "" and k == len(parts) - 1:  # (a folder's own entry: "a/b/")
            return ""
        if p == "" or p.startswith(".") or (k == 0 and p.byte_length() >= 2 and p.as_bytes()[1] == UInt8(ord(":"))):
            return ""
        out += ("/" if out != "" else "") + p
    return out


def _crc_table() -> List[UInt32]:
    var table = List[UInt32](capacity=256)
    for n in range(256):
        var c = UInt32(n)
        for _ in range(8):
            c = (UInt32(0xEDB88320) ^ (c >> 1)) if (c & 1) != 0 else (c >> 1)
        table.append(c)
    return table^


def crc32(data: List[UInt8]) -> UInt32:
    """CRC-32 (ZIP's, PNG's)."""
    var table = _crc_table()
    var c = UInt32(0xFFFFFFFF)
    for b in data:
        c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
    return c ^ UInt32(0xFFFFFFFF)


def _u16(b: List[UInt8], at: Int) -> Int:
    return Int(b[at]) | (Int(b[at + 1]) << 8)


def _u32(b: List[UInt8], at: Int) -> Int:
    return _u16(b, at) | (_u16(b, at + 2) << 16)


def _put16(mut out: List[UInt8], v: Int):
    out.append(UInt8(v & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))


def _put32(mut out: List[UInt8], v: Int):
    _put16(out, v & 0xFFFF)
    _put16(out, (v >> 16) & 0xFFFF)


def read_zip(data: List[UInt8], limits: Limits = Limits()) raises -> FileSet:
    """The files of a ZIP archive (see the module's notes for what is left out and what raises)."""
    var n = len(data)
    var end = -1
    var k = n - 22
    while k >= 0 and k >= n - 22 - 65535:
        if data[k] == 0x50 and data[k + 1] == 0x4B and data[k + 2] == 5 and data[k + 3] == 6:
            end = k
            break
        k -= 1
    if end < 0:
        raise Error("That is not a ZIP archive")
    var count = _u16(data, end + 10)
    var cd_size = _u32(data, end + 12)
    var cd_at = _u32(data, end + 16)
    if count == 0xFFFF or cd_at == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:
        raise Error("That archive is a ZIP64 archive, which isn't read here")
    if cd_at + cd_size > end:
        raise Error("That ZIP archive is damaged (its directory is past its end)")
    # the directory first: sizes and names, every limit checked before anything is inflated
    var names = List[String]()
    var methods = List[Int]()
    var crcs = List[Int]()
    var csizes = List[Int]()
    var usizes = List[Int]()
    var offsets = List[Int]()
    var flags = List[Int]()
    var at = cd_at
    var total = 0
    var files = 0
    for _ in range(count):
        if at + 46 > end or _u32(data, at) != 0x02014B50:
            raise Error("That ZIP archive is damaged (a directory entry isn't one)")
        var nlen = _u16(data, at + 28)
        var elen = _u16(data, at + 30)
        var clen = _u16(data, at + 32)
        if at + 46 + nlen > end:
            raise Error("That ZIP archive is damaged (a name is past its directory)")
        var name = String(from_utf8_lossy=Span(data)[at + 46 : at + 46 + nlen])
        var usize = _u32(data, at + 24)
        if not name.endswith("/"):
            files += 1
            total += usize
        names.append(name^)
        flags.append(_u16(data, at + 8))
        methods.append(_u16(data, at + 10))
        crcs.append(_u32(data, at + 16))
        csizes.append(_u32(data, at + 20))
        usizes.append(usize)
        offsets.append(_u32(data, at + 42))
        at += 46 + nlen + elen + clen
    if files > limits.files or total > limits.total_bytes:
        raise Error("The archive is larger than the import limit")
    var out = FileSet()
    for i in range(len(names)):
        if names[i].endswith("/"):
            continue
        var path = safe_relative(names[i])
        if path == "":
            out.skipped.append(names[i] + ": not a safe path")
            continue
        if usizes[i] > limits.file_bytes:
            out.skipped.append(names[i] + ": larger than the limit")
            continue
        if (flags[i] & 1) != 0 or (methods[i] != 0 and methods[i] != 8) or usizes[i] == 0xFFFFFFFF or csizes[i] == 0xFFFFFFFF:
            out.skipped.append(names[i] + ": encrypted, ZIP64 or compressed in a way not read here")
            continue
        var loc = offsets[i]
        if loc + 30 > end or _u32(data, loc) != 0x04034B50:
            raise Error("That ZIP archive is damaged (" + names[i] + " isn't where its directory says)")
        var start = loc + 30 + _u16(data, loc + 26) + _u16(data, loc + 28)
        if start + csizes[i] > end:
            raise Error("That ZIP archive is damaged (" + names[i] + " ends past the archive)")
        var raw = List[UInt8](capacity=csizes[i])
        for q in range(start, start + csizes[i]):
            raw.append(data[q])
        var bytes: List[UInt8]
        if methods[i] == 0:
            bytes = raw^
        else:
            bytes = inflate_raw(raw^, usizes[i], usizes[i])
        if len(bytes) != usizes[i] or Int(crc32(bytes)) != crcs[i]:
            raise Error("That ZIP archive is damaged (" + names[i] + " doesn't match its checksum)")
        out.add(path, bytes^)
    return out^


def _header(mut dst: List[UInt8], central: Bool, crc: Int, size: Int, name: Span[UInt8, _], offset: Int):
    """A stored entry's local header, or its directory entry (central)."""
    _put32(dst, 0x02014B50 if central else 0x04034B50)
    if central:
        _put16(dst, 0x0314)  # made by: Unix, 2.0
    _put16(dst, 20)  # needed: 2.0
    _put16(dst, 0x0800)  # UTF-8 names
    _put16(dst, 0)  # stored
    _put16(dst, 0)  # 00:00
    _put16(dst, 0x21)  # 1980-01-01
    _put32(dst, crc)
    _put32(dst, size)
    _put32(dst, size)
    _put16(dst, len(name))
    _put16(dst, 0)  # no extra field
    if central:
        _put16(dst, 0)  # no comment
        _put16(dst, 0)  # disk 0
        _put16(dst, 0)  # internal attributes
        _put32(dst, 0o100644 << 16)  # a regular file, rw-r--r--
        _put32(dst, offset)
    for c in name:
        dst.append(c)


def zip_bytes(files: FileSet) raises -> List[UInt8]:
    """A ZIP archive of the set (stored entries, UTF-8 names, CRC-32; raises past 65,535 files or 4 GB)."""
    if len(files.files) > 65535:
        raise Error("too many files for a ZIP archive without ZIP64")
    var out = List[UInt8](capacity=files.total() + 128 * len(files.files) + 22)
    var central = List[UInt8]()
    for ref f in files.files:
        var offset = len(out)
        var crc = Int(crc32(f.data))
        var size = len(f.data)
        var name = f.path.as_bytes()
        if offset + size > 0xFFFFFFFE:
            raise Error("the archive would be larger than 4 GB")
        _header(out, False, crc, size, name, offset)
        _header(central, True, crc, size, name, offset)
        for b in f.data:
            out.append(b)
    var cd_at = len(out)
    for b in central:
        out.append(b)
    _put32(out, 0x06054B50)
    _put16(out, 0)
    _put16(out, 0)
    _put16(out, len(files.files))
    _put16(out, len(files.files))
    _put32(out, len(central))
    _put32(out, cd_at)
    _put16(out, 0)
    return out^


def read_folder(root: String, limits: Limits = Limits()) raises -> FileSet:
    """Every file under `root` by its path relative to it, sorted; dot files and folders and symlinks left out, files over
    the size limit too (said in skipped); more files or bytes than the limits raise."""
    var top = String(root.rstrip("/")) if root != "/" else root
    if not isdir(top):
        raise Error(root + " is not a folder")
    var out = FileSet()
    var todo = List[String]()
    todo.append("")
    var total = 0
    var found = List[String]()
    while len(todo) > 0:
        var rel = todo.pop()
        var dir = top + ("/" + rel if rel != "" else String(""))
        for entry in list_dir(dir):
            if entry[0].startswith("."):
                continue
            var path = (rel + "/" if rel != "" else String("")) + entry[0]
            if entry[1]:
                todo.append(path)
            else:
                found.append(path)
    sort(found)
    for path in found:
        var bytes: List[UInt8]
        with open(top + "/" + path, "r") as f:
            bytes = f.read_bytes()
        if len(bytes) > limits.file_bytes:
            out.skipped.append(path + ": larger than the limit")
            continue
        total += len(bytes)
        if len(out.files) >= limits.files or total > limits.total_bytes:
            raise Error("The folder is larger than the import limit")
        out.add(path, bytes^)
    return out^


def write_folder(files: FileSet, root: String) raises -> Int:
    """The set written into `root` (made if missing); how many files. Refuses before writing anything when a path isn't safe
    or one of its files is already there (an export never overwrites)."""
    var clashes = 0
    var first = String("")
    for ref f in files.files:
        if safe_relative(f.path) != f.path:
            raise Error("Refusing to write " + f.path + ": not a safe path")
        if file_exists(root + "/" + f.path):
            clashes += 1
            if first == "":
                first = f.path
    if clashes > 0:
        raise Error("Refusing to overwrite " + String(clashes) + " existing file(s), for example " + first + "; export into an empty folder")
    makedirs(root, exist_ok=True)
    for ref f in files.files:
        var slash = f.path.rfind("/")
        if slash > 0:
            makedirs(root + "/" + String(f.path[byte=:slash]), exist_ok=True)
        with open(root + "/" + f.path, "w") as out:
            out.write_bytes(Span(f.data))
    return len(files.files)
