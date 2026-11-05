# /admin/search?q=: the curated models and MAX's catalog (MXC_HOME/max_catalog.json), each with its size estimate and
# whether it fits the roomiest GPU (or the RAM) now (spec §4 search). Offline: no Hugging Face lookup for an owner/name
# query that isn't in the pool (D-4772: a warning says so).

from std.os.path import exists
from mojoui.json import Json, json_string
from supervisor import gpus
from views import num, rnd
from learn import read_text

comptime CURATED = ["qwen2.5-0.5b", "qwen2.5-1.5b", "qwen2.5-3b", "smollm2-1.7b", "llama3.2-1b", "all-minilm-l6"]
comptime CURATED_REPOS = ["Qwen/Qwen2.5-0.5B-Instruct", "Qwen/Qwen2.5-1.5B-Instruct", "Qwen/Qwen2.5-3B-Instruct", "HuggingFaceTB/SmolLM2-1.7B-Instruct", "meta-llama/Llama-3.2-1B-Instruct", "sentence-transformers/all-MiniLM-L6-v2"]


@fieldwise_init
struct Entry(Copyable, Movable):
    var id: String
    var repo: String
    var arch: String  # "" when the catalog doesn't name one
    var params: Int  # -1: unknown
    var curated: Bool


def params_from_name(repo: String) -> Int:
    """The largest NUMBER[bBmM] in the name not inside a word: 0.5B → 5e8, 360M → 3.6e8 (-1: none)."""
    var b = repo.as_bytes()
    var best = -1.0
    var i = 0
    while i < len(b):
        var c = Int(b[i])
        var prev_ok = i == 0 or not (_word(Int(b[i - 1])) or Int(b[i - 1]) == 46)
        if c >= 48 and c <= 57 and prev_ok:
            var j = i
            var dot = False
            while j < len(b) and ((Int(b[j]) >= 48 and Int(b[j]) <= 57) or (Int(b[j]) == 46 and not dot and j + 1 < len(b) and Int(b[j + 1]) >= 48 and Int(b[j + 1]) <= 57)):
                if Int(b[j]) == 46:
                    dot = True
                j += 1
            if j < len(b):
                var u = Int(b[j])
                var after_ok = j + 1 >= len(b) or not _alnum(Int(b[j + 1]))
                if (u == 66 or u == 98 or u == 77 or u == 109) and after_ok:
                    try:
                        var v = atof(String(repo[byte = i : j])) * (1e9 if u == 66 or u == 98 else 1e6)
                        best = max(best, v)
                    except:
                        pass
            i = j
            continue
        i += 1
    return Int(best) if best > 0 else -1


