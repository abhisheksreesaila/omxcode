# mojoui.llmjob (goal 72 M6): a job thinks on sequence 1 while the conversation answers on sequence 0; its answer has no
# thinking in it and its card shows a clock, not the thoughts. The model is the real Qwen3.8-27B on GPU $LLM_GPU (default 0).
#   scripts/mxbuild.sh tests/test_llmjob.mojo -o build/test_llmjob && build/test_llmjob
from std.os import getenv
from std.testing import assert_equal, assert_true
from mojoui.clock import now_ns
from mojoui.llm import Llm
from mojoui.llmjob import ThinkJob, ThinkCard, job_notice, job_memory, strip_thinking, JOB_DONE, JOB_RUNNING
from mojoui.uijobs import wake_pipe
from mojoui.view import TEXT
from mojoui import libc


def main() raises:
    # the parts that need no model
    assert_equal(strip_thinking("<think>hmm, 2+2</think>The answer is four."), "The answer is four.")
    assert_equal(strip_thinking("notes that never opened</think>  Four."), "Four.")
    assert_equal(strip_thinking("Four."), "Four.")
    var idle = ThinkJob("two plus two", "What is two plus two?")
    assert_equal(idle.clock(), "0:00")
    assert_equal(job_notice(idle), "I couldn't finish thinking about two plus two.")  # (not done: the notice for a failure)

    var gguf = getenv("LLM_GGUF", getenv("HOME", "") + "/Projects/omx-local/models/Qwen3.8-27B-UD-Q4_K_M.gguf")
    var gpu = Int(getenv("LLM_GPU", "0"))
    _ = wake_pipe()
    var llm = Llm(gguf, gpu=gpu, n_ctx=32768, n_seq=2)

    var job = ThinkJob("a small sum", "Work out 17 times 23 and tell me the result. Think it through.")
    job.start(llm)
    assert_equal(job.state, JOB_RUNNING)

    # while it thinks, the conversation (sequence 0) answers at once
    var t0 = now_ns()
    var paris = llm.complete('[{"role":"user","content":"What is the capital of France? One word."}]')
    var chat_ms = Float64(now_ns() - t0) / 1e6
    assert_true(paris.text.find("Paris") >= 0, "Paris: " + paris.text)
    print("llmjob: the conversation answered in", chat_ms, "ms while the job was", "running" if job.state == JOB_RUNNING else "done")

    var until = now_ns() + 240_000_000_000
    while not job.finished() and now_ns() < until:
        _ = job.poll(llm)
        _ = libc.usleep(5000)
    assert_equal(job.state, JOB_DONE)
    assert_true(job.answer.find("391") >= 0, "the answer: " + job.answer)
    assert_true(job.answer.find("<think>") < 0 and job.answer.find("</think>") < 0, "thinking in the answer")
    assert_true(job.thought_chars > 0, "no thinking came back separately: was thinking on?")
    assert_equal(job.notes, "")  # the thinking is dropped once the answer is in
    print("llmjob: ok", job.seconds(), "s,", job.thought_chars, "chars of thinking kept out;", job.answer[byte = :60])

    # the card says the time and shows the answer, never the thoughts
    var card = ThinkCard(job)
    var texts = String("")
    for ref n in card.nodes:
        if n.kind == TEXT:
            texts += n.text + "|"
    assert_equal(texts, "a small sum|Thought for " + job.clock() + "|")
    assert_equal(job_notice(job), "I've finished thinking about a small sum. It's on your screen.")
    assert_true(job_memory(job).startswith("(I finished thinking about a small sum in the background"))
