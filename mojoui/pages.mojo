# mojoui.pages: crawlable server-rendered public pages for a mojoui.serve SaaS (goal 66 M5; fh-saas's utils_seo and
# its landing/contact pages). Templates that escape every value, a sitemap.xml and robots.txt, a PWA manifest and service
# worker served with the headers browsers want, and a contact form (a CSRF token in a sealed cookie and a hidden field, a
# per-client rate limit, a honeypot, the message sent as a mojoui.mail job). The page's HTML carries its text: nothing
# needs JavaScript to be read.
#
#   var html = render(LANDING, names, values)        # {{name}} escaped, {{{name}}} trusted HTML (another render's output)
#   return public_page(html)                         # CSP: own scripts/styles/images only, never framed
#   sitemap_xml(base, paths) · robots_txt(base, disallow) · manifest_json(...) · service_worker_js(cache, precache)
#   var contact = ContactForm(key, base, to="owner@…", per_minute=5, queue=jobs)
#   contact.page(req, html_with_{{{form}}})  /  contact.post(req)
from mojoui.serve import Req, Reply, escape_html, decode
from mojoui.crypto import seal, unseal, random_token, same
from mojoui.ratelimit import RateLimit
from mojoui.clientip import rate_key
from mojoui.jobs import Queue
from mojoui.mail import Mail
from mojoui.json import json_string
from mojoui.clock import wall_seconds

comptime CSP_PUBLIC = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
comptime CSRF_COOKIE = "contact_csrf"
comptime CSRF_TTL_S = 3600


def render(template: String, names: List[String], values: List[String]) -> String:
    """`{{name}}` becomes the value HTML-escaped; `{{{name}}}` the value as it is (only for HTML this code made, such as
    another render's output). An unknown name becomes ""."""
    var out = String("")
    var s = template
    var i = 0
    var n = s.byte_length()
    while i < n:
        var open = s.find("{{", i)
        if open < 0:
            out += String(s[byte = i :])
            break
        out += String(s[byte = i : open])
        var raw = open + 2 < n and s.as_bytes()[open + 2] == UInt8(ord("{"))
        var start = open + (3 if raw else 2)
        var close = s.find("}}}" if raw else "}}", start)
        if close < 0:
            out += String(s[byte = open :])
            break
        var name = String(String(s[byte = start : close]).strip())
        var value = String("")
        for k in range(len(names)):
            if names[k] == name:
                value = values[k]
        out += value if raw else escape_html(value)
        i = close + (3 if raw else 2)
    return out^


def public_page(html: String, status: Int = 200, cache: String = "public, max-age=300") -> Reply:
    """A public HTML page: its own scripts, styles and images only, never framed; `cache` its one Cache-Control (a page
    that sets a cookie or shows a person's data: "no-store")."""
    return Reply(status, "text/html; charset=utf-8", html).header("Content-Security-Policy", CSP_PUBLIC).header(
        "Referrer-Policy", "strict-origin-when-cross-origin").header("Cache-Control", cache)


def _xml(s: String) -> String:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&apos;")


def sitemap_xml(base: String, paths: List[String], lastmod: String = "") -> String:
    var out = String('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n')
    for p in paths:
        out += "  <url><loc>" + _xml(base + p) + "</loc>" + ("<lastmod>" + _xml(lastmod) + "</lastmod>" if lastmod != "" else "") + "</url>\n"
    return out + "</urlset>\n"


def sitemap_reply(base: String, paths: List[String], lastmod: String = "") -> Reply:
    return Reply(200, "application/xml; charset=utf-8", sitemap_xml(base, paths, lastmod)).header("Cache-Control", "public, max-age=3600")


def robots_txt(base: String, disallow: List[String]) -> String:
    var out = String("User-agent: *\n")
    for d in disallow:
        out += "Disallow: " + d + "\n"
    return out + "Allow: /\n\nSitemap: " + base + "/sitemap.xml\n"


