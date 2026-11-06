# consoled's store: the Python daemon's SQLite file (~/.mxc/mst.db), its schema and its rules (mxconsole/store.py,
# keys.py), through mojoui.sqlite. Replies that are rows come out of SQLite as JSON (json_object, json_group_array).

from mojoui.sqlite import Database
from mojoui.json import json_string


# The Python daemon's schema (mxconsole store.py, pulls.py, bench.py, port_auto.py), created when missing: a first run
# has no store yet (goal 55 M0), and an existing ~/.mxc/mst.db is left as it is (IF NOT EXISTS; no ALTERs).
comptime SCHEMA = """
CREATE TABLE IF NOT EXISTS models (name TEXT PRIMARY KEY, repo_id TEXT NOT NULL, revision TEXT NOT NULL, source TEXT NOT NULL,
    architecture TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, keep_alive INTEGER NOT NULL DEFAULT 300, weights_path TEXT,
    custom_arch_path TEXT, kind TEXT NOT NULL DEFAULT 'chat', created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS labels (name TEXT PRIMARY KEY, position INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS model_labels (model TEXT NOT NULL, label TEXT NOT NULL, PRIMARY KEY (model, label));
CREATE INDEX IF NOT EXISTS model_labels_label ON model_labels (label);
CREATE TABLE IF NOT EXISTS requests (id INTEGER PRIMARY KEY, ts REAL NOT NULL, app TEXT, model TEXT, route TEXT NOT NULL,
    status INTEGER NOT NULL, prompt_tokens INTEGER, completion_tokens INTEGER, ttft_ms REAL, duration_ms REAL NOT NULL,
    estimated INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS requests_ts ON requests (ts);
CREATE TABLE IF NOT EXISTS keys (app TEXT PRIMARY KEY, prefix TEXT NOT NULL, key_hash TEXT NOT NULL UNIQUE, created_at REAL NOT NULL,
    last_used_at REAL, revoked_at REAL);
CREATE TABLE IF NOT EXISTS pulls (id INTEGER PRIMARY KEY, ref TEXT NOT NULL, name TEXT, repo_id TEXT, status TEXT NOT NULL,
    step TEXT NOT NULL, message TEXT NOT NULL DEFAULT '', hint TEXT, error_kind TEXT, started_at REAL NOT NULL, finished_at REAL,
    total_bytes INTEGER NOT NULL DEFAULT 0, done_bytes INTEGER NOT NULL DEFAULT 0, speed REAL NOT NULL DEFAULT 0,
    files TEXT NOT NULL DEFAULT '[]', details TEXT NOT NULL DEFAULT '{}', model TEXT);
CREATE TABLE IF NOT EXISTS bench_runs (id INTEGER PRIMARY KEY, started_at REAL NOT NULL, finished_at REAL, status TEXT NOT NULL,
    runs INTEGER NOT NULL, max_tokens INTEGER NOT NULL, prompt_tokens INTEGER NOT NULL, models TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS bench_results (id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, model TEXT NOT NULL, status TEXT NOT NULL,
    error TEXT, load_seconds REAL, runs_ok INTEGER NOT NULL, errors INTEGER NOT NULL, decode_tps REAL, prefill_tps REAL,
    ttft_p50_ms REAL, ttft_p95_ms REAL, duration_ms REAL, total_ms REAL, prompt_tokens INTEGER, completion_tokens INTEGER,
    estimated INTEGER NOT NULL DEFAULT 0, prompt_estimated INTEGER NOT NULL DEFAULT 0, completion_estimated INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS bench_results_run ON bench_results (run_id);
CREATE TABLE IF NOT EXISTS bench_samples (id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, model TEXT NOT NULL, idx INTEGER NOT NULL,
    ttft_ms REAL, duration_ms REAL, prompt_tokens INTEGER, completion_tokens INTEGER, decode_tps REAL, prefill_tps REAL, error TEXT);
CREATE INDEX IF NOT EXISTS bench_samples_run ON bench_samples (run_id);
CREATE TABLE IF NOT EXISTS ports (id INTEGER PRIMARY KEY, ref TEXT NOT NULL, name TEXT, repo_id TEXT, status TEXT NOT NULL,
    stage TEXT NOT NULL, message TEXT NOT NULL DEFAULT '', started_at REAL NOT NULL, finished_at REAL,
    max_attempts INTEGER NOT NULL DEFAULT 3, stages TEXT NOT NULL DEFAULT '[]', model TEXT, procs TEXT);
"""


