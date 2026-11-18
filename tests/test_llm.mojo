# mojoui.llm (goal 72 M1): the real Qwen3.8-27B on one GPU, in this process. Numbers go to build/g72/llm-bench.json.
#   scripts/build_llm_shim.sh                                          (once: build/llm/libmojoui_llm.so)
#   scripts/mxbuild.sh tests/test_llm.mojo -o build/test_llm && build/test_llm
# Environment: LLM_GGUF (default ~/Projects/omx-local/models/Qwen3.8-27B-UD-Q4_K_M.gguf), LLM_GPU (default 1: the other
# GPU belongs to the prototype's llama-server), LLM_HTTP (default http://127.0.0.1:8181; "" skips the HTTP comparison).
# Prints one `llm <case>: ok …` line per case.
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true
from std.ffi import external_call
from mojoui.clock import now_ns
from mojoui.json import Json, json_string
from mojoui.llm import Llm, LlmEvent, TEXT, REASONING, TOOL_CALLS, DONE, ERROR
from mojoui.process import output
from mojoui.uijobs import wake_pipe
from mojoui.wake import fd_io
from mojoui import libc

comptime TOOLS = '[{"type":"function","function":{"name":"get_weather","description":"The current weather in a city.","parameters":{"type":"object","properties":{"city":{"type":"string","description":"The city"}},"required":["city"]}}}]'


def msg(role: String, content: String) -> String:
    return '{"role":' + json_string(role) + ',"content":' + json_string(content) + "}"


def ms_since(t0: Int) -> Float64:
    return Float64(now_ns() - t0) / 1e6


def sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](Int32(ms * 1000))


def long_system(tag: String) -> String:
    """About 3k tokens of rules (the voice assistant's system prompt is this size), made unique by `tag` so no earlier
    case's cache can serve it."""
    var s = String("You are omx, a voice assistant (session ") + tag + "). "
    for k in range(150):
        s += "Rule " + String(k) + ": be brief and kind, and never invent facts about item " + String(k) + ". "
    return s


