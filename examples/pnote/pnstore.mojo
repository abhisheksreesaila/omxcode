# Personal Note's notes file (goal 79): its schema, made when the app starts with none (Personal Note's own app_schema.py and the
# columns it adds, so the web app opens the file as its own), and the changes to whole notes as its API makes them
# (services.py create_note, move_note, delete_note): the row, the search index and the change log in one transaction.

from mojoui.sqlite import Database
from mojoui.docstore import RowNew, RowSave, Followup, SqlArg, NewResult, SaveResult, NEW_ROW, text_arg, int_arg, new_row, drop_row, save_row
from mojoui.crypto import random_bytes
from mojoui.files import private_dir, data_dir

comptime EMPTY_CANVAS = '{"nodes":[],"edges":[],"pn":{"schemaVersion":1,"page":{"columns":1,"rows":1},"grid":{"width":860,"height":1080}}}'
comptime EMPTY_PAGE = '{"version":1,"markdown":"","ink":{"marks":[],"drawings":[]}}'
comptime EMPTY_MAP = '{"version":1,"title":"Untitled mind map","rootId":"root","defaultPresentation":"box","nodes":[{"id":"root","parentId":null,"text":"Central idea","x":0,"y":0,"color":"#ef684b","fontSize":28,"bold":true,"font":"hand","presentation":"box","curve":78}]}'

comptime SCHEMA = """
CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
    resource_id TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    note_type TEXT NOT NULL DEFAULT 'canvas',
    content_format TEXT NOT NULL DEFAULT 'fabric',
  title TEXT NOT NULL DEFAULT 'Untitled note',
  content TEXT NOT NULL DEFAULT '{"objects":[]}',
  page_state TEXT NOT NULL DEFAULT '{"columns":1,"rows":1}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS notebooks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
    resource_id TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
  name TEXT NOT NULL,
  color TEXT NOT NULL DEFAULT '#B86B4B',
  category TEXT NOT NULL DEFAULT 'projects',
  icon TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE VIRTUAL TABLE IF NOT EXISTS note_search USING fts5(
    note_id UNINDEXED,
    title,
    body,
    tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TABLE IF NOT EXISTS workspace_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    workspace_id TEXT NOT NULL UNIQUE,
    sequence INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS workspace_changes (
    sequence INTEGER PRIMARY KEY,
    resource_kind TEXT NOT NULL,
    resource_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    change_type TEXT NOT NULL CHECK (change_type IN ('created', 'updated', 'deleted')),
    occurred_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS agent_activity (
    agent TEXT PRIMARY KEY,
    note_id INTEGER,
    action TEXT NOT NULL CHECK (action IN ('reading', 'writing')),
    at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS agent_edits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    agent TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'applied' CHECK (state IN ('applied', 'undone')),
    after_revision INTEGER NOT NULL,
    changed TEXT NOT NULL,
    before_content TEXT NOT NULL,
    before_format TEXT NOT NULL,
    before_page_state TEXT NOT NULL,
    after_content TEXT NOT NULL,
    after_format TEXT NOT NULL,
    after_page_state TEXT NOT NULL,
    at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS agent_edits_note ON agent_edits (note_id, after_revision);
CREATE TABLE IF NOT EXISTS secure_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    key_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('keychain', 'passphrase', 'recovery')),
    version INTEGER NOT NULL DEFAULT 1,
    salt TEXT,
    params TEXT,
    wrapped TEXT NOT NULL,
    is_primary INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS note_embeddings (
    note_id INTEGER PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL,
    model TEXT NOT NULL,
    dims INTEGER NOT NULL,
    vector BLOB NOT NULL,
    text_hash TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS mindmap_reminders (
    note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    node_id TEXT NOT NULL,
    label TEXT NOT NULL,
    due TEXT NOT NULL,
    fired INTEGER NOT NULL DEFAULT 0,
    done INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (note_id, node_id)
);
CREATE TABLE IF NOT EXISTS x_posts (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    post_id TEXT NOT NULL UNIQUE,
    note_id INTEGER REFERENCES notes(id) ON DELETE SET NULL
);
CREATE TABLE IF NOT EXISTS x_notebook (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    notebook_id INTEGER REFERENCES notebooks(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_workspace_changes_resource
ON workspace_changes(resource_kind, resource_id, sequence);
ALTER TABLE notes ADD COLUMN notebook_id INTEGER REFERENCES notebooks(id);
ALTER TABLE notes ADD COLUMN secure INTEGER NOT NULL DEFAULT 0;
ALTER TABLE notes ADD COLUMN secure_key_id TEXT;
ALTER TABLE notes ADD COLUMN seal_id TEXT;
ALTER TABLE notes ADD COLUMN sealed TEXT;
ALTER TABLE notes ADD COLUMN icon TEXT NOT NULL DEFAULT '';
ALTER TABLE notes ADD COLUMN icon_tint INTEGER NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX IF NOT EXISTS idx_notes_resource_id ON notes(resource_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_notebooks_resource_id ON notebooks(resource_id);
"""


def hex_id(prefix: String) raises -> String:
    """prefix and 32 hex digits from the OS's randomness (uuid4().hex, as Personal Note names its rows)."""
    var out = prefix
    var b = random_bytes(16)
    for i in range(16):
        var v = Int(b[i])
        if i == 6:
            v = (v & 0x0F) | 0x40
        elif i == 8:
            v = (v & 0x3F) | 0x80
        out += String("0123456789abcdef")[byte=v >> 4 : (v >> 4) + 1]
        out += String("0123456789abcdef")[byte=v & 15 : (v & 15) + 1]
    return out