def robots_reply(base: String, disallow: List[String]) -> Reply:
    return Reply.text(robots_txt(base, disallow)).header("Cache-Control", "public, max-age=3600")


def manifest_json(name: String, short_name: String, start_url: String, theme: String, background: String, icon: String,
                  icon_type: String = "image/svg+xml", icon_sizes: String = "any") -> String:
    return ('{"name": ' + json_string(name) + ', "short_name": ' + json_string(short_name) + ', "start_url": ' + json_string(start_url)
            + ', "scope": "/", "display": "standalone", "theme_color": ' + json_string(theme) + ', "background_color": ' + json_string(background)
            + ', "icons": [{"src": ' + json_string(icon) + ', "sizes": ' + json_string(icon_sizes) + ', "type": ' + json_string(icon_type)
            + ', "purpose": "any"}]}')


def manifest_reply(text: String) -> Reply:
    return Reply(200, "application/manifest+json", text).header("Cache-Control", "public, max-age=3600")


def service_worker_js(cache: String, precache: List[String]) -> String:
    """A small offline-first worker: precaches `precache`; static files cache-first; pages network-first falling back to
    the cache; API calls and anything not GET never touched."""
    var list = String("")
    for i in range(len(precache)):
        list += ("," if i > 0 else "") + json_string(precache[i])
    return ("const CACHE = " + json_string(cache) + ";\nconst PRECACHE = [" + list + "];\n"
            + "self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(PRECACHE)).then(() => self.skipWaiting())); });\n"
            + "self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });\n"
            + "self.addEventListener('fetch', e => {\n"
            + "  const u = new URL(e.request.url);\n"
            + "  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.startsWith('/api/') || u.pathname.startsWith('/operator/')) return;\n"
            + "  if (u.pathname.startsWith('/static/')) { e.respondWith(caches.match(e.request).then(r => r || fetch(e.request).then(n => { const c = n.clone(); caches.open(CACHE).then(k => k.put(e.request, c)); return n; }))); return; }\n"
            + "  if (e.request.mode === 'navigate') e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));\n"
            + "});\n")


def worker_reply(js: String) -> Reply:
    """A service worker: JavaScript, revalidated every time, allowed to control the whole site."""
    return Reply(200, "text/javascript; charset=utf-8", js).header("Cache-Control", "no-cache").header("Service-Worker-Allowed", "/")


def form_value(body: String, name: String) -> String:
    """A field of an application/x-www-form-urlencoded body ('+' is a space), "" when absent."""
    for part in body.split("&"):
        var p = String(part)
        var eq = p.find("=")
        var k = String(p) if eq < 0 else String(p[byte = : eq])
        if decode(k.replace("+", " ")) == name:
            return decode((String("") if eq < 0 else String(p[byte = eq + 1 :])).replace("+", " "))
    return ""


def _cookie(req: Req, name: String) -> String:
    var found = String("")
    var n = 0
    for part in req.header_all("cookie", "; ").split(";"):
        var p = String(String(part).strip())
        if p.startswith(name + "="):
            found = String(p[byte = name.byte_length() + 1 :])
            n += 1
    return found if n == 1 else ""


def _origin_ok(req: Req, base: String) -> Bool:
    var origin = req.header("origin")
    var site = req.header("sec-fetch-site")
    if origin == "":
        return site == "" or site == "same-origin" or site == "none"
    if origin == "null":
        return site == "same-origin"
    return origin == base


