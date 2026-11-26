"""Who may use the web host from another device (goal 72 M5, docs/web-audio.md).

The web host binds this machine's loopback, so on its own only this machine can reach it. A tablet reaches it through a
reverse proxy on the same machine (`tailscale serve`: https://<machine>.<tailnet>.ts.net:<port> -> http://127.0.0.1:<port>),
which makes every caller look local. So a request from anything but "this machine's loopback, with no proxy in between" must
carry the pairing key, and every request, local or not, must name an allowed host and come from the page's own origin:

  * Host: one of this machine's names (localhost, 127.0.0.1, [::1], its host name, its addresses) or one added with
    $MOJOUI_EXTRA_HOSTS (comma separated: the tailnet name). Anything else is refused (DNS rebinding, a stray proxy).
  * Origin (when the browser sends one): the same as Host. A page on another site can't use the host from a visitor's browser.
  * Key: the first visit is https://<name>/?k=<key>; the host sets a cookie (HttpOnly, SameSite=Strict, Secure over https) and
    redirects to the same address without the key, so it isn't left in the address bar. Pages, events and the audio socket
    all carry the cookie.

The key is made once and kept in the user's state folder with mode 0600 ($MOJOUI_PAIR_KEY_FILE, else
$XDG_STATE_HOME/mojoui/pair-key); `python web.py --pair-key` prints it (scripts/tablet.sh does). Not used by the public copy
(MOJOUI_PUBLIC=1), which has its own rules.
"""

import hmac
import ipaddress
import os
import secrets
import socket
import subprocess
import time
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit

COOKIE = "mojoui_pair"
LOOPBACK_PEERS = {"127.0.0.1", "::1"}
PROXY_HEADERS = (b"x-forwarded-for", b"x-forwarded-host", b"x-forwarded-proto", b"x-forwarded-port", b"forwarded", b"x-real-ip",
                 b"x-original-host", b"tailscale-user-login", b"tailscale-user-name")


def key_file():
    override = os.environ.get("MOJOUI_PAIR_KEY_FILE")
    if override:
        return Path(override)
    state = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(state) / "mojoui" / "pair-key"


def pair_key():
    """The pairing key: made once (url-safe, 24 characters), kept at mode 0600."""
    path = key_file()
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)  # (never readable by anyone else, not even for a moment)
        try:
            os.write(fd, secrets.token_urlsafe(18).encode())
        finally:
            os.close(fd)
    return path.read_text().strip()


def allowed_hosts():
    """The names a browser may use to reach this host (re-read now and then: an address can change)."""
    me = socket.gethostname().lower()
    names = {"localhost", "127.0.0.1", "[::1]", "0.0.0.0", me, f"{me}.local"}
    try:
        out = subprocess.run(["ip", "-o", "addr", "show", "up"], capture_output=True, text=True, timeout=2).stdout
        for line in out.splitlines():
            parts = line.split()
            if len(parts) > 3 and parts[2] in ("inet", "inet6"):
                addr = parts[3].split("/")[0].lower()
                names.add(f"[{addr}]" if parts[2] == "inet6" else addr)
    except (OSError, subprocess.SubprocessError):
        pass
    return names | {h.strip().lower() for h in os.environ.get("MOJOUI_EXTRA_HOSTS", "").split(",") if h.strip()}


def host_name(host):
    """A Host header without its port."""
    host = host.lower()
    return host.split("]")[0] + "]" if host.startswith("[") else host.rsplit(":", 1)[0] if ":" in host else host


def admit(origin, host, peer, key_given, key, hosts, forwarded=False):
    """Whether this request may go on. `hosts`: the allowed names; `forwarded`: a proxy's headers are on it, so the peer is
    the proxy, not the caller."""
    if host_name(host) not in hosts:
        return False
    if origin and (origin == "null" or urlsplit(origin).netloc.lower() != host.lower()):
        return False  # ("null" is a sandboxed iframe or a file:// page: a foreign page, never ours)
    local = peer in LOOPBACK_PEERS and not forwarded
    if local:
        return True
    return bool(key_given) and hmac.compare_digest(key_given.encode(), key.encode())


def _cookies(raw):
    out = {}
    for part in raw.split(";"):
        name, _, value = part.strip().partition("=")
        if name:
            out[name] = value
    return out


class Pairing:
    """ASGI middleware: refuses (403, or a closed socket) what admit() refuses; a first visit with ?k= sets the cookie and
    redirects to the address without it."""

    def __init__(self, app, hosts=allowed_hosts, key=None):
        self.app = app
        self.hosts = hosts
        self.key = key or pair_key()
        self._cache = (0.0, set())

    def _hosts(self):
        t, names = self._cache
        if time.monotonic() - t > 5:
            names = self.hosts()
            self._cache = (time.monotonic(), names)
        return names

    async def __call__(self, scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            return await self.app(scope, receive, send)
        headers = {k: v for k, v in scope["headers"]}
        host = headers.get(b"host", b"").decode("latin-1")
        origin = headers.get(b"origin", b"").decode("latin-1")
        peer = (scope.get("client") or ("", 0))[0]
        forwarded = any(h in headers for h in PROXY_HEADERS) or os.environ.get("MOJOUI_BEHIND_PROXY") == "1"
        query = dict(parse_qsl(scope.get("query_string", b"").decode("latin-1")))
        given = query.get("k") or _cookies(headers.get(b"cookie", b"").decode("latin-1")).get(COOKIE, "")
        if not admit(origin, host, peer, given, self.key, self._hosts(), forwarded):
            if scope["type"] == "websocket":
                return await send({"type": "websocket.close", "code": 1008})
            body = b"pair this device: open the address with its ?k= key"
            await send({"type": "http.response.start", "status": 403, "headers": [(b"content-type", b"text/plain"), (b"cache-control", b"no-store")]})
            return await send({"type": "http.response.body", "body": body})
        if scope["type"] == "http" and scope["method"] == "GET" and query.get("k") and hmac.compare_digest(query["k"].encode(), self.key.encode()):
            https = headers.get(b"x-forwarded-proto", b"").decode() == "https" or scope.get("scheme") == "https"
            rest = urlencode([(k, v) for k, v in parse_qsl(scope.get("query_string", b"").decode("latin-1")) if k != "k"])
            where = "/" + scope["path"].lstrip("//\\") + ("?" + rest if rest else "")
            cookie = f"{COOKIE}={self.key}; Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000" + ("; Secure" if https else "")
            await send({"type": "http.response.start", "status": 303,
                        "headers": [(b"location", where.encode()), (b"set-cookie", cookie.encode()), (b"cache-control", b"no-store")]})
            return await send({"type": "http.response.body", "body": b""})
        await self.app(scope, receive, send)
