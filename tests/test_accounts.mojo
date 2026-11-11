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
from mojoui.clock import wall_seconds
from mojoui import libc


def hex4(i: Int) -> String:
    var d = "0123456789abcdef"
    var out = String("")
    for k in range(4):
        var n = (i >> (12 - 4 * k)) & 15
        out += String(d[byte = n : n + 1])
    return out


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
    var acc = Accounts(dir, AuthConfig("id", "secret", "", "", "", "http://127.0.0.1:1", random_token(32), 7 * 86400, 7 * 86400, 0, "", "omxcode SaaS"))
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
    var a3 = Accounts(dir3, AuthConfig("id", "secret", "https://p.example/a", "", "", "https://app.example", random_token(32), 7 * 86400, 7 * 86400, 0, "", "omxcode SaaS"), events=q)
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
    # (hardening, D-6031: a pending sign-in is a sealed cookie, no row: a flood of /login from 10,000 clients, one
    # IPv6 /48's /64s, writes nothing, so there is no server-wide cap to fill and nobody gets 503)
    var before = hdb.one_text("SELECT group_concat(name || ':' || n) FROM (SELECT 'sessions' AS name, count(*) AS n FROM sessions UNION ALL SELECT 'users', count(*) FROM users UNION ALL SELECT 'signin_used', count(*) FROM signin_used UNION ALL SELECT 'desktop_codes', count(*) FROM desktop_codes UNION ALL SELECT 'desktop_pending', count(*) FROM desktop_pending UNION ALL SELECT 'audit', count(*) FROM audit)")
    for i in range(10_000):
        lg = Req("GET", "/login")
        lg.client = "2001:db8:77:" + hex4(i) + "::1"
        if a3.handle(lg).status != 303:
            raise Error("a /login in the flood wasn't 303 (the old cap was 3)")
    var after = hdb.one_text("SELECT group_concat(name || ':' || n) FROM (SELECT 'sessions' AS name, count(*) AS n FROM sessions UNION ALL SELECT 'users', count(*) FROM users UNION ALL SELECT 'signin_used', count(*) FROM signin_used UNION ALL SELECT 'desktop_codes', count(*) FROM desktop_codes UNION ALL SELECT 'desktop_pending', count(*) FROM desktop_pending UNION ALL SELECT 'audit', count(*) FROM audit)")
    expect(before == after and hdb.count("SELECT count(*) FROM sqlite_master WHERE name = 'oauth_states'") == 0, "10,000 /logins wrote rows: " + before + " → " + after)
    _ = hdb.run("INSERT INTO sessions(id, user_id, tenant, expires, last_seen) VALUES ('old', 1, '', 1, 1)")
    _ = hdb.run("INSERT INTO signin_used(id, expires) VALUES ('old', 1)")
    expect(a3.sweep() == 2, "the sweep: a used state and a session")
    expect(hdb.count("SELECT count(*) FROM sqlite_master WHERE name IN ('signin_used_expires', 'sessions_expires', 'desktop_codes_expires', 'desktop_pending_expires')") == 4, "the expiry indexes")
    print("sweep: ok")
    # round 3 review: pending sign-ins per client, cookies over several lines, a changed address under the same sub
    var dir4 = "build/test_accounts.data4"
    _ = libc.unlink(dir4 + "/host.db")
    _ = libc.unlink(dir4 + "/host.db-wal")
    var a4 = Accounts(dir4, AuthConfig("id", "secret", "https://p.example/a", "", "", "http://127.0.0.1:1", random_token(32), 7 * 86400, 7 * 86400, 0, "", "omxcode SaaS"))
    # (hardening, D-6031: the sign-in state is the browser's sealed cookie: bound to it (another state, another
    # browser's cookie, a tampered one, an expired one: refused), used once, and a client's limit is SAAS_RATE a minute)
    var l1 = Req("GET", "/login")
    var started = a4.handle(l1)
    var jar = String("")
    var loc = String("")
    for i in range(len(started.names)):
        if started.names[i] == "Set-Cookie":
            jar = started.values[i]
        if started.names[i] == "Location":
            loc = started.values[i]
    var sealed = String(jar[byte = jar.find("=") + 1 : jar.find(";")])
    var tail = String(loc[byte = loc.find("&state=") + 7 :])
    var st = String(tail[byte = : tail.find("&")])
    var now = Int(wall_seconds())
    expect(Bool(a4.open_state(sealed, st, now)), "the browser's own state")
    expect(not a4.open_state(sealed, "x" * 43, now), "another state with this browser's cookie")
    var l2 = Req("GET", "/login")
    var second = a4.handle(l2)
    var jar2 = String("")
    for i in range(len(second.names)):
        if second.names[i] == "Set-Cookie":
            jar2 = second.values[i]
    expect(not a4.open_state(String(jar2[byte = jar2.find("=") + 1 : jar2.find(";")]), st, now), "this state with another browser's cookie")
    expect(not a4.open_state(String(sealed[byte = : sealed.byte_length() - 2]) + "AA", st, now), "a tampered state cookie")
    expect(not a4.open_state(sealed, st, now + 601), "a state cookie past its 10 minutes")
    expect(a4.open_state(sealed, st, now).value().verifier.byte_length() == 43 and a4.open_state(sealed, st, now).value().verifier not in jar, "the PKCE verifier is the server's (not in the cookie)")
    expect(a4.use_state(st) and not a4.use_state(st), "a state used twice")
    var limited = Accounts(dir4 + "r", AuthConfig("id", "secret", "https://p.example/a", "", "", "http://127.0.0.1:1", random_token(32), 7 * 86400, 7 * 86400, 3, "", "omxcode SaaS"))
    var codes = String("")
    for _ in range(4):
        var la = Req("GET", "/login")
        la.client = "198.51.100.1"
        codes += String(limited.handle(la).status) + " "
    var lb = Req("GET", "/login")
    lb.client = "198.51.100.2"
    expect(codes == "303 303 303 429 " and limited.handle(lb).status == 303, "SAAS_RATE per client: " + codes)
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
