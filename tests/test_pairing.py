"""The web host's pairing rules (goal 72 M5, mojoui/hosts/pairing.py): who may reach it from another device.

    pixi run python tests/test_pairing.py          # prints "pairing: ok"

Drives the ASGI middleware directly (no server): each case is a request's Host, Origin, peer, proxy headers, key.
"""

import asyncio
import os
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "mojoui" / "hosts"))
import pairing  # noqa: E402

KEY = "k3y-for-the-test-0123"
HOSTS = {"localhost", "127.0.0.1", "[::1]", "ablearn.tail53f36c.ts.net"}


async def inner(scope, receive, send):
    if scope["type"] == "websocket":
        return await send({"type": "websocket.accept"})
    await send({"type": "http.response.start", "status": 200, "headers": []})
    await send({"type": "http.response.body", "body": b"inside"})


def ask(kind="http", host="127.0.0.1:5001", peer="127.0.0.1", origin=None, query=b"", cookie=None, proxy=False, path="/", https=False):
    headers = [(b"host", host.encode())]
    if origin:
        headers.append((b"origin", origin.encode()))
    if cookie:
        headers.append((b"cookie", cookie.encode()))
    if proxy:
        headers.append((b"x-forwarded-for", b"100.64.0.9"))
    if https:
        headers.append((b"x-forwarded-proto", b"https"))
    scope = {"type": kind, "method": "GET", "path": path, "query_string": query, "headers": headers, "client": (peer, 40000), "scheme": "http"}
    sent = []

    async def receive():
        return {"type": "http.request", "body": b""}

    async def send(m):
        sent.append(m)

    app = pairing.Pairing(inner, hosts=lambda: HOSTS, key=KEY)
    asyncio.run(app(scope, receive, send))
    first = sent[0]
    if kind == "websocket":
        return first["type"], first.get("code"), None
    heads = {k: v for k, v in first["headers"]}
    return first["type"], first["status"], heads


def main():
    # this machine, no proxy: no key needed
    assert ask()[1] == 200
    assert ask(host="localhost:5001", origin="http://localhost:5001")[1] == 200
    assert ask(kind="websocket")[:2] == ("websocket.accept", None)
    # a host name that isn't ours is refused even from here (DNS rebinding)
    assert ask(host="evil.example:5001")[1] == 403
    # a page on another site (its Origin is not the Host) is refused even from here
    assert ask(origin="http://evil.example")[1] == 403
    # D-7251: "Origin: null" (a sandboxed iframe, a file:// page) is a foreign page, even from loopback with no key: the page
    # and the audio socket are both refused
    assert ask(origin="null")[1] == 403
    assert ask(kind="websocket", origin="null")[:2] == ("websocket.close", 1008)
    assert ask(kind="websocket", origin="null", path="/audio")[:2] == ("websocket.close", 1008)
    # D-7251: the redirect after the key goes to a relative path on this host, never "//evil.example/"
    _, status, heads = ask(host="ablearn.tail53f36c.ts.net:8444", proxy=True, query=("k=" + KEY).encode(), path="//evil.example/x")
    assert status == 303 and heads[b"location"] == b"/evil.example/x"
    # behind `tailscale serve`: the peer is loopback but a proxy header is on the request, so nobody is local
    behind = dict(host="ablearn.tail53f36c.ts.net:8444", proxy=True)
    assert ask(**behind)[1] == 403  # no key
    assert ask(**behind, query=b"k=wrong")[1] == 403
    assert ask(**behind, cookie="mojoui_pair=wrong")[1] == 403
    # a socket without the key is refused before it is accepted
    assert ask(kind="websocket", **behind)[:2] == ("websocket.close", 1008)
    # the first visit with the key: a cookie (Secure over https), and a redirect without ?k=
    kind, status, heads = ask(**behind, query=("k=" + KEY + "&boot=1").encode(), path="/x")
    assert status == 303 and heads[b"location"] == b"/x?boot=1"
    cookie = heads[b"set-cookie"].decode()
    assert cookie.startswith("mojoui_pair=" + KEY + ";") and "HttpOnly" in cookie and "SameSite=Strict" in cookie
    assert "Secure" not in cookie
    _, _, heads = ask(**behind, query=("k=" + KEY).encode(), https=True)
    assert b"; Secure" in heads[b"set-cookie"]  # (tailscale serve says x-forwarded-proto: https)
    # with the cookie, pages and the socket go through, under the tailnet name; its own origin only
    ok = dict(host="ablearn.tail53f36c.ts.net:8444", proxy=True, cookie="mojoui_pair=" + KEY)
    assert ask(**ok)[1] == 200
    assert ask(**ok, origin="https://ablearn.tail53f36c.ts.net:8444")[1] == 200
    assert ask(kind="websocket", **ok)[:2] == ("websocket.accept", None)
    assert ask(**ok, origin="https://evil.example")[1] == 403
    # MOJOUI_BEHIND_PROXY=1 (scripts/tablet.sh sets it): a proxy that adds no header still makes every caller need the key
    os.environ["MOJOUI_BEHIND_PROXY"] = "1"
    try:
        assert ask(host="ablearn.tail53f36c.ts.net:8444")[1] == 403
        assert ask(host="ablearn.tail53f36c.ts.net:8444", cookie="mojoui_pair=" + KEY)[1] == 200
    finally:
        del os.environ["MOJOUI_BEHIND_PROXY"]
    # a peer that isn't loopback (the host was bound wide by mistake) needs the key too
    assert ask(peer="192.168.1.50")[1] == 403
    assert ask(peer="192.168.1.50", cookie="mojoui_pair=" + KEY)[1] == 200

    # the key file: made once, mode 0600, the same on every read
    with tempfile.TemporaryDirectory() as d:
        os.environ["MOJOUI_PAIR_KEY_FILE"] = str(Path(d) / "state" / "pair-key")
        k1 = pairing.pair_key()
        assert len(k1) == 24 and pairing.pair_key() == k1
        assert stat.S_IMODE(os.stat(os.environ["MOJOUI_PAIR_KEY_FILE"]).st_mode) == 0o600
    # extra host names come from the environment
    os.environ["MOJOUI_EXTRA_HOSTS"] = "Ablearn.Tail53f36c.ts.net, other.ts.net"
    assert {"ablearn.tail53f36c.ts.net", "other.ts.net"} <= pairing.allowed_hosts()
    print("pairing: ok")


if __name__ == "__main__":
    main()
