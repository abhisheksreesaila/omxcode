# consoled's benchmark (goal 55 M4; the Python daemon's bench.py, same workload, row and numbers): POST /admin/bench
# runs on a thread of its own and calls this daemon's /v1 gateway with an in-memory key (app "_bench"), so a cold
# model loads the way any request loads it. Per model: one warm-up, then `runs` timed chats of a ~512-token prompt
# (unique per run, so no prefix cache answers) with 128 tokens out, streamed (mojoui.http_flare.stream_timed).
# Kept per model: decode tok/s = p50 of (n - 1) / (last token - first token), time to first token p50 and p95,
# prefill tok/s = prompt tokens / ttft; n and the prompt's tokens from the usage block (counted pieces otherwise).

from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc
from mojoui.http import Request, SseReader
from mojoui.http_flare import stream_timed
from mojoui.serve import spawn
from mojoui.json import Json, json_string
from mojoui.clock import wall_seconds
from store import Store

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime MAX_TOKENS = 128
comptime PROMPT_TARGET = 512  # tokens, at four characters each
comptime DEFAULT_RUNS = 5
comptime MAX_RUNS = 50
comptime SENTENCES = ["The quick brown fox jumps over the lazy dog while the farmer watches from the porch.",
                      "A good benchmark repeats the same small task many times so that noise averages out and the signal remains.",
                      "The ferry crosses the bay in forty minutes when the wind is calm and in an hour when it is not.",
                      "Every spring the town repaints the bridge a slightly different shade of green, and nobody agrees which was best."]


def build_prompt(nonce: String) -> String:
    """bench.py build_prompt: a deterministic passage of ~512 tokens, a nonce line first (paid out of the budget)."""
    var task = String("Continue this passage in the same style, for as long as you can.")
    var head = nonce + "\n" if nonce != "" else String("")
    var budget = PROMPT_TARGET * 4 - task.byte_length() - 1 - head.byte_length()
    var out = String("")
    var size = 0
    var i = 0
    while True:
        var s = String(materialize[SENTENCES]()[i % 4])
        if size + s.byte_length() + 1 > budget:
            break
        out += (" " if size > 0 else "") + s
        size += s.byte_length() + 1
        i += 1
    return head + out + " " + task


@fieldwise_init
struct Sample(Copyable, Movable):
    var ok: Bool
    var error: String
    var ttft_ms: Float64
    var duration_ms: Float64
    var prompt_tokens: Int
    var completion_tokens: Int
    var decode_tps: Float64
    var prefill_tps: Float64
    var estimated: Bool


def one_chat(port: Int, key: String, model: String, prompt: String) -> Sample:
    var body = '{"model": ' + json_string(model) + ', "messages": [{"role": "user", "content": ' + json_string(prompt) + '}], "max_tokens": ' + String(MAX_TOKENS)
    body += ', "stream": true, "stream_options": {"include_usage": true}}'
    var req = Request(0, "POST", "http://127.0.0.1:" + String(port) + "/v1/chat/completions", body).header("Content-Type", "application/json")
    req = req^.header("Authorization", "Bearer " + key).timeout(900_000)
    var s = stream_timed(req^)
    if s.error != "" or s.status != 200:
        var text = String("")
        for c in s.chunks:
            text += c
        return Sample(False, s.error if s.error != "" else "HTTP " + String(s.status) + ": " + String(text[byte = : min(200, text.byte_length())]), 0, 0, 0, 0, 0, 0, False)
    var reader = SseReader()
    var first = -1
    var last = -1
    var pieces = 0
    var prompt_tokens = -1
    var completion_tokens = -1
    for k in range(len(s.chunks)):
        for p in reader.feed(Span(s.chunks[k].as_bytes())):
            if p.data == "[DONE]" or p.data == "":
                continue
            try:
                var j = Json.parse(p.data)
                var u = j.get(0, "usage")
                if u >= 0 and j.kind(u) == 5:
                    prompt_tokens = j.number(j.get(u, "prompt_tokens"), -1)
                    completion_tokens = j.number(j.get(u, "completion_tokens"), -1)
                var ch = j.at(j.get(0, "choices"), 0)
                if ch >= 0 and j.text(j.get(j.get(ch, "delta"), "content")) != "":
                    pieces += 1
                    if first < 0:
                        first = s.at_ns[k]
                    last = s.at_ns[k]
            except:
                pass
    if first < 0:
        return Sample(False, "no tokens came back", 0, 0, 0, 0, 0, 0, False)
    var estimated = completion_tokens < 0 or prompt_tokens < 0
    var n = completion_tokens if completion_tokens > 0 else pieces
    var pt = prompt_tokens if prompt_tokens > 0 else prompt.byte_length() // 4
    var ttft = Float64(first - s.sent_ns) / 1e6
    var decode_s = Float64(last - first) / 1e9
    var decode = Float64(n - 1) / decode_s if decode_s > 0 and n > 1 else 0.0
    return Sample(True, "", ttft, Float64(last - s.sent_ns) / 1e6, pt, n, decode, Float64(pt) / (ttft / 1000) if ttft > 0 else 0.0, estimated)