def _alnum(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


def _word(c: Int) -> Bool:
    return _alnum(c) or c == 95


def memory() -> Tuple[String, Float64]:
    """(the memory JSON, free GB) from the roomiest GPU, else /proc/meminfo."""
    var list = gpus()
    if len(list) > 0:
        var best = 0
        for i in range(len(list)):
            if list[i].total_mb - list[i].used_mb > list[best].total_mb - list[best].used_mb:
                best = i
        var free = Float64(list[best].total_mb - list[best].used_mb) / 1024
        return ('{"basis": "gpu", "name": ' + json_string(list[best].name) + ', "free_gb": ' + num(rnd(free, 1)) + ', "total_gb": '
                + num(rnd(Float64(list[best].total_mb) / 1024, 1)) + "}", free)
    var avail = 0.0
    var total = 0.0
    for line in read_text("/proc/meminfo").split("\n"):
        var parts = String(line).split()
        if len(parts) >= 2:
            try:
                if parts[0] == "MemAvailable:":
                    avail = Float64(atol(parts[1])) / 1048576
                elif parts[0] == "MemTotal:":
                    total = Float64(atol(parts[1])) / 1048576
            except:
                pass
    return ('{"basis": "ram", "name": "system RAM (no NVIDIA GPU found)", "free_gb": ' + num(rnd(avail, 1)) + ', "total_gb": ' + num(rnd(total, 1)) + "}", avail)


def est_of(params: Int) -> Float64:
    return -1.0 if params < 0 else (Float64(params) * 2 / 1e9) * 1.2 + 1.0


def fit_of(est: Float64, free: Float64) -> String:
    if est < 0:
        return "null"
    if est <= free * 0.8:
        return '"ok"'
    if est <= free:
        return '"tight"'
    return '"no"'


def row(e: Entry, free: Float64, suggestions: String = "[]") -> String:
    var size = -1.0 if e.params < 0 else Float64(e.params) * 2 / 1e9
    var est = est_of(e.params)
    return ('{"id": ' + json_string(e.id) + ', "repo_id": ' + json_string(e.repo) + ', "source": "max", "architecture": '
            + (json_string(e.arch) if e.arch != "" else "null") + ', "params": ' + (String(e.params) if e.params >= 0 else "null")
            + ', "size_gb": ' + (num(rnd(size, 2)) if size >= 0 else "null") + ', "est_vram_gb": ' + (num(rnd(est, 1)) if est >= 0 else "null")
            + ', "supported": true, "fit": ' + fit_of(est, free) + ', "suggestions": ' + suggestions + "}")


def search_json(q: String, home: String) raises -> String:
    var query = String(q.strip())
    var warnings = List[String]()
    var catalog_text = read_text(home + "/max_catalog.json")
    var pool = List[Entry]()
    var seen = List[String]()
    var arch_of = Dict[String, String]()
    var cat_names = List[String]()
    if catalog_text != "":
        var cat = Json.parse(catalog_text)
        for a in range(cat.size(0)):
            var name = cat.keys[0][a]
            cat_names.append(name)
            var ids = cat.get(cat.at(0, a), "example_repo_ids")
            for k in range(cat.size(ids)):
                var r = cat.text(cat.at(ids, k)).lower()
                if r not in arch_of:
                    arch_of[r] = name
    else:
        warnings.append("No MAX catalog cache in " + home + " (max_catalog.json): architectures are unknown.")
    for i in range(len(materialize[CURATED]())):
        var repo = String(materialize[CURATED_REPOS]()[i])
        pool.append(Entry(String(materialize[CURATED]()[i]), repo, arch_of.get(repo.lower(), ""), params_from_name(repo), True))
        seen.append(repo.lower())
    if catalog_text != "":
        var cat = Json.parse(catalog_text)
        var order = cat_names.copy()
        sort(order)
        for name in order:
            for a in range(cat.size(0)):
                if cat.keys[0][a] != name:
                    continue
                var ids = cat.get(cat.at(0, a), "example_repo_ids")
                for k in range(cat.size(ids)):
                    var r = cat.text(cat.at(ids, k))
                    if r.lower() in seen:
                        continue
                    seen.append(r.lower())
                    pool.append(Entry(r, r, name, params_from_name(r), False))
    var mem = memory()
    var free = mem[1]
    var picked = List[Int]()
    if query == "":
        for i in range(len(pool)):
            if pool[i].curated:
                picked.append(i)
    else:
        var tokens = query.lower().split()
        var exact = List[Int]()
        var cur = List[Int]()
        var rest = List[Int]()
        for i in range(len(pool)):
            var hay = (pool[i].id + " " + pool[i].repo + " " + pool[i].arch).lower()
            var all_in = True
            for t in tokens:
                if hay.find(String(t)) < 0:
                    all_in = False
            if not all_in:
                continue
            if pool[i].id.lower() == query.lower():
                exact.append(i)
            elif pool[i].curated:
                cur.append(i)
            else:
                rest.append(i)
        for i in exact:
            picked.append(i)
        for i in cur:
            picked.append(i)
        for i in rest:
            picked.append(i)
        if len(picked) > 20:
            picked.resize(20, 0)
        if query.find("/") > 0 and len(picked) == 0:
            warnings.append("Looking up " + query + " on Hugging Face isn't available in this daemon yet.")
    var results = String("[")
    for k in range(len(picked)):
        ref e = pool[picked[k]]
        var sugg = String("[]")
        var est = est_of(e.params)
        if fit_of(est, free) == '"no"':
            var cands = List[Int]()
            for i in range(len(pool)):
                var ei = est_of(pool[i].params)
                if fit_of(ei, free) == '"ok"' and pool[i].repo != e.repo and (ei < est or est < 0):
                    cands.append(i)
            sugg = "["
            var n = 0
            for i in cands:
                if n >= 3:
                    break
                ref c = pool[i]
                var size = Float64(c.params) * 2 / 1e9
                sugg += (", " if n > 0 else "") + '{"id": ' + json_string(c.id) + ', "repo_id": ' + json_string(c.repo) + ', "architecture": ' + (json_string(c.arch) if c.arch != "" else "null")
                sugg += ', "params": ' + String(c.params) + ', "size_gb": ' + num(rnd(size, 2)) + ', "est_vram_gb": ' + num(rnd(est_of(c.params), 1)) + "}"
                n += 1
            sugg += "]"
        results += (", " if k > 0 else "") + row(e, free, sugg)
    results += "]"
    var w = String("[")
    for i in range(len(warnings)):
        w += (", " if i > 0 else "") + json_string(warnings[i])
    return '{"query": ' + json_string(query) + ', "memory": ' + mem[0] + ', "results": ' + results + ', "warnings": ' + w + "]}"
