# consoled's LAN endpoint (goal 64 M4; the Python daemon's expose.py, same Caddyfile and the same request path,
# D-6401): client → Caddy (tls internal, forward_auth → the daemon's /auth/check) → daemon → max serve. The daemon
# checks the app key again and routes by `model`. Caddy forwards only the OpenAI routes, so an app key never reaches
# the daemon's loopback-only admin pages, and a path that cleaning would change is refused before it is proxied.
# Caddy isn't ours to bundle: it is found on PATH (or EXPOSE_CADDY_CMD), and when it is missing the answer says so
# with how to install it. Localhost keeps working over plain HTTP whatever this does.

from std.os import makedirs, getenv
from std.os.path import exists
from mojoui.json import json_string
from mojoui.process import Process, file_tail
from mojoui.workbook import read_text, write_text
from mojoui.clock import now_ns
from mojoui import libc
from sandbox import which
from sysinfo import hostname

comptime EXPOSE_PORT = 8443
comptime CADDY_ADMIN = "127.0.0.1:2099"
comptime API_PATHS = ["/v1/models", "/v1/chat/completions", "/v1/completions", "/v1/embeddings"]
comptime SETTLE_MS = 1000  # Caddy is watched this long: a bad config exits at once and the caller hears why
comptime NO_CADDY = ("Caddy was not found, and omxconsole does not bundle it. Install Caddy (Arch: `sudo pacman -S caddy`; "
                     + "Debian/Ubuntu: `sudo apt install caddy`; macOS: `brew install caddy`; or caddyserver.com/download), "
                     + "then try again.")
comptime BETA_NOTE = "beta: HTTPS on your own network with a certificate your machines must trust once"


