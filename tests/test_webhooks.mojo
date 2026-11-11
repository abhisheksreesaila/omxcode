# Goal 66 M1: mojoui.webhooks without a server: each signing scheme against vectors computed by Python's hmac (and
# Standard Webhooks' own published example), the time window, the event logged and queued once, the size cap.
from std.os import makedirs, getenv
from mojoui.serve import Req, Reply
from mojoui.webhooks import Source, Webhooks, check, b64_std_decode
from mojoui.jobs import Queue
from mojoui.clock import wall_seconds
from mojoui import libc


def req(body: String, n1: String = "", v1: String = "", n2: String = "", v2: String = "", n3: String = "", v3: String = "") -> Req:
    var r = Req("POST", "/hook", body)
    for p in [(n1, v1), (n2, v2), (n3, v3)]:
        if p[0] != "":
            r.names.append(p[0].lower())
            r.values.append(p[1])
    return r^


def ok(c: Bool, what: String) raises:
    if not c:
        raise Error("FAILED: " + what)


def main() raises:
    var body = String('{"id":"evt_1"}')
    var t = 1700000000
    var stripe = Source.stripe("stripe", "whsec_66")
    var sig = String("1f1dfe825acf9575c41776a90a3528ac25c49fd5c4a9d396a3c038ec3ffa6f98")
    ok(check(stripe, req(body, "Stripe-Signature", "t=" + String(t) + ",v1=" + sig), t + 10) == 0, "stripe good")
    ok(check(stripe, req(body, "Stripe-Signature", "t=" + String(t) + ",v1=00,v1=" + sig), t) == 0, "stripe: any v1")
    ok(check(stripe, req(body + " ", "Stripe-Signature", "t=" + String(t) + ",v1=" + sig), t) == 401, "stripe: body changed")
    ok(check(stripe, req(body, "Stripe-Signature", "t=" + String(t + 1) + ",v1=" + sig), t) == 401, "stripe: t changed")
    ok(check(stripe, req(body), t) == 401, "stripe: unsigned")
    print("stripe: ok")

    var hx = Source.hmac_hex("hex", "hex-66")
    var hsig = String("5480437d896dabc50b224213e0ac9209cde1ae2f2d28ae250bb7e6274c96458e")
    ok(check(hx, req(body, "X-Signature", hsig), t) == 0 and check(hx, req(body, "X-Signature", "sha256=" + hsig.upper()), t) == 0, "hex good")
    ok(check(hx, req(body, "X-Signature", "00" + String(hsig[byte = 2:])), t) == 401, "hex bad")
    ok(check(Source.hmac_hex("hex", ""), req(body, "X-Signature", hsig), t) == 401, "no secret: nothing passes")
    print("hex: ok")

    var bs = Source.hmac_b64("b64", "b64-66")
    ok(check(bs, req(body, "X-Signature", "Eta90eFPbphoFo5TLCNQskbAMfkvXrJqjoeWcb7gi84="), t) == 0, "b64 good")
    ok(check(bs, req(body, "X-Signature", "Eta90eFPbphoFo5TLCNQskbAMfkvXrJqjoeWcb7gi85="), t) == 401, "b64 bad")
    print("b64: ok")

    var sv = Source.standard("svix", "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")  # (standardwebhooks.com's example)
    var sbody = String('{"test": 2432232314}')
    var good = req(sbody, "webhook-id", "msg_p5jXN8AQM9LWM0D4loKWxJek", "webhook-timestamp", "1614265330", "webhook-signature",
                   "v1,bm9ldHUjKzFob2VudXRob2VodWUzMjRvdWVvdW9ldQo= v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
    ok(check(sv, good, 1614265330 + 60) == 0, "standard webhooks' own example")
    var other = req(sbody, "webhook-id", "msg_other", "webhook-timestamp", "1614265330", "webhook-signature", "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
    ok(check(sv, other, 1614265330) == 401, "the id is signed too")
    ok(b64_std_decode("aGk=").value()[1] == UInt8(ord("i")), "base64")
    print("svix: ok")

    ok(check(stripe, req(body, "Stripe-Signature", "t=" + String(t) + ",v1=" + sig), t + 301) == 400, "stripe: old")
    ok(check(stripe, req(body, "Stripe-Signature", "t=" + String(t) + ",v1=" + sig), t - 301) == 400, "stripe: future")
    ok(check(sv, good, 1614265330 + 301) == 400 and check(sv, good, 1614265330 - 301) == 400, "standard: window")
    print("window: ok")

    var dir = getenv("TMPDIR", "/tmp") + "/mojoui-webhooks-" + String(libc.getpid())
    makedirs(dir, exist_ok=True)
    var q = Queue(dir + "/host.db")
    var hooks = Webhooks(dir + "/host.db", q)
    var now = String(Int(wall_seconds()))
    var b = String('{"id":"evt_9","type":"x.y"}')
    from mojoui.crypto import hmac_sha256
    from mojoui.hash import hex
    var s9 = hex(hmac_sha256("hex-66", b))
    var first = hooks.receive(req(b, "X-Signature", s9), hx)
    var second = hooks.receive(req(b, "X-Signature", s9), hx)
    ok(first.status == 200 and second.status == 200, "both 200")
    var db = hooks.db()
    ok(db.count("SELECT count(*) FROM webhook_events") == 1 and db.count("SELECT count(*) FROM jobs WHERE kind = 'webhook'") == 1, "logged and queued once")
    var job = q.claim()
    ok(Bool(job), "a job")
    var ev = hooks.job_event(job.value().payload)
    ok(ev[0] == "hex" and ev[1] == "evt_9" and ev[2] == "x.y" and ev[3] == b, "the job finds its event")
    ok(hooks.receive(req(b, "X-Signature", "00"), hx).status == 401, "401")
    ok(hooks.receive(req('{"type":"x"}', "X-Signature", hex(hmac_sha256("hex-66", '{"type":"x"}'))), hx).status == 400, "no id 400")
    print("once: ok")

    var big = String("{\"id\": \"big\", \"pad\": \"")
    var pad = String("x") * (1024 * 1024)
    big += pad + "\"}"
    ok(hooks.receive(req(big, "X-Signature", hex(hmac_sha256("hex-66", big))), hx).status == 413, "1 MB cap")
    print("cap: ok")
