# saas_min (goal 60 M11): Google sign-in, a tenant per person and a welcome email, from three mojoui modules dropped
# in (accounts, jobs, mail) on mojoui.serve: no billing linked. Same environment as examples/saas (docs/saas.md).
#   scripts/mojo_flare.sh build examples/saas_min/server.mojo -o build/saas_min/server
from std.os import getenv
from mojoui.serve import Handler, Req, Reply, serve
from mojoui.accounts import Accounts, AuthConfig
from mojoui.jobs import Queue, QueuedJob, Runner, start_workers
from mojoui.mail import SmtpConfig, send, welcome
from mojoui.json import Json
from mojoui.log import Log
from mojoui import libc


struct App(Handler):
    var acc: Accounts

    def __init__(out self, var acc: Accounts):
        self.acc = acc^

    def answer(self, mut req: Req) -> Reply:
        var r = self.acc.handle(req)  # sign-in, sessions, /api/me, tenants, invites
        if r.status != 0:
            return r^
        return Reply.not_found()

    def blocking(self, req: Req) -> Bool:
        return self.acc.blocking(req)  # (the callback waits on Google: off the reactor)

    def tick(self):
        pass

    def stop(self):
        pass


struct Welcome(Runner):
    var smtp: SmtpConfig
    var base: String

    def __init__(out self, var smtp: SmtpConfig, base: String):
        self.smtp = smtp^
        self.base = base

    def run(self, job: QueuedJob) -> String:
        if job.kind != "signed_up" or not self.smtp.ready():
            return ""
        try:
            var j = Json.parse(job.payload)
            send(self.smtp, welcome(j.text(j.get(0, "email")), j.text(j.get(0, "name")), "saas_min", self.base))
            return ""
        except e:
            return String(e)  # (retried with backoff, then dead)


def main() raises:
    var data = getenv("SAAS_DATA", "data")
    var log = Log.open(getenv("SAAS_LOG"))
    log.secret(getenv("SMTP_PASSWORD"))
    var jobs = Queue(data + "/host.db")
    var acc = Accounts(data, AuthConfig.from_env(), log, jobs)
    start_workers(jobs, Welcome(SmtpConfig.from_env(), acc.cfg.base + "/"))
    var served = serve(App(acc^), port=atol(getenv("SAAS_PORT", "8000")), log=log)
    print("SAAS: listening " + String(served.port), flush=True)
    while not served.stopped():
        _ = libc.poll(0, 0, 500)
    served.stop()