def percentile(var xs: List[Float64], p: Float64) -> Float64:
    """metrics.py _percentile: linear between the closest ranks."""
    if len(xs) == 0:
        return 0
    sort(xs)
    var k = (Float64(len(xs)) - 1) * p
    var lo = Int(k)
    var hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - Float64(lo))


struct BenchJob(Movable):
    var run_id: Int
    var names: List[String]
    var runs: Int
    var port: Int
    var key: String
    var home: String
    var ended: Int  # its word: 1 once the run's row is final

    def __init__(out self, run_id: Int, var names: List[String], runs: Int, port: Int, key: String, home: String, ended: Int):
        self.run_id = run_id
        self.names = names^
        self.runs = runs
        self.port = port
        self.key = key
        self.home = home
        self.ended = ended


struct Bench(Movable):
    """The daemon's benchmark: one run at a time."""

    var ended: Int  # the running job's word (0: none running)

    def __init__(out self):
        self.ended = 0

    def running(mut self) -> Bool:
        if self.ended != 0 and _A.load(_P(unsafe_from_address=self.ended)) != 0:
            _P(unsafe_from_address=self.ended).unsafe_free()
            self.ended = 0
        return self.ended != 0

    def start(mut self, store: Store, var names: List[String], runs: Int, port: Int, key: String, home: String) raises -> Int:
        var models = String("[")
        for i in range(len(names)):
            models += (", " if i > 0 else "") + json_string(names[i])
        models += "]"
        _ = store.db.run("INSERT INTO bench_runs (started_at, status, runs, max_tokens, prompt_tokens, models) VALUES (?, 'running', ?, ?, ?, ?)",
                         [String(wall_seconds()), String(runs), String(MAX_TOKENS), String(build_prompt("").byte_length() // 4), models])
        var id = Int(atol(store.db.one_text("SELECT last_insert_rowid()")))
        var word = unsafe_alloc[Int64](1)
        word[0] = 0
        var job = unsafe_alloc[BenchJob](1)
        job.unsafe_write(BenchJob(id, names^, runs, port, key, home, Int(word)))
        if not spawn[_work](Int(job)):
            job.unsafe_deinit_pointee()
            job.unsafe_free()
            word.unsafe_free()
            _ = store.db.run("UPDATE bench_runs SET status = 'failed', finished_at = ? WHERE id = ?", [String(wall_seconds()), String(id)])
            return id
        self.ended = Int(word)
        return id


def _work(addr: Int):
    var job = Pointer[BenchJob, MutUntrackedOrigin](unsafe_from_address=addr)
    var word = job[].ended
    try:
        var store = Store(job[].home + "/mst.db")
        var all_failed = True
        for name in job[].names:
            var began = wall_seconds()
            var warm = one_chat(job[].port, job[].key, name, build_prompt("Benchmark " + String(job[].run_id) + " · Warm-up ·"))
            var samples = List[Sample]()
            if warm.ok:
                for i in range(1, job[].runs + 1):
                    samples.append(one_chat(job[].port, job[].key, name, build_prompt("Benchmark " + String(job[].run_id) + " · Run " + String(i) + " of " + String(job[].runs) + " ·")))
            var ok = List[Sample]()
            for s in samples:
                if s.ok:
                    ok.append(s.copy())
            var status = "done" if len(ok) > 0 else "failed"
            var err = warm.error if not warm.ok else (samples[0].error if len(ok) == 0 and len(samples) > 0 else String(""))
            if len(ok) > 0:
                all_failed = False
            var dec = List[Float64]()
            var tt = List[Float64]()
            var pre = List[Float64]()
            var dur = List[Float64]()
            var pt = 0
            var ct = 0
            var est = False
            for s in ok:
                dec.append(s.decode_tps)
                tt.append(s.ttft_ms)
                pre.append(s.prefill_tps)
                dur.append(s.duration_ms)
                pt += s.prompt_tokens
                ct += s.completion_tokens
                est = est or s.estimated
            var have = len(ok) > 0
            _ = store.db.run("""INSERT INTO bench_results (run_id, model, status, error, load_seconds, runs_ok, errors, decode_tps, prefill_tps,
                ttft_p50_ms, ttft_p95_ms, duration_ms, total_ms, prompt_tokens, completion_tokens, estimated, prompt_estimated, completion_estimated)
                VALUES (?, ?, ?, nullif(?, ''), NULL, ?, ?, nullif(?, ''), nullif(?, ''), nullif(?, ''), nullif(?, ''), nullif(?, ''), ?, nullif(?, ''), nullif(?, ''), ?, ?, ?)""",
                             [String(job[].run_id), name, status, err, String(len(ok)), String(len(samples) - len(ok) + (0 if warm.ok else 1)),
                              String(percentile(dec.copy(), 0.5)) if have else String(""), String(percentile(pre.copy(), 0.5)) if have else String(""),
                              String(percentile(tt.copy(), 0.5)) if have else String(""), String(percentile(tt.copy(), 0.95)) if have else String(""),
                              String(percentile(dur.copy(), 0.5)) if have else String(""), String((wall_seconds() - began) * 1000),
                              String(pt // len(ok)) if have else String(""), String(ct // len(ok)) if have else String(""),
                              "1" if est else "0", "1" if est else "0", "1" if est else "0"])
            for i in range(len(samples)):
                ref s = samples[i]
                _ = store.db.run("""INSERT INTO bench_samples (run_id, model, idx, ttft_ms, duration_ms, prompt_tokens, completion_tokens, decode_tps, prefill_tps, error)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, nullif(?, ''))""", [String(job[].run_id), name, String(i + 1), String(s.ttft_ms), String(s.duration_ms),
                                                                         String(s.prompt_tokens), String(s.completion_tokens), String(s.decode_tps), String(s.prefill_tps), s.error])
        _ = store.db.run("UPDATE bench_runs SET status = ?, finished_at = ? WHERE id = ?", ["failed" if all_failed else "done", String(wall_seconds()), String(job[].run_id)])
    except:  # (the store wouldn't open, or a write failed: the run is marked failed, never left running)
        try:
            _ = Store(job[].home + "/mst.db").db.run("UPDATE bench_runs SET status = 'failed', finished_at = ? WHERE id = ? AND status = 'running'", [String(wall_seconds()), String(job[].run_id)])
        except:
            pass
    job.unsafe_deinit_pointee()
    job.unsafe_free()
    _A.store(_P(unsafe_from_address=word), 1)  # (the last thing: the daemon frees the word after this)
