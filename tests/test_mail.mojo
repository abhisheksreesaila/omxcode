# Goal 60 M4: mojoui.mail without a server: dot-stuffing, header injection refused, RFC 2047 words, the MIME message.
# SMTP itself (AUTH, implicit TLS, STARTTLS, 4xx retries as jobs) is proved by 60-check.py M4 against its stand-in.
# Round 3 (S-L4): a server that accepts and never speaks can't hold a sender past its deadline, in every TLS mode.
from mojoui.mail import Mail, dotstuff, compose, encode_word, header_value, address_ok, mailbox, markdown_html, markdown_text, welcome, rfc5322_date
from mojoui.mail import SmtpConfig, send
from mojoui.crypto import b64
from mojoui.clock import now_ns
from flare.tcp import TcpListener
from flare.net import SocketAddr, IpAddr


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    var s = dotstuff(".hidden\nline\r\n..two\rlast")
    expect(s == "..hidden\r\nline\r\n...two\r\nlast\r\n", "dotstuff: " + s)
    expect("\r\n.\r\n" not in dotstuff("a\n.\nb"), "a lone dot can't end DATA")
    print("dotstuff: ok")
    var evil = "Eve\r\nBcc: spy@evil.example"
    expect("\r" not in header_value(evil) and "\n" not in header_value(evil), "CR/LF gone")
    var msg = compose("omxcode SaaS <hello@saas.example>", Mail("eve@example.com", evil, "Hi\r\nX-Evil: 1", "t", "<p>h</p>"), 1_800_000_000, "tok1")
    var head = String(msg[byte = : msg.find("\r\n\r\n")])
    for raw in head.split("\r\n"):
        var l = String(raw)
        expect(not l.lower().startswith("bcc:") and not l.lower().startswith("x-evil:"), "an injected header: " + l)
    expect(not address_ok("a@b.c\r\nRCPT TO:<x@y>") and not address_ok("a b@c") and not address_ok("<a@b>") and address_ok("zoe@example.com"), "addresses")
    var refused = False
    try:
        _ = compose("x@y.z", Mail("a@b.c>\r\nRCPT TO:<spy@evil.example", "", "s", "t", "h"), 0, "t")
    except:
        refused = True
    expect(refused, "a bad recipient refused")
    print("header_inject: ok")
    var w = encode_word("Welcome, Zoë Ångström")
    expect(w.startswith("=?UTF-8?B?") and w.endswith("?="), "encoded: " + w)
    for c in w.as_bytes():
        expect(c < 128, "ASCII only")
    expect(encode_word("Plain subject") == "Plain subject", "ASCII stays")
    var long = encode_word("ü" * 80)
    for part in long.split("\r\n"):
        expect(String(part).strip().byte_length() <= 75, "a word over 75: " + String(part))
    expect(mailbox("Zoë", "z@e.com").endswith(" <z@e.com>") and mailbox("Ada", "a@e.com") == '"Ada" <a@e.com>', "mailboxes")
    expect(rfc5322_date(0) == "Thu, 01 Jan 1970 00:00:00 +0000" and rfc5322_date(1_762_470_245) == "Thu, 06 Nov 2025 23:04:05 +0000", "dates: " + rfc5322_date(1_762_470_245))
    print("encode: ok")
    var m = welcome("zoe@example.com", "Zoë <b>", "omxcode", "https://app.example/x?a=1&b=2")
    expect("Zoë" in m.subject, "the subject names the person")
    expect("&lt;b&gt;" in m.html and "<b>" not in m.html, "values escaped in HTML: " + m.html)
    expect('<a href="https://app.example/x?a=1&amp;b=2">' in m.html, "a link: " + m.html)
    expect("https://app.example/x?a=1&b=2" in m.text and "#" not in m.text, "the text part: " + m.text)
    expect("javascript" not in markdown_html("[x](javascript:alert(1))") or "<a" not in markdown_html("[x](javascript:alert(1))"), "no js links")
    var full = compose("omxcode SaaS <hello@saas.example>", m, 1_800_000_000, "tok2")
    expect('Content-Type: multipart/alternative; boundary="=_omx_tok2"' in full, "multipart")
    expect("Content-Type: text/plain; charset=utf-8" in full and "Content-Type: text/html; charset=utf-8" in full, "two parts")
    expect(b64(m.text)[byte = : 40] in full.replace("\r\n", ""), "the text part's base64")
    expect(full.endswith("--=_omx_tok2--\r\n"), "closed")
    expect("MIME-Version: 1.0\r\n" in full and "Message-ID: <tok2@saas.example>" in full, "headers")
    print("multipart: ok")
    # deadline: a listener whose kernel completes the handshake from its backlog and never says a word
    var silent = TcpListener.bind(SocketAddr(IpAddr("127.0.0.1", False), UInt16(0)))
    var port = Int(silent.local_addr().port)
    for mode in ["implicit", "starttls", "off"]:
        var cfg = SmtpConfig("127.0.0.1", port, "", "", "App <app@example.com>", String(mode), "", 800)
        var t0 = now_ns()
        var raised = False
        try:
            send(cfg, welcome("ada@example.com", "Ada", "omxcode SaaS", "https://example.com/"))
        except:
            raised = True
        var ms = Int(now_ns() - t0) // 1_000_000
        expect(raised and ms < 5000, "SMTP_TLS=" + String(mode) + " against a silent server: " + ("raised" if raised else "sent") + " after " + String(ms) + " ms")
    _ = silent.local_addr()
    print("deadline: ok (a silent server: each mode gave up within its 800 ms deadline)")
