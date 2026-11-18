# mojoui.llmjob: "think it through and get back to me": a background job on the model's second sequence, with thinking on
# (goal 72 M6, D-7264; omx-local's jobs.py, M23).
#
#   var job = ThinkJob("a second RTX 3090 or one 5090", "I have 3,000 dollars. Should I buy …?")
#   job.start(agent.llm)                 # sequence 1 (the conversation keeps sequence 0 and stays live); returns at once
#   update() on a timer / the LLM's wake:  if job.poll(agent.llm): …                 # True when something changed
#   ThinkCard(job)                       # "Thinking 0:42" while it works, the answer when it is done; the thinking is never shown
#   job_notice(job)                      # "I've finished thinking about X. It's on your screen." (the app speaks it when the
#                                        #  person isn't talking)    job_memory(job): what the conversation learns from it
#
# Sequence 0's `think` stays fixed (D-7204: switching it between turns breaks the prompt cache); the job is its own request on
# sequence 1, so it costs the conversation one batch row per step and nothing else. The model's thinking arrives as REASONING
# events: it is counted (the card says how long, not what), kept only to write the answer from if the thinking used up the
# whole budget, and dropped. A stray <think> block in the answer is cut.

from mojoui.clock import now_ns
from mojoui.json import json_string
from mojoui.llm import Llm, LlmEvent, TEXT, REASONING, TOOL_CALLS, DONE, ERROR
from mojoui.paragraph import Paragraph, Plain, Run
from mojoui.view import View, Text, Button, Card, HEADLINE, CAPTION, SUBTLE, NO_MSG

comptime JOB_RUNNING = 0
comptime JOB_DONE = 1
comptime JOB_FAILED = 2

comptime JOB_SYSTEM = (
    "Think carefully, then give a clear, well-organised answer for a busy person: a one-line bottom line first, then short "
    "sections or a numbered list. Plain text, no tables."
)
comptime KEEP_NOTES = 12000  # bytes of thinking kept for a second pass
comptime MAX_ANSWER = 6000
comptime MEMORY_ANSWER = 3000


def strip_thinking(text: String) -> String:
    """The text without any <think>…</think> block (or an unopened one's tail up to </think>)."""
    var t = text
    while True:
        var a = t.find("<think>")
        if a < 0:
            break
        var z = t.find("</think>", a)
        if z < 0:
            var head = String(t[byte = :a])
            t = head^
            break
        var joined = String(t[byte = :a]) + String(t[byte = z + 8 :])
        t = joined^
    var z = t.find("</think>")
    if z >= 0:
        var rest = String(t[byte = z + 8 :])
        t = rest^
    return String(t.strip())


