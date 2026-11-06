# Goal 57 M3: mojoui.billing's webhook check without a server: Stripe's documented signature (HMAC-SHA256 of "<t>.<body>"),
# a wrong secret, a changed body, an old or future timestamp, several v1 values (a key being rolled), malformed headers.
# The checkout, the webhook route and plans are proved by docs/goals/57-check.py M3 against its Stripe stand-in.
from mojoui.billing import signature_ok
from mojoui.crypto import hmac_sha256
from mojoui.hash import hex


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    var secret = "whsec_test_1"
    var body = '{"id": "evt_1", "type": "checkout.session.completed"}'
    var t = 1_800_000_000
    var sig = hex(hmac_sha256(secret, String(t) + "." + body))
    var h = "t=" + String(t) + ",v1=" + sig
    expect(signature_ok(h, body, secret, t + 10), "a good signature")
    expect(signature_ok("t=" + String(t) + ",v1=" + "0" * 64 + ",v1=" + sig + ",v0=x", body, secret, t), "a second v1")
    expect(not signature_ok(h, body, "whsec_other", t), "another secret")
    expect(not signature_ok(h, body + " ", secret, t), "a changed body")
    expect(not signature_ok(h, body, secret, t + 301), "a 301-second-old signature")
    expect(not signature_ok(h, body, secret, t - 301), "a signature from the future")
    expect(not signature_ok(h, body, "", t), "no secret set")
    for bad in ["", "v1=" + sig, "t=" + String(t), "t=x,v1=" + sig, "t=" + String(t) + ",v1=" + sig[byte = : 63]]:
        expect(not signature_ok(bad, body, secret, t), "a malformed header: " + bad)
    print("webhook signature: ok")
