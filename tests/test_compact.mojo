# mojoui.llmagent's "never full" (goal 72 review, D-7292): a long scripted conversation on a small context (8192 tokens, so the
# budget is 3276) never fails with "does not fit". The older turns are condensed by the model's second sequence between turns,
# a fact told in the very first turn is still recalled after several condensings, the first words of late turns come as fast
# as those of early ones (the cache is warmed for the condensed history while nobody waits), and start_over() forgets it all.
#   scripts/mojo_flare.sh build tests/test_compact.mojo -o build/test_compact && LLM_GPU=0 build/test_compact
# Environment: LLM_GGUF (default ~/Projects/omx-local/models/Qwen3.8-27B-UD-Q4_K_M.gguf), LLM_GPU (default 0).
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true
from std.ffi import external_call
from mojoui.clock import now_ns
from mojoui.json import json_string
from mojoui.llm import Llm
from mojoui.llmagent import LlmAgent, SUMMARY_MARK

comptime TURNS = 84  # (COMPACT_TURNS shortens a run while looking into something)
comptime SYSTEM = "You are a voice assistant. Answer in one short sentence. When the person asks about something they told you earlier, answer from what you remember of the conversation."


def sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](Int32(ms * 1000))


def ms_since(t0: Int) -> Float64:
    return Float64(now_ns() - t0) / 1e6


def run_input(run: String, user: String) -> String:
    return ('{"threadId":"long","runId":' + json_string(run) + ',"state":{},"messages":[{"id":"u-' + run + '","role":"user","content":' + json_string(user)
            + '}],"tools":[],"context":[],"forwardedProps":{}}')


