# mojoui.mail: email for servers (goal 60 M4; fh-saas's utils_email): markdown templates rendered to a text and an HTML
# part, a MIME message any client reads, and an SMTP client with AUTH over implicit TLS or STARTTLS (Flare's OpenSSL,
# the certificate checked against the system's CAs or SMTP_CA_FILE). Send through mojoui.jobs so a slow or refusing
# server is retried and never holds a request: `queue.add("mail", mail.to_json())`, then `MailRunner` sends it.
#
#   var cfg = SmtpConfig.from_env()          # SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM SMTP_TLS SMTP_CA_FILE
#   var m = Mail.from_template(to, name, "Welcome, {{name}}", "# Hi {{name}}\n\nYour [workspace]({{link}}) is ready.",
#                              ["name", "link"], [name, link])
#   send(cfg, m)                             # raises with the server's reply ("451 try again later") when refused
#
# Safety: every header value has its CR, LF and other controls replaced (a name can't add a header or a recipient);
# addresses are checked (one @, no spaces, quotes, <>, commas or controls); a non-ASCII name or subject is an RFC 2047
# encoded word; bodies are base64 (so lines and dots never matter) and the DATA stream is dot-stuffed anyway. Template
# values are HTML-escaped in the HTML part; links are http(s) only.

from std.os import getenv
from std.sys import CompilationTarget
from mojoui.crypto import b64, random_bytes
from mojoui.hash import hex
from mojoui.json import Json, json_string
from mojoui.clock import wall_seconds
from flare.tcp import TcpStream
from flare.tls import TlsStream, TlsConfig
from flare.net import SocketAddr, IpAddr

comptime CRLF = "\r\n"


@fieldwise_init
struct SmtpConfig(Copyable, Movable):
    var host: String
    var port: Int
    var user: String
    var password: String
    var sender: String  # "Name <address>" or an address
    var tls: String  # implicit | starttls | off
    var ca_file: String
    var timeout_ms: Int

    @staticmethod
    def from_env() -> SmtpConfig:
        var tls = getenv("SMTP_TLS", "starttls")
        var port = 465 if tls == "implicit" else 587
        try:
            port = atol(getenv("SMTP_PORT", String(port)))
        except:
            pass
        return SmtpConfig(getenv("SMTP_HOST"), port, getenv("SMTP_USER"), getenv("SMTP_PASSWORD"), getenv("SMTP_FROM"),
                          tls, getenv("SMTP_CA_FILE"), 20_000)

    def ready(self) -> Bool:
        return self.host != "" and self.sender != ""


@fieldwise_init
struct Mail(Copyable, Movable):
    var to: String
    var to_name: String
    var subject: String
    var text: String
    var html: String

    @staticmethod
    def from_template(to: String, to_name: String, subject: String, markdown: String, names: List[String], values: List[String]) -> Mail:
        """{{name}} filled in the subject and the body (HTML-escaped in the HTML part); the body markdown → text + HTML."""
        var plain = fill(markdown, names, values, False)
        var safe = fill(markdown, names, values, True)
        return Mail(to, to_name, fill(subject, names, values, False), markdown_text(plain), markdown_html(safe))

    def to_json(self) -> String:
        return ('{"to": ' + json_string(self.to) + ', "to_name": ' + json_string(self.to_name) + ', "subject": ' + json_string(self.subject)
            + ', "text": ' + json_string(self.text) + ', "html": ' + json_string(self.html) + "}")

    @staticmethod
    def from_json(text: String) raises -> Mail:
        var j = Json.parse(text)
        return Mail(j.text(j.get(0, "to")), j.text(j.get(0, "to_name")), j.text(j.get(0, "subject")), j.text(j.get(0, "text")), j.text(j.get(0, "html")))


# templates and markdown ------------------------------------------------------------------------------------------------

def escape_html(s: String) -> String:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&#39;")


def _inert(s: String) -> String:
    """A value that can't become markdown (a name like "[Accept](https://evil.example)" stays text)."""
    return s.replace("[", "(").replace("]", ")").replace("*", "·").replace("`", "'")


def fill(template: String, names: List[String], values: List[String], html: Bool) -> String:
    """{{name}} → its value, never read as markdown; HTML-escaped too when `html`. A value that is a whole link target
    (`({{link}})`) is kept as it is."""
    var out = template
    for i in range(min(len(names), len(values))):
        var v = values[i] if "(" + "{{" + names[i] + "}}" + ")" in template else _inert(values[i])
        out = out.replace("{{" + names[i] + "}}", escape_html(v) if html else v)
    return out


