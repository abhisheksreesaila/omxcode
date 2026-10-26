# Add a model's flows (blade-add.js mountAdd): what each message and reply does to the Add state. The original's
# awaits become replies: a pull is POST /admin/pulls, then GET /admin/pulls/<id> every 0.7 s until it ends, then load
# (compile), the models list (serve), POST /admin/try/chat (smoke test), the Ready card; a port is POST /admin/ports,
# then GET /admin/ports/<id> every 1.5 s, then the smoke test. Every request carries the run's number (or the search's),
# so a reply for a run that was cancelled, or a search that was overtaken, is dropped.

from mojoui.app import Event
from mojoui.effects import Every
from mojoui.json import Json, json_string, J_OBJECT, J_STRING, J_ARRAY
from mojoui.http import uri_component
from mojoui.clock import now_ns, clock_time
from mojoui.logview import LogLine, LOG_PLAIN, LOG_ERROR, LOG_OK, LOG_WARN, log_kind_of
from add import Add, Run, Pick, Sugg, Job, read_pick, read_job, pull_detail, twin, curl_for, last_part, trim1, DEFAULT_SUB, NOTICE_NONE, NOTICE_WARN, NOTICE_PORT
from api import Api
from data import Store
from msgs import *

comptime DEBOUNCE_MS = 250
comptime PULL_POLL_MS = 700
comptime PORT_POLL_MS = 1500
comptime TICK_MS = 500
comptime MAX_POLL_ERRORS = 6


def now_ms() -> Float64:
    return Float64(now_ns()) / 1e6


struct AddOut(Copyable, Movable):
    """What the shell does after an Add message: go somewhere, copy something, poll the models again."""
    var go: String
    var clip: String
    var refresh: Bool

    def __init__(out self):
        self.go = ""
        self.clip = ""
        self.refresh = False


def problem(event: Event) -> String:
    """core.js api()'s error message: the daemon's error.message, else what went wrong on the way."""
    if event.error != "":
        return event.error
    try:
        var j = Json.parse(event.text)
        var e = j.get(0, "error")
        var msg = j.text(j.get(e, "message")) if j.kind(e) == J_OBJECT else j.text(e)
        if msg != "":
            return msg
    except:
        pass
    return "HTTP " + String(event.number)


def error_code(event: Event) -> String:
    try:
        var j = Json.parse(event.text)
        return j.text(j.get(j.get(0, "error"), "code"))
    except:
        return ""


def add_every(a: Add) -> List[Every]:
    var out = List[Every]()
    if a.debounce >= 0:
        out.append(Every(DEBOUNCE_MS, ADD_DEBOUNCE + a.debounce % 2))
    if a.running:
        out.append(Every(TICK_MS, ADD_TICK))
        if a.run.phase == "fetch" and a.pull_id > 0 and a.run.kind == "pull":
            out.append(Every(PULL_POLL_MS, ADD_PULL_POLL))
        if a.run.phase == "fetch" and a.port_id > 0 and a.run.kind == "port":
            out.append(Every(PORT_POLL_MS, ADD_PORT_POLL))
    return out^


def run_search(mut a: Add, mut api: Api):
    a.seq += 1
    a.debounce = -1
    a.loading = True
    a.error = ""
    api.get(ADD_GOT_SEARCH, "/admin/search?q=" + uri_component(String(a.q.strip())), id=a.seq)


def add_enter(mut a: Add, mut api: Api):
    """A fresh screen (the original mounts a new blade each time): the find view and the curated list."""
    a = Add()
    run_search(a, api)


# ---------- the log ----------

def write_log(mut a: Add, text: String, kind: Int = LOG_PLAIN, pre: Bool = False):
    if pre or a.run.phase == "check":
        a.pre.append(LogLine(clock_time(), text, kind))
    else:
        a.post.append(LogLine(clock_time(), text, kind))


def set_tail(mut a: Add, lines: List[String]):
    a.tail = List[LogLine]()
    for l in lines:
        a.tail.append(LogLine("", l, log_kind_of(l)))


def freeze_tail(mut a: Add):
    a.pre += a.tail.copy()
    a.tail = List[LogLine]()


# ---------- the flows ----------

def mark(mut a: Add, phase: String, start: Bool, now: Float64):
    var k = a.run.index(phase)
    if k < 0:
        return
    if start:
        a.run.starts[k] = now
    else:
        a.run.ends[k] = now