struct ContactForm(Copyable, Movable):
    var key: List[UInt8]
    var base: String
    var to: String  # where messages go
    var site_name: String
    var limit: RateLimit
    var queue: Queue
    var mail_kind: String  # the job kind whose runner sends a Mail.to_json payload

    def __init__(out self, key: List[UInt8], base: String, to: String, site_name: String, per_minute: Int, queue: Queue, mail_kind: String = "mail"):
        self.key = key.copy()
        self.base = base
        self.to = to
        self.site_name = site_name
        self.limit = RateLimit(per_minute, 60)
        self.queue = queue
        self.mail_kind = mail_kind

    def form_html(self, token: String) -> String:
        return render(
            '<form method="post" action="/contact" class="contact">'
            + '<input type="hidden" name="csrf" value="{{csrf}}">'
            + '<label>Name <input name="name" maxlength="100" required></label>'
            + '<label>Email <input name="email" type="email" maxlength="200" required></label>'
            + '<label>Message <textarea name="message" maxlength="4000" rows="6" required></textarea></label>'
            + '<div class="hp" aria-hidden="true" style="position:absolute;left:-10000px"><label>Website <input name="website" tabindex="-1" autocomplete="off"></label></div>'
            + '<button type="submit">Send</button></form>',
            ["csrf"], [token])

    def page(self, page_template: String) -> Reply:
        """The form put in place of `{{{form}}}` in an already rendered page, with a fresh token in its hidden field and
        its sealed cookie."""
        var token: String
        try:
            token = random_token(24)
        except:
            return Reply.error(503, "no randomness: try again", "busy")
        var sealed = seal(self.key, "contact\n" + token, CSRF_TTL_S, Int(wall_seconds()))
        var secure = "; Secure" if self.base.startswith("https://") else ""
        return public_page(page_template.replace("{{{form}}}", self.form_html(token)), cache="no-store").header(  # (not a second render: the page's own text stays as it is)
            "Set-Cookie", CSRF_COOKIE + "=" + sealed + "; Path=/contact; HttpOnly; SameSite=Strict; Max-Age=" + String(CSRF_TTL_S) + secure)

    def post(self, req: Req, thanks_html: String) -> Reply:
        """403 another site or a bad token, 429 too many from this client, 400 a bad field; a filled honeypot gets the
        same thanks and sends nothing; otherwise the message is queued as a mail job."""
        if self.to == "":
            return Reply.error(503, "the contact form isn't set up", "not_configured")
        if not _origin_ok(req, self.base):
            return Reply.error(403, "this form posts from its own page only", "forbidden")
        var wait = self.limit.hit("contact " + rate_key(req.client if req.client != "" else req.peer))
        if wait > 0:
            return Reply.error(429, "too many messages: try again later", "rate_limited").header("Retry-After", String(wait))
        var token = form_value(req.body, "csrf")
        var opened = unseal(self.key, _cookie(req, CSRF_COOKIE), Int(wall_seconds()))
        if token == "" or not opened or not same(opened.value(), "contact\n" + token):
            return Reply.error(403, "the form has expired: reload the page", "bad_csrf")
        if form_value(req.body, "website") != "":
            return public_page(thanks_html, cache="no-store")  # (a bot: thanked, nothing sent)
        var name = String(form_value(req.body, "name").strip())
        var email = String(form_value(req.body, "email").strip())
        var message = String(form_value(req.body, "message").strip())
        if name == "" or name.byte_length() > 100 or email.byte_length() > 200 or email.find("@") < 1 or message == "" or message.byte_length() > 4000:
            return Reply.error(400, "a name, an email and a message (up to 4000 characters) please", "bad_request")
        for b in (name + email).as_bytes():
            if b < 0x20:
                return Reply.error(400, "no control characters in the name or email", "bad_request")
        var mail = Mail.from_template(self.to, self.site_name, "Contact from {{name}}",
                                      "A message from the contact form.\n\nFrom: {{name}} ({{email}})\n\n{{message}}\n",
                                      ["name", "email", "message"], [name, email, message])
        try:
            _ = self.queue.add(self.mail_kind, mail.to_json())
        except:
            return Reply.error(503, "can't take the message now: try again", "busy")
        return public_page(thanks_html, cache="no-store").header("Set-Cookie", CSRF_COOKIE + "=; Path=/contact; Max-Age=0; HttpOnly; SameSite=Strict")