def _inline_html(line: String) -> String:
    """**bold**, *italic*, `code` and [text](http(s)-url) on an already HTML-escaped line."""
    var out = String("")
    var b = line.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        if c == 91:  # [text](url)
            var close = line.find("](", i)
            var end = line.find(")", close + 2) if close > i else -1
            if close > i and end > close:
                var label = String(line[byte = i + 1 : close])
                var url = String(line[byte = close + 2 : end])
                if (url.startswith("https://") or url.startswith("http://")) and " " not in url:
                    out += '<a href="' + url + '">' + label + "</a>"
                    i = end + 1
                    continue
        if c == 42 and i + 1 < n and b[i + 1] == 42:
            var end = line.find("**", i + 2)
            if end > i + 2:
                out += "<strong>" + String(line[byte = i + 2 : end]) + "</strong>"
                i = end + 2
                continue
        if c == 42 or c == 96:
            var end = line.find(chr(Int(c)), i + 1)
            if end > i + 1:
                var tag = "em" if c == 42 else "code"
                out += "<" + tag + ">" + String(line[byte = i + 1 : end]) + "</" + tag + ">"
                i = end + 1
                continue
        var j = i + 1
        while j < n and (b[j] & 0xC0) == 0x80:
            j += 1
        out += String(line[byte = i : j])
        i = j
    return out


def markdown_html(md: String) -> String:
    """Headings (#, ##, ###), paragraphs, - lists and inline marks → a small, inline-styled HTML document."""
    var body = String("")
    var para = String("")
    var in_list = False
    for raw in md.split("\n"):
        var line = String(String(raw).strip())
        if line == "":
            if para != "":
                body += "<p>" + _inline_html(para) + "</p>\n"
                para = ""
            if in_list:
                body += "</ul>\n"
                in_list = False
            continue
        if line.startswith("#"):
            var level = 0
            while level < line.byte_length() and line.as_bytes()[level] == 35:
                level += 1
            level = min(level, 3)
            body += "<h" + String(level) + ">" + _inline_html(String(String(line[byte = level :]).strip())) + "</h" + String(level) + ">\n"
            continue
        if line.startswith("- ") or line.startswith("* "):
            if not in_list:
                body += "<ul>\n"
                in_list = True
            body += "<li>" + _inline_html(String(line[byte = 2 :])) + "</li>\n"
            continue
        para += (" " if para != "" else "") + line
    if para != "":
        body += "<p>" + _inline_html(para) + "</p>\n"
    if in_list:
        body += "</ul>\n"
    return ('<!doctype html><html><body style="font-family: -apple-system, Segoe UI, Roboto, sans-serif; line-height: 1.5; color: #1c1b1f">\n'
        + body + "</body></html>\n")


def markdown_text(md: String) -> String:
    """The plain part: marks dropped, [text](url) as "text (url)"."""
    var out = String("")
    for raw in md.split("\n"):
        var line = String(raw)
        var s = String(line.strip())
        while s.startswith("#"):
            var rest = String(s[byte = 1 :])
            s = rest
        s = String(s.strip()) if line.strip().startswith("#") else line
        var res = String("")
        var i = 0
        while i < s.byte_length():
            var close = s.find("](", i)
            var open = s.find("[", i)
            var end = s.find(")", close + 2) if close >= 0 else -1
            if open >= 0 and close > open and end > close:
                res += String(s[byte = i : open]) + String(s[byte = open + 1 : close]) + " (" + String(s[byte = close + 2 : end]) + ")"
                i = end + 1
            else:
                res += String(s[byte = i :])
                break
        out += res.replace("**", "").replace("`", "") + "\n"
    return out


# the message ---------------------------------------------------------------------------------------------------------

def header_value(s: String) -> String:
    """A header's value with CR, LF and every other control (and DEL) replaced by a space."""
    var out = String("")
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c < 32 or c == 127:
            out += " "
            i += 1
            continue
        var j = i + 1
        while j < len(b) and (b[j] & 0xC0) == 0x80:
            j += 1
        out += String(s[byte = i : j])
        i = j
    return out


def address_ok(a: String) -> Bool:
    if a.byte_length() < 3 or a.byte_length() > 254 or a.count("@") != 1 or a.startswith("@") or a.endswith("@"):
        return False
    for c in a.as_bytes():
        if c <= 32 or c >= 127 or c == 60 or c == 62 or c == 34 or c == 44 or c == 59 or c == 40 or c == 41 or c == 92 or c == 91 or c == 93:
            return False
    return True