def advance(mut a: Add, to: String):
    var now = now_ms()
    var was = a.run.phase
    mark(a, was, False, now)
    a.run.phase = to
    mark(a, to, True, now)


def end_run(mut a: Add):
    a.running = False


def fail(mut a: Add, message: String):
    a.run.failed_at = a.run.phase
    a.run.error = message
    var was = a.run.phase
    mark(a, was, False, now_ms())
    a.run.phase = "failed"
    write_log(a, message, LOG_ERROR)
    end_run(a)
    a.acts = 2


def show_find(mut a: Add):
    a.flow += 1
    a.running = False
    a.setup = False
    a.ready = False
    a.title = "Add a model"
    a.crumb = "Add a model"
    a.sub = DEFAULT_SUB


def show_setup(mut a: Add, title: String, sub: String, mref: String):
    a.run.mref = mref
    a.pre = List[LogLine]()
    a.tail = List[LogLine]()
    a.post = List[LogLine]()
    a.seen = List[Tuple[String, String]]()
    a.acts = 0
    a.ready = False
    a.setup = True
    a.running = True
    a.title = title
    a.crumb = mref
    a.sub = sub
    a.notice = NOTICE_NONE
    a.copies = 0
    a.copied_ep = False


def begin(mut a: Add):
    a.flow += 1
    a.aborted = False
    a.pull_id = 0
    a.port_id = 0
    a.waiting = False
    a.errors = 0


def start_pull(mut a: Add, mut api: Api, var r: Pick):
    begin(a)
    var mref = r.id
    var repo = r.repo if r.repo != "" else mref
    var hw = a.hw_detail(r)
    a.run = Run("pull", r^, mref, hw, now_ms())
    show_setup(a, "Setting up " + mref, twin("pull", repo) + " && " + twin("serve", mref), mref)
    a.acts = 1
    write_log(a, "hardware: " + hw, pre=True)
    api.post(ADD_GOT_PULL_START, "/admin/pulls", "{\"ref\": " + json_string(mref) + "}", id=a.flow)


def start_port(mut a: Add, mut api: Api, var r: Pick):
    var mref = r.repo if r.repo != "" else r.id
    a.noticed = r^
    api.post(ADD_GOT_PORT_START, "/admin/ports", "{\"ref\": " + json_string(mref) + "}", id=a.flow)


def begin_port(mut a: Add, job: Job):
    begin(a)
    var r = a.noticed.copy()
    var mref = r.repo if r.repo != "" else r.id
    var hw = a.hw_detail(r)
    a.port_id = job.id
    a.run = Run("port", r^, mref, hw, now_ms())
    a.run.name = job.name if job.name != "" else mref
    a.run.port = job.copy()
    show_setup(a, "Porting " + last_part(mref), twin("port", mref) + " · Claude Code with Modular’s import-model skill", mref)
    a.acts = 1
    write_log(a, "hardware: " + hw, pre=True)
    write_log(a, "Claude Code is running Modular’s import-model skill in a sandbox. This may take a while.", pre=True)


def pick(mut a: Add, mut api: Api, var r: Pick):
    a.notice = NOTICE_NONE
    a.guided, a.refused, a.sandbox, a.note = False, "", False, ""
    if r.fit == "no":
        a.noticed = r^
        a.notice = NOTICE_WARN
    elif r.fit == "port":
        a.noticed = r^
        a.notice = NOTICE_PORT
    else:
        start_pull(a, api, r^)


def on_pull_job(mut a: Add, job: Job):
    """Log each step once as it lands (the download every tenth of its bytes), then the stages repaint."""
    a.run.fetch = job.copy()
    for s in job.steps:
        var key = ("now|" + String(Int(max(job.percent, 0.0) / 10))) if s.id == "download" and s.state == "now" else s.state + "|" + s.detail
        var had = String("")
        var at = -1
        for k in range(len(a.seen)):
            if a.seen[k][0] == s.id:
                had = a.seen[k][1]
                at = k
        if had != key and s.state != "next" and (s.detail != "" or s.state == "done"):
            write_log(a, (s.label if s.label != "" else s.id) + ": " + (s.detail if s.detail != "" else s.state), LOG_OK if s.state == "done" else LOG_PLAIN)
            if at >= 0:
                a.seen[at] = (s.id, key)
            else:
                a.seen.append((s.id, key))