struct ThinkJob(Movable):
    var title: String
    var task: String
    var state: Int
    var started_ns: Int
    var ended_ns: Int
    var req: Int
    var second: Bool  # the second pass (the answer from the notes) is the request now
    var answer: String
    var notes: String
    var thought_chars: Int
    var error: String
    var max_tokens: Int

    def __init__(out self, title: String, task: String, max_tokens: Int = 5000):
        self.title = title
        self.task = task
        self.state = JOB_RUNNING
        self.started_ns = now_ns()
        self.ended_ns = 0
        self.req = 0
        self.second = False
        self.answer = String("")
        self.notes = String("")
        self.thought_chars = 0
        self.error = String("")
        self.max_tokens = max_tokens

    def start(mut self, llm: Llm):
        """Begins thinking on sequence 1; a failure to start is the job's failure."""
        self.started_ns = now_ns()
        var msgs = '[{"role":"system","content":' + json_string(JOB_SYSTEM) + '},{"role":"user","content":' + json_string(self.task) + "}]"
        try:
            self.req = llm.chat(msgs, "", 1, True, self.max_tokens, 0.6)
        except e:
            self.fail(String(e))

    def fail(mut self, why: String):
        self.state = JOB_FAILED
        self.error = String("The background job failed: " + why)
        self.ended_ns = now_ns()

    def finished(self) -> Bool:
        return self.state != JOB_RUNNING

    def seconds(self) -> Int:
        var end = self.ended_ns if self.ended_ns > 0 else now_ns()
        return (end - self.started_ns) // 1_000_000_000

    def clock(self) -> String:
        """The time so far as m:ss."""
        var s = self.seconds()
        return String(s // 60) + ":" + ("0" if s % 60 < 10 else "") + String(s % 60)

    def poll(mut self, llm: Llm) -> Bool:
        """Reads what the model has produced since; True when the job changed state or the clock moved a whole second."""
        if self.state != JOB_RUNNING:
            return False
        var before = self.seconds()
        var evs = List[LlmEvent]()
        try:
            evs = llm.poll(self.req)
        except e:
            self.fail(String(e))
            return True
        for ref e in evs:
            if e.kind == TEXT:
                self.answer = self.answer + e.text
            elif e.kind == REASONING:
                self.thought_chars += e.text.byte_length()
                if not self.second:
                    self.notes = self.notes + e.text
                    if self.notes.byte_length() > KEEP_NOTES * 2:
                        var tail = String(self.notes[byte = self.notes.byte_length() - KEEP_NOTES :])
                        self.notes = tail^
            elif e.kind == ERROR:
                self.fail(e.text)
                return True
            elif e.kind == DONE:
                self.settle(llm)
                return True
        return self.seconds() != before

    def settle(mut self, llm: Llm):
        """The request ended. A short answer after a long thinking (the budget ran out) gets one more pass, with thinking off,
        that writes the answer from the notes; otherwise the job is done."""
        var text = strip_thinking(self.answer)
        if text.byte_length() < 80 and self.notes != "" and not self.second:
            self.second = True
            self.answer = String("")
            var tail = self.notes if self.notes.byte_length() <= KEEP_NOTES else String(self.notes[byte = self.notes.byte_length() - KEEP_NOTES :])
            var msgs = (
                '[{"role":"system","content":' + json_string(JOB_SYSTEM) + '},{"role":"user","content":'
                + json_string(self.task + "\n\nYour working notes so far (private, do not quote them):\n" + tail + "\n\nNow write the final answer.") + "}]"
            )
            try:
                self.req = llm.chat(msgs, "", 1, False, 1500, 0.6)
                return
            except e:
                self.fail(String(e))
                return
        var cut = text if text.byte_length() <= MAX_ANSWER else String(text[byte = :MAX_ANSWER])
        self.answer = cut if cut != "" else String("I couldn't reach an answer.")
        self.state = JOB_DONE
        self.ended_ns = now_ns()
        self.notes = String("")  # (the thinking is dropped: never shown, never kept)

    def cancel(mut self, llm: Llm):
        if self.state == JOB_RUNNING:
            llm.cancel(self.req)
            self.fail("cancelled")


def ThinkCard(job: ThinkJob, dismiss: Int = NO_MSG) -> View:
    """The job as a card: its title; "Thinking 0:42" while it works, "Thought for 1:12" and the answer when it is done; the
    error when it failed, and (given a message) a Dismiss button once it has ended. Build it from the job each time: the clock is
    the job's, so it ticks in place."""
    var rows = List[View]()
    rows.append(Text(job.title if job.title != "" else String("Thinking it through"), HEADLINE))
    if job.state == JOB_RUNNING:
        rows.append(Text("Thinking " + job.clock(), CAPTION))
    elif job.state == JOB_DONE:
        rows.append(Text("Thought for " + job.clock(), CAPTION))
        var runs = List[Run]()
        runs.append(Plain(job.answer))
        rows.append(Paragraph(runs^, role="job-answer"))
    else:
        rows.append(Text(job.error, CAPTION))
    if job.state != JOB_RUNNING and dismiss != NO_MSG:
        rows.append(Button("Dismiss", dismiss, SUBTLE))
    return Card(rows^).tag("job").fill()


def job_notice(job: ThinkJob) -> String:
    """The one sentence spoken when it is done (the person isn't talking), or when it failed."""
    if job.state == JOB_DONE:
        return "I've finished thinking about " + job.title + ". It's on your screen." if job.title != "" else String("I've finished thinking it through. It's on your screen.")
    return "I couldn't finish thinking about " + job.title + "." if job.title != "" else String("I couldn't finish thinking that through.")


def job_memory(job: ThinkJob) -> String:
    """What the conversation learns when the job lands (at the start of the next turn, never in the middle of one)."""
    if job.state != JOB_DONE:
        return String("")
    var a = job.answer if job.answer.byte_length() <= MEMORY_ANSWER else String(job.answer[byte = :MEMORY_ANSWER])
    return "(I finished thinking about " + job.title + " in the background and showed it on screen. What I worked out:) " + a
