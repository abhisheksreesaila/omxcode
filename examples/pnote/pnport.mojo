# Personal Note's import and export formats (goal 82 M3), as its own portability.py, vault.py and services.py write and read
# them, so a backup or a vault made by either app opens in the other:
#   backup_json      the whole workspace as one lossless JSON file ("personal-note-workspace", version 3): canvases as
#                    JSON Canvas with their pictures inline as data URLs, pages and maps as their documents, secure notes as
#                    ciphertext only, with the wrapped keys
#   import_backup    such a file (versions 1, 2, 3) merged in: new notebooks and new notes, new resource ids, links between
#                    the backup's notes pointed at the copies; nothing that exists is changed or deleted
#   vault_files      an Obsidian vault: a folder per notebook; a canvas a .canvas file (pictures under attachments/), a page
#                    its Markdown, a map a Markdown outline, a secure note only its title
#   import_vault     a vault (a folder or a zip: mojoui.archive) as new notes in new notebooks: each .canvas a canvas, each .md
#                    a canvas with one text card, as the web imports them
# The generic parts are the framework's: mojoui.archive (zip and folders), mojoui.mediastore (pictures and data URLs),
# mojoui.json / jsonedit (reading and rewriting documents). This file only knows Personal Note's own fields.

from std.collections import Dict
from std.math import floor, ceil
from mojoui.sqlite import Database
from mojoui.json import Json, json_string, J_OBJECT, J_ARRAY, J_STRING, J_NUMBER
from mojoui.jsonedit import members, elements, find_member
from mojoui.archive import FileSet, safe_relative
from mojoui.files import file_exists
from mojoui.mediastore import MAX_MEDIA_BYTES
from mojoui.mediastore import put_media, read_media, data_url, decode_data_url, ext_of_suffix
from mojoui.objectlayer import import_json_canvas, reading_text
from mojoui.hash import sha256, hex
from mojoui.schedule import iso_utc
from mojoui.files import _wall_ns
from pnstore import hex_id, changed, EMPTY_PAGE

comptime BACKUP_FORMAT = "personal-note-workspace"
comptime BACKUP_VERSION = 3
comptime INBOX = "Inbox"
comptime DEFAULT_NOTEBOOK = "Imported vault"
comptime ATTACHMENTS = "attachments"


struct PortResult(Copyable, Movable):
    var notebooks: Int
    var notes: Int
    var ids: List[Int]
    var skipped: List[String]

    def __init__(out self):
        self.notebooks = 0
        self.notes = 0
        self.ids = List[Int]()
        self.skipped = List[String]()


def first_chars(text: String, n: Int) -> String:
    """The first n characters (code points, as Python's text[:n] counts them; never a cut inside one)."""
    var out = String("")
    var k = 0
    for c in text.codepoint_slices():
        if k >= n:
            break
        out += String(c)
        k += 1
    return out^


