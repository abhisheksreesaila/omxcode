# Goal 66 M5: mojoui.pages without a server: templates escape, sitemap and robots, the manifest, the contact form's
# CSRF token (forged, missing cookie, other site, honeypot, rate limit).
from std.os import makedirs, getenv
from mojoui.serve import Req, Reply
from mojoui.pages import render, sitemap_xml, robots_txt, manifest_json, ContactForm, form_value
from mojoui.jobs import Queue
from mojoui.json import Json
from mojoui import libc


def ok(c: Bool, what: String) raises:
    if not c:
        raise Error("FAILED: " + what)


def head(r: Reply, name: String) -> String:
    for i in range(len(r.names)):
        if r.names[i].lower() == name.lower():
            return r.values[i]
    return ""


def post(body: String, cookie: String, origin: String = "https://fin.example") -> Req:
    var r = Req("POST", "/contact", body)
    r.client = "203.0.113.9"
    if cookie != "":
        r.names.append("cookie")
        r.values.append(cookie)
    if origin != "":
        r.names.append("origin")
        r.values.append(origin)
    return r^


def main() raises:
    var html = render("<h1>{{title}}</h1><p>{{{body}}}</p>{{missing}}", ["title", "body"], ["<script>alert('x')</script> & co", "<b>ok</b>"])
    ok(html == "<h1>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; co</h1><p><b>ok</b></p>", "render: " + html)
    ok(render("{{ a }} {{a}}", ["a"], ['"']) == "&quot; &quot;", "spaces inside braces")
    print("escape: ok")
    var sm = sitemap_xml("https://fin.example", ["/", "/a&b"])
    ok(sm.find("<loc>https://fin.example/</loc>") >= 0 and sm.find("/a&amp;b") >= 0 and sm.startswith("<?xml"), "sitemap")
    print("sitemap: ok")
    var rb = robots_txt("https://fin.example", ["/api/"])
    ok(rb.find("Disallow: /api/") >= 0 and rb.find("Sitemap: https://fin.example/sitemap.xml") >= 0, "robots")
    print("robots: ok")
    var mj = Json.parse(manifest_json("Fin \"x\"", "Fin", "/app", "#000", "#fff", "/i.svg"))
    ok(mj.text(mj.get(0, "name")) == "Fin \"x\"" and mj.text(mj.get(0, "start_url")) == "/app" and mj.size(mj.get(0, "icons")) == 1, "manifest")
    print("manifest: ok")

    var dir = getenv("TMPDIR", "/tmp") + "/mojoui-pages-" + String(libc.getpid())
    makedirs(dir, exist_ok=True)
    var q = Queue(dir + "/host.db")
    var key = List[UInt8]()
    for b in String("k" * 64).as_bytes():
        key.append(b)
    var form = ContactForm(key, "https://fin.example", "owner@fin.example", "Fin", 4, q)
    var page = form.page("<main>{{{form}}}</main>")
    var cookie = head(page, "set-cookie")
    var body = String(from_utf8_lossy=Span(page.body))
    var at = body.find('name="csrf" value="')
    var token = String(body[byte = at + 19 : body.find('"', at + 19)])
    ok(cookie.find("HttpOnly") >= 0 and cookie.find("SameSite=Strict") >= 0 and cookie.find("Secure") >= 0 and token != "", "the cookie and token")
    var jar = String(cookie[byte = : cookie.find(";")])
    var good = "csrf=" + token + "&name=Ben+O%27Neil&email=ben%40example.com&message=Hi+there%0Aline+2&website="
    ok(form_value(good, "name") == "Ben O'Neil" and form_value(good, "message") == "Hi there\nline 2", "form values")
    ok(form.post(post(good.replace(token, "forged"), jar), "thanks").status == 403, "forged token")
    ok(form.post(post(good, ""), "thanks").status == 403, "no cookie")
    ok(form.post(post(good, jar, "https://evil.example"), "thanks").status == 403, "another site")
    var sent = form.post(post(good, jar), "thanks")
    ok(sent.status == 200 and q.db().count("SELECT count(*) FROM jobs WHERE kind = 'mail'") == 1, "queued: " + String(sent.status))
    var payload = q.db().one_text("SELECT payload FROM jobs")
    ok(payload.find("owner@fin.example") >= 0 and payload.find("Ben O'Neil") >= 0, "the mail: " + payload)
    _ = form.post(post(good.replace("website=", "website=http%3A%2F%2Fspam"), jar), "thanks")
    ok(q.db().count("SELECT count(*) FROM jobs WHERE kind = 'mail'") == 1, "the honeypot sent nothing")
    ok(form.post(post(good, jar), "thanks").status == 429, "rate limited after 4")
    print("csrf: ok forged, cookieless and cross-site 403; honeypot silent; the 5th in a minute 429")
