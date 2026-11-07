# Goal 57 M3: mojoui.billing's webhook check without a server: Stripe's documented signature (HMAC-SHA256 of "<t>.<body>"),
# a wrong secret, a changed body, an old or future timestamp, several v1 values (a key being rolled), malformed headers.
# The checkout, the webhook route and plans are proved by docs/goals/57-check.py M3 against its Stripe stand-in.
# Round 3 (S-L3): a subscription's update that arrives before its checkout.session.completed is held, then applied.


def hook(bill: Billing, acc: Accounts, body: String) raises -> Int:
    var t = Int(wall_seconds())
    var r = Req("POST", "/billing/webhook", body)
    r.names.append("stripe-signature")
    r.values.append("t=" + String(t) + ",v1=" + hex(hmac_sha256("whsec_test_1", String(t) + "." + body)))
    return bill.handle(r, acc).status
from mojoui.billing import signature_ok, Billing, BillingConfig
from mojoui.accounts import Accounts, AuthConfig
from mojoui.serve import Req
from mojoui.crypto import random_token
from mojoui.clock import wall_seconds
from mojoui import libc
from mojoui.crypto import hmac_sha256, hmac_hex_ok
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
    # a generic source's signature (GitHub's documented example: secret "It's a Secret to Everybody", body "Hello, World!")
    var gh = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"
    expect(hmac_hex_ok(gh, "Hello, World!", "It's a Secret to Everybody"), "GitHub's example")
    expect(not hmac_hex_ok(gh, "Hello, World?", "It's a Secret to Everybody") and not hmac_hex_ok(gh, "Hello, World!", ""), "a wrong body or no secret")
    print("generic signature: ok")
    var dir = "build/test_billing.data"
    _ = libc.unlink(dir + "/host.db")
    _ = libc.unlink(dir + "/host.db-wal")
    var acc = Accounts(dir, AuthConfig("id", "secret", "", "", "", "http://127.0.0.1:1", random_token(32), 7 * 86400, 7 * 86400, 0, "", 10_000))
    var bill = Billing(dir, BillingConfig("http://127.0.0.1:1", "sk_test_x", "whsec_test_1", "price_1", "http://127.0.0.1:1", "", List[String]()), acc.log)
    var tok = acc.test_session("pat@example.com")
    var me = Req("GET", "/api/me")
    me.names.append("authorization")
    me.values.append("Bearer " + tok)
    var tenant = acc.member(me).value().tenant
    var now = Int(wall_seconds())
    var upd = '{"id": "evt_upd", "type": "customer.subscription.updated", "created": ' + String(now + 5) + ', "data": {"object": {"id": "sub_early", "status": "active", "cancel_at_period_end": true, "current_period_end": ' + String(now + 86400) + "}}}"
    expect(hook(bill, acc, upd) == 200, "the early update accepted")
    expect(bill.plan(tenant).name == "free", "an unsold subscription changed a plan")
    var done = '{"id": "evt_done", "type": "checkout.session.completed", "created": ' + String(now) + ', "data": {"object": {"id": "cs_1", "mode": "subscription", "status": "complete", "payment_status": "paid", "client_reference_id": "' + tenant + '", "customer": "cus_1", "subscription": "sub_early"}}}'
    expect(hook(bill, acc, done) == 200, "the checkout")
    var p = bill.plan(tenant)
    expect(p.pro and p.cancels_at == now + 86400, "the held update after its checkout: pro " + String(p.pro) + ", cancels_at " + String(p.cancels_at))
    expect(hook(bill, acc, upd) == 200 and bill.plan(tenant).cancels_at == now + 86400, "the update again is a duplicate")
    var gone = '{"id": "evt_del", "type": "customer.subscription.deleted", "created": ' + String(now + 9) + ', "data": {"object": {"id": "sub_late", "status": "canceled"}}}'
    expect(hook(bill, acc, gone) == 200, "an early deletion")
    var done2 = '{"id": "evt_done2", "type": "checkout.session.completed", "created": ' + String(now) + ', "data": {"object": {"id": "cs_2", "mode": "subscription", "status": "complete", "payment_status": "paid", "client_reference_id": "' + tenant + '", "customer": "cus_1", "subscription": "sub_late"}}}'
    expect(hook(bill, acc, done2) == 200 and not bill.plan(tenant).pro, "a deletion that came before its checkout still ends it")
    print("out_of_order: ok")