def now_utc() -> String:
    return iso_utc(_wall_ns() // 1_000_000_000)


def media_dir_of(db_path: String) -> String:
    """Personal Note's pictures: the notes file's folder + /media."""
    var slash = db_path.rfind("/")
    return (String(db_path[byte=:slash]) if slash > 0 else String(".")) + "/media"


def _replace_spans(text: String, var edits: List[Tuple[Int, Int, String]]) -> String:
    """`text` with each [start, end) replaced, from the end."""
    var out = text
    while len(edits) > 0:
        var at = 0
        for k in range(1, len(edits)):
            if edits[k][0] > edits[at][0]:
                at = k
        var e = edits.pop(at)
        out = String(out[byte = 0 : e[0]]) + e[2] + String(out[byte = e[1] :])
    return out^


def _member_value(text: String, start: Int, end: Int, key: String) raises -> Tuple[Int, Int]:
    """Where member `key`'s value is in the object at [start, end) ((-1, -1): it has none)."""
    var ms = members(text, start, end)
    var at = find_member(ms, key)
    return (ms[at].start, ms[at].end) if at >= 0 else (-1, -1)


def _string_at(text: String, span: Tuple[Int, Int]) -> String:
    if span[0] < 0:
        return ""
    try:
        var j = Json.parse(String(text[byte = span[0] : span[1]]))
        return j.text(0) if j.kind(0) == J_STRING else String("")
    except:
        return ""


# ---------------------------------------------------------------- canvases' pictures, in and out

def canvas_media_inline(text: String, media_dir: String) -> String:
    """A stored canvas with each node's "file" that names a picture in the media folder ("media/<sha>.<ext>") as a data URL
    (a backup is one file: services.snapshot_content). Anything else stays as it is."""
    try:
        var ms = members(text, 0, text.byte_length())
        var n = find_member(ms, "nodes")
        if n < 0:
            return text
        var edits = List[Tuple[Int, Int, String]]()
        for s in elements(text, ms[n].start, ms[n].end):
            var f = _member_value(text, s.start, s.end, "file")
            var name = _string_at(text, f)
            if not name.startswith("media/"):
                continue
            var data = read_media(media_dir, name)
            if not data:
                continue
            edits.append((f[0], f[1], json_string(data_url(data.value(), String(name[byte = name.rfind(".") + 1 :])))))
        return _replace_spans(text, edits^)
    except:
        return text


def canvas_media_files(text: String, media_dir: String, mut out: FileSet) -> String:
    """A stored canvas for a vault: each picture of the media folder copied to attachments/<name> and named so (Obsidian
    resolves a file node by its vault path); a picture inline as a data URL written there by its hash."""
    try:
        var ms = members(text, 0, text.byte_length())
        var n = find_member(ms, "nodes")
        if n < 0:
            return text
        var edits = List[Tuple[Int, Int, String]]()
        for s in elements(text, ms[n].start, ms[n].end):
            var f = _member_value(text, s.start, s.end, "file")
            var name = _string_at(text, f)
            var bytes = List[UInt8]()
            var file = String("")
            if name.startswith("media/"):
                var data = read_media(media_dir, name)
                file = String(ATTACHMENTS) + "/" + String(name[byte=6:])
                if data:
                    bytes = data.take()
            elif name.startswith("data:"):
                var d = decode_data_url(name)
                if d:
                    file = String(ATTACHMENTS) + "/" + hex(sha256(Span(d.value()[0]))) + "." + d.value()[1]
                    bytes = d.value()[0].copy()
            if file == "":
                continue
            if len(bytes) > 0:
                out.add(file, bytes^)
            edits.append((f[0], f[1], json_string(file)))
        return _replace_spans(text, edits^)
    except:
        return text


def _reserved_ids(mut db: Database) raises -> Dict[String, Bool]:
    """Every object id the workspace's canvases use (services.reserved_block_ids): an imported one that clashes is renamed."""
    var out = Dict[String, Bool]()
    var q = db.prepare("SELECT content FROM notes WHERE note_type = 'canvas' AND secure = 0")
    while q.step():
        try:
            var j = Json.parse(q.text(0))
            for arr in ["nodes", "edges"]:
                var a = j.get(0, arr)
                for k in range(j.size(a)):
                    var id = j.text(j.get(j.at(a, k), "id"))
                    if id != "":
                        out[id] = True
        except:
            pass
    return out^


def canvas_for_import(text: String, media_dir: String, mut reserved: Dict[String, Bool]) raises -> String:
    """An incoming canvas as it is stored: its pictures given as data URLs into the media folder ("media/<sha>.<ext>"), every
    object a unique id no other note uses (services.repair_ids: a clash gets a new res_ id; an edge follows its nodes)."""
    var ms = members(text, 0, text.byte_length())
    var n = find_member(ms, "nodes")
    if n < 0:
        raise Error("not a JSON Canvas document (no nodes)")
    var e = find_member(ms, "edges")
    var edits = List[Tuple[Int, Int, String]]()
    var renamed = Dict[String, String]()
    var here = Dict[String, Bool]()
    for s in elements(text, ms[n].start, ms[n].end):
        var f = _member_value(text, s.start, s.end, "file")
        var name = _string_at(text, f)
        if name.startswith("data:"):
            var d = decode_data_url(name)
            if d:
                edits.append((f[0], f[1], json_string(put_media(media_dir, d.value()[0], d.value()[1]))))
        var idv = _member_value(text, s.start, s.end, "id")
        var id = _string_at(text, idv)
        if id == "" or id in reserved:
            var fresh = hex_id("res_")
            if id != "" and id not in here:
                renamed[id] = fresh
            if idv[0] >= 0:
                edits.append((idv[0], idv[1], json_string(fresh)))
            id = fresh
        reserved[id] = True
        here[id] = True
    if e >= 0 and text.as_bytes()[ms[e].start] == UInt8(ord("[")):
        for s in elements(text, ms[e].start, ms[e].end):
            var idv = _member_value(text, s.start, s.end, "id")
            var id = _string_at(text, idv)
            if id == "" or id in reserved:
                var fresh = hex_id("res_")
                if idv[0] >= 0:
                    edits.append((idv[0], idv[1], json_string(fresh)))
                id = fresh
            reserved[id] = True
            for end in ["fromNode", "toNode"]:
                var ev = _member_value(text, s.start, s.end, end)
                var to = _string_at(text, ev)
                if to in renamed:
                    edits.append((ev[0], ev[1], json_string(renamed[to])))
    return _replace_spans(text, edits^)


# ---------------------------------------------------------------- mind maps

def map_words(text: String) -> String:
    """What search holds for a map (services.mindmap_text): every idea's words, space-joined, in stored order."""
    try:
        var j = Json.parse(text)
        var nodes = j.get(0, "nodes")
        var out = String("")
        var first = True
        for k in range(j.size(nodes)):
            var t = j.get(j.at(nodes, k), "text")
            if j.kind(t) == J_STRING:
                out += ("" if first else " ") + j.text(t)
                first = False
        return out^
    except:
        return ""


def _has_nodes(text: String) -> Bool:
    """A JSON Canvas: an object with a "nodes" array (else another app's format, or Personal Note's old Fabric JSON)."""
    try:
        var c = Json.parse(text)
        return c.kind(c.get(0, "nodes")) == J_ARRAY
    except:
        return False


def _num(j: Json, node: Int) -> Float64:
    return j.real(node) if j.kind(node) == J_NUMBER else 0.0


def mindmap_outline(text: String) -> String:
    """A map as an indented list from its centre (note_text.mindmap_outline): children by their height, then id; ideas no
    branch reaches after."""
    try:
        var j = Json.parse(text)
        var nodes = j.get(0, "nodes")
        if j.kind(nodes) != J_ARRAY:
            return ""
        var ids = List[String]()
        var at = List[Int]()
        for k in range(j.size(nodes)):
            var n = j.at(nodes, k)
            var id = j.text(j.get(n, "id"))
            if j.kind(n) != J_OBJECT or id == "" or id in ids:
                if id in ids:  # (the last of a name wins, as a dict does)
                    at[ids.index(id)] = n
                continue
            ids.append(id)
            at.append(n)
        var root = j.text(j.get(0, "rootId"))
        var lines = List[String]()
        var seen = Dict[String, Bool]()
        var todo = List[Tuple[Int, Int]]()  # (node, depth), a stack
        var roots = List[Int]()
        if root in ids:
            roots.append(at[ids.index(root)])
        else:
            for k in range(len(at)):
                if j.kind(j.get(at[k], "parentId")) != J_STRING:
                    roots.append(at[k])
        for k in range(len(at)):
            roots.append(at[k])
        for r in roots:
            todo.append((r, 0))
            while len(todo) > 0:
                var top = todo.pop()
                var n = top[0]
                var id = j.text(j.get(n, "id"))
                if id in seen:
                    continue
                seen[id] = True
                var t = String(j.text(j.get(n, "text")).strip())
                lines.append(String("  ") * top[1] + "- " + (t if t != "" else String("Untitled idea")))
                var kids = List[Tuple[Float64, String, Int]]()
                for k in range(len(at)):
                    if j.text(j.get(at[k], "parentId")) == id:
                        kids.append((_num(j, j.get(at[k], "y")), ids[k], at[k]))
                # (sorted by y then id; pushed in reverse so the first is visited first)
                for a in range(len(kids)):
                    for b in range(a + 1, len(kids)):
                        if kids[b][0] < kids[a][0] or (kids[b][0] == kids[a][0] and kids[b][1] < kids[a][1]):
                            var x = kids[a]
                            kids[a] = kids[b]
                            kids[b] = x
                for q in range(len(kids) - 1, -1, -1):
                    todo.append((kids[q][2], top[1] + 1))
        var out = String("")
        for k in range(len(lines)):
            out += ("\n" if k > 0 else "") + lines[k]
        return out^
    except:
        return ""


# ---------------------------------------------------------------- the backup

def _json_or(text: String, fallback: String) -> String:
    """The stored text when it is a JSON object, else the fallback."""
    try:
        var j = Json.parse(text)
        return text if j.kind(0) == J_OBJECT else fallback
    except:
        return fallback


def backup_json(mut db: Database, media_dir: String) raises -> String:
    """The workspace as Personal Note's backup (portability.workspace_backup)."""
    var out = '{"format":"' + String(BACKUP_FORMAT) + '","version":' + String(BACKUP_VERSION) + ',"exportedAt":' + json_string(now_utc())
    out += ',"workspaceId":' + json_string(db.one_text("SELECT workspace_id FROM workspace_state WHERE id = 1"))
    out += ',"secureKeys":['
    var q = db.prepare("SELECT key_id, kind, version, salt, params, wrapped, is_primary FROM secure_keys ORDER BY id")
    var first = True
    while q.step():
        out += ("" if first else ",") + '{"keyId":' + json_string(q.text(0)) + ',"kind":' + json_string(q.text(1)) + ',"version":' + String(q.int(2))
        out += ',"salt":' + (json_string(q.text(3)) if not q.is_null(3) else String("null")) + ',"params":' + (_json_or(q.text(4), "null") if not q.is_null(4) else String("null"))
        out += ',"wrapped":' + json_string(q.text(5)) + ',"primary":' + ("true" if q.int(6) != 0 else "false") + "}"
        first = False
    out += '],"notebooks":['
    var resources = Dict[Int, String]()
    q = db.prepare("SELECT id, resource_id, name, color, category, icon, created_at, updated_at FROM notebooks ORDER BY id")
    first = True
    while q.step():
        resources[q.int(0)] = q.text(1)
        out += ("" if first else ",") + '{"resourceId":' + json_string(q.text(1)) + ',"name":' + json_string(q.text(2)) + ',"color":' + json_string(q.text(3))
        out += ',"category":' + json_string(q.text(4)) + ',"icon":' + json_string(q.text(5)) + ',"createdAt":' + json_string(q.text(6)) + ',"updatedAt":' + json_string(q.text(7)) + "}"
        first = False
    out += '],"notes":['
    q = db.prepare("SELECT resource_id, note_type, title, content, content_format, page_state, IFNULL(notebook_id, 0), created_at, updated_at, secure, secure_key_id, seal_id, sealed, icon, icon_tint FROM notes ORDER BY id")
    first = True
    while q.step():
        var kind = q.text(1)
        var fmt = String("mindmap") if kind == "mindmap" else (String("page") if kind == "page" else (String("fabric") if q.text(4) == "fabric" else String("json-canvas")))
        var book = resources.get(q.int(6), String(""))
        out += ("" if first else ",") + '{"resourceId":' + json_string(q.text(0)) + ',"notebookResourceId":' + (json_string(book) if book != "" else String("null"))
        out += ',"noteType":' + json_string(kind) + ',"title":' + json_string(q.text(2)) + ',"contentFormat":' + json_string(fmt)
        out += ',"createdAt":' + json_string(q.text(7)) + ',"updatedAt":' + json_string(q.text(8))
        if q.text(13) != "":
            out += ',"icon":' + json_string(q.text(13)) + ',"iconTint":' + String(q.int(14))
        if q.int(9) != 0:
            out += ',"content":{},"pageState":{"columns":1,"rows":1},"secure":true,"keyId":' + json_string(q.text(10)) + ',"sealId":' + json_string(q.text(11)) + ',"sealed":' + json_string(q.text(12)) + "}"
        else:
            var content: String
            if kind == "page":
                content = _json_or(q.text(3), String(EMPTY_PAGE))
            elif kind == "mindmap":
                content = _json_or(q.text(3), '{"objects":[]}')
            else:
                content = canvas_media_inline(_json_or(q.text(3), '{"objects":[]}'), media_dir)
            out += ',"content":' + content + ',"pageState":' + _json_or(q.text(5), '{"columns":1,"rows":1}') + "}"
        first = False
    return out + "]}"


def _new_notebook(mut db: Database, name: String, color: String, category: String, icon: String) raises -> Int:
    var res = hex_id("res_")
    _ = db.run("INSERT INTO notebooks (resource_id, name, color, category, icon) VALUES (?, ?, ?, ?, ?)", [res, name, color, category, icon])
    var id = db.last_id()
    _record(db, "notebook", res)
    return id


def _record(mut db: Database, kind: String, res: String) raises:
    """services.record_change: the sequence moves on, a row for the new resource at revision 1."""
    _ = db.run("UPDATE workspace_state SET sequence = sequence + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1", List[String]())
    _ = db.run("INSERT INTO workspace_changes (sequence, resource_kind, resource_id, revision, change_type) SELECT sequence, ?, ?, 1, 'created' FROM workspace_state WHERE id = 1", [kind, res])


def _hex_color(c: String) -> Bool:
    if c.byte_length() != 7 or not c.startswith("#"):
        return False
    for k in range(1, 7):
        var x = Int(c.as_bytes()[k])
        if not (48 <= x <= 57 or 97 <= x <= 102 or 65 <= x <= 70):
            return False
    return True


def _repoint(text: String, new_ids: Dict[String, String]) -> String:
    """Every link to a note of the backup (personal-note://note/res_…) pointing at the copy it is imported as."""
    var key = String("personal-note://note/")
    if text.find(key) < 0:
        return text
    var out = String("")
    var at = 0
    while True:
        var f = text.find(key, at)
        if f < 0:
            break
        var s = f + key.byte_length()
        var e = s
        var b = text.as_bytes()
        while e < len(b) and (Int(b[e]) == 95 or 48 <= Int(b[e]) <= 57 or 97 <= Int(b[e]) <= 122):
            e += 1
        var old = String(text[byte=s:e])
        out += String(text[byte=at:s]) + new_ids.get(old, old)
        at = e
    return out + String(text[byte=at:])


def import_snapshot(mut db: Database, media_dir: String, j: Json, notebooks: Int, notes: Int) raises -> PortResult:
    """services.import_workspace_snapshot: the snapshot's notebooks and notes added (checked whole first; one transaction:
    all or nothing)."""
    var res = PortResult()
    var nb_keys = List[String]()
    for k in range(j.size(notebooks)):
        var nb = j.at(notebooks, k)
        var key = j.text(j.get(nb, "resourceId"))
        if j.kind(nb) != J_OBJECT or key == "" or key in nb_keys:
            raise Error("Notebook resource IDs must be unique")
        nb_keys.append(key)
    if j.size(notebooks) > 1000 or j.size(notes) > 20000:
        raise Error("Backup exceeds the supported workspace size")
    for k in range(j.size(notes)):
        var n = j.at(notes, k)
        if j.kind(n) != J_OBJECT:
            raise Error("Each note must be an object")
        var book = j.get(n, "notebookResourceId")
        if j.kind(book) == J_STRING and j.text(book) not in nb_keys:
            raise Error("Every note must reference an included notebook, or none (the Inbox)")
        var kind = j.text(j.get(n, "noteType"), "canvas")
        if kind != "canvas" and kind != "page" and kind != "mindmap":
            raise Error("Backup contains an unsupported note type")
        if j.kind(j.get(n, "content")) != J_OBJECT:
            raise Error("Every note must contain a document object")
        if j.flag(j.get(n, "secure")):
            raise Error("This backup has locked notes: import it in Personal Note (the native app doesn't open locked notes yet)")
    var new_ids = Dict[String, String]()
    for k in range(j.size(notes)):
        var r = j.text(j.get(j.at(notes, k), "resourceId"))
        if r != "" and r not in new_ids:
            new_ids[r] = hex_id("res_")
    db.begin()
    try:
        var reserved = _reserved_ids(db)
        var books = Dict[String, Int]()
        for k in range(j.size(notebooks)):
            var nb = j.at(notebooks, k)
            var name = String(j.text(j.get(nb, "name"), "Imported notebook").strip())
            name = first_chars(name, 80)
            var color = j.text(j.get(nb, "color"))
            var cat = j.text(j.get(nb, "category"), "projects")
            books[j.text(j.get(nb, "resourceId"))] = _new_notebook(db, name if name != "" else String("Imported notebook"), color if _hex_color(color) else String("#B86B4B"), cat if cat != "" else String("projects"), j.text(j.get(nb, "icon")))
            res.notebooks += 1
        var claimed = Dict[String, Bool]()
        for k in range(j.size(notes)):
            var n = j.at(notes, k)
            var kind = j.text(j.get(n, "noteType"), "canvas")
            var content = _repoint(j.dump(j.get(n, "content")), new_ids)
            var fmt: String
            var body: String
            if kind == "page":
                fmt = "page"
                var p = Json.parse(content)
                body = p.text(p.get(0, "markdown"))
            elif kind == "mindmap":
                fmt = "mindmap"
                body = map_words(content)
            elif j.text(j.get(n, "contentFormat")) == "fabric" or not _has_nodes(content):
                fmt = "fabric"  # (a version-1 backup's canvas: stored as it came; Personal Note converts it when it next starts)
                body = ""
            else:
                fmt = "json-canvas"
                content = canvas_for_import(content, media_dir, reserved)
                body = reading_text(import_json_canvas(content))
            var title = j.text(j.get(n, "title"), "Untitled note")
            if title == "":
                title = "Untitled note"
            title = first_chars(title, 180)
            var icon = j.text(j.get(n, "icon"))
            var tint = j.number(j.get(n, "iconTint"), 0)
            var old = j.text(j.get(n, "resourceId"))
            var rid = new_ids[old] if old in new_ids and old not in claimed else hex_id("res_")
            claimed[old] = True
            var ps = j.get(n, "pageState")
            var page_state = j.dump(ps) if j.kind(ps) == J_OBJECT else String('{"columns":1,"rows":1}')
            _ = db.run("INSERT INTO notes (resource_id, note_type, title, content, content_format, page_state, icon, icon_tint) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       [rid, kind, title, content, fmt, page_state, icon, String(tint if icon != "" else 0)])
            var id = db.last_id()
            var book = j.get(n, "notebookResourceId")
            if j.kind(book) == J_STRING:
                _ = db.run("UPDATE notes SET notebook_id = ? WHERE id = ?", [String(books[j.text(book)]), String(id)])
            _ = db.run("INSERT INTO note_search (note_id, title, body) VALUES (?, ?, ?)", [String(id), title, body])
            _record(db, "note", rid)
            res.ids.append(id)
            res.notes += 1
        db.commit()
    except e:
        _ = db.rollback_quiet()
        raise e^
    return res^


def import_backup(mut db: Database, media_dir: String, text: String) raises -> PortResult:
    """A backup file's text merged in (portability.import_workspace_backup)."""
    if text.byte_length() > 100 * 1024 * 1024:
        raise Error("Backup is larger than the 100 MB import limit")
    var j = Json.parse(text)
    var v = j.number(j.get(0, "version"), -1)
    if j.kind(0) != J_OBJECT or j.text(j.get(0, "format")) != BACKUP_FORMAT or (v != 1 and v != 2 and v != 3):
        raise Error("Unsupported Personal Note backup format")
    var nbs = j.get(0, "notebooks")
    var ns = j.get(0, "notes")
    if j.kind(nbs) != J_ARRAY or j.kind(ns) != J_ARRAY:
        raise Error("Backup must contain notebooks and notes")
    return import_snapshot(db, media_dir, j, nbs, ns)


# ---------------------------------------------------------------- the Obsidian vault

def vault_name(value: String, fallback: String) -> String:
    """vault.vault_name: \\ / : * ? " < > | # ^ [ ] and control characters as "-", spaces, dots and dashes trimmed, 100 at most."""
    var out = String("")
    var dash = False
    for c in value.codepoint_slices():
        var s = String(c)
        var b = s.as_bytes()
        var bad = len(b) == 1 and (Int(b[0]) < 32 or s == "\\" or s == "/" or s == ":" or s == "*" or s == "?" or s == '"' or s == "<" or s == ">" or s == "|" or s == "#" or s == "^" or s == "[" or s == "]")
        if bad:
            if not dash:
                out += "-"
            dash = True
        else:
            out += s
            dash = False
    var cut = first_chars(String(out.strip(" .-")), 100)
    return cut if cut != "" else fallback


def _unique(path: String, mut used: Dict[String, Bool]) -> String:
    var cand = path
    var dot = path.rfind(".")
    var stem = String(path[byte=:dot]) if dot >= 0 else path
    var ext = String(path[byte = dot + 1 :]) if dot >= 0 else String("")
    var k = 2
    while cand.lower() in used:
        cand = stem + " (" + String(k) + ")" + ("." + ext if dot >= 0 else String(""))
        k += 1
    used[cand.lower()] = True
    return cand


def vault_files(mut db: Database, media_dir: String) raises -> FileSet:
    """The workspace as an Obsidian vault (vault.export_vault); notes that couldn't be written are in skipped."""
    var out = FileSet()
    var used = Dict[String, Bool]()
    var q = db.prepare("SELECT notes.id, notes.note_type, notes.title, notes.content, notes.secure, IFNULL(notebooks.name, ?) FROM notes LEFT JOIN notebooks ON notebooks.id = notes.notebook_id ORDER BY notes.id")
    q.bind(1, String(INBOX))
    while q.step():
        var folder = vault_name(q.text(5), "Notebook")
        var title = vault_name(q.text(2), "Note " + String(q.int(0)))
        var kind = q.text(1)
        if q.int(4) != 0:
            out.add_text(_unique(folder + "/" + title + ".md", used), "# " + q.text(2) + "\n\n*Secure note: its words are not part of this export.*\n")
            continue
        if kind == "page":
            var md = String("")
            try:
                var p = Json.parse(q.text(3))
                md = p.text(p.get(0, "markdown"))
            except:
                pass
            out.add_text(_unique(folder + "/" + title + ".md", used), String(md.rstrip("\n")) + "\n")
            continue
        if kind == "mindmap":
            out.add_text(_unique(folder + "/" + title + ".md", used), "# " + q.text(2) + "\n\n" + mindmap_outline(q.text(3)) + "\n")
            continue
        var text = q.text(3)
        try:
            var j = Json.parse(text)
            if j.kind(j.get(0, "nodes")) != J_ARRAY:
                raise Error("not a JSON Canvas")
        except:
            out.skipped.append(q.text(2))
            continue
        out.add_text(_unique(folder + "/" + title + ".canvas", used), canvas_media_files(text, media_dir, out))
    return out^


def _resolve(files: FileSet, folder: String, name: String) -> Int:
    """vault._resolve_attachment: the vault path, then next to the canvas, then a unique file of that name anywhere."""
    for cand in [name, folder + "/" + name if folder != "" else name]:
        var k = files.find(String(cand))
        if k >= 0:
            return k
    var base = String(name[byte = name.rfind("/") + 1 :]).lower()
    var found = -1
    for k in range(len(files.files)):
        var p = files.files[k].path
        if String(p[byte = p.rfind("/") + 1 :]).lower() == base:
            if found >= 0:
                return -1
            found = k
    return found


def _estimate_height(text: String, width: Float64) -> Int:
    """json_canvas.estimate_text_box with the foreign text style (Source Serif 4, 24 px, line height 1.45, padding 8)."""
    var per_line = max(1, Int(floor(width / 12.0)))
    var lines = 0
    for line in text.split("\n"):
        var n = 0
        for _ in String(line).codepoint_slices():
            n += 1
        lines += max(1, Int(ceil(Float64(n) / Float64(per_line))))
    var h = Float64(lines) * 24.0 * 1.45 + 16.0
    return Int(floor(h + 0.5))


def import_vault(mut db: Database, media_dir: String, files: FileSet) raises -> PortResult:
    """A vault's .canvas and .md files as new canvas notes in new notebooks, one a folder (vault.import_vault_files)."""
    var paths = List[String]()
    for ref f in files.files:
        paths.append(f.path)
    sort(paths)
    var books = List[String]()
    var nb_json = String("")
    var notes_json = String("")
    var skipped = List[String]()
    var count = 0
    for path in paths:
        var low = path.lower()
        var is_canvas = low.endswith(".canvas")
        if not is_canvas and not low.endswith(".md"):
            continue
        var slash = path.rfind("/")
        var folder = String(path[byte=:slash]) if slash > 0 else String("")
        var stem = String(path[byte = slash + 1 : path.rfind(".")])
        var f = files.files[files.find(path)].copy()
        if not f.is_utf8():
            skipped.append(path)
            continue
        var text = f.text()
        var canvas: String
        if is_canvas:
            try:
                var j = Json.parse(text)
                if j.kind(0) != J_OBJECT:
                    raise Error("not an object")
            except:
                skipped.append(path)
                continue
            # (pictures by their vault path, as data URLs: canvas_for_import keeps them in the media folder)
            var ms = members(text, 0, text.byte_length())
            var n = find_member(ms, "nodes")
            var edits = List[Tuple[Int, Int, String]]()
            if n >= 0 and text.as_bytes()[ms[n].start] == UInt8(ord("[")):
                for s in elements(text, ms[n].start, ms[n].end):
                    if _string_at(text, _member_value(text, s.start, s.end, "type")) != "file":
                        continue
                    var fv = _member_value(text, s.start, s.end, "file")
                    var name = _string_at(text, fv)
                    var clean = String(name.split("#")[0])
                    var ext = ext_of_suffix(String(clean[byte = clean.rfind(".") + 1 :]))
                    if ext == "" or name.startswith("data:"):
                        continue
                    var at = _resolve(files, folder, clean)
                    if at >= 0:
                        edits.append((fv[0], fv[1], json_string(data_url(files.files[at].data, ext))))
            canvas = _replace_spans(text, edits^)
        else:
            canvas = '{"nodes":[{"id":"markdown","type":"text","text":' + json_string(text) + ',"x":72,"y":80,"width":716,"height":' + String(_estimate_height(text, 716)) + '}],"edges":[]}'
        var key = folder if folder != "" else String(DEFAULT_NOTEBOOK)
        if key not in books:
            books.append(key)
            var cut = first_chars(folder.replace("/", " / ") if folder != "" else String(DEFAULT_NOTEBOOK), 80)
            nb_json += ("," if nb_json != "" else "") + '{"resourceId":' + json_string(key) + ',"name":' + json_string(cut) + "}"
        var title = stem if stem != "" else String("Untitled note")
        notes_json += ("," if notes_json != "" else "") + '{"notebookResourceId":' + json_string(key) + ',"noteType":"canvas","title":' + json_string(title) + ',"content":' + canvas + ',"pageState":{"columns":1,"rows":1}}'
        count += 1
    if count == 0:
        raise Error("No .canvas or .md files found")
    var j = Json.parse('{"notebooks":[' + nb_json + '],"notes":[' + notes_json + "]}")
    var res = import_snapshot(db, media_dir, j, j.get(0, "notebooks"), j.get(0, "notes"))
    res.skipped = skipped^
    for s in files.skipped:
        res.skipped.append(s)
    return res^


def one_file_set(path: String) raises -> FileSet:
    """One .canvas or .md file, opened by itself, as a vault of one: a .canvas's pictures, named by vault paths as Obsidian
    names them, looked for from the file's folder up through its parents (the vault's root is one of them; 8 levels at most),
    so a canvas opened from inside a vault keeps its pictures. Only safe relative names, only picture types, 20 MB at most."""
    var out = FileSet()
    var slash = path.rfind("/")
    var name = String(path[byte = slash + 1 :])
    var dir = String(path[byte=:slash]) if slash > 0 else String(".")
    var bytes: List[UInt8]
    with open(path, "r") as f:
        bytes = f.read_bytes()
    out.add(name, bytes.copy())
    if not name.lower().endswith(".canvas"):
        return out^
    var text = String(from_utf8_lossy=Span(bytes))
    try:
        var j = Json.parse(text)
        var nodes = j.get(0, "nodes")
        for k in range(j.size(nodes)):
            var n = j.at(nodes, k)
            if j.text(j.get(n, "type")) != "file":
                continue
            var ref_name = String(j.text(j.get(n, "file")).split("#")[0])
            var rel = safe_relative(ref_name)
            if rel == "" or ext_of_suffix(String(rel[byte = rel.rfind(".") + 1 :])) == "" or out.find(rel) >= 0:
                continue
            var up = dir
            for _ in range(8):
                if file_exists(up + "/" + rel):
                    var data: List[UInt8]
                    with open(up + "/" + rel, "r") as f:
                        data = f.read_bytes()
                    if len(data) <= MAX_MEDIA_BYTES:
                        out.add(rel, data^)
                    break
                var s2 = up.rfind("/")
                if s2 <= 0:
                    break
                var parent = String(up[byte=:s2])
                up = parent^
    except:
        pass
    return out^
