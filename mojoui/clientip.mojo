# mojoui.clientip: who a request comes from, for limits and logs (goal 60 round 3, D-6019). Behind a reverse proxy
# (the TLS terminator docs/saas.md asks for) the socket's peer is the proxy: every client would share one per-IP limit,
# and anyone could lock everyone out of sign-in. So: only when the peer is a trusted proxy (CIDRs the operator names,
# SAAS_TRUSTED_PROXIES) is X-Forwarded-For read, from the right, and the first hop that isn't itself a trusted proxy
# is the client (a client can write any hops on the left; the right ones were appended by proxies we trust). From any
# other peer the header is ignored. For a limit's key, IPv6 addresses group by their /64 (one home or one server gets a
# /64: per-address keys would give a client 2^64 buckets) and IPv4-mapped IPv6 reads as IPv4.
#
#   var proxies = TrustedProxies.parse(getenv("SAAS_TRUSTED_PROXIES"))   # "10.0.0.0/8, 127.0.0.1, fd00::/8"
#   var ip = client_ip(req.peer, req.header("x-forwarded-for"), proxies) # (mojoui.serve sets req.client so)
#   var key = rate_key(ip)                                               # "203.0.113.5", "2001:db8:1:2::/64"


@fieldwise_init
struct Cidr(Copyable, Movable):
    var bytes: List[UInt8]  # 4 or 16
    var bits: Int

    def contains(self, ip: List[UInt8]) -> Bool:
        if len(ip) != len(self.bytes):
            return False
        var full = self.bits // 8
        for i in range(full):
            if ip[i] != self.bytes[i]:
                return False
        var rest = self.bits % 8
        if rest == 0:
            return True
        var mask = UInt8((0xFF << (8 - rest)) & 0xFF)
        return (ip[full] & mask) == (self.bytes[full] & mask)


struct TrustedProxies(Copyable, Movable):
    var nets: List[Cidr]

    def __init__(out self):
        self.nets = List[Cidr]()

    @staticmethod
    def parse(text: String) raises -> TrustedProxies:
        """Comma- or space-separated addresses and CIDRs ("" → none trusted); raises on one it can't read (a typo here
        would silently trust nothing, or everything)."""
        var out = TrustedProxies()
        for part in text.replace(",", " ").split(" "):
            var p = String(String(part).strip())
            if p == "":
                continue
            var slash = p.find("/")
            var addr = p if slash < 0 else String(p[byte = : slash])
            var ip = parse_ip(addr)
            if len(ip) == 0:
                raise Error("SAAS_TRUSTED_PROXIES: not an address: " + p)
            var bits = len(ip) * 8
            if slash >= 0:
                try:
                    bits = Int(atol(String(p[byte = slash + 1 :])))
                except:
                    raise Error("SAAS_TRUSTED_PROXIES: not a prefix length: " + p)
                if bits < 0 or bits > len(ip) * 8:
                    raise Error("SAAS_TRUSTED_PROXIES: not a prefix length: " + p)
            out.nets.append(Cidr(ip^, bits))
        return out^

    def trusts(self, addr: String) -> Bool:
        if len(self.nets) == 0:
            return False
        var ip = _unmapped(parse_ip(addr))
        if len(ip) == 0:
            return False
        for n in self.nets:
            if n.contains(ip):
                return True
        return False

    def any(self) -> Bool:
        return len(self.nets) > 0


