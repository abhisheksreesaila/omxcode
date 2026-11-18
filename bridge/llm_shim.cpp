// mojoui's LLM shim (goal 72 M1): libllama in the app's own process behind a C ABI of scalars and pointers.
//
// One engine thread per loaded model owns the llama_context and schedules every sequence in it (sequence 0 = the
// conversation, 1 = background work, as many as n_seq asked for), batching their tokens into one llama_process() call the
// way llama-server's slots do. A caller (the UI thread, through mojoui/llm.mojo) never waits for the model: chat() queues
// a request and returns its id, poll() hands back the events produced so far as JSON lines, and one byte goes down the
// framework's wake pipe whenever there is something new to read.
//
//   chat:   the GGUF's own chat template + tools (common_chat_session, the code llama-server --jinja runs) -> tokens
//   cache:  each sequence remembers the tokens its KV holds. A new request reuses the longest common prefix. The model
//           is hybrid (recurrent layers cannot drop their tail), so the engine keeps context checkpoints (the recurrent
//           state, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY) taken right before each prompt's generation prompt, and restores the
//           newest one at or before the shared prefix, as llama-server does.
//   output: text / reasoning deltas as the reply is parsed (tool-call markup is never emitted as text), the parsed tool
//           calls at the end, then done with the numbers (tokens, cache hit, prefill and first-token time, decode speed).
//
// Events (one JSON object per line):
//   {"t":"text","s":"..."}  {"t":"reasoning","s":"..."}  {"t":"tools","calls":[{"id":"","name":"","arguments":"{...}"}]}
//   {"t":"done","reason":"stop|length|cancel","n_prompt":N,"n_cached":N,"n_gen":N,"prefill_ms":F,"ttft_ms":F,"tps":F}
//   {"t":"error","s":"..."}
//
// Built by scripts/build_llm_shim.sh into build/llm/libmojoui_llm.so (links libllama + libllama-common from
// $MOJOUI_LLAMA_DIR, rpath set to it). Everything exported is extern "C" with 64-bit integers and pointers.

#include "llama.h"
#include "common.h"
#include "chat.h"
#include "sampling.h"
#include "log.h"
#include "ggml-backend.h"
#include "json.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

using clk = std::chrono::steady_clock;

std::mutex g_err_mu;
std::string g_err;
void set_error(const std::string & s) { std::lock_guard<std::mutex> l(g_err_mu); g_err = s; }

struct Ckpt {
    int32_t n = 0;                  // tokens covered (positions 0 .. n-1)
    std::vector<uint8_t> data;      // the recurrent state at that point
};

struct Req {
    int64_t id = 0;
    std::string messages, tools;
    bool think = true;
    int max_tokens = 512;
    float temp = 0.7f;
    std::atomic<bool> cancel{false};
    clk::time_point t_submit = clk::now();

    // engine thread only, from admission on
    std::unique_ptr<common_chat_session> session;
    common_sampler * smpl = nullptr;
    std::vector<llama_token> prompt;
    int32_t n_done = 0;             // prompt tokens already in the KV
    int32_t n_cached = 0;           // of those, the ones reused from the cache
    int32_t ck_at = -1;             // take a checkpoint when the KV holds this many tokens
    int32_t i_logits = -1;          // index of this request's logits row in the batch being processed
    bool generating = false;
    llama_token last = LLAMA_TOKEN_NULL;
    std::string generated;          // the reply text so far (complete UTF-8 only)
    std::string pending;            // bytes of an unfinished UTF-8 character
    common_chat_msg msg;            // what the parser has made of the reply so far
    int n_gen = 0;
    clk::time_point t_admit, t_prefilled, t_first, t_last;
    bool got_first = false;
    double ms_decode = 0, ms_sample = 0, ms_parse = 0;     // where the time went (MOJOUI_LLM_DEBUG prints them)

    // events not yet polled (guarded by Engine::mu)
    std::string out;
    bool finished = false;
};

struct Seq {
    std::vector<llama_token> cached;    // tokens whose KV the sequence holds, in order
    std::deque<Ckpt> ckpts;
    std::shared_ptr<Req> active;
    std::deque<std::shared_ptr<Req>> queue;
};

struct Engine {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    const llama_vocab * vocab = nullptr;
    common_chat_templates_ptr tmpls;
    int n_ctx = 0, n_batch = 0, n_ubatch = 0;
    int wake_fd = -1;

