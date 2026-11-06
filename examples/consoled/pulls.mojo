# consoled's pulls (goal 55 M2; the Python daemon's pulls.py, same steps and row): POST /admin/pulls starts one on a
# thread of its own: resolve the ref on the Hub (mojoui.hf), check MAX runs its architecture (MAX's catalog, cached in
# MXC_HOME/max_catalog.json from `max list --json`), download its config, tokenizer and safetensors (only the shards an
# index names) into MXC_HOME/models/<owner>--<name>/, check their sizes, register the model. The worker writes the
# pulls row at each step; the file being downloaded counts in a Transfer the daemon reads to show live progress
# (Pulls.refresh). A cancel keeps nothing it made: a new model's folder goes; a model already registered (a re-pull)
# keeps its files, only this pull's unfinished .part files go; no model is registered.

from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc
from std.os import makedirs
from std.os.path import exists, isdir, getsize
from mojoui.hf import hub_repo, hub_download, HubRepo, HubFile
from mojoui.http_flare import Transfer
from mojoui.serve import spawn
from mojoui.json import Json, json_string
from mojoui.files import remove_tree
from mojoui.process import output
from mojoui.clock import wall_seconds, now_ns
from store import Store
from search import CURATED, CURATED_REPOS
from learn import read_text

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime W_FILE = 0  # the index of the file downloading now
comptime W_ENDED = 1  # 1 once the worker wrote its last row: it touches nothing after
comptime TOKENIZER_FILES = ["tokenizer.json", "tokenizer.model", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json",
                            "vocab.json", "vocab.txt", "merges.txt", "spiece.model", "sentencepiece.bpe.model", "generation_config.json", "chat_template.jinja"]


def _w(words: Int, k: Int) -> _P:
    return _P(unsafe_from_address=words + 8 * k)


def ref_problem(asked: String) -> String:
    """"" when `asked` is a curated name or owner/name we'd pass on (pulls.py REF_RE)."""
    var b = asked.as_bytes()
    if len(b) == 0 or len(b) > 193:
        return "A model reference is a curated name or owner/name from Hugging Face."
    var slashes = 0
    for i in range(len(b)):
        var c = Int(b[i])
        var ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 46 or c == 95 or c == 45
        if c == 47:
            slashes += 1
            ok = i > 0 and i < len(b) - 1
        if not ok or slashes > 1 or (i == 0 and not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122))):
            return "`" + asked + "` isn't a model reference: use a curated name or owner/name from Hugging Face."
    return ""


def repo_of(asked: String) -> String:
    for i in range(len(materialize[CURATED]())):
        if String(materialize[CURATED]()[i]) == asked.lower():
            return String(materialize[CURATED_REPOS]()[i])
    return asked


def model_name(asked: String, repo: String) -> String:
    """resolve.py model_name: a curated alias, else the repo's name in lower case."""
    for i in range(len(materialize[CURATED]())):
        if String(materialize[CURATED]()[i]) == asked.lower() or String(materialize[CURATED_REPOS]()[i]).lower() == repo.lower():
            return String(materialize[CURATED]()[i])
    var cut = repo.rfind("/")
    return String(repo[byte = cut + 1 :]).lower()


def folder_of(home: String, repo: String) -> String:
    return home + "/models/" + repo.replace("/", "--")


def wanted(repo: HubRepo, shards: List[String]) -> List[Int]:
    """snapshot_patterns: config, tokenizer files, the shard index, safetensors (only the index's shards, if any)."""
    var out = List[Int]()
    for i in range(len(repo.files)):
        var n = repo.files[i].name
        var keep = n == "config.json" or n.endswith(".safetensors.index.json") or n.startswith("additional_chat_templates/")
        for t in materialize[TOKENIZER_FILES]():
            if n == String(t):
                keep = True
        if n.endswith(".safetensors") and n.find("/") < 0:
            keep = len(shards) == 0 or n in shards
        if keep:
            out.append(i)
    return out^