def _hexval(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 87
    if c >= 65 and c <= 70:
        return Int(c) - 55
    return -1


def _ipv4(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var parts = s.split(".")
    if len(parts) != 4:
        return List[UInt8]()
    for p in parts:
        var b = p.as_bytes()
        if len(b) == 0 or len(b) > 3 or (len(b) > 1 and b[0] == 48):
            return List[UInt8]()
        var v = 0
        for c in b:
            if c < 48 or c > 57:
                return List[UInt8]()
            v = v * 10 + Int(c) - 48
        if v > 255:
            return List[UInt8]()
        out.append(UInt8(v))
    return out^


def parse_ip(text: String) -> List[UInt8]:
    """An IP literal's bytes: 4 for IPv4, 16 for IPv6 (brackets and a %zone allowed); empty when it isn't one."""
    var s = String(text.strip())
    if s.startswith("[") and s.endswith("]"):
        var inner = String(s[byte = 1 : s.byte_length() - 1])
        s = inner^
    var pct = s.find("%")
    if pct >= 0:
        var bare = String(s[byte = : pct])
        s = bare^
    if ":" not in s:
        return _ipv4(s)
    if s.byte_length() > 45:
        return List[UInt8]()
    var dbl = s.find("::")
    if dbl >= 0 and String(s[byte = dbl + 1 :]).find("::") >= 0:
        return List[UInt8]()  # (two "::")
    var head = String(s) if dbl < 0 else String(s[byte = : dbl])
    var tail = String("") if dbl < 0 else String(s[byte = dbl + 2 :])
    var words = List[Int]()
    var tail_words = List[Int]()
    for side in range(2):
        var text_side = head if side == 0 else tail
        if text_side == "":
            continue
        var groups = text_side.split(":")
        for gi in range(len(groups)):
            var g = String(groups[gi])
            var into = side
            if "." in g:  # an IPv4 tail: the last group only
                if gi != len(groups) - 1 or (side == 0 and dbl >= 0):
                    return List[UInt8]()
                var v4 = _ipv4(g)
                if len(v4) != 4:
                    return List[UInt8]()
                var w1 = Int(v4[0]) * 256 + Int(v4[1])
                var w2 = Int(v4[2]) * 256 + Int(v4[3])
                if into == 0:
                    words.append(w1)
                    words.append(w2)
                else:
                    tail_words.append(w1)
                    tail_words.append(w2)
                continue
            var gb = g.as_bytes()
            if len(gb) == 0 or len(gb) > 4:
                return List[UInt8]()
            var v = 0
            for c in gb:
                var h = _hexval(c)
                if h < 0:
                    return List[UInt8]()
                v = v * 16 + h
            if into == 0:
                words.append(v)
            else:
                tail_words.append(v)
    var n = len(words) + len(tail_words)
    if (dbl < 0 and n != 8) or (dbl >= 0 and n > 7):
        return List[UInt8]()
    var all = words.copy()
    for _ in range(8 - n):
        all.append(0)
    for w in tail_words:
        all.append(w)
    var out = List[UInt8]()
    for w in all:
        out.append(UInt8(w >> 8))
        out.append(UInt8(w & 0xFF))
    return out^


def _unmapped(ip: List[UInt8]) -> List[UInt8]:
    """::ffff:a.b.c.d → a.b.c.d (a dual-stack socket's view of an IPv4 client)."""
    if len(ip) != 16:
        return ip.copy()
    for i in range(10):
        if ip[i] != 0:
            return ip.copy()
    if ip[10] != 0xFF or ip[11] != 0xFF:
        return ip.copy()
    var out = List[UInt8]()
    for i in range(12, 16):
        out.append(ip[i])
    return out^


def format_ip(ip: List[UInt8]) -> String:
    """Bytes back to text: dotted IPv4, or IPv6's lower-case words with the longest zero run as "::" (RFC 5952)."""
    if len(ip) == 4:
        return String(Int(ip[0])) + "." + String(Int(ip[1])) + "." + String(Int(ip[2])) + "." + String(Int(ip[3]))
    if len(ip) != 16:
        return ""
    var w = List[Int]()
    for i in range(8):
        w.append(Int(ip[2 * i]) * 256 + Int(ip[2 * i + 1]))
    var best = -1
    var best_len = 0
    var i = 0
    while i < 8:
        if w[i] == 0:
            var j = i
            while j < 8 and w[j] == 0:
                j += 1
            if j - i > best_len and j - i >= 2:
                best = i
                best_len = j - i
            i = j
        else:
            i += 1
    var out = String("")
    i = 0
    while i < 8:
        if i == best:
            out += "::"
            i += best_len
            continue
        if out != "" and not out.endswith(":"):
            out += ":"
        out += _hex_word(w[i])
        i += 1
    return out^


def _hex_word(v: Int) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("")
    var started = False
    for shift in [12, 8, 4, 0]:
        var d = (v >> shift) & 0xF
        if d != 0 or started or shift == 0:
            out += digits[byte = d]
            started = True
    return out^


def client_ip(peer: String, forwarded: String, proxies: TrustedProxies) -> String:
    """The client's address: the peer, unless the peer is a trusted proxy; then X-Forwarded-For's rightmost hop that
    isn't one (all trusted: the leftmost). A hop that isn't an IP literal stops the walk: a broken proxy chain, keyed
    as "invalid" (never as the proxy itself, which would put everyone in one bucket again)."""
    if not proxies.any() or not proxies.trusts(peer) or forwarded == "":
        return peer
    var hops = forwarded.split(",")
    var i = len(hops) - 1
    var last = peer
    while i >= 0:
        var h = String(String(hops[i]).strip())
        var ip = parse_ip(h)
        if len(ip) == 0:
            return "invalid"
        last = format_ip(_unmapped(ip))
        if not proxies.trusts(last):
            return last
        i -= 1
    return last


def rate_key(ip: String) -> String:
    """A per-client limit's key: IPv4 as it is, IPv6 by its /64 ("2001:db8:1:2::/64"), anything else as given."""
    var b = _unmapped(parse_ip(ip))
    if len(b) == 4:
        return format_ip(b)
    if len(b) != 16:
        return ip
    var net = List[UInt8]()
    for i in range(16):
        net.append(b[i] if i < 8 else UInt8(0))
    return format_ip(net) + "/64"