def _plain_word(s: String) -> Bool:
    for c in s.as_bytes():
        if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 32 or c == 46 or c == 45 or c == 39 or c == 95):
            return False
    return True


def encode_word(s: String) -> String:
    """RFC 2047: the text as =?UTF-8?B?…?= words of at most 75 characters, split between characters, never inside one;
    plain ASCII text stays as it is."""
    var v = header_value(s)
    var ascii = True
    for c in v.as_bytes():
        if c >= 128:
            ascii = False
    if ascii and "=?" not in v:
        return v
    var out = String("")
    var b = v.as_bytes()
    var i = 0
    while i < len(b):
        var chunk = List[UInt8]()
        while i < len(b) and len(chunk) < 45:  # (45 bytes → 60 base64 characters + 12 of wrapping ≤ 75)
            var j = i + 1
            while j < len(b) and (b[j] & 0xC0) == 0x80:
                j += 1
            if len(chunk) + (j - i) > 45 and len(chunk) > 0:
                break
            for k in range(i, j):
                chunk.append(b[k])
            i = j
        out += (CRLF + " " if out != "" else "") + "=?UTF-8?B?" + b64(chunk) + "?="
    return out


def mailbox(name: String, addr: String) -> String:
    """`Name <addr>` with the name quoted or encoded as it needs (just `<addr>` when there's no name)."""
    var n = String(header_value(name).strip())
    if n == "":
        return "<" + addr + ">"
    if _plain_word(n):
        return '"' + n + '" <' + addr + ">"
    return encode_word(n) + " <" + addr + ">"


def split_sender(sender: String) -> Tuple[String, String]:
    """"Name <a@b>" → (Name, a@b); "a@b" → ("", a@b)."""
    var lt = sender.find("<")
    var gt = sender.find(">")
    if lt >= 0 and gt > lt:
        var nm = String(String(sender[byte = : lt]).strip())
        if nm.startswith('"') and nm.endswith('"') and nm.byte_length() >= 2:
            var inner = String(nm[byte = 1 : nm.byte_length() - 1])
            nm = inner
        return (nm, String(String(sender[byte = lt + 1 : gt]).strip()))
    return (String(""), String(sender.strip()))


def _wrap76(s: String) -> String:
    var out = String("")
    var i = 0
    while i < s.byte_length():
        out += String(s[byte = i : min(i + 76, s.byte_length())]) + CRLF
        i += 76
    return out


def _two(n: Int) -> String:
    return ("0" if n < 10 else "") + String(n)