def catalog(home: String, max_cmd: String, env: List[String], fresh: Bool = False) -> String:
    """MAX's architectures as JSON ({name: {example_repo_ids, supported_encodings}}): MXC_HOME/max_catalog.json (the
    Python daemon's cache, same file and shape), else, or when `fresh`, `max list --json` again. "" if MAX can't say."""
    var path = home + "/max_catalog.json"
    if not fresh and exists(path):
        var cached = read_text(path)
        if cached != "":
            return cached
    var argv = List[String]()
    for part in max_cmd.split(" "):
        if String(part) != "":
            argv.append(String(part))
    argv += ["list", "--json"]
    var text = output(argv, 180_000, env)
    var at = text.find('"architectures"')
    if at < 0:
        return ""
    var start = text.find("{", at)
    var depth = 0
    var in_str = False
    var b = text.as_bytes()
    var i = start
    while i >= 0 and i < len(b):  # (the object after "architectures": balanced braces outside strings)
        var c = Int(b[i])
        if in_str:
            if c == 92:
                i += 1
            elif c == 34:
                in_str = False
        elif c == 34:
            in_str = True
        elif c == 123:
            depth += 1
        elif c == 125:
            depth -= 1
            if depth == 0:
                var arches = String(text[byte = start : i + 1])
                try:
                    _ = Json.parse(arches)
                    with open(path, "w") as f:
                        f.write(arches)
                except:
                    return ""
                return arches^
        i += 1
    return ""


struct PullJob(Movable):
    """What a worker needs, on the heap until it starts (it takes it)."""

    var id: Int
    var asked: String
    var name: String
    var home: String
    var max_cmd: String
    var env: List[String]
    var t: Transfer
    var words: Int

    def __init__(out self, id: Int, asked: String, name: String, home: String, max_cmd: String, var env: List[String], t: Transfer, words: Int):
        self.id = id
        self.asked = asked
        self.name = name
        self.home = home
        self.max_cmd = max_cmd
        self.env = env^
        self.t = t.copy()
        self.words = words


@fieldwise_init
struct Running(Copyable, Movable):
    var id: Int
    var t: Transfer
    var words: Int
    var last_ns: Int
    var last_done: Int
    var speed: Float64


