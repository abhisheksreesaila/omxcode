# mojoui.clientip (goal 60 round 3, R3): X-Forwarded-For read only from a trusted proxy, its rightmost untrusted hop the
# client; an untrusted peer's header ignored; IPv6 grouped by /64 for limits; addresses parsed strictly.
from mojoui.clientip import TrustedProxies, client_ip, rate_key, parse_ip, format_ip


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    expect(len(parse_ip("203.0.113.5")) == 4 and len(parse_ip("2001:db8::1")) == 16 and len(parse_ip("[::1]")) == 16, "literals")
    for bad in ["", "1.2.3", "1.2.3.256", "01.2.3.4", "2001:db8::1::2", "2001:db8:1:2:3:4:5:6:7", "g::1", "1.2.3.4.5", "evil.example"]:
        expect(len(parse_ip(bad)) == 0, "parsed a non-address: " + bad)
    expect(format_ip(parse_ip("2001:0db8:0000:0000:0000:0000:0000:0001")) == "2001:db8::1", "RFC 5952: " + format_ip(parse_ip("2001:0db8:0000:0000:0000:0000:0000:0001")))
    expect(format_ip(parse_ip("::ffff:192.0.2.1")) == "::ffff:c000:201", "a mapped address's text")
    print("parse: ok")
    var p = TrustedProxies.parse("127.0.0.1, 10.0.0.0/8 fd00::/8")
    expect(p.trusts("10.9.8.7") and p.trusts("127.0.0.1") and p.trusts("fd12::5") and not p.trusts("11.0.0.1") and not p.trusts("203.0.113.5"), "CIDR matching")
    expect(p.trusts("::ffff:10.1.2.3"), "an IPv4-mapped peer")
    expect(client_ip("10.0.0.2", "203.0.113.5", p) == "203.0.113.5", "a trusted proxy's client")
    expect(client_ip("10.0.0.2", "6.6.6.6, 203.0.113.5, 10.0.0.9", p) == "203.0.113.5", "the rightmost untrusted hop (a spoofed left hop ignored)")
    expect(client_ip("10.0.0.2", "10.0.0.7, 10.0.0.9", p) == "10.0.0.7", "every hop trusted: the leftmost")
    expect(client_ip("10.0.0.2", "", p) == "10.0.0.2", "no header: the proxy itself")
    expect(client_ip("10.0.0.2", "junk, 203.0.113.5", p) == "203.0.113.5", "junk left of the client is never read")
    expect(client_ip("10.0.0.2", "203.0.113.5, junk", p) == "invalid", "a broken chain isn't the proxy's bucket")
    print("trusted: ok")
    expect(client_ip("203.0.113.9", "1.1.1.1", p) == "203.0.113.9", "an untrusted peer's X-Forwarded-For was believed")
    expect(client_ip("10.0.0.2", "1.1.1.1", TrustedProxies()) == "10.0.0.2", "no proxies configured: the header was believed")
    var raised = False
    try:
        _ = TrustedProxies.parse("10.0.0.0/33")
    except:
        raised = True
    expect(raised, "a bad prefix accepted")
    raised = False
    try:
        _ = TrustedProxies.parse("proxy.internal")
    except:
        raised = True
    expect(raised, "a name accepted as a proxy")
    print("untrusted: ok")
    expect(rate_key("2001:db8:1:2::1") == "2001:db8:1:2::/64" and rate_key("2001:db8:1:2:ffff:ffff:ffff:ffff") == "2001:db8:1:2::/64", "one /64, one key: " + rate_key("2001:db8:1:2::1"))
    expect(rate_key("2001:db8:1:3::1") != rate_key("2001:db8:1:2::1"), "two /64s share a key")
    expect(rate_key("::ffff:203.0.113.5") == "203.0.113.5" and rate_key("203.0.113.5") == "203.0.113.5", "IPv4 kept whole")
    print("ipv6: ok")
