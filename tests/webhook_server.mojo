# Goal 66 M1's server: mojoui.webhooks with four sources (Stripe-style, hex, base64, Standard Webhooks), processing
# on mojoui.jobs: each new event's job records processed(source, event, attempts) in host.db; a body holding
# "fail_once" fails its first try. Driven by docs/goals/66-check.py (WH_DATA, WH_PORT).
from std.os import getenv, makedirs
from mojoui.serve import Handler, Req, Reply, serve
from mojoui.webhooks import Webhooks, Source, JOB_KIND
from mojoui.jobs import Queue, QueuedJob, Runner, start_workers
from mojoui import libc


struct Hooks(Handler):
    var hooks: Webhooks
    var sources: List[Source]

    def __init__(out self, hooks: Webhooks, var sources: List[Source]):
        self.hooks = hooks
        self.sources = sources^

    def answer(self, mut req: Req) -> Reply:
        if req.matches("POST", "/hooks/{name}"):
            for s in self.sources:
                if s.name == req.param("name"):
                    return self.hooks.receive(req, s)
        return Reply.not_found()

    def blocking(self, req: Req) -> Bool:
        return False

    def tick(self):
        pass

    def stop(self):
        pass


struct Record(Runner):
    var hooks: Webhooks

    def __init__(out self, hooks: Webhooks):
        self.hooks = hooks

    def run(self, job: QueuedJob) -> String:
        if job.kind != JOB_KIND:
            return ""
        try:
            var ev = self.hooks.job_event(job.payload)
            if ev[3].find("fail_once") >= 0 and job.attempts == 1:
                return "the first try fails on purpose"
            var db = self.hooks.db()
            var q = db.prepare("INSERT OR REPLACE INTO processed(source, event, attempts) VALUES (?, ?, ?)")
            q.bind(1, ev[0])
            q.bind(2, ev[1])
            q.bind(3, job.attempts)
            q.run()
            return ""
        except e:
            return String(e)


def main() raises:
    var data = getenv("WH_DATA", "data")
    makedirs(data, exist_ok=True)
    var q = Queue(data + "/host.db", backoff_ms=200, max_attempts=4)
    var hooks = Webhooks(data + "/host.db", q)
    hooks.db().exec("CREATE TABLE IF NOT EXISTS processed(source TEXT, event TEXT, attempts INTEGER, PRIMARY KEY(source, event))")
    var sources = List[Source]()
    sources.append(Source.stripe("stripe", "whsec_66"))
    sources.append(Source.hmac_hex("hex", "hex-66"))
    sources.append(Source.hmac_b64("b64", "b64-66"))
    sources.append(Source.standard("svix", "whsec_c3ZpeC02Ni1zZWNyZXQ="))
    start_workers(q, Record(hooks), threads=2)
    var served = serve(Hooks(hooks, sources^), port=atol(getenv("WH_PORT", "8000")), max_body=2 * 1024 * 1024)
    print("SAAS: listening " + String(served.port), flush=True)
    while not served.stopped():
        _ = libc.poll(0, 0, 500)
    served.stop()