struct Pulls(Movable):
    """The daemon's running pulls: their Transfers and words, freed once their worker ended."""

    var running: List[Running]

    def __init__(out self):
        self.running = List[Running]()

    def start(mut self, store: Store, asked: String, name: String, home: String, max_cmd: String, env: List[String]) raises -> Int:
        """A new pull's id (a running pull of the same ref: that one's id)."""
        var busy = store.db.one_text("SELECT id FROM pulls WHERE status = 'running' AND lower(ref) = lower(?) ORDER BY id DESC LIMIT 1", [asked])
        if busy != "":
            for r in self.running:
                if String(r.id) == busy:
                    return r.id
        _ = store.db.run("INSERT INTO pulls (ref, name, status, step, message, started_at) VALUES (?, ?, 'running', 'resolve', ?, ?)",
                         [asked, name, "looking up " + asked + " on Hugging Face…", String(wall_seconds())])
        var id = Int(atol(store.db.one_text("SELECT last_insert_rowid()")))
        var words = unsafe_alloc[Int64](2)
        words[0] = 0
        words[1] = 0
        var t = Transfer()
        var job = unsafe_alloc[PullJob](1)
        job.unsafe_write(PullJob(id, asked, name, home, max_cmd, env.copy(), t, Int(words)))
        if not spawn[_work](Int(job)):
            _ = store.db.run("UPDATE pulls SET status = 'failed', message = 'no thread for the pull', finished_at = ? WHERE id = ?", [String(wall_seconds()), String(id)])
            job.unsafe_deinit_pointee()  # (no thread: nothing else holds them)
            job.unsafe_free()
            t.free()
            words.unsafe_free()
            return id
        self.running.append(Running(id, t.copy(), Int(words), now_ns(), 0, 0.0))
        return id

    def cancel(self, id: Int) -> Bool:
        for r in self.running:
            if r.id == id:
                r.t.cancel()
                return True
        return False

    def refresh(mut self, store: Store):
        """The running pulls' live progress into their rows (the file now: its Transfer; the speed over ~1 s), and the
        ended ones' Transfers freed. Rows that aren't running any more are never touched (the worker's last word)."""
        var keep = List[Running]()
        for i in range(len(self.running)):
            var r = self.running[i].copy()
            if _A.load(_w(r.words, W_ENDED)) != 0:
                r.t.free()
                _P(unsafe_from_address=r.words).unsafe_free()
                continue
            try:
                var row = store.db.one_text("SELECT files FROM pulls WHERE id = ? AND status = 'running' AND step = 'download'", [String(r.id)])
                if row != "":
                    var j = Json.parse(row)
                    var now_file = Int(_A.load(_w(r.words, W_FILE)))
                    var files = String("[")
                    var done = 0
                    for k in range(j.size(0)):
                        var f = j.at(0, k)
                        var size = j.number(j.get(f, "size"))
                        var d = size if k < now_file else (min(r.t.done(), size) if k == now_file else 0)
                        done += d
                        files += (", " if k > 0 else "") + '{"name": ' + json_string(j.text(j.get(f, "name"))) + ', "size": ' + String(size) + ', "done": ' + String(d) + "}"
                    files += "]"
                    var now = now_ns()
                    if now - r.last_ns >= 1_000_000_000:
                        var inst = Float64(done - r.last_done) / (Float64(now - r.last_ns) / 1e9)
                        r.speed = inst if r.speed == 0 else 0.5 * r.speed + 0.5 * inst
                        r.last_ns = now
                        r.last_done = done
                    _ = store.db.run("UPDATE pulls SET files = ?, done_bytes = ?, speed = ? WHERE id = ? AND status = 'running' AND step = 'download'",
                                     [files, String(done), String(Int(r.speed)), String(r.id)])
                    var resumed = r.t.resumes()  # (a dropped connection picked up again: the person sees why the speed dipped)
                    if resumed > 0:
                        _ = store.db.run("UPDATE pulls SET message = ? WHERE id = ? AND status = 'running' AND step = 'download'",
                                         ["downloading " + String(j.size(0)) + " files… (the connection dropped " + ("once" if resumed == 1 else String(resumed) + " times")
                                          + "; picked up where it stopped)", String(r.id)])
            except:
                pass
            keep.append(r^)
        self.running = keep^


def remove_parts(folder: String):
    """Deletes the unfinished downloads (*.part) under `folder`, nothing else."""
    from std.os import listdir, remove
    try:
        for name in listdir(folder):
            var p = folder + "/" + name
            if isdir(p):
                remove_parts(p)
            elif name.endswith(".part"):
                remove(p)
    except:
        pass


def _set(store: Store, id: Int, step: String, message: String, detail_step: String = "", detail: String = "") raises:
    _ = store.db.run("UPDATE pulls SET step = ?, message = ? WHERE id = ?", [step, message, String(id)])
    if detail_step != "":
        _ = store.db.run("UPDATE pulls SET details = json_set(details, '$.' || ?, ?) WHERE id = ?", [detail_step, detail, String(id)])


def _finish(store: Store, id: Int, status: String, message: String, error_kind: String = "", hint: String = "") raises:
    _ = store.db.run("UPDATE pulls SET status = ?, message = ?, error_kind = nullif(?, ''), hint = nullif(?, ''), finished_at = ?, speed = 0 WHERE id = ?",
                     [status, message, error_kind, hint, String(wall_seconds()), String(id)])


def kind_of(arch: String) -> String:
    """chat, or embedding for an encoder (kinds.py: BERT-style models, no causal LM head)."""
    if arch.endswith("ForCausalLM") or arch.endswith("ForConditionalGeneration"):
        return "chat"
    if arch.startswith("Bert") or arch.startswith("XLMRoberta") or arch.endswith("Model"):
        return "embedding"
    return "chat"


