# saas_min (goal 60 M11): Google sign-in, a tenant per person and a welcome email, from three mojoui modules dropped
# in (accounts, jobs, mail) on mojoui.serve: no billing linked. Same environment as examples/saas (docs/saas.md).
#   scripts/mojo_flare.sh build examples/saas_min/server.mojo -o build/saas_min/server
from std.os import getenv
from mojoui.serve import Handler, Req, Reply, serve
from mojoui.accounts import Accounts, AuthConfig
from mojoui.jobs import Queue, QueuedJob, Runner, start_workers, permanent
from mojoui.clientip import TrustedProxies
from mojoui.mail import SmtpConfig, send, welcome
from mojoui.json import Json
from mojoui.log import Log
from mojoui import libc


struct App(Handler):
    var acc: Accounts
    var jobs: Queue

    def __init__(out self, var acc: Accounts, jobs: Queue):
        self.acc = acc^
        self.jobs = jobs

    def answer(self, mut req: Req) -> Reply:
        var r = self.acc.handle(req)  # sign-in, sessions, /api/me, tenants, invites
        if r.status != 0:
            return r^
        return Reply.not_found()

    def blocking(self, req: Req) -> Bool:
        return self.acc.blocking(req)  # (the callback waits on Google: off the reactor)

    def tick(self):
        try:  # (expired sign-ins and sessions, old jobs)
            _ = self.acc.sweep()
            _ = self.jobs.sweep()
        except:
            pass

    def stop(self):
        pass


struct Welcome(Runner):
    var smtp: SmtpConfig
    var acc: Accounts

    def __init__(out self, var smtp: SmtpConfig, var acc: Accounts):
        self.smtp = smtp^
        self.acc = acc^

    def run(self, job: QueuedJob) -> String:
        if job.kind != "signed_up":
            return ""
        try:
            var j = Json.parse(job.payload)  # {user}
            var who = self.acc.user_email(j.number(j.get(0, "user")))
            if who:
                send(self.smtp, welcome(who.value()[0], who.value()[1], "saas_min", self.acc.cfg.base + "/"))
            return ""
        except e:
            return String(e)  # (retried with backoff, then dead; an SMTP 5xx at once)


def main() raises:
    var data = getenv("SAAS_DATA", "data")
    var log = Log.open(getenv("SAAS_LOG"))
    _ = log.secret(getenv("SMTP_PASSWORD"))
    var jobs = Queue(data + "/host.db")
    var acc = Accounts(data, AuthConfig.from_env(), log, jobs)
    var smtp = SmtpConfig.from_env()
    if smtp.ready():  # (else the welcomes wait, pending, until a restart with SMTP set)
        start_workers(jobs, Welcome(smtp^, acc.copy()))
    var served = serve(App(acc^, jobs), port=atol(getenv("SAAS_PORT", "8000")), tick_ms=60_000, log=log,
                       proxies=TrustedProxies.parse(getenv("SAAS_TRUSTED_PROXIES")))
    print("SAAS: listening " + String(served.port), flush=True)
    while not served.stopped():
        _ = libc.poll(0, 0, 500)
    served.stop()