def rfc5322_date(t: Int) -> String:
    """"Thu, 06 Nov 2026 22:04:05 +0000" for a Unix time (UTC)."""
    var days = t // 86400
    var secs = t % 86400
    var wd = (days + 4) % 7  # (1970-01-01 was a Thursday)
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    var y = yoe + era * 400 + (1 if m <= 2 else 0)
    var wds: List[String] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var ms: List[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return wds[wd] + ", " + _two(d) + " " + ms[m - 1] + " " + String(y) + " " + _two(secs // 3600) + ":" + _two(secs % 3600 // 60) + ":" + _two(secs % 60) + " +0000"


def compose(sender: String, m: Mail, now: Int, token: String) raises -> String:
    """The whole message (CRLF lines): headers, then multipart/alternative with the text and the HTML part."""
    var from_parts = split_sender(sender)
    if not address_ok(from_parts[1]):
        raise Error("mail: SMTP_FROM isn't an address")
    if not address_ok(m.to):
        raise Error("mail: not an address: " + header_value(m.to))
    var domain = String(from_parts[1][byte = from_parts[1].find("@") + 1 :])
    var boundary = "=_omx_" + token
    var h = "From: " + mailbox(from_parts[0], from_parts[1]) + CRLF
    h += "To: " + mailbox(m.to_name, m.to) + CRLF
    h += "Subject: " + encode_word(m.subject) + CRLF
    h += "Date: " + rfc5322_date(now) + CRLF
    h += "Message-ID: <" + token + "@" + domain + ">" + CRLF
    h += "MIME-Version: 1.0" + CRLF
    h += 'Content-Type: multipart/alternative; boundary="' + boundary + '"' + CRLF + CRLF
    var body = "--" + boundary + CRLF + "Content-Type: text/plain; charset=utf-8" + CRLF + "Content-Transfer-Encoding: base64" + CRLF + CRLF
    body += _wrap76(b64(m.text))
    body += "--" + boundary + CRLF + "Content-Type: text/html; charset=utf-8" + CRLF + "Content-Transfer-Encoding: base64" + CRLF + CRLF
    body += _wrap76(b64(m.html))
    body += "--" + boundary + "--" + CRLF
    return h + body


def dotstuff(message: String) -> String:
    """SMTP's DATA transparency (RFC 5321 §4.5.2): lines end in CRLF (a bare LF or CR becomes one) and a line that
    starts with "." gets another, so no line of the message can end the DATA early."""
    var out = String("")
    var b = message.as_bytes()
    var start = True
    var i = 0
    while i < len(b):
        var c = b[i]
        if start and c == 46:
            out += "."
        if c == 13:
            out += CRLF
            if i + 1 < len(b) and b[i + 1] == 10:
                i += 1
            start = True
            i += 1
            continue
        if c == 10:
            out += CRLF
            start = True
            i += 1
            continue
        var j = i + 1
        while j < len(b) and (b[j] & 0xC0) == 0x80:
            j += 1
        out += String(message[byte = i : j])
        start = False
        i = j
    if not out.endswith(CRLF):
        out += CRLF
    return out


# SMTP ----------------------------------------------------------------------------------------------------------------

struct _Wire(Movable):
    var tcp: Optional[TcpStream]
    var tls: Optional[TlsStream]
    var buf: List[UInt8]

    def __init__(out self, var tcp: TcpStream):
        self.tcp = tcp^
        self.tls = None
        self.buf = List[UInt8]()

    def __init__(out self, var tls: TlsStream):
        self.tcp = None
        self.tls = tls^
        self.buf = List[UInt8]()

    def send(mut self, text: String) raises:
        if self.tls:
            self.tls.value().write_all(text.as_bytes())
        else:
            self.tcp.value().write_all(text.as_bytes())

    def _fill(mut self) raises:
        var chunk = List[UInt8](length=4096, fill=0)
        var n: Int
        if self.tls:
            n = self.tls.value().read(chunk.unsafe_ptr(), 4096)
        else:
            n = self.tcp.value().read(chunk.unsafe_ptr(), 4096)
        if n <= 0:
            raise Error("the SMTP server closed the connection")
        for i in range(n):
            self.buf.append(chunk[i])

    def line(mut self) raises -> String:
        while True:
            for i in range(len(self.buf)):
                if self.buf[i] == 10:
                    var s = String(from_utf8_lossy=Span(self.buf)[: i + 1])
                    var rest = List[UInt8]()
                    for k in range(i + 1, len(self.buf)):
                        rest.append(self.buf[k])
                    self.buf = rest^
                    return String(s.strip())
            if len(self.buf) > 65536:
                raise Error("an SMTP reply line is too long")
            self._fill()

    def reply(mut self) raises -> Tuple[Int, String]:
        """A whole (multi-line) reply: its code and every line's text."""
        var all = String("")
        while True:
            var l = self.line()
            if l.byte_length() < 3:
                raise Error("a malformed SMTP reply: " + header_value(l))
            all += l + "\n"
            if l.byte_length() == 3 or l.as_bytes()[3] != 45:  # (not "250-…")
                var code = 0
                try:
                    code = atol(String(l[byte = : 3]))
                except:
                    raise Error("a malformed SMTP reply: " + header_value(l))
                return (code, all)

    def expect(mut self, want: Int, what: String) raises -> String:
        """The reply when its class is `want`'s; else raises with it: a 5xx (RFC 5321 §4.2.1: permanent, sending
        again won't help) starts "permanent: " (mojoui.jobs' PERMANENT: such a job is dead at once)."""
        var r = self.reply()
        if r[0] // 100 != want // 100:
            raise Error(("permanent: " if r[0] // 100 == 5 else "") + "SMTP " + what + ": " + String(String(r[1]).strip()))
        return r[1]


def _connect(host: String, port: Int, timeout_ms: Int) raises -> TcpStream:
    var tcp = TcpStream.connect(host, UInt16(port), timeout_ms)  # (each resolved address within the deadline)
    tcp.set_recv_timeout(timeout_ms)
    tcp.set_send_timeout(timeout_ms)
    return tcp^


def _tls_config(cfg: SmtpConfig) -> TlsConfig:
    return TlsConfig(ca_bundle=cfg.ca_file)


def send(cfg: SmtpConfig, m: Mail) raises:
    """One message over SMTP; raises with the server's reply (or the network's error) when it isn't accepted."""
    if not cfg.ready():
        raise Error("mail: SMTP isn't set up (SMTP_HOST, SMTP_FROM)")
    if cfg.tls != "implicit" and cfg.tls != "starttls" and not (cfg.tls == "off" and (cfg.host == "127.0.0.1" or cfg.host == "::1" or cfg.host == "localhost")):
        raise Error("mail: SMTP_TLS must be implicit or starttls (off only for a relay on this machine)")
    var token = hex(random_bytes(12))
    var data = dotstuff(compose(cfg.sender, m, Int(wall_seconds()), token))
    var from_addr = split_sender(cfg.sender)[1]
    var w: _Wire
    if cfg.tls == "implicit":
        var tls = TlsStream.connect_timeout(cfg.host, UInt16(cfg.port), _tls_config(cfg), cfg.timeout_ms)  # (the connect and the handshake each bounded)
        tls.set_recv_timeout(cfg.timeout_ms)
        w = _Wire(tls^)
    else:
        w = _Wire(_connect(cfg.host, cfg.port, cfg.timeout_ms))
    _ = w.expect(220, "greeting")
    var me = "omxcode.local"
    w.send("EHLO " + me + CRLF)
    var caps = w.expect(250, "EHLO").upper()
    if cfg.tls == "starttls":
        if "STARTTLS" not in caps:
            raise Error("mail: the server doesn't offer STARTTLS (SMTP_TLS=starttls): not sending in the clear")
        w.send("STARTTLS" + CRLF)
        _ = w.expect(220, "STARTTLS")
        var tls = TlsStream.connect_over_tcp(w.tcp.take(), cfg.host, _tls_config(cfg))  # (the socket's receive timeout bounds the handshake)
        tls.set_recv_timeout(cfg.timeout_ms)
        w = _Wire(tls^)
        w.send("EHLO " + me + CRLF)
        caps = w.expect(250, "EHLO after STARTTLS").upper()
    if cfg.user != "":
        if "AUTH" not in caps:
            raise Error("mail: the server offers no AUTH")
        var blob = List[UInt8]()
        blob.append(0)
        for c in cfg.user.as_bytes():
            blob.append(c)
        blob.append(0)
        for c in cfg.password.as_bytes():
            blob.append(c)
        w.send("AUTH PLAIN " + b64(blob) + CRLF)
        _ = w.expect(235, "AUTH")
    w.send("MAIL FROM:<" + from_addr + ">" + CRLF)
    _ = w.expect(250, "MAIL FROM")
    w.send("RCPT TO:<" + m.to + ">" + CRLF)
    _ = w.expect(250, "RCPT TO")
    w.send("DATA" + CRLF)
    _ = w.expect(354, "DATA")
    w.send(data + "." + CRLF)
    _ = w.expect(250, "the message")
    try:
        w.send("QUIT" + CRLF)
        _ = w.reply()
    except:
        pass


struct MailRunner(Copyable, Movable):
    """Sends a job's mail (payload: Mail.to_json()): "" when the server took it, else its reply. Compose it into an
    app's mojoui.jobs Runner: `if job.kind == "mail": return self.mail.run(job.payload)`."""
    var cfg: SmtpConfig

    def __init__(out self, var cfg: SmtpConfig):
        self.cfg = cfg^

    def run(self, payload: String) -> String:
        try:
            send(self.cfg, Mail.from_json(payload))
            return ""
        except e:
            var why = String(e)
            return why if why != "" else String("mail: failed")


def welcome(to: String, name: String, product: String, link: String) -> Mail:
    """fh-saas's send_welcome_email: the subject names the person."""
    var names: List[String] = ["name", "product", "link"]
    var values: List[String] = [name if name != "" else to, product, link]
    return Mail.from_template(to, name, "Welcome to {{product}}, {{name}}",
        "# Welcome, {{name}}\n\nYour {{product}} workspace is ready.\n\n[Open {{product}}]({{link}})\n", names, values)


def invitation(to: String, inviter: String, tenant: String, product: String, link: String, days: Int) -> Mail:
    """fh-saas's send_invitation_email: a link to accept (it expires)."""
    var names: List[String] = ["inviter", "tenant", "product", "link", "days"]
    var values: List[String] = [inviter, tenant, product, link, String(days)]
    return Mail.from_template(to, "", "{{inviter}} invited you to {{tenant}} on {{product}}",
        "# Join {{tenant}}\n\n**{{inviter}}** invited you to **{{tenant}}** on {{product}}.\n\n[Accept the invitation]({{link}})\n\nThe link works once and expires in {{days}} days.\n",
        names, values)