    std::mutex mu;
    std::condition_variable cv;
    std::map<int64_t, std::shared_ptr<Req>> reqs;
    std::vector<Seq> seqs;
    int64_t next_id = 1;
    bool quit = false;
    std::thread th;
};

const size_t MAX_CKPTS = 6;

std::string jstr(const std::string & s) {
    std::string o = "\"";
    for (unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 32) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; } else o += (char) c;
        }
    }
    return o + "\"";
}

std::string num(double v) { char b[48]; snprintf(b, sizeof b, "%.3f", v); return b; }

void wake(Engine * e) {
    if (e->wake_fd >= 0) {
        char b = 1;
        ssize_t r = ::write(e->wake_fd, &b, 1);
        (void) r;
    }
}

// append one event line to a request's output
void emit(Engine * e, Req & r, const std::string & json) {
    bool was_empty;
    {
        std::lock_guard<std::mutex> l(e->mu);
        was_empty = r.out.empty();
        r.out += json;
        r.out += "\n";
    }
    if (was_empty) wake(e);
}

void emit_deltas(Engine * e, Req & r, const common_chat_msg & now) {
    for (const auto & d : common_chat_msg_diff::compute_diffs(r.msg, now)) {
        if (!d.reasoning_content_delta.empty()) emit(e, r, "{\"t\":\"reasoning\",\"s\":" + jstr(d.reasoning_content_delta) + "}");
        if (!d.content_delta.empty()) emit(e, r, "{\"t\":\"text\",\"s\":" + jstr(d.content_delta) + "}");
    }
    r.msg = now;
}

void emit_error(Engine * e, Req & r, const std::string & why) {
    emit(e, r, "{\"t\":\"error\",\"s\":" + jstr(why) + "}");
    std::lock_guard<std::mutex> l(e->mu);
    r.finished = true;
}

// length of the complete-UTF-8 prefix of s
size_t utf8_complete(const std::string & s) {
    size_t n = s.size();
    for (size_t back = 1; back <= 3 && back <= n; back++) {
        unsigned char c = (unsigned char) s[n - back];
        if ((c & 0xC0) == 0x80) continue;          // a continuation byte: look further back for its lead
        size_t need = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC0) ? 2 : 1;
        return need > back ? n - back : n;
    }
    return n;
}

size_t common_prefix(const std::vector<llama_token> & a, const std::vector<llama_token> & b) {
    size_t n = std::min(a.size(), b.size()), i = 0;
    while (i < n && a[i] == b[i]) i++;
    return i;
}

void seq_reset(Engine * e, int s) {
    llama_memory_seq_rm(llama_get_memory(e->ctx), s, -1, -1);
    e->seqs[s].cached.clear();
    e->seqs[s].ckpts.clear();
}