def finish_pull(mut a: Add, mut api: Api, job: Job, mut out: AddOut):
    if job.status == "unsupported":
        var r = a.run.source.copy()
        show_find(a)
        r.fit = "port"
        a.noticed = r^
        a.notice = NOTICE_PORT
        a.note = pull_detail(job)
        return
    if job.status != "done":
        var d = pull_detail(job)
        fail(a, d if d != "" else "the pull " + job.status)
        return
    a.run.name = job.model if job.model != "" else a.run.mref
    out.refresh = True
    bring_up(a, api)


def bring_up(mut a: Add, mut api: Api):
    """compile (load) → serve → smoke test, for a registered model (a port's is served already: confirm, then test)."""
    var name = a.run.name
    if a.run.kind == "port":
        api.get(ADD_GOT_MODELS, "/admin/models", id=a.flow)
        return
    advance(a, "compile")
    write_log(a, "loading " + name + " · compiling the graph (" + twin("serve", name) + ")")
    api.post(ADD_GOT_LOAD, "/admin/models/" + uri_component(name) + "/load", id=a.flow)


def smoke_test(mut a: Add, mut api: Api):
    advance(a, "smoke")
    write_log(a, "smoke test: asking for one short reply")
    api.post(ADD_GOT_SMOKE, "/admin/try/chat", "{\"model\": " + json_string(a.run.name)
             + ", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in five words.\"}], \"max_tokens\": 24}", id=a.flow)


def cancel(mut a: Add, mut api: Api):
    a.aborted = True
    var at = a.run.phase
    a.run.failed_at = at
    mark(a, at, False, now_ms())
    a.run.phase = "cancelled"
    write_log(a, "cancelled", LOG_WARN)
    end_run(a)
    a.acts = 3
    # cancelPlan: what Cancel must send for the phase it was in
    var stop = "/admin/models/" + uri_component(a.run.name) + "/stop"
    if at == "fetch":
        if a.run.kind == "port":
            if a.run.port.status == "done":
                api.post(ADD_GOT_CANCEL, stop, id=-1)
            elif a.port_id > 0:
                api.post(ADD_GOT_CANCEL, "/admin/ports/" + String(a.port_id) + "/cancel", id=-1)
        elif a.pull_id > 0:
            api.post(ADD_GOT_CANCEL, "/admin/pulls/" + String(a.pull_id) + "/cancel", id=-1)
    elif at == "compile" or at == "serve" or at == "smoke":
        api.post(ADD_GOT_CANCEL, stop, id=-1)


def retry(mut a: Add, mut api: Api):
    var r = a.run.source.copy()
    if a.run.kind == "port":
        start_port(a, api, r^)
    else:
        start_pull(a, api, r^)


# ---------- update ----------