def has_notes(db: Database) -> Bool:
    """The file has Personal Note's tables."""
    try:
        return db.count("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'notes'") > 0
    except:
        return False


def make_notes_file(mut db: Database) raises:
    """Personal Note's tables in an empty file, with its first notebook ("My Notes") and the change log's rows, as a
    brand-new file of its own starts. A file that has them already is left as it is."""
    if has_notes(db):
        return
    if db.count("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'") > 0:  # (some other program's database: nothing is added to it)
        raise Error("this isn't a notes file")
    db.exec("PRAGMA journal_mode = WAL")
    db.begin()
    try:
        db.exec(SCHEMA)
        _ = db.run("INSERT INTO workspace_state (id, workspace_id) VALUES (1, ?)", [hex_id("ws_")])
        var res = hex_id("res_")
        _ = db.run("INSERT INTO notebooks (resource_id, name, color) VALUES (?, 'My Notes', '#B86B4B')", [res])
        _ = db.run("UPDATE workspace_state SET sequence = sequence + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1", List[String]())
        _ = db.run("INSERT INTO workspace_changes (sequence, resource_kind, resource_id, revision, change_type) SELECT sequence, 'notebook', ?, 1, 'created' FROM workspace_state WHERE id = 1", [res])
        db.commit()
    except e:
        _ = db.rollback_quiet()
        raise e^


def changed(kind: String, id: Int, what: String, table: String = "notes") -> List[Followup]:
    """record_change: the workspace's sequence moves on and a row for this revision of the resource (read from its own row:
    id, or NEW_ROW)."""
    var out = List[Followup]()
    out.append(Followup("UPDATE workspace_state SET sequence = sequence + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1", List[SqlArg]()))
    out.append(Followup("INSERT INTO workspace_changes (sequence, resource_kind, resource_id, revision, change_type) SELECT (SELECT sequence FROM workspace_state WHERE id = 1), '" + kind
                        + "', resource_id, revision" + (" + 1" if what == "deleted" else "") + ", '" + what + "' FROM " + table + " WHERE id = ?", [int_arg(id)]))
    return out^


def default_notes_file() -> String:
    """Where a person's notes are when the app is told nothing else: the app's own data folder, readable by them alone
    (made when missing). Never Personal Note's own file: two apps on one file is a choice a person makes (PNOTE_DB)."""
    var dir = data_dir("pnote")
    _ = private_dir(dir)
    return dir + "/notes.db"


def empty_content(kind: String) -> String:
    return String(EMPTY_PAGE) if kind == "page" else (String(EMPTY_MAP) if kind == "mindmap" else String(EMPTY_CANVAS))


def make_note(mut db: Database, kind: String, title: String, notebook: Int, content: String = "", body: String = "") -> NewResult:
    """A new note (services.create_note): kind page | canvas | mindmap, in a notebook (0: the Inbox). content "": empty."""
    try:
        var s = RowNew("notes")
        s.set("resource_id", text_arg(hex_id("res_")))
        s.set("note_type", text_arg(kind))
        s.set("title", text_arg(title if title != "" else String("Untitled note")))
        s.set("content", text_arg(content if content != "" else empty_content(kind)))
        s.set("content_format", text_arg("page" if kind == "page" else ("mindmap" if kind == "mindmap" else "json-canvas")))
        s.then("UPDATE notes SET notebook_id = (SELECT id FROM notebooks WHERE id = ?) WHERE id = ?", [int_arg(notebook), int_arg(NEW_ROW)])
        s.then("INSERT INTO note_search (note_id, title, body) SELECT id, title, ? FROM notes WHERE id = ?",
               [text_arg(body if content != "" else (String("Central idea") if kind == "mindmap" else String(""))), int_arg(NEW_ROW)])
        for f in changed("note", NEW_ROW, "created"):
            s.after.append(f.copy())
        return new_row(db, s)
    except e:
        return NewResult(0, String(e))


def drop_note(mut db: Database, id: Int) -> String:
    """A note and its index rows deleted (services.delete_note); "" or why not."""
    var before = changed("note", id, "deleted")
    before.append(Followup("DELETE FROM note_search WHERE note_id = ?", [int_arg(id)]))
    for table in ["note_embeddings", "mindmap_reminders", "agent_edits"]:
        before.append(Followup("DELETE FROM " + String(table) + " WHERE note_id = ?", [int_arg(id)]))
    before.append(Followup("UPDATE x_posts SET note_id = NULL WHERE note_id = ?", [int_arg(id)]))
    return drop_row(db, "notes", "id", id, before)


def make_notebook(mut db: Database, name: String, category: String) -> NewResult:
    """A new notebook on a shelf (services.create_notebook)."""
    try:
        var s = RowNew("notebooks")
        s.set("resource_id", text_arg(hex_id("res_")))
        s.set("name", text_arg(name if name != "" else String("Untitled notebook")))
        s.set("color", text_arg("#B86B4B"))
        s.set("category", text_arg(category))
        for f in changed("notebook", NEW_ROW, "created", "notebooks"):
            s.after.append(f.copy())
        return new_row(db, s)
    except e:
        return NewResult(0, String(e))


def file_note(mut db: Database, id: Int, revision: Int, notebook: Int) -> SaveResult:
    """A note filed into a notebook, or back to the Inbox (0) (services.move_note), on the revision the caller has."""
    var s = RowSave("notes", "id", id, "revision", revision)
    s.stamp("updated_at")
    s.read_back("updated_at")
    s.then("UPDATE notes SET notebook_id = (SELECT id FROM notebooks WHERE id = ?) WHERE id = ?", [int_arg(notebook), int_arg(id)])
    for f in changed("note", id, "updated"):
        s.after.append(f.copy())
    return save_row(db, s)