void take_checkpoint(Engine * e, int s, int32_t n) {
    Seq & sq = e->seqs[s];
    llama_synchronize(e->ctx);
    size_t sz = llama_state_seq_get_size_ext(e->ctx, s, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
    Ckpt c;
    c.n = n;
    c.data.resize(sz);
    size_t got = llama_state_seq_get_data_ext(e->ctx, c.data.data(), sz, s, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
    if (got != sz) return;
    for (auto it = sq.ckpts.begin(); it != sq.ckpts.end();) {
        if (it->n == n) it = sq.ckpts.erase(it); else ++it;
    }
    sq.ckpts.push_back(std::move(c));
    while (sq.ckpts.size() > MAX_CKPTS) sq.ckpts.pop_front();
}

// Turn a queued request into a prefilling one: template, tokens, cache reuse. false: an error event was emitted.
bool admit(Engine * e, int s, Req & r) {
    r.t_admit = clk::now();
    try {
        common_chat_templates_inputs in;
        in.messages = common_chat_msgs_parse_oaicompat(common_json::parse(r.messages));
        if (!r.tools.empty() && r.tools != "[]") in.tools = common_chat_tools_parse_oaicompat(common_json::parse(r.tools));
        in.add_generation_prompt = true;
        in.use_jinja = true;
        in.enable_thinking = r.think;
        in.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
        r.session = std::make_unique<common_chat_session>(e->tmpls.get(), e->vocab, in);
    } catch (const std::exception & ex) {
        emit_error(e, r, std::string("chat template: ") + ex.what());
        return false;
    }
    r.prompt.clear();
    for (const auto & part : r.session->prompt().parts) {
        auto t = common_tokenize(e->vocab, part.text, false, !part.is_input);
        r.prompt.insert(r.prompt.end(), t.begin(), t.end());
    }
    const int32_t n = (int32_t) r.prompt.size();
    if (n < 1 || n >= e->n_ctx - 8) {
        emit_error(e, r, "prompt of " + std::to_string(n) + " tokens does not fit the context of " + std::to_string(e->n_ctx));
        return false;
    }

    // where this prompt's generation prompt starts: the point the next turn will share (checkpoint there)
    int32_t gp = 0;
    {
        auto g = common_tokenize(e->vocab, r.session->generation_prompt(), false, true);
        gp = (int32_t) g.size();
        if (gp >= n || !std::equal(g.begin(), g.end(), r.prompt.end() - gp)) gp = std::min<int32_t>(4, n - 1);
    }
    r.ck_at = n - gp;

    // the cache
    Seq & sq = e->seqs[s];
    size_t common = common_prefix(sq.cached, r.prompt);
    if (common >= (size_t) n) common = n - 1;              // the last token is always evaluated, it makes the logits
    int32_t keep = 0;
    if (common > 0) {
        if (common == sq.cached.size()) {
            keep = (int32_t) common;                         // the live state is exactly the shared prefix
        } else {
            // the live recurrent state is ahead of the shared prefix: restore the newest checkpoint at or before it
            const Ckpt * best = nullptr;
            for (const auto & c : sq.ckpts) if ((size_t) c.n <= common && (!best || c.n > best->n)) best = &c;
            if (best && llama_state_seq_set_data_ext(e->ctx, best->data.data(), best->data.size(), s, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY) > 0) {
                keep = best->n;
            }
        }
    }
    if (getenv("MOJOUI_LLM_DEBUG")) {
        std::string cks;
        for (const auto & c : sq.ckpts) cks += " " + std::to_string(c.n);
        fprintf(stderr, "llm: seq %d prompt %d cached %zu common %zu keep %d ck_at %d checkpoints:%s\n", s, n, sq.cached.size(), common, keep, r.ck_at, cks.c_str());
    }
    if (keep > 0 && !llama_memory_seq_rm(llama_get_memory(e->ctx), s, keep, -1)) keep = 0;
    if (keep == 0) {
        seq_reset(e, s);
    } else {
        sq.cached.resize(keep);
        for (auto it = sq.ckpts.begin(); it != sq.ckpts.end();) {
            if (it->n > keep) it = sq.ckpts.erase(it); else ++it;
        }
    }
    r.n_done = r.n_cached = keep;
    if (r.ck_at <= keep) r.ck_at = -1;                       // already have it (or are past it)

    common_params_sampling sp;
    sp.temp = r.temp;
    sp.top_k = 20;
    sp.top_p = 0.95f;
    r.session->apply_sampling(sp);
    r.smpl = common_sampler_init(e->model, sp);
    if (!r.smpl) {
        emit_error(e, r, "could not make the sampler");
        return false;
    }
    return true;
}

void finish(Engine * e, int s, Req & r, const char * reason) {
    const bool cancelled = std::string(reason) == "cancel";
    if (r.session) {
        common_chat_input rest;
        if (!r.pending.empty()) rest = common_chat_input(std::string(r.pending));
        r.pending.clear();
        common_chat_msg fin = r.session->finish(rest);
        emit_deltas(e, r, fin);
        if (!fin.tool_calls.empty() && !cancelled) {
            std::string calls = "[";
            for (size_t i = 0; i < fin.tool_calls.size(); i++) {
                const auto & tc = fin.tool_calls[i];
                if (i) calls += ",";
                calls += "{\"id\":" + jstr(tc.id) + ",\"name\":" + jstr(tc.name) + ",\"arguments\":" + jstr(tc.arguments) + "}";
            }
            emit(e, r, "{\"t\":\"tools\",\"calls\":" + calls + "]}");
        }
    }
    auto ms = [](clk::time_point a, clk::time_point b) { return std::chrono::duration<double, std::milli>(b - a).count(); };
    double ttft = r.got_first ? ms(r.t_submit, r.t_first) : 0.0;
    double dec = r.got_first ? ms(r.t_first, r.t_last) : 0.0;
    double tps = (r.n_gen > 1 && dec > 0) ? (r.n_gen - 1) * 1000.0 / dec : 0.0;
    double prefill = r.generating ? ms(r.t_admit, r.t_prefilled) : 0.0;
    emit(e, r, std::string("{\"t\":\"done\",\"reason\":\"") + reason + "\",\"n_prompt\":" + std::to_string(r.prompt.size()) +
                   ",\"n_cached\":" + std::to_string(r.n_cached) + ",\"n_gen\":" + std::to_string(r.n_gen) +
                   ",\"prefill_ms\":" + num(prefill) + ",\"ttft_ms\":" + num(ttft) + ",\"tps\":" + num(tps) + "}");
    if (getenv("MOJOUI_LLM_DEBUG"))
        fprintf(stderr, "llm: %d tokens: decode %.1f ms/token, sample %.2f, parse+emit %.2f\n", r.n_gen,
                r.ms_decode / std::max(r.n_gen, 1), r.ms_sample / std::max(r.n_gen, 1), r.ms_parse / std::max(r.n_gen, 1));
    if (r.smpl) { common_sampler_free(r.smpl); r.smpl = nullptr; }
    {
        std::lock_guard<std::mutex> l(e->mu);
        r.finished = true;
        e->seqs[s].active.reset();
    }
    wake(e);
}

void handle_token(Engine * e, int s, Req & r, llama_token tok) {
    auto now = clk::now();
    if (!r.got_first) { r.got_first = true; r.t_first = now; }
    r.t_last = now;
    r.n_gen++;
    common_sampler_accept(r.smpl, tok, true);
    r.last = tok;
    if (llama_vocab_is_eog(e->vocab, tok)) { finish(e, s, r, "stop"); return; }

    r.pending += common_token_to_piece(e->ctx, tok, true);
    size_t ok = utf8_complete(r.pending);
    if (ok > 0) {
        std::string chunk = r.pending.substr(0, ok);
        r.pending.erase(0, ok);
        r.generated += chunk;
        common_chat_input ci;
        ci.append(chunk, tok);
        emit_deltas(e, r, r.session->feed(ci));
    }
    for (const auto & st : r.session->additional_stops()) {
        if (!st.empty() && r.generated.size() >= st.size() && r.generated.compare(r.generated.size() - st.size(), st.size(), st) == 0) {
            finish(e, s, r, "stop");
            return;
        }
    }
    if (r.n_gen >= r.max_tokens || (int) e->seqs[s].cached.size() + 1 >= e->n_ctx) finish(e, s, r, "length");
}

void engine_main(Engine * e) {
    common_batch batch(e->ctx);
    while (true) {
        {
            std::unique_lock<std::mutex> l(e->mu);
            e->cv.wait(l, [&] {
                if (e->quit) return true;
                for (auto & sq : e->seqs) if (sq.active || !sq.queue.empty()) return true;
                return false;
            });
            if (e->quit) break;
        }
        // admit what is waiting, end what was cancelled
        std::vector<std::pair<int, std::shared_ptr<Req>>> active;
        for (int s = 0; s < (int) e->seqs.size(); s++) {
            Seq & sq = e->seqs[s];
            while (true) {
                std::shared_ptr<Req> q;
                {
                    std::lock_guard<std::mutex> l(e->mu);
                    if (sq.active || sq.queue.empty()) break;
                    q = sq.queue.front();
                    sq.queue.pop_front();
                    sq.active = q;
                }
                if (q->cancel) { finish(e, s, *q, "cancel"); continue; }
                if (!admit(e, s, *q)) {
                    std::lock_guard<std::mutex> l(e->mu);
                    sq.active.reset();
                    continue;
                }
                break;
            }
            std::shared_ptr<Req> a;
            { std::lock_guard<std::mutex> l(e->mu); a = sq.active; }
            if (a && a->cancel) { finish(e, s, *a, "cancel"); a.reset(); }
            if (a) active.emplace_back(s, a);
        }
        if (active.empty()) continue;

        // one batch for every active sequence: a token each for the ones generating, a chunk for the ones reading
        batch.clear();
        for (auto & [s, rp] : active) {
            Req & r = *rp;
            Seq & sq = e->seqs[s];
            r.i_logits = -1;
            if (r.generating) {
                sq.cached.push_back(r.last);
                r.i_logits = batch.add(r.last, (llama_pos) (sq.cached.size() - 1), s, true);
            } else {
                int32_t n = (int32_t) r.prompt.size();
                int32_t take = std::min<int32_t>(n - r.n_done, e->n_ubatch);
                if (r.ck_at > r.n_done) take = std::min<int32_t>(take, r.ck_at - r.n_done);
                take = std::min<int32_t>(take, e->n_batch - batch.size());
                for (int32_t i = 0; i < take; i++) {
                    bool out = (r.n_done + i == n - 1);
                    int idx = batch.add(r.prompt[r.n_done + i], r.n_done + i, s, out);
                    if (out) r.i_logits = idx;
                    sq.cached.push_back(r.prompt[r.n_done + i]);
                }
                r.n_done += take;
            }
        }
        if (batch.size() == 0) continue;
        auto t_dec = clk::now();
        int ret = llama_process(e->ctx, LLAMA_PROCESS_TYPE_DECODE, batch.get());
        if (ret == 0) llama_synchronize(e->ctx);
        double dec_ms = std::chrono::duration<double, std::milli>(clk::now() - t_dec).count();
        if (ret != 0) {
            for (auto & [s, rp] : active) {
                emit_error(e, *rp, ret == 1 ? "the context is full" : "decode failed (" + std::to_string(ret) + ")");
                if (rp->smpl) { common_sampler_free(rp->smpl); rp->smpl = nullptr; }
                seq_reset(e, s);
                std::lock_guard<std::mutex> l(e->mu);
                e->seqs[s].active.reset();
            }
            wake(e);
            continue;
        }

        for (auto & [s, rp] : active) {
            Req & r = *rp;
            if (!r.generating && r.ck_at > 0 && r.n_done == r.ck_at) {
                take_checkpoint(e, s, r.ck_at);
                r.ck_at = -1;
            }
            if (r.i_logits < 0) continue;
            if (!r.generating) { r.generating = true; r.t_prefilled = clk::now(); }
            auto t_smp = clk::now();
            llama_token tok = common_sampler_sample(r.smpl, e->ctx, r.i_logits);
            auto t_prs = clk::now();
            r.ms_decode += dec_ms;
            r.ms_sample += std::chrono::duration<double, std::milli>(t_prs - t_smp).count();
            handle_token(e, s, r, tok);
            r.ms_parse += std::chrono::duration<double, std::milli>(clk::now() - t_prs).count();
        }
    }
    for (int s = 0; s < (int) e->seqs.size(); s++) {
        auto a = e->seqs[s].active;
        if (a && !a->finished) finish(e, s, *a, "cancel");
    }
}

}  // namespace

extern "C" {

int64_t llm_load(const char * path, int64_t gpu, int64_t n_ctx, int64_t n_seq, int64_t kv_q8, int64_t flash, int64_t wake_fd) {
    try {
        static std::once_flag once;
        std::call_once(once, [] {
            const char * dir = getenv("MOJOUI_LLAMA_DIR");
            if (!getenv("MOJOUI_LLM_LOG")) {                // quiet unless asked: llama.cpp is chatty on stderr
                llama_log_set([](ggml_log_level lv, const char * text, void *) {
                    if (lv == GGML_LOG_LEVEL_ERROR) fputs(text, stderr);
                }, nullptr);
                common_log_set_verbosity_thold(-1);
            }
            llama_backend_init();
            if (dir && *dir) ggml_backend_load_all_from_path(dir); else ggml_backend_load_all();
        });
        llama_model_params mp = llama_model_default_params();
        ggml_backend_dev_t devs[2] = {nullptr, nullptr};
        if (gpu >= 0) {
            int seen = 0;
            for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
                ggml_backend_dev_t d = ggml_backend_dev_get(i);
                if (ggml_backend_dev_type(d) == GGML_BACKEND_DEVICE_TYPE_GPU && seen++ == gpu) { devs[0] = d; break; }
            }
            if (!devs[0]) { set_error("no GPU number " + std::to_string(gpu)); return 0; }
            mp.devices = devs;
            mp.n_gpu_layers = -1;
            mp.split_mode = LLAMA_SPLIT_MODE_NONE;
            mp.main_gpu = 0;
        } else {
            mp.n_gpu_layers = 0;
        }
        std::unique_ptr<Engine> e(new Engine());
        e->model = llama_model_load_from_file(path, mp);
        if (!e->model) { set_error(std::string("could not load ") + path); return 0; }
        e->vocab = llama_model_get_vocab(e->model);

        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = (uint32_t) n_ctx;
        cp.n_batch = 2048;
        cp.n_ubatch = 512;
        cp.n_seq_max = (uint32_t) std::max<int64_t>(n_seq, 1);
        cp.kv_unified = true;
        cp.flash_attn_type = flash ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED;
        if (kv_q8) { cp.type_k = GGML_TYPE_Q8_0; cp.type_v = GGML_TYPE_Q8_0; }
        cp.no_perf = true;
        e->ctx = llama_init_from_model(e->model, cp);
        if (!e->ctx) { llama_model_free(e->model); set_error("could not make the context (out of memory?)"); return 0; }
        e->n_ctx = (int) llama_n_ctx(e->ctx);
        e->n_batch = (int) llama_n_batch(e->ctx);
        e->n_ubatch = (int) llama_n_ubatch(e->ctx);
        e->tmpls = common_chat_templates_init(e->model, "");
        if (!e->tmpls) { llama_free(e->ctx); llama_model_free(e->model); set_error("the model has no chat template"); return 0; }
        e->wake_fd = (int) wake_fd;
        e->seqs.resize(cp.n_seq_max);
        Engine * raw = e.release();
        raw->th = std::thread(engine_main, raw);
        return (int64_t) (intptr_t) raw;
    } catch (const std::exception & ex) {
        set_error(ex.what());
        return 0;
    }
}

int64_t llm_last_error(char * buf, int64_t cap) {
    std::lock_guard<std::mutex> l(g_err_mu);
    int64_t n = std::min<int64_t>((int64_t) g_err.size(), cap);
    if (buf && n > 0) memcpy(buf, g_err.data(), (size_t) n);
    return n;
}

// what: 0 = the context's size in tokens, 1 = the number of sequences
int64_t llm_info(int64_t h, int64_t what) {
    Engine * e = (Engine *) (intptr_t) h;
    if (!e) return -1;
    return what == 0 ? e->n_ctx : what == 1 ? (int64_t) e->seqs.size() : -1;
}

int64_t llm_chat(int64_t h, int64_t seq, const char * msgs, int64_t msgs_len, const char * tools, int64_t tools_len,
                 int64_t think, int64_t max_tokens, int64_t temp_milli) {
    Engine * e = (Engine *) (intptr_t) h;
    if (!e || seq < 0 || seq >= (int64_t) e->seqs.size()) { set_error("bad handle or sequence"); return 0; }
    auto r = std::make_shared<Req>();
    r->messages.assign(msgs, (size_t) msgs_len);
    if (tools && tools_len > 0) r->tools.assign(tools, (size_t) tools_len);
    r->think = think != 0;
    r->max_tokens = (int) max_tokens;
    r->temp = (float) temp_milli / 1000.0f;
    int64_t id;
    {
        std::lock_guard<std::mutex> l(e->mu);
        id = r->id = e->next_id++;
        e->reqs[id] = r;
        e->seqs[seq].queue.push_back(r);
    }
    e->cv.notify_all();
    return id;
}

// New events of request `req` as whole JSON lines. >= 0: bytes copied (0: nothing yet); -1: unknown request (finished and
// read, or never made); <= -2: the next line needs (-n - 1) bytes: call again with a bigger buffer.
int64_t llm_poll(int64_t h, int64_t req, char * buf, int64_t cap) {
    Engine * e = (Engine *) (intptr_t) h;
    if (!e) return -1;
    std::lock_guard<std::mutex> l(e->mu);
    auto it = e->reqs.find(req);
    if (it == e->reqs.end()) return -1;
    Req & r = *it->second;
    size_t take = 0;
    if (!r.out.empty()) {
        if (r.out.size() <= (size_t) cap) {
            take = r.out.size();
        } else {
            size_t nl = r.out.rfind('\n', (size_t) cap - 1);
            if (nl == std::string::npos) return -(int64_t) (r.out.find('\n') + 1) - 1;
            take = nl + 1;
        }
        memcpy(buf, r.out.data(), take);
        r.out.erase(0, take);
    }
    if (r.out.empty() && r.finished) e->reqs.erase(it);
    return (int64_t) take;
}

void llm_cancel(int64_t h, int64_t req) {
    Engine * e = (Engine *) (intptr_t) h;
    if (!e) return;
    {
        std::lock_guard<std::mutex> l(e->mu);
        auto it = e->reqs.find(req);
        if (it == e->reqs.end()) return;
        it->second->cancel = true;
    }
    e->cv.notify_all();
}

void llm_free(int64_t h) {
    Engine * e = (Engine *) (intptr_t) h;
    if (!e) return;
    {
        std::lock_guard<std::mutex> l(e->mu);
        e->quit = true;
    }
    e->cv.notify_all();
    e->th.join();
    e->tmpls.reset();
    llama_free(e->ctx);
    llama_model_free(e->model);
    delete e;
}

}