def add_update(mut a: Add, mut api: Api, st: Store, m: Int, event: Event) -> AddOut:
    var out = AddOut()
    var failed = event.error != "" or event.number >= 400
    var live = event.id == a.flow and not a.aborted  # (a reply for the run on screen)
    if m == ADD_FIELD:
        a.q = event.text
        a.debounce = (a.debounce + 1) if a.debounce >= 0 else a.seq * 2 + 2  # (a new number: the timer restarts)
    elif m == ADD_ENTER:
        a.q = event.text if event.text != "" or a.q == "" else a.q
        run_search(a, api)
    elif m == ADD_DEBOUNCE or m == ADD_DEBOUNCE + 1:
        if a.debounce >= 0 and m == ADD_DEBOUNCE + a.debounce % 2:
            run_search(a, api)
    elif ADD_FILTER <= m < ADD_FILTER + 3:
        a.filter = m - ADD_FILTER
    elif m == ADD_EMPTY:
        if a.error != "":
            run_search(a, api)
        elif String(a.q.strip()) != "":
            a.q = ""
            run_search(a, api)
        else:
            a.filter = 0
    elif ADD_PICK <= m < ADD_SUGGEST:
        var k = m - ADD_PICK
        if k < len(a.results):
            pick(a, api, a.results[k].copy())
    elif ADD_SUGGEST <= m < ADD_PORT_IT:
        var k = m - ADD_SUGGEST
        if k < len(a.noticed.suggestions):
            var s = a.noticed.suggestions[k].copy()
            start_pull(a, api, Pick(s.id, s.repo, "max", s.arch, s.params, s.size_gb, s.est_gb, "ok", List[Sugg]()))
    elif m == ADD_PORT_IT:
        start_port(a, api, a.noticed.copy())
    elif m == ADD_COPY_CMD:
        out.clip = twin("guided", a.noticed.repo if a.noticed.repo != "" else a.noticed.id)
    elif m == ADD_CANCEL and a.running and not a.aborted:
        cancel(a, api)
    elif m == ADD_RETRY:
        retry(a, api)
    elif m == ADD_TO_SEARCH or m == ADD_ANOTHER:
        show_find(a)
    elif m == ADD_LOG:
        a.log_open = not a.log_open
    elif m == ADD_TICK:
        pass  # (the stages' elapsed times are drawn from the clock)
    elif m == ADD_PULL_POLL and a.running and not a.waiting and a.pull_id > 0:
        a.waiting = True
        api.get(ADD_GOT_PULL, "/admin/pulls/" + String(a.pull_id), id=a.flow)
    elif m == ADD_PORT_POLL and a.running and not a.waiting and a.port_id > 0:
        a.waiting = True
        api.get(ADD_GOT_PORT, "/admin/ports/" + String(a.port_id), id=a.flow)
    elif m == ADD_COPY_EP:
        a.copied_ep = True
        out.clip = a.run.endpoint
    elif m == ADD_COPY_CURL:
        a.copies += 1
        out.clip = curl_for(a.run.endpoint, a.run.name)
    elif m == ADD_OPEN:
        out.go = "/models/" + a.run.name + "/overview"
    elif m == ADD_SECURE:
        out.go = "/security"
    elif m == ADD_BACK:
        out.go = "/"
    elif m == ADD_GOT_SEARCH:
        if event.id != a.seq:
            return out^
        a.loading = False
        if failed:
            a.error = problem(event)
            return out^
        try:
            var j = Json.parse(event.text)
            var rs = j.get(0, "results")
            a.results = List[Pick]()
            for k in range(j.size(rs)):
                a.results.append(read_pick(j, j.at(rs, k)))
            var mem = j.get(0, "memory")
            a.mem_name = j.text(j.get(mem, "name"))
            a.mem_free = j.real(j.get(mem, "free_gb"))
            a.mem_total = j.real(j.get(mem, "total_gb"))
            a.answered = True
            a.error = ""
        except e:
            a.error = String(e)
    elif m == ADD_GOT_PULL_START:
        if event.id != a.flow:
            return out^
        if a.aborted:  # cancelled while the POST was out: stop that pull on the server too
            if not failed:
                try:
                    var j = Json.parse(event.text)
                    api.post(ADD_GOT_CANCEL, "/admin/pulls/" + String(j.number(j.get(0, "id"))) + "/cancel", id=-1)
                except:
                    pass
            return out^
        var job = Job()
        try:
            var j = Json.parse(event.text)
            if event.number == 409:
                job = read_job(j, j.get(0, "pull"))
            elif not failed:
                job = read_job(j, 0)
        except:
            pass
        if event.number == 409 and not job.present:
            api.get(ADD_GOT_PULLS, "/admin/pulls", id=a.flow)
            return out^
        if failed and event.number != 409:
            fail(a, problem(event))
            return out^
        if event.number == 409:
            write_log(a, a.run.mref + " is already being pulled · following it")
        start_following(a, api, job, out)
    elif m == ADD_GOT_PULLS and live:
        var job = Job()
        try:
            var j = Json.parse(event.text)
            var ps = j.get(0, "pulls")
            for k in range(j.size(ps)):
                var p = j.at(ps, k)
                if j.text(j.get(p, "ref")) == a.run.mref and j.text(j.get(p, "status")) == "running":
                    job = read_job(j, p)
        except:
            pass
        if not job.present:
            fail(a, a.run.mref + " is already being pulled.")
            return out^
        write_log(a, a.run.mref + " is already being pulled · following it")
        start_following(a, api, job, out)
    elif m == ADD_GOT_PULL and live:
        a.waiting = False
        if failed:
            a.errors += 1
            if a.errors >= MAX_POLL_ERRORS:
                fail(a, problem(event))
            return out^
        a.errors = 0
        try:
            var job = read_job(Json.parse(event.text), 0)
            on_pull_job(a, job)
            if job.finished():
                finish_pull(a, api, job, out)
        except e:
            a.errors += 1
    elif m == ADD_GOT_PORT_START:
        if failed:
            var code = error_code(event)
            if event.number == 404 or event.number == 405:
                a.guided = True
            elif event.number == 409:
                try:
                    var j = Json.parse(event.text)
                    var job = read_job(j, j.get(0, "port"))
                    if job.present:
                        begin_port(a, job)
                        follow_port(a, api, job, out)
                        return out^
                except:
                    pass
                a.note = "Could not start the port: " + problem(event)
            elif event.number == 400 and code == "no_sandbox":
                a.refused = problem(event)
                a.sandbox = True
            elif event.number == 400:
                a.refused = problem(event)
            else:
                a.note = "Could not start the port: " + problem(event)
            a.notice = NOTICE_PORT
            return out^
        try:
            var job = read_job(Json.parse(event.text), 0)
            begin_port(a, job)
            follow_port(a, api, job, out)
        except e:
            a.note = "Could not start the port: " + String(e)
    elif m == ADD_GOT_PORT and live:
        a.waiting = False
        if failed:
            a.errors += 1
            if a.errors >= MAX_POLL_ERRORS:
                fail(a, problem(event))
            return out^
        a.errors = 0
        try:
            var job = read_job(Json.parse(event.text), 0)
            follow_port(a, api, job, out)
        except:
            a.errors += 1
    elif m == ADD_GOT_LOAD and live:
        if failed:
            fail(a, problem(event))
            return out^
        if a.run.kind == "port":  # (the port's model wasn't ready: loaded now)
            write_log(a, "serving on " + a.run.endpoint, LOG_OK)
            smoke_test(a, api)
            return out^
        write_log(a, "graph compiled", LOG_OK)
        advance(a, "serve")
        a.run.endpoint = st.endpoint_now()
        api.get(ADD_GOT_MODELS, "/admin/models", id=a.flow)
    elif m == ADD_GOT_MODELS and live:
        if failed:
            fail(a, problem(event))
            return out^
        var state = String("")
        try:
            var j = Json.parse(event.text)
            for k in range(j.size(0)):
                var x = j.at(0, k)
                if j.text(j.get(x, "name")) == a.run.name:
                    state = j.text(j.get(x, "state"), "?")
        except e:
            fail(a, String(e))
            return out^
        if a.run.kind == "port":
            a.run.endpoint = st.endpoint_now()
            if state != "ready":
                api.post(ADD_GOT_LOAD, "/admin/models/" + uri_component(a.run.name) + "/load", id=a.flow)
                return out^
            write_log(a, "serving on " + a.run.endpoint, LOG_OK)
            smoke_test(a, api)
            return out^
        if state != "ready":
            fail(a, ("the server is " + state + ", not ready") if state != "" else a.run.name + " is not in your models")
            return out^
        write_log(a, "serving on " + a.run.endpoint, LOG_OK)
        out.refresh = True
        smoke_test(a, api)
    elif m == ADD_GOT_SMOKE and live:
        if failed:
            fail(a, "smoke test failed: " + problem(event))
            return out^
        var text = String("")
        try:
            var j = Json.parse(event.text)
            var c = j.at(j.get(0, "choices"), 0)
            text = j.text(j.get(j.get(c, "message"), "content"))
        except:
            pass
        var words = String("")
        for w in text.split():
            words += (" " if words != "" else "") + String(w)
        if words == "":
            fail(a, "the model answered with nothing")
            return out^
        a.run.smoke = words if words.byte_length() <= 80 else String(words[byte = :79]) + "…"
        write_log(a, "reply: " + a.run.smoke, LOG_OK)
        mark(a, "smoke", False, now_ms())
        a.run.phase = "ready"
        end_run(a)
        out.refresh = True
        a.title = a.run.name + " is ready"
        a.crumb = a.run.name
        a.sub = a.run.endpoint + " · model “" + a.run.name + "”"
        a.acts = 0
        a.ready = True
    return out^


def start_following(mut a: Add, mut api: Api, job: Job, mut out: AddOut):
    a.pull_id = job.id
    write_log(a, "pull #" + String(job.id) + " started for " + a.run.mref)
    on_pull_job(a, job)
    if job.finished():
        finish_pull(a, api, job, out)


def follow_port(mut a: Add, mut api: Api, job: Job, mut out: AddOut):
    a.run.port = job.copy()
    set_tail(a, job.log_tail)
    if job.status != "done" and job.status != "failed" and job.status != "cancelled":
        return
    freeze_tail(a)
    if job.status != "done":
        var bad = String("")
        for s in job.stages:
            if s.status == "failed":
                bad = s.detail
        fail(a, job.message if job.message != "" else (bad if bad != "" else "the port " + job.status + ": the log above says what was tried"))
        return
    if job.model == "":
        fail(a, "the port finished but no model was registered")
        return
    a.run.name = job.model
    out.refresh = True
    bring_up(a, api)
