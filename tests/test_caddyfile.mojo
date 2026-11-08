# Goal 64 M4: the Caddyfile omxconsole writes for the LAN endpoint (examples/consoled/expose.mojo). The same file
# the Python version wrote: `tls internal`, the key check as forward_auth to the daemon's /auth/check, only the
# OpenAI routes forwarded, a path that cleaning would change refused, everything else 404. Offline.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_caddyfile.mojo -o build/test_caddyfile
from expose import render_caddyfile, hostname_ok, EXPOSE_PORT


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    var text = render_caddyfile(["box.local", "localhost"], EXPOSE_PORT)
    for want in ["https://box.local:8443, https://localhost:8443 {", "tls internal", "skip_install_trust",
                 "auto_https disable_redirects", "admin 127.0.0.1:2099", "uri /auth/check", "copy_headers X-Mst-App",
                 "forward_auth 127.0.0.1:", "reverse_proxy 127.0.0.1:", "@api path /v1/models /v1/chat/completions /v1/completions /v1/embeddings",
                 "respond 400", "respond 404", '{http.request.orig_uri.path}.contains("/.")',
                 '{http.request.orig_uri.path}.contains("//")', '{http.request.orig_uri}.contains("%")']:
        check(text.find(String(want)) >= 0, "the Caddyfile is missing " + String(want) + ":\n" + text)
    # the admin routes are never forwarded: only the four API paths are
    check(text.find("/admin") < 0, "no admin route may be forwarded:\n" + text)
    check(hostname_ok("box.local") and hostname_ok("192.168.1.9") and hostname_ok("[fe80::1]"), "plain hosts")
    for bad in ["box.local } respond 200", "a b", "", "-box", "box-", "host\n{"]:
        check(not hostname_ok(String(bad)), "must be refused: " + String(bad))
    var raised = False
    try:
        _ = render_caddyfile(["box.local } respond 200 {"], 8443)
    except:
        raised = True
    check(raised, "a host that could end the site block is refused")
    print("caddyfile: ok")