@fieldwise_init
struct LabelProblem(Copyable, Movable):
    var code: String  # "" when it went through
    var message: String

    @staticmethod
    def none() -> LabelProblem:
        return LabelProblem("", "")


def label_name_problem(name: String) -> LabelProblem:
    """kinds.py check_label: lower-case letters, digits and hyphens, up to 40, not starting or ending with a hyphen."""
    var ok = name.byte_length() >= 1 and name.byte_length() <= 40
    var b = name.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        var alnum = (c >= 97 and c <= 122) or (c >= 48 and c <= 57)
        if not (alnum or (c == 45 and i > 0 and i < len(b) - 1)):
            ok = False
    if ok:
        return LabelProblem.none()
    return LabelProblem("invalid_label", "label names are lower-case letters, digits and hyphens, up to 40 characters (like `work` or `my-label`); got " + json_string(name).replace('"', "'"))


struct Store(Movable):
    var db: Database

    def __init__(out self, path: String) raises:
        self.db = Database(path)
        self.db.exec("PRAGMA journal_mode=WAL")
        self.db.exec(SCHEMA)

    # labels ---------------------------------------------------------------------------------------------------------

    def labels_json(self) raises -> String:
        return self.db.one_text("""SELECT coalesce(json_group_array(json_object('name', name, 'position', position, 'count', n)), '[]') FROM (
            SELECT l.name, l.position, COUNT(x.name) AS n FROM labels l
            LEFT JOIN model_labels m ON m.label = l.name LEFT JOIN models x ON x.name = m.model
            GROUP BY l.name ORDER BY l.position)""")

    def label_exists(self, name: String) raises -> Bool:
        return self.db.one_text("SELECT 1 FROM labels WHERE name = ?", [name]) == "1"

    def model_exists(self, name: String) raises -> Bool:
        return self.db.one_text("SELECT 1 FROM models WHERE name = ?", [name]) == "1"

    def _make_label(self, name: String) raises:
        _ = self.db.run("INSERT INTO labels (name, position) VALUES (?, (SELECT coalesce(MAX(position) + 1, 0) FROM labels))", [name])

    def create_label(self, name: String) raises -> LabelProblem:
        var p = label_name_problem(name)
        if p.code != "":
            return p^
        self.db.begin()
        if self.label_exists(name):
            self.db.rollback()
            return LabelProblem("label_exists", "a label named " + name + " already exists")
        self._make_label(name)
        self.db.commit()
        return LabelProblem.none()

    def rename_label(self, old: String, new: String) raises -> LabelProblem:
        var p = label_name_problem(new)
        if p.code != "":
            return p^
        self.db.begin()
        if not self.label_exists(old):
            self.db.rollback()
            return LabelProblem("label_not_found", "no label named " + old + ". See: mxc labels")
        if new != old and self.label_exists(new):
            self.db.rollback()
            return LabelProblem("label_exists", "a label named " + new + " already exists")
        _ = self.db.run("UPDATE labels SET name = ? WHERE name = ?", [new, old])
        _ = self.db.run("UPDATE model_labels SET label = ? WHERE label = ?", [new, old])
        self.db.commit()
        return LabelProblem.none()

    def reorder_labels(self, names: List[String]) raises -> LabelProblem:
        self.db.begin()
        var have = self.db.one_text("SELECT coalesce(json_group_array(name), '[]') FROM (SELECT name FROM labels ORDER BY name)")
        var sorted_names = names.copy()
        sort(sorted_names)
        var want = String("[")
        for i in range(len(sorted_names)):
            want += ("," if i > 0 else "") + json_string(sorted_names[i])
        want += "]"
        if have != want:
            self.db.rollback()
            return LabelProblem("invalid_order", "send every label exactly once to reorder them")
        for i in range(len(names)):
            _ = self.db.run("UPDATE labels SET position = ? WHERE name = ?", [String(i), names[i]])
        self.db.commit()
        return LabelProblem.none()

    def delete_label(self, name: String) raises -> LabelProblem:
        self.db.begin()
        if not self.label_exists(name):
            self.db.rollback()
            return LabelProblem("label_not_found", "no label named " + name + ". See: mxc labels")
        _ = self.db.run("DELETE FROM model_labels WHERE label = ?", [name])
        _ = self.db.run("DELETE FROM labels WHERE name = ?", [name])
        self.db.commit()
        return LabelProblem.none()

    def _missing_model(self, models: List[String]) raises -> String:
        for m in models:
            if not self.model_exists(m):
                return m
        return ""

    def add_labels(self, models: List[String], label: String) raises -> LabelProblem:
        """The label (made when new) on every model; all or nothing."""
        var p = label_name_problem(label)
        if p.code != "":
            return p^
        self.db.begin()
        var gone = self._missing_model(models)
        if gone != "":
            self.db.rollback()
            return LabelProblem("model_not_found", "no model named " + gone + ". See: mxc list")
        if not self.label_exists(label):
            self._make_label(label)
        for m in models:
            _ = self.db.run("INSERT OR IGNORE INTO model_labels (model, label) VALUES (?, ?)", [m, label])
        self.db.commit()
        return LabelProblem.none()

    def remove_labels(self, models: List[String], label: String) raises -> LabelProblem:
        self.db.begin()
        var gone = self._missing_model(models)
        if gone != "":
            self.db.rollback()
            return LabelProblem("model_not_found", "no model named " + gone + ". See: mxc list")
        if not self.label_exists(label):
            self.db.rollback()
            return LabelProblem("label_not_found", "no label named " + label + ". See: mxc labels")
        for m in models:
            _ = self.db.run("DELETE FROM model_labels WHERE model = ? AND label = ?", [m, label])
        self.db.commit()
        return LabelProblem.none()

    # keys -----------------------------------------------------------------------------------------------------------

    def keys_json(self) raises -> String:
        """Every app's key but omxconsole's own (`_`-names), by app (keys.py list_keys)."""
        return self.db.one_text("""SELECT coalesce(json_group_array(json_object('app', app, 'prefix', prefix, 'created_at', created_at,
            'last_used_at', last_used_at, 'revoked_at', revoked_at, 'status', CASE WHEN revoked_at IS NULL THEN 'active' ELSE 'revoked' END)), '[]')
            FROM (SELECT * FROM keys WHERE app NOT LIKE '\\_%' ESCAPE '\\' ORDER BY app)""")

    def key_exists(self, app: String) raises -> Bool:
        return self.db.one_text("SELECT 1 FROM keys WHERE app = ?", [app]) == "1"

    def key_active(self, app: String) raises -> Bool:
        return self.db.one_text("SELECT 1 FROM keys WHERE app = ? AND revoked_at IS NULL", [app]) == "1"

    def put_key(self, app: String, secret: String, key_hash: String, now: Float64) raises:
        """Create or replace the app's key (rotate brings a revoked app back): keys.py create_key's upsert."""
        _ = self.db.run("""INSERT INTO keys (app, prefix, key_hash, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(app) DO UPDATE SET prefix=excluded.prefix, key_hash=excluded.key_hash,
            created_at=excluded.created_at, last_used_at=NULL, revoked_at=NULL""", [app, String(secret[byte = : 12]), key_hash, String(now)])

    def revoke_key(self, app: String, now: Float64) raises -> Bool:
        return self.db.run("UPDATE keys SET revoked_at = ? WHERE app = ? AND revoked_at IS NULL", [String(now), app]) > 0

    def app_for_key(self, secret: String, key_hash: String, now: Float64) raises -> String:
        """The app a /v1 key belongs to ("" when none or revoked); stamps last_used_at."""
        var app = self.db.one_text("SELECT app FROM keys WHERE key_hash = ? AND revoked_at IS NULL", [key_hash])
        if app != "":  # (gateway.py: written when unset or a minute old, not on every call)
            _ = self.db.run("UPDATE keys SET last_used_at = ? WHERE app = ? AND (last_used_at IS NULL OR last_used_at <= ? - 60)", [String(now), app, String(now)])
        return app

    # the request log (gateway.py) -----------------------------------------------------------------------------------

    def log_request(self, ts: Float64, app: String, model: String, route: String, status: Int, prompt: Int, completion: Int, ttft_ms: Float64, duration_ms: Float64, estimated: Bool) raises:
        var q = self.db.prepare("INSERT INTO requests (ts, app, model, route, status, prompt_tokens, completion_tokens, ttft_ms, duration_ms, estimated) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        q.bind(1, ts)
        if app == "":
            q.bind_null(2)
        else:
            q.bind(2, app)
        if model == "":
            q.bind_null(3)
        else:
            q.bind(3, model)
        q.bind(4, route)
        q.bind(5, status)
        if prompt < 0:
            q.bind_null(6)
        else:
            q.bind(6, prompt)
        if completion < 0:
            q.bind_null(7)
        else:
            q.bind(7, completion)
        if ttft_ms < 0:
            q.bind_null(8)
        else:
            q.bind(8, ttft_ms)
        q.bind(9, duration_ms)
        q.bind(10, 1 if estimated else 0)
        q.run()
