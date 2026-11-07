# Goal 57 M2: mojoui.accounts without a provider: which redirects and next pages it takes (no open redirect), cookies,
# users and tenants (own tenant as admin; an invite joins as its role), sessions (sealed, looked up, ended), one SQLite
# file per tenant. The OAuth round trip itself is proved by docs/goals/57-check.py M2 against its stand-in.
from std.os import getenv
from mojoui.accounts import Accounts, AuthConfig, is_loopback_redirect, is_local_path, cookie
from mojoui.serve import Req
from mojoui.crypto import random_token
from mojoui import libc


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    for good in ["http://127.0.0.1:5173/cb", "http://127.0.0.1:1", "http://[::1]:8080/done?x=1"]:
        expect(is_loopback_redirect(good), "refused " + good)
    for bad in ["https://evil.example/done", "http://localhost:80/", "http://127.0.0.1.evil.example:80/", "http://127.0.0.1:80@evil.example/",
                "http://127.0.0.1:99999/", "http://127.0.0.1:/x", "http://127.0.0.1:80//evil.example", "http://127.0.0.1:80/a\r\nX: y", "javascript:alert(1)"]:
        expect(not is_loopback_redirect(bad), "took " + bad)
    print("redirects: ok")
    for good in ["/", "/app", "/a/b?x=1&y=2"]:
        expect(is_local_path(good), "refused next " + good)
    for bad in ["//evil.example", "/\\evil.example", "https://evil.example", "app", "/a b", "/a\"onload"]:
        expect(not is_local_path(bad), "took next " + bad)
    print("next: ok")
    var r = Req("GET", "/api/me")
    r.names.append("cookie")
    r.values.append("a=1; saas=xyz.1.abc; b=2")
    expect(cookie(r, "saas") == "xyz.1.abc" and cookie(r, "nope") == "", "cookie parsing")
    print("cookie: ok")
    var dir = "build/test_accounts.data"
    _ = libc.unlink(dir + "/host.db")
    var acc = Accounts(dir, AuthConfig("id", "secret", "", "", "", "http://127.0.0.1:1", random_token(32), 7 * 86400, 7 * 86400, 0, ""))
    var ada = acc.test_session("Ada@Example.com")
    var req = Req("GET", "/api/me")
    req.names.append("authorization")
    req.values.append("Bearer " + ada)
    var m = acc.member(req)
    expect(Bool(m) and m.value().email == "ada@example.com" and m.value().role == "admin" and m.value().plan == "free", "ada's session")
    var tenant = m.value().tenant
    var inv = Req("POST", "/api/invites", '{"email": "cy@example.com", "role": "viewer"}')
    inv.names.append("authorization")
    inv.values.append("Bearer " + ada)
    expect(acc.handle(inv).status == 201, "the admin's invite")
    var cy = Req("GET", "/api/me")
    cy.names.append("authorization")
    cy.values.append("Bearer " + acc.test_session("cy@example.com"))
    var c = acc.member(cy)
    expect(Bool(c) and c.value().tenant != tenant, "an invite joins only once accepted (goal 60 M5)")
    var link = acc.invite_details(1).value().link
    var path = String(link[byte = link.find("/invites/") :])
    var accept = Req("POST", path)
    accept.names.append("authorization")
    accept.values.append(cy.values[0])
    accept.names.append("origin")
    accept.values.append("http://127.0.0.1:1")
    var took = acc.handle(accept).status
    expect(took == 200 or took == 201 or took == 303, "the invited person accepts")
    var sw = Req("POST", "/api/switch", '{"tenant": "' + tenant + '"}')
    sw.names.append("authorization")
    sw.values.append(cy.values[0])
    expect(acc.handle(sw).status == 200, "switching to the inviting tenant")
    c = acc.member(cy)
    expect(Bool(c) and c.value().tenant == tenant and c.value().role == "viewer" and not c.value().can_write(), "the invited viewer")
    var db = acc.tenant_db(m.value())
    expect(db.path.endswith("/tenants/" + tenant + ".db"), "the tenant's file")
    expect(acc.set_plan(tenant, "pro") and acc.member(req).value().plan == "pro", "set_plan")
    var out = Req("POST", "/logout")
    out.names.append("authorization")
    out.values.append("Bearer " + ada)
    _ = acc.handle(out)
    expect(not acc.member(req), "the session outlived sign-out")
    var flip = Req("GET", "/api/me")
    flip.names.append("authorization")
    flip.values.append("Bearer " + String(ada[byte = : ada.byte_length() - 2]) + "!!")
    expect(not acc.member(flip), "a tampered token")
    print("accounts: ok")
