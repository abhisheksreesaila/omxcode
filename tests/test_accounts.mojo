# Goal 57 M2: mojoui.accounts without a provider: which redirects and next pages it takes (no open redirect), cookies,
# users and tenants (own tenant as admin; an invite joins as its role), sessions (sealed, looked up, ended), one SQLite
# file per tenant. The OAuth round trip itself is proved by docs/goals/57-check.py M2 against its stand-in.
from std.os import getenv, makedirs
from std.os.path import exists
from mojoui.accounts import Accounts, AuthConfig, is_loopback_redirect, is_local_path, cookie
from mojoui.jobs import Queue
from mojoui.json import Json
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
    var two = Req("GET", "/api/me")
    two.names.append("cookie")
    two.values.append("saas=planted.1.x; saas=xyz.1.abc")
    expect(cookie(two, "saas") == "", "a cookie sent twice read as one of them")
    print("cookie: ok")
    var dir = "build/test_accounts.data"
    _ = libc.unlink(dir + "/host.db")
    var acc = Accounts(dir, AuthConfig("id", "secret", "", "", "", "http://127.0.0.1:1", random_token(32), 7 * 86400, 7 * 86400, 0, "", 10_000, 20))
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
    # round 3: identities, __Host- cookies, two cookies refused, the sweep and the pending cap, the outbox
    var dir3 = "build/test_accounts.data3"
    _ = libc.unlink(dir3 + "/host.db")
    _ = libc.unlink(dir3 + "/host.db-wal")
    if not exists(dir3):
        makedirs(dir3)
    var q = Queue(dir3 + "/host.db")
    var a3 = Accounts(dir3, AuthConfig("id", "secret", "https://p.example/a", "", "", "https://app.example", random_token(32), 7 * 86400, 7 * 86400, 0, "", 3, 20), events=q)
    var first = a3.user_for("dan@example.com", "Dan", "sub-1")
    expect(first[0] > 0, "a new person")
    expect(a3.user_for("dan@example.com", "Dan", "sub-1")[0] == first[0], "the same sub: the same person")
    var other = a3.user_for("dan@example.com", "Mallory", "sub-2")
    expect(other[0] == -1, "another sub with dan's address signed in as dan")
    var hdb = a3.db()
    expect(hdb.count("SELECT count(*) FROM audit WHERE action = 'identity_mismatch'") == 1, "the refused sign-in's audit row")
    expect(a3.user_for("dan.new@example.com", "Dan", "sub-1")[0] == first[0], "the sub found under a changed address")
    var t = a3.user_for("tess@example.com", "", "")  # (a test session: no sub yet)
    expect(a3.user_for("tess@example.com", "Tess", "sub-t")[0] == t[0], "the first sub claims the row")
    expect(a3.user_for("tess@example.com", "Tess", "sub-u")[0] == -1, "a second sub after the claim")
    print("identity: ok")
    var j = Json.parse(hdb.one_text("SELECT payload FROM jobs WHERE kind = 'signed_up' ORDER BY id LIMIT 1"))
    expect(j.number(j.get(0, "user")) == first[0] and "dan" not in hdb.one_text("SELECT payload FROM jobs WHERE kind = 'signed_up' ORDER BY id LIMIT 1"), "a signed_up payload of ids only")
    expect(hdb.count("SELECT count(*) FROM jobs WHERE kind = 'signed_up'") == hdb.count("SELECT count(*) FROM users"), "a job per account")
    expect(a3.user_email(first[0]).value()[0] == "dan.new@example.com", "user_email (the address the provider vouched for last)")
    print("outbox: ok")
    var tok = a3.test_session("dan@example.com")
    var lg = Req("GET", "/login")
    var lr = a3.handle(lg)
    var set = String("")
    for i in range(len(lr.names)):
        if lr.names[i] == "Set-Cookie":
            set = lr.values[i]
    expect(set.startswith("__Host-saas_state=") and "; Path=/;" in set and "Secure" in set, "the https state cookie: " + set)
    expect(a3.session_cookie(tok).startswith("__Host-saas=") and "Secure" in a3.session_cookie(tok), "the https session cookie")
    var me = Req("GET", "/api/me")
    me.names.append("cookie")
    me.values.append("__Host-saas=" + tok)
    expect(a3.handle(me).status == 200, "a __Host- session")
    var dup = Req("GET", "/api/me")
    dup.names.append("cookie")
    dup.values.append("__Host-saas=" + tok + "; __Host-saas=planted")
    expect(a3.handle(dup).status == 400, "two session cookies weren't refused")
    print("cookies: ok")
    for _ in range(2):
        lg = Req("GET", "/login")
        _ = a3.handle(lg)
    lg = Req("GET", "/login")
    expect(a3.handle(lg).status == 503, "a 4th pending sign-in past the cap of 3")
    _ = hdb.run("UPDATE oauth_states SET expires = 1")
    _ = hdb.run("INSERT INTO sessions(id, user_id, tenant, expires, last_seen) VALUES ('old', 1, '', 1, 1)")
    expect(a3.sweep() == 4, "the sweep: 3 states and a session")
    lg = Req("GET", "/login")
    expect(a3.handle(lg).status == 303, "sign-in after the sweep")
    var plan = hdb.one_text("EXPLAIN QUERY PLAN DELETE FROM oauth_states WHERE rowid IN (SELECT rowid FROM oauth_states WHERE expires < 5 LIMIT 10)")
    expect(hdb.count("SELECT count(*) FROM sqlite_master WHERE name IN ('oauth_states_expires', 'sessions_expires', 'desktop_codes_expires')") == 3, "the expiry indexes")
    _ = plan
    print("sweep: ok")
    # round 3 review: pending sign-ins per client, cookies over several lines, a changed address under the same sub
    var dir4 = "build/test_accounts.data4"
    _ = libc.unlink(dir4 + "/host.db")
    _ = libc.unlink(dir4 + "/host.db-wal")
    var a4 = Accounts(dir4, AuthConfig("id", "secret", "https://p.example/a", "", "", "http://127.0.0.1:1", random_token(32), 7 * 86400, 7 * 86400, 0, "", 1000, 20))
    for _ in range(20):
        var la = Req("GET", "/login")
        la.client = "198.51.100.1"
        expect(a4.handle(la).status == 303, "a client's first 20 pending sign-ins")
    var la21 = Req("GET", "/login")
    la21.client = "198.51.100.1"
    expect(a4.handle(la21).status == 429, "a client's 21st pending sign-in")
    var lb = Req("GET", "/login")
    lb.client = "198.51.100.2"
    expect(a4.handle(lb).status == 303, "another client blocked by the first one's pending sign-ins")
    var tk = a4.test_session("gil@example.com")
    var split = Req("GET", "/api/me")
    split.names.append("cookie")
    split.values.append("a=1")
    split.names.append("cookie")
    split.values.append("saas=" + tk)
    expect(a4.handle(split).status == 200, "a session in the second Cookie line")
    var dup2 = Req("GET", "/api/me")
    dup2.names.append("cookie")
    dup2.values.append("saas=" + tk)
    dup2.names.append("cookie")
    dup2.values.append("saas=planted")
    var dr = a4.handle(dup2)
    var cleared = False
    for i in range(len(dr.names)):
        cleared = cleared or (dr.names[i] == "Set-Cookie" and dr.values[i].startswith("saas=;") and "Max-Age=0" in dr.values[i])
    expect(dr.status == 400 and cleared, "two session cookies over two lines: refused and expired")
    var hal = a4.user_for("hal@example.com", "Hal", "sub-h")
    expect(a4.user_for("hal@new.example", "Hal", "sub-h")[0] == hal[0] and a4.user_email(hal[0]).value()[0] == "hal@new.example", "the provider's new address replaces the old one")
    _ = a4.user_for("ivy@example.com", "Ivy", "sub-i")
    expect(a4.user_for("ivy@example.com", "Hal", "sub-h")[0] == -1, "a sub moving onto another account's address")
    print("per_client: ok")