def _work(addr: Int):
    var p = Pointer[PullJob, MutUntrackedOrigin](unsafe_from_address=addr)
    var words = p[].words
    try:
        var store = Store(p[].home + "/mst.db")
        try:
            _ = _pipeline(store, p[])
        except e:
            var why = String(e)
            var folder = folder_of(p[].home, repo_of(p[].asked))
            if p[].t.cancelled() or why == "cancelled":
                if isdir(folder):
                    if store.db.one_text("SELECT 1 FROM models WHERE weights_path = ? LIMIT 1", [folder]) == "1":
                        remove_parts(folder)  # (a re-pull of a registered model: its weights stay)
                    else:
                        remove_tree(folder)
                _finish(store, p[].id, "cancelled", "Cancelled; nothing was kept.")
            elif why.startswith("unsupported: "):
                _finish(store, p[].id, "unsupported", String(why[byte = 13 :]), "unsupported")
            else:
                var kind = "gated" if why.find("needs access") >= 0 else ("not_found" if why.find("no such repo") >= 0 else "error")
                _finish(store, p[].id, "failed", why, kind, "Pull again to resume the files already downloaded." if kind == "error" else "")
    except e:  # (the store wouldn't open, or writing the outcome failed: try once more so the row never stays running)
        try:
            _finish(Store(p[].home + "/mst.db"), p[].id, "failed", "The pull stopped: " + String(e), "error")
        except:
            pass
    p.unsafe_deinit_pointee()
    p.unsafe_free()
    _A.store(_w(words, W_ENDED), 1)  # (the last thing: the daemon frees the words and the Transfer after this)