def median(var xs: List[Float64]) -> Float64:
    sort(xs)
    return xs[len(xs) // 2]


comptime ANIMALS = "fox,heron,otter,badger,lynx,stork,marmot,newt,bison,gecko,falcon,tapir"
comptime PLACES = "marsh,canyon,orchard,glacier,harbour,meadow,quarry,island,valley,forest,desert,lagoon"
comptime FOODS = "acorns,beetles,clover,dates,eels,figs,grubs,honey,ivy,juniper berries,kelp,lichen"


def pick(csv: String, k: Int) -> String:
    return String(csv.split(",")[k % 12])


def the_food(n: Int, i: Int) -> String:
    return pick(String(FOODS), n + i * 7 + 3)


def a_turn(n: Int) -> String:
    """A user turn of about 150 tokens: nine sentences about animals that differ from one turn to the next, then a question about
    one of them (a plain question and answer: the replies stay real, however long the conversation gets)."""
    var text = String("Field notes number ") + String(n) + ". "
    for i in range(9):
        text += "The " + pick(String(ANIMALS), n + i * 5) + " in the " + pick(String(PLACES), n * 3 + i) + " eats " + the_food(n, i) + ". "
    var k = n % 9
    return text + "Question: what does the " + pick(String(ANIMALS), n + k * 5) + " eat?"


def spoken(events: List[String]) raises -> String:
    """The words of the reply: the TEXT_MESSAGE_CONTENT deltas, joined."""
    var out = String("")
    for ref e in events:
        if e.find('"type":"TEXT_MESSAGE_CONTENT"') >= 0:
            out += String(e.split('"delta":"')[1].split('"}')[0])
    return out^


def says(events: List[String], what: String) -> Bool:
    for ref e in events:
        if e.find(what) >= 0:
            return True
    return False


def main() raises:
    var gguf = getenv("LLM_GGUF", getenv("HOME", "") + "/Projects/omx-local/models/Qwen3.8-27B-UD-Q4_K_M.gguf")
    var gpu = Int(getenv("LLM_GPU", "0"))
    var agent = LlmAgent(Llm(gguf, gpu=gpu, n_ctx=8192, n_seq=2), SYSTEM, max_tokens=80, temperature=Float64(getenv("COMPACT_TEMP", "0.0") == "0.3") * 0.3)  # (greedy: the same words every run; COMPACT_TEMP=0.3 looks into sampling)
    assert_equal(agent.budget(), 3276)
    var turns = Int(getenv("COMPACT_TURNS", String(TURNS)))
    var early = List[Float64]()
    var late = List[Float64]()
    var worst_history = 0
    var errors = String("")
    var replies = String("")
    var wrong = 0  # replies that didn't name the right food
    var first_gone_at = -1
    var compactions_seen = 0
    for turn in range(1, turns + 1):
        var words = String("My locker code is 7731 and my dog is called Biscuit. Please remember both. ") + a_turn(turn) if turn == 1 else a_turn(turn)
        var events = agent.respond(run_input("r" + String(turn), words))
        if says(events, '"type":"RUN_ERROR"'):
            errors += "turn " + String(turn) + ": " + events[len(events) - 1] + " | "
        assert_true(says(events, '"type":"RUN_FINISHED"'), "turn " + String(turn) + " did not finish")
        var said_now = spoken(events)
        assert_true(said_now.byte_length() > 0, "turn " + String(turn) + " got an empty reply")
        if said_now.lower().find(the_food(turn, turn % 9)) < 0:
            wrong += 1
        replies += String(turn) + ":" + said_now + " [" + agent.last_reason + "] | "
        if turn >= 3 and turn <= 12:
            early.append(agent.first_text_ms)
        # the idle moment between turns: the summary is made and swapped in, the cache is warmed (an app does this on its tick)
        var t_idle = now_ns()
        while agent.maintain():
            sleep_ms(5)
            assert_true(ms_since(t_idle) < 120_000, "the condensing never ended")
        if agent.compactions > compactions_seen:
            compactions_seen = agent.compactions
            print("  turn", turn, ": condensed", compactions_seen, "time(s); the summary took", agent.compact_ms, "ms; the history is now", len(agent.history), "messages; waited", ms_since(t_idle), "ms")
        if agent.compactions >= 2:
            assert_true(agent.first_text_ms > 0, "late turn " + String(turn) + " had no first words")
            late.append(agent.first_text_ms)
        var bytes = 0
        for ref m in agent.history:
            bytes += m.byte_length()
        worst_history = max(worst_history, bytes)
        if first_gone_at < 0 and agent.compactions > 0:
            first_gone_at = turn
    print("  replies:", replies)
    assert_equal(errors, "")  # never "does not fit", never a failed run
    assert_true(wrong <= turns // 10, String(wrong) + " of " + String(turns) + " answers were wrong")
    assert_true(agent.compactions >= 3, "condensed " + String(agent.compactions) + " times in " + String(TURNS) + " turns")
    assert_true(worst_history < 3276 * 5, "the history stayed inside its budget: " + String(worst_history) + " bytes")
    # the first turn's words are gone from the history, and what they said is in a summary
    var summary = String("")
    var original_there = False
    for ref m in agent.history:
        if m.find(SUMMARY_MARK) >= 0:
            summary = m
        if m.find("Please remember both") >= 0:  # (the first turn's own words)
            original_there = True
    assert_true(summary != "", "the history opens with a summary")
    assert_true(not original_there, "the first turn was condensed away")
    assert_true(summary.find("7731") >= 0 and summary.find("Biscuit") >= 0, "the summary kept both facts: " + summary)
    # ... and the model still knows them
    var recall = agent.respond(run_input("recall", "Quick question, what is my locker code and what is my dog called?"))
    var said = spoken(recall)
    print("  asked after", agent.compactions, "condensings:", said)
    assert_true(said.find("7731") >= 0 and said.find("Biscuit") >= 0, "recalled both facts from the first turn: " + said)
    # first words of late turns against early ones
    var e_med = median(early.copy())
    var l_med = median(late.copy())
    print("  first words: early turns (3-12) median", e_med, "ms; late turns (after two condensings,", len(late), "of them) median", l_med, "ms; ratio", l_med / e_med)
    assert_true(len(late) >= 10, "enough late turns to compare: " + String(len(late)))
    assert_true(l_med <= e_med * 1.3, "late turns' first words took " + String(l_med) + " ms against " + String(e_med) + " ms early")
    # start over forgets it all
    agent.start_over()
    assert_equal(len(agent.history), 0)
    assert_equal(agent.compactions, 0)
    var blank = agent.respond(run_input("after-reset", "What is my locker code? If you don't know say you don't know."))
    var after = spoken(blank)
    assert_true(after.find("7731") < 0, "after start over it does not know the code: " + after)
    makedirs("build/g72", exist_ok=True)
    with open("build/g72/compact-bench.json", "w") as f:
        f.write('{"n_ctx":8192,"budget":3276,"turns":' + String(TURNS) + ',"compactions":' + String(compactions_seen) + ',"early_first_words_ms":' + String(e_med)
                + ',"late_first_words_ms":' + String(l_med) + ',"ratio":' + String(l_med / e_med) + ',"worst_history_bytes":' + String(worst_history) + "}\n")
    print("compact: ok")