def median(var xs: List[Float64]) -> Float64:
    sort(xs)
    return xs[len(xs) // 2]


def main() raises:
    var gguf = getenv("LLM_GGUF", getenv("HOME", "") + "/Projects/omx-local/models/Qwen3.8-27B-UD-Q4_K_M.gguf")
    var gpu = Int(getenv("LLM_GPU", "1"))
    var wake_fd = wake_pipe()  # (the host's job-wake pipe: the shim writes a byte down it when events are waiting)
    var t_load = now_ns()
    var llm = Llm(gguf, gpu=gpu, n_ctx=32768, n_seq=2)
    var load_ms = ms_since(t_load)
    print("llm loaded:", gguf, "on GPU", gpu, "in", load_ms, "ms; context", llm.n_ctx, "x", llm.n_seq, "sequences")

    # 1. a plain answer
    var paris = llm.complete("[" + msg("user", "What is the capital of France? One word.") + "]")
    assert_true(paris.text.find("Paris") >= 0, "Paris: " + paris.text)
    assert_equal(paris.done.text, "stop")
    print("llm paris: ok", paris.text, "| ttft", paris.done.ttft_ms, "ms")

    # 1b. the wake pipe: a byte arrives when events are waiting, without polling
    var fds = List[Int32](length=2, fill=0)
    fds[0] = Int32(wake_fd)
    fds[1] = Int32(1)  # POLLIN
    var one = List[UInt8](length=4096, fill=0)
    while libc.poll(Int(fds.unsafe_ptr()), 1, 0) == 1:  # (the earlier requests' wakes: drain them)
        _ = fd_io("read", wake_fd, Int(one.unsafe_ptr()), 4096)
    var t_wake = now_ns()
    var wid = llm.chat("[" + msg("user", "Say hello in one word.") + "]", max_tokens=20)
    var ready = libc.poll(Int(fds.unsafe_ptr()), 1, 10000)
    var woke_ms = ms_since(t_wake)
    _ = len(fds)  # (the lists live until their calls end)
    _ = len(one)
    assert_equal(ready, 1)
    var hello = llm.wait(wid)
    assert_true(hello.text != "", "the reply: " + hello.text)
    assert_true(woke_ms > 20.0, "the wake came from the model, not an old byte: " + String(woke_ms) + " ms")
    print("llm wake: ok, the pipe woke the UI", woke_ms, "ms after the request (the first token's time)")

    # 2. a tool call, parsed; its markup is never text
    var weather = llm.complete("[" + msg("user", "What's the weather in Lisbon?") + "]", TOOLS)
    assert_true(weather.tool_calls != "", "a tool call was made; the model said: " + weather.text)
    var calls = Json.parse(weather.tool_calls)
    assert_equal(calls.text(calls.get(calls.at(0, 0), "name")), "get_weather")
    var args = Json.parse(calls.text(calls.get(calls.at(0, 0), "arguments")))
    assert_equal(args.text(args.get(0, "city")), "Lisbon")
    for e in weather.events:
        assert_true(e.kind != TEXT or (e.text.find("<tool_call>") < 0 and e.text.find("<function") < 0), "no markup as text: " + e.text)
    assert_true(weather.text.find("tool_call") < 0 and weather.text.find("<function") < 0, "no markup as text: " + weather.text)
    print("llm tool call: ok", weather.tool_calls)

    # 3. decode speed (no speculative decoding): a long answer on a warm sequence, three runs (the GPU's clocks and a
    # neighbour's work move one run by +-5%; the best run is the engine's speed, the others are in the numbers file)
    var tps_runs = List[Float64]()
    var best_tps = 0.0
    var story_tokens = 0
    for _ in range(3):
        var story = llm.complete("[" + msg("user", "Write a story of about 250 words about a fox who learns to read.") + "]", max_tokens=300)
        assert_true(story.done.n_gen >= 200, "a long reply: " + String(story.done.n_gen) + " tokens")
        tps_runs.append(story.done.tps)
        story_tokens = story.done.n_gen
        best_tps = max(best_tps, story.done.tps)
    print("llm decode:", story_tokens, "tokens per run at", tps_runs[0], tps_runs[1], tps_runs[2], "tok/s")
    assert_true(best_tps >= 40.0, "decode >= 40 tok/s: " + String(best_tps))

    # 4. cancel mid-reply
    var id = llm.chat("[" + msg("user", "Count from 1 to 500, separated by commas, with no other words.") + "]", max_tokens=1500)
    var heard = False
    var t_ask = now_ns()
    while not heard:
        for e in llm.poll(id):
            if e.kind == TEXT:
                heard = True
        if ms_since(t_ask) > 20000:
            break
        sleep_ms(1)
    assert_true(heard, "the reply started")
    sleep_ms(400)  # (mid-reply)
    var t_cancel = now_ns()
    llm.cancel(id)
    var ended = False
    var reason = String("")
    var cancel_ms = 0.0
    while not ended and ms_since(t_cancel) < 5000:
        for e in llm.poll(id):
            if e.kind == DONE:
                ended = True
                reason = e.text
                cancel_ms = ms_since(t_cancel)
        sleep_ms(1)
    assert_true(ended, "the cancelled request ended")
    assert_equal(reason, "cancel")
    assert_true(cancel_ms <= 100.0, "cancel took " + String(cancel_ms) + " ms")
    print("llm cancel: ok", cancel_ms, "ms")

    # 5. the prompt cache: a ~3k-token system prompt + tools, two turns
    var sys1 = long_system(String(now_ns()))
    var turn1 = "[" + msg("system", sys1) + "," + msg("user", "What is the capital of France? One word.") + "]"
    var r1 = llm.complete(turn1, TOOLS, max_tokens=40)
    assert_true(r1.text.find("Paris") >= 0, "turn 1: " + r1.text)
    var turn2 = "[" + msg("system", sys1) + "," + msg("user", "What is the capital of France? One word.") + "," + msg("assistant", r1.text) + "," + msg("user", "And the capital of Spain? One word.") + "]"
    var r2 = llm.complete(turn2, TOOLS, max_tokens=40)
    assert_true(r2.text.find("Madrid") >= 0, "turn 2: " + r2.text)
    print("llm cache: prompt", r1.done.n_prompt, "tokens; turn 1 ttft", r1.done.ttft_ms, "ms (cached", r1.done.n_cached, "); turn 2 ttft", r2.done.ttft_ms, "ms (cached", r2.done.n_cached, "of", r2.done.n_prompt, ")")
    assert_true(r1.done.n_prompt >= 2500, "a ~3k-token prompt: " + String(r1.done.n_prompt))
    assert_true(r2.done.n_cached >= r1.done.n_prompt - 8, "the second turn reuses the first's prompt: " + String(r2.done.n_cached))
    assert_true(r2.done.ttft_ms <= 0.5 * r1.done.ttft_ms, "turn 2 ttft " + String(r2.done.ttft_ms) + " <= half of " + String(r1.done.ttft_ms))

    # 5b. D-7302: whatever goes wrong inside the engine for one request ends that request with an error and nothing else. Each
    # fault (the token feed, the admission, the end of the reply) hits the next request; the one after it, and a request on the
    # other sequence in the same moment, answer as if nothing had happened.
    for what in range(1, 4):
        _ = llm.test_fault(what)
        var other = llm.chat("[" + msg("user", "What is the capital of Italy? One word.") + "]", seq=1, max_tokens=24)  # (sequence 1 is queued behind nothing: the fault is for whichever the engine takes first)
        var failing = llm.chat("[" + msg("user", "Count from one to ten in words.") + "]", seq=0, max_tokens=40)
        var bad = String("")
        var ids = List[Int]()
        ids.append(other)
        ids.append(failing)
        var errors = 0
        var finished = 0
        for id in ids:
            try:
                var rep = llm.wait(id)
                finished += 1
                _ = rep^
            except err:
                errors += 1
                bad = String(err)
        assert_equal(errors, 1)  # exactly one of the two requests met the fault
        assert_equal(finished, 1)  # ... and the other one finished
        assert_true(bad.find("test fault") >= 0, "the error says what failed: " + bad)
        var after = llm.complete("[" + msg("user", "What is the capital of France? One word.") + "]", max_tokens=24)
        assert_true(after.text.find("Paris") >= 0, "the engine answers after fault " + String(what) + ": " + after.text)
        var after1 = llm.complete("[" + msg("user", "What is the capital of Spain? One word.") + "]", seq=1, max_tokens=24)
        assert_true(after1.text.find("Madrid") >= 0, "the other sequence answers after fault " + String(what) + ": " + after1.text)
        print("llm fault", what, ": ok |", bad)

    # 6. a background request beside the conversation: both finish, both right
    var bg = llm.chat("[" + msg("user", "Write the numbers from 1 to 60, one per line, and nothing else.") + "]", seq=1, max_tokens=400)
    sleep_ms(300)  # (the background one is generating)
    var fg = llm.chat("[" + msg("user", "What is the capital of France? One word.") + "]", seq=0, max_tokens=40)
    var fg_text = String("")
    var bg_text = String("")
    var fg_done = False
    var bg_done = False
    var fg_done_ms = 0.0
    var t6 = now_ns()
    while not (fg_done and bg_done) and ms_since(t6) < 60000:
        for e in llm.poll(fg):
            if e.kind == TEXT:
                fg_text += e.text
            elif e.kind == DONE:
                fg_done = True
                fg_done_ms = ms_since(t6)
        for e in llm.poll(bg):
            if e.kind == TEXT:
                bg_text += e.text
            elif e.kind == DONE:
                bg_done = True
        sleep_ms(2)
    assert_true(fg_done and bg_done, "both requests finished")
    assert_true(fg_text.find("Paris") >= 0, "the conversation answered: " + fg_text)
    assert_true(bg_text.find("60") >= 0 and bg_text.find("30") >= 0, "the background work answered: " + bg_text)
    print("llm background: ok; the conversation answered in", fg_done_ms, "ms while the background sequence ran:", fg_text)

    # 7. in-process against the same prompt through llama-server over HTTP (both warm: the same messages repeated)
    var http_url = getenv("LLM_HTTP", "http://127.0.0.1:8181")
    var sys7 = long_system(String(now_ns()))
    var m7 = "[" + msg("system", sys7) + "," + msg("user", "What is the capital of France? One word.") + "]"
    var in_proc = List[Float64]()
    var n7 = 0
    for i in range(6):
        var r = llm.complete(m7, TOOLS, max_tokens=2)
        n7 = r.done.n_prompt
        if i > 0:  # (the first one warms the cache)
            in_proc.append(r.done.ttft_ms)
    var http_ms = List[Float64]()
    # (D-7311: the baseline is part of the proof, never skipped: no LLM_HTTP means a failed test, not a quiet pass)
    assert_true(http_url != "", "no HTTP baseline: set LLM_HTTP to a running llama-server with the same model (the checker starts one)")
    if True:
        makedirs("build/g72", exist_ok=True)
        var spec = open("build/g72/ttft-messages.json", "w")
        spec.write('{"messages":' + m7 + ',"tools":' + TOOLS + "}")
        spec.close()
        var got = output(["pixi", "run", "python", "-I", "scripts/llm_http_ttft.py", "build/g72/ttft-messages.json", http_url, "6"], timeout_ms=120000)
        var j = Json.parse(String(got.strip()))
        var arr = j.get(0, "ttft_ms")
        for i in range(1, j.size(arr)):  # (the first one warms the server's cache)
            http_ms.append(j.real(j.at(arr, i)))
        assert_true(len(http_ms) > 0 and http_ms[0] > 0, "the HTTP server answered: " + got)
    var in_med = median(in_proc.copy())
    print("llm first token, warm: in-process median", in_med, "ms; HTTP median", median(http_ms.copy()) if len(http_ms) > 0 else -1.0, "ms")
    if len(http_ms) > 0:
        assert_true(in_med <= median(http_ms.copy()), "in-process " + String(in_med) + " ms <= HTTP " + String(median(http_ms.copy())) + " ms")

    # the numbers
    makedirs("build/g72", exist_ok=True)
    var out = open("build/g72/llm-bench.json", "w")
    var http_list = String("[")
    for i in range(len(http_ms)):
        http_list += ("," if i > 0 else "") + String(http_ms[i])
    http_list += "]"
    var in_list = String("[")
    for i in range(len(in_proc)):
        in_list += ("," if i > 0 else "") + String(in_proc[i])
    in_list += "]"
    out.write(
        '{"model":' + json_string(gguf) + ',"gpu":' + String(gpu) + ',"n_ctx":' + String(llm.n_ctx) + ',"load_ms":' + String(load_ms)
        + ',"decode_tps":' + String(best_tps) + ',"decode_tps_runs":[' + String(tps_runs[0]) + "," + String(tps_runs[1]) + "," + String(tps_runs[2]) + '],"decode_tokens":' + String(story_tokens)
        + ',"cancel_ms":' + String(cancel_ms)
        + ',"cache":{"prompt_tokens":' + String(r1.done.n_prompt) + ',"turn1_ttft_ms":' + String(r1.done.ttft_ms) + ',"turn1_cached":' + String(r1.done.n_cached)
        + ',"turn2_ttft_ms":' + String(r2.done.ttft_ms) + ',"turn2_cached":' + String(r2.done.n_cached) + ',"turn2_prompt":' + String(r2.done.n_prompt) + "}"
        + ',"background":{"conversation_answer_ms":' + String(fg_done_ms) + "}"
        + ',"first_token_warm_ms":{"in_process":' + in_list + ',"http":' + http_list + ',"prompt_tokens":' + String(n7) + "}}\n"
    )
    out.close()
    print("llm: all cases ok; numbers in build/g72/llm-bench.json")