def _pipeline(store: Store, job: PullJob) raises -> String:
    var repo_id = repo_of(job.asked)
    var repo = hub_repo(repo_id)
    _ = store.db.run("UPDATE pulls SET repo_id = ? WHERE id = ?", [repo.id, String(job.id)])
    var alias = (job.asked + " → " + repo.id) if job.asked.lower() != repo.id.lower() else repo.id
    _set(store, job.id, "architecture", "checking MAX runs it…", "resolve", alias + " @ " + String(repo.sha[byte=:8]))
    if job.t.cancelled():
        raise Error("cancelled")
    var folder = folder_of(job.home, repo.id)
    makedirs(folder, exist_ok=True)
    var cfg_at = -1
    for i in range(len(repo.files)):
        if repo.files[i].name == "config.json":
            cfg_at = i
    if cfg_at < 0:
        raise Error("unsupported: " + repo.id + " has no config.json: not a transformers model MAX can serve.")
    var r = hub_download(repo, repo.files[cfg_at], folder, job.t)
    if r.error != "":
        raise Error(r.error)
    if r.status != 200:
        raise Error("Hugging Face answered " + String(r.status) + " for config.json")
    var cfg = Json.parse(read_text(folder + "/config.json"))
    var arch = cfg.text(cfg.at(cfg.get(0, "architectures"), 0))
    var cat_text = catalog(job.home, job.max_cmd, job.env)
    if cat_text != "" and Json.parse(cat_text).get(0, arch) < 0:
        cat_text = catalog(job.home, job.max_cmd, job.env, fresh=True)  # (a newer MAX may run it: ask again once)
    if cat_text != "":
        var cat = Json.parse(cat_text)
        if cat.get(0, arch) < 0:
            raise Error("unsupported: " + repo.id + " is a " + (arch if arch != "" else "model with no architecture") + ", which MAX doesn't run.")
        _set(store, job.id, "architecture", "checking MAX runs it…", "architecture", arch + " is supported by MAX")
    else:
        _set(store, job.id, "architecture", "checking MAX runs it…", "architecture", arch + " (MAX's catalog couldn't be read; trying it)")
    var name = job.name if job.name != "" else model_name(job.asked, repo.id)
    var taken = store.db.one_text("SELECT repo_id FROM models WHERE name = ?", [name])
    if taken != "" and taken.lower() != repo.id.lower():
        raise Error("the name `" + name + "` is already registered for " + taken + "; pick another name")
    _ = store.db.run("UPDATE pulls SET name = ? WHERE id = ?", [name, String(job.id)])
    # the files: only the shards an index names
    var shards = List[String]()
    for i in range(len(repo.files)):
        if repo.files[i].name.endswith(".safetensors.index.json"):
            r = hub_download(repo, repo.files[i], folder, job.t)
            if r.error != "":
                raise Error(r.error)
            if r.status != 200:
                raise Error("Hugging Face answered " + String(r.status) + " for " + repo.files[i].name)
            var idx = Json.parse(read_text(folder + "/" + repo.files[i].name))
            var wm = idx.get(0, "weight_map")
            for k in range(idx.size(wm)):
                var s = idx.text(idx.at(wm, k))
                if s not in shards:
                    shards.append(s)
    var pick = wanted(repo, shards)
    var any_weights = False
    var files = String("[")
    for k in range(len(pick)):
        ref f = repo.files[pick[k]]
        any_weights = any_weights or f.name.endswith(".safetensors")
        files += (", " if k > 0 else "") + '{"name": ' + json_string(f.name) + ', "size": ' + String(f.size) + ', "done": 0}'
    files += "]"
    if not any_weights:
        raise Error("unsupported: " + repo.id + " has no safetensors weights.")
    var total = 0
    for k in pick:
        total += repo.files[k].size
    _ = store.db.run("UPDATE pulls SET files = ?, total_bytes = ? WHERE id = ?", [files, String(total), String(job.id)])
    _set(store, job.id, "download", "downloading " + String(len(pick)) + " files…")
    for k in range(len(pick)):
        _A.store(_w(job.words, W_FILE), Int64(k))
        ref f = repo.files[pick[k]]
        if exists(folder + "/" + f.name) and getsize(folder + "/" + f.name) == f.size:
            continue  # (config.json and the index came first; a re-pull keeps what's whole)
        r = hub_download(repo, f, folder, job.t)
        if r.error != "":
            raise Error(r.error)
        if r.status != 200:
            raise Error("Hugging Face answered " + String(r.status) + " for " + f.name)
    _A.store(_w(job.words, W_FILE), Int64(len(pick)))
    # verify
    _set(store, job.id, "verify", "checking file sizes…", "download", String(len(pick)) + " files, " + String(total // 1_000_000) + " MB")
    for k in pick:
        ref f = repo.files[k]
        if not exists(folder + "/" + f.name) or getsize(folder + "/" + f.name) != f.size:
            raise Error(f.name + " did not download completely; pull again to resume.")
    var done_files = String("[")
    for k in range(len(pick)):
        ref f = repo.files[pick[k]]
        done_files += (", " if k > 0 else "") + '{"name": ' + json_string(f.name) + ', "size": ' + String(f.size) + ', "done": ' + String(f.size) + "}"
    done_files += "]"
    _ = store.db.run("UPDATE pulls SET files = ?, done_bytes = ? WHERE id = ?", [done_files, String(total), String(job.id)])
    _set(store, job.id, "register", "adding " + name + " to your models…", "verify", String(len(pick)) + " files match their sizes")
    var source = "max-catalog" if cat_text.find('"' + repo.id + '"') >= 0 else "hf-supported"
    _ = store.db.run("""INSERT INTO models (name, repo_id, revision, source, architecture, weights_path, kind, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET revision = excluded.revision, weights_path = excluded.weights_path, architecture = excluded.architecture""",
                     [name, repo.id, repo.sha, source, arch, folder, kind_of(arch), String(wall_seconds())])
    _ = store.db.run("UPDATE pulls SET model = ?, details = json_set(details, '$.register', ?) WHERE id = ?", [name, "served as " + name + " · keep-alive 5 min", String(job.id)])
    _finish(store, job.id, "done", "Pulled " + name + " (" + repo.id + "@" + String(repo.sha[byte=:8]) + ", " + source + ").")
    return folder