def hostname_ok(h: String) -> Bool:
    """expose.py's HOSTNAME: a hostname or an IP address, nothing that could end the site block."""
    if h.byte_length() == 0 or h.byte_length() > 253:
        return False
    if h.startswith("[") and h.endswith("]"):  # a literal IPv6 address
        for b in String(h[byte = 1 : h.byte_length() - 1]).as_bytes():
            var c = Int(b)
            var hex = (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
            if not (hex or c == 58):
                return False
        return True
    var bytes = h.as_bytes()
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        var alnum = (c >= 48 and c <= 57) or (c >= 97 and c <= 122) or (c >= 65 and c <= 90)
        if not (alnum or ((c == 46 or c == 45) and i > 0 and i < len(bytes) - 1)):
            return False
    return True


def render_caddyfile(hosts: List[String], port: Int) raises -> String:
    """The Caddyfile (expose.py render_caddyfile, kept as it is): `tls internal` for a certificate Caddy signs
    itself, the key check as forward_auth to the daemon, only the OpenAI routes forwarded, and anything whose path
    cleaning would change refused — `/anthropic/../v1/models` must not reach the daemon."""
    var sites = String("")
    for h in hosts:
        if not hostname_ok(h):
            raise Error(json_string(h) + " is not a hostname or IP address")
        sites += (", " if sites != "" else "") + "https://" + h + ":" + String(port)
    var unclean = String("")
    for s in ["/.", "//", "\\\\"]:
        unclean += (" || " if unclean != "" else "") + '{http.request.orig_uri.path}.contains("' + String(s) + '")'
    unclean += ' || {http.request.orig_uri}.contains("%")'
    var api = String("")
    for p in materialize[API_PATHS]():
        api += (" " if api != "" else "") + String(p)
    return ("{\n\tadmin " + CADDY_ADMIN + "\n\tskip_install_trust\n\tauto_https disable_redirects\n}\n\n"
            + sites + " {\n\ttls internal\n"
            + "\t# reverse_proxy forwards the raw path while `path` matches the cleaned one, so refuse any\n"
            + "\t# path that cleaning would change: /anthropic/../v1/models must not reach the daemon.\n"
            + "\t@unclean expression `" + unclean + "`\n\thandle @unclean {\n\t\trespond 400\n\t}\n"
            + "\t@api path " + api + "\n\thandle @api {\n\t\tforward_auth 127.0.0.1:" + String(_daemon_port())
            + " {\n\t\t\turi /auth/check\n\t\t\tcopy_headers X-Mst-App\n\t\t}\n\t\treverse_proxy 127.0.0.1:"
            + String(_daemon_port()) + "\n\t}\n\thandle {\n\t\trespond 404\n\t}\n}\n")


def _daemon_port() raises -> Int:
    return Int(atol(getenv("MXC_PORT", "11435")))


def expose_dir(home: String) raises -> String:
    var path = home + "/expose"
    makedirs(path, exist_ok=True)
    return path^


def start_time(pid: Int) -> String:
    """Kernel start time of a live (non-zombie) process; tells our process from a reused pid."""
    var text = file_tail("/proc/" + String(pid) + "/stat", 4000)
    var at = text.rfind(")")
    if at < 0:
        return ""
    var fields = String(text[byte = at + 1 :]).split()
    if len(fields) < 21 or String(fields[0]) == "Z":
        return ""
    return String(fields[20])


def running_pid(home: String) -> Int:
    """The Caddy we started, or 0 (a pid file whose process is gone, or reused, counts as nothing)."""
    try:
        var text = read_text(home + "/expose/caddy.pid")
        var parts = text.split()
        if len(parts) < 2:
            return 0
        var pid = Int(atol(String(parts[0])))
        return pid if start_time(pid) == String(parts[1]) else 0
    except:
        return 0


def exposed(home: String) -> Bool:
    return running_pid(home) > 0


def lan_endpoint(home: String) -> String:
    """The https endpoint on the LAN while Caddy runs, else ""."""
    if not exposed(home):
        return ""
    try:
        return "https://" + String(read_text(home + "/expose/host").strip()) + ":" + String(EXPOSE_PORT) + "/v1"
    except:
        return ""


def default_host() -> String:
    return hostname() + ".local"


def caddy_argv(caddyfile: String) raises -> List[String]:
    """How Caddy is run (EXPOSE_CADDY_CMD replaces it, which is how the checks drive a stand-in)."""
    var override = getenv("EXPOSE_CADDY_CMD")
    if override != "":
        var argv = List[String]()
        for part in override.split(" "):
            if String(part) != "":
                argv.append(String(part))
        argv += ["--config", caddyfile]
        return argv^
    var caddy = which("caddy")
    if caddy == "":
        raise Error(NO_CADDY)
    return [caddy, "run", "--adapter", "caddyfile", "--config", caddyfile]


struct Exposing(Movable):
    """The Caddy this daemon started (at most one). It stops when the daemon stops: a LAN endpoint nobody is
    watching should not outlive the app that opened it (D-6409); the pid file lets a restarted daemon stop a
    leftover from a crash."""
    var child: List[Process]

    def __init__(out self):
        self.child = List[Process]()

    def stop(mut self, home: String) raises -> Bool:
        var stopped = False
        if len(self.child) > 0:
            _ = self.child[0].stop(10_000)
            _ = self.child.pop(0)
            stopped = True
        var pid = running_pid(home)
        if pid > 0:  # a leftover from an earlier daemon (its whole group, as expose.py did)
            _ = libc.kill(-pid, 15)
            var until = now_ns() + 10_000_000_000
            while now_ns() < until and start_time(pid) != "":
                _ = libc.poll(0, 0, 50)
            if start_time(pid) != "":
                _ = libc.kill(-pid, 9)
            stopped = True
        _ = libc.unlink(home + "/expose/caddy.pid")
        return stopped

    def start(mut self, home: String, host: String) raises -> String:
        """Write the Caddyfile and (re)start Caddy. Returns "" when it is up, else why it is not."""
        _ = self.stop(home)
        var dir = expose_dir(home)
        var hosts: List[String] = [host]
        if host != "localhost":
            hosts.append("localhost")
        var caddyfile = dir + "/Caddyfile"
        write_text(caddyfile, render_caddyfile(hosts, EXPOSE_PORT))
        write_text(dir + "/host", host)
        var log = dir + "/caddy.log"
        # Only what Caddy needs: no key in the daemon's environment belongs in a LAN-facing process.
        var env: List[String] = ["MXC_API_KEY=", "ANTHROPIC_API_KEY=", "HF_TOKEN=", "OPENAI_API_KEY="]
        var p = Process.start(caddy_argv(caddyfile), log, env)
        write_text(dir + "/caddy.pid", String(p.pid) + " " + start_time(p.pid))
        var until = now_ns() + SETTLE_MS * 1_000_000
        while now_ns() < until:
            if not p.running():
                var tail = String(file_tail(log, 600).strip())
                _ = libc.unlink(dir + "/caddy.pid")
                return "Caddy exited with code " + String(p.exit_code()) + ". Last log lines (" + log + "):\n" + tail
            _ = libc.poll(0, 0, 50)
        self.child.append(p^)
        return ""
