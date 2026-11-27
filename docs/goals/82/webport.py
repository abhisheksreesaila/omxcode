"""Goal 82 M3: the web app's own import and export, run in its own Python on scratch files (never its real notes, never a file
of its repo written: -B -I). Commands (one per run, JSON on stdout):
  seed <dir>                      a workspace made through the web's NoteService: notebooks, a page with a link, a canvas with
                                  text, a sticky, a picture and an edge, a mind map; its notes.db and media/ in <dir>
  backup <db> <out.json>          portability.workspace_backup
  vault <db> <out.zip>            vault.export_vault_archive
  import-backup <db> <in.json>    portability.import_workspace_backup
  import-vault <db> <in.zip|dir>  vault.import_vault_archive / import_vault_directory
  norm <db>                       every note as the web reads it, without what an import renames (ids): for comparing
  rows <db>                       every note's id, revision, updated_at and content's sha256 (import never changes these)
"""
import hashlib, json, os, re, sys
WEB = os.path.expanduser("~/Projects/personalnotev2")
sys.path.insert(0, WEB)
sys.dont_write_bytecode = True
from services import NoteService  # noqa: E402
from portability import workspace_backup, import_workspace_backup  # noqa: E402
from vault import export_vault_archive, import_vault_archive, import_vault_directory  # noqa: E402
from page_note import normalize_page_document  # noqa: E402

PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000020000000208060000007f8a5f2c0000001749444154789c63f8cf0004ff3330fc6760f8cfc0f01f0011f703fe6f6b0e5a0000000049454e44ae426082")


def svc(db):
    return NoteService(db)


def seed(d):
    os.makedirs(d, exist_ok=True)
    s = svc(os.path.join(d, "notes.db"))
    travel = s.create_notebook({"name": "Travel", "category": "projects"})
    work = s.create_notebook({"name": "Work / Ideas", "category": "projects"})
    pic = s.media.put_bytes(PNG, "png")
    page2 = s.create_note({"noteType": "page", "title": "Packing list", "notebookId": travel["id"]})
    s.update_note(page2["id"], {"title": "Packing list", "content": {"version": 1, "markdown": "- passport\n- charger\n- **socks** ünïcode ✓", "ink": {"marks": [], "drawings": []}}, "expectedRevision": 1})
    page = s.create_note({"noteType": "page", "title": "Trip plan", "notebookId": travel["id"]})
    s.update_note(page["id"], {"title": "Trip plan", "content": {"version": 1, "markdown": f"# Lisbon\n\nSee [the list](personal-note://note/{page2['resourceId']}).\n\nDay one: tram 28.", "ink": {"marks": [], "drawings": []}}, "expectedRevision": 1})
    board = s.create_note({"noteType": "canvas", "title": "Board", "notebookId": work["id"]})
    canvas = {"nodes": [
        {"id": "t1", "type": "text", "text": "hello board", "x": 100, "y": 120, "width": 300, "height": 60},
        {"id": "s1", "type": "text", "text": "sticky words", "x": 480, "y": 120, "width": 200, "height": 200, "color": "3", "pn": {"type": "sticky"}},
        {"id": "p1", "type": "file", "file": pic, "x": 100, "y": 400, "width": 120, "height": 120},
    ], "edges": [{"id": "e1", "fromNode": "t1", "toNode": "s1"}]}
    s.update_note(board["id"], {"title": "Board", "content": canvas, "expectedRevision": 1})
    m = s.create_note({"noteType": "mindmap", "title": "Ideas"})
    s.update_note(m["id"], {"title": "Ideas", "content": {"version": 1, "title": "Ideas", "rootId": "root", "nodes": [
        {"id": "root", "parentId": None, "text": "Central idea", "x": 0, "y": 0},
        {"id": "a", "parentId": "root", "text": "north", "x": 200, "y": -80},
        {"id": "b", "parentId": "root", "text": "south", "x": 200, "y": 80},
        {"id": "c", "parentId": "a", "text": "far north", "x": 400, "y": -120}]}, "expectedRevision": 1})
    return {"notes": len(s.list_notes())}


def link_titles(s, text):
    ids = {}
    with s.connection() as c:
        for r in c.execute("SELECT resource_id, title FROM notes"):
            ids[r["resource_id"]] = r["title"]
    return re.sub(r"personal-note://note/(res_[0-9a-f]{32})", lambda m: "note:" + ids.get(m.group(1), "?"), text)


def norm(db):
    s = svc(db)
    out = []
    with s.connection() as c:
        rows = c.execute("SELECT notes.*, IFNULL(notebooks.name, 'Inbox') AS book FROM notes LEFT JOIN notebooks ON notebooks.id = notes.notebook_id ORDER BY notes.id").fetchall()
    for r in rows:
        n = {"title": r["title"], "type": r["note_type"], "notebook": r["book"], "icon": r["icon"]}
        if r["note_type"] == "page":
            n["markdown"] = link_titles(s, normalize_page_document(json.loads(r["content"]))["markdown"])
        elif r["note_type"] == "mindmap":
            d = json.loads(r["content"])
            n["ideas"] = sorted([node.get("id"), node.get("parentId"), node.get("text")] for node in d.get("nodes", []))
        else:
            c = s.snapshot_content(r)  # (the web's own reading: JSON Canvas, pictures inline)
            by_id = {}
            nodes = []
            for node in c.get("nodes", []):
                f = node.get("file") or ""
                if f.startswith("data:image/svg"):
                    continue  # (a derived drawing of ink or a shape: made again from its object by each app)
                if f.startswith("data:"):
                    f = "sha:" + hashlib.sha256(__import__("base64").b64decode(f.split(",", 1)[1])).hexdigest()[:16]
                key = [node.get("type"), node.get("text", ""), round(node.get("x", 0)), round(node.get("y", 0)), round(node.get("width", 0)), round(node.get("height", 0)), node.get("color", ""), f, (node.get("pn") or {}).get("type", "")]
                by_id[node.get("id")] = node.get("text", "") or f
                nodes.append(key)
            n["nodes"] = sorted(nodes, key=json.dumps)
            n["edges"] = sorted([by_id.get(e.get("fromNode")), by_id.get(e.get("toNode"))] for e in c.get("edges", []))
        out.append(n)
    return sorted(out, key=lambda n: (n["notebook"], n["title"], n["type"]))


def rows(db):
    with svc(db).connection() as c:
        return [[r["id"], r["revision"], r["updated_at"], hashlib.sha256(r["content"].encode()).hexdigest()] for r in c.execute("SELECT id, revision, updated_at, content FROM notes ORDER BY id")]


def main():
    cmd, *a = sys.argv[1:]
    if cmd == "seed":
        r = seed(a[0])
    elif cmd == "backup":
        b = workspace_backup(svc(a[0]))
        open(a[1], "w").write(json.dumps(b, ensure_ascii=False))
        r = {"notes": len(b["notes"])}
    elif cmd == "vault":
        open(a[1], "wb").write(export_vault_archive(svc(a[0])))
        r = {"ok": True}
    elif cmd == "import-backup":
        r = import_workspace_backup(svc(a[0]), json.load(open(a[1])))
    elif cmd == "import-vault":
        r = import_vault_directory(svc(a[0]), a[1]) if os.path.isdir(a[1]) else import_vault_archive(svc(a[0]), open(a[1], "rb").read())
    elif cmd == "norm":
        r = norm(a[0])
    elif cmd == "rows":
        r = rows(a[0])
    print(json.dumps(r, ensure_ascii=False, sort_keys=True))


main()
