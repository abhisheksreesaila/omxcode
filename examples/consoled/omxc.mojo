# omxc: omxconsole's tools for agents (D-6502). One command per thing the console does (search, pull, serve, port,
# keys, notebooks), each one call to the running daemon's admin API, its JSON reply printed as it is. A thin
# pass-through, not another CLI on top of MAX: everything it can do, the console's screens do through the same routes,
# so an agent (Claude Code, a script) and the person at the screen see one state.
#
#   scripts/mojo_flare.sh build -I examples/consoled examples/consoled/omxc.mojo -o build/omxc
#
# Exit codes: 0 done; 1 the daemon said no, a pull or port --wait ended other than done, or the daemon was too slow
# (the JSON says which); 2 a usage mistake (on stderr); 3 no daemon answering.
# Environment: MXC_PORT (default 11435), MXC_ADMIN_KEY (default "1", as the daemon's).

from std.sys import argv, exit, stderr
from std.os import getenv
from std.time import sleep
from mojoui.http import Request, uri_component
from mojoui.http_socket import SocketTransport
from mojoui.json import Json, json_string

comptime HELP = """omxc: omxconsole's tools for agents. Each command is one call to the running omxconsole daemon;
it prints the daemon's JSON reply on stdout. Exit codes: 0 done; 1 refused, failed or too slow (the JSON says which);
2 usage (on stderr); 3 no daemon.

Find and get models
  omxc search <text>                  models to try (curated, MAX's catalog, Hugging Face), sized for this machine's GPU
  omxc pull <owner/name|hf url> [--name <name>] [--wait]
                                      download and register a model (it checks MAX supports the architecture first);
                                      --wait answers when it has ended, exit 0 only when it is done
  omxc pulls                          recent downloads;   omxc pull-status <id>;   omxc pull-cancel <id>
  omxc remove <model>                 unregister a model (and delete files a pull downloaded)

Run models
  omxc models                         registered models and whether each is loaded
  omxc serve <model>                  start it on MAX; answers once it serves (the first load can take minutes)
  omxc stop <model>                   unload it
  omxc chat <model> <text>            one short reply, as the console's Try box sends it
  omxc log <model>                    the end of its max serve log
  omxc endpoint                       the OpenAI-compatible base URL apps use, and how they authenticate
  omxc status                         the daemon, the GPU and what is loaded

Apps and keys (apps call <endpoint> with "Authorization: Bearer <key>")
  omxc keys                           every app's key (hashes only)
  omxc keys create <app>              a new key; printed once, store it
  omxc keys rotate <app>              replace it (the old one stops working)
  omxc keys delete <app>              revoke it

Port a model MAX can't run yet (beta; uses Claude Code)
  omxc port <owner/name> [--attempts <1-5>] [--wait]
  omxc ports;   omxc port-status <id>;   omxc port-cancel <id>

Learn
  omxc notebook <model>               start Jupyter on the model's notebook; prints its link (url) and file (path)

Anything else
  omxc call <METHOD> <path> [json]    any admin route, e.g. omxc call GET /admin/system
"""


def daemon() -> String:
    return "http://127.0.0.1:" + getenv("MXC_PORT", "11435")


def call(method: String, path: String, body: String = "", timeout_ms: Int = 60_000) -> Tuple[Int, String]:
    var r = Request(0, method, daemon() + path, body).header("x-mst-admin", getenv("MXC_ADMIN_KEY", "1"))
    if body != "":
        r = r^.header("Content-Type", "application/json")
    var res = SocketTransport.send(r^.timeout(timeout_ms))
    if res.error.startswith("timed out") and not res.error.startswith("timed out after " + String(timeout_ms) + " ms connecting"):
        print('{"error": {"message": ' + json_string("omxconsole is running but did not answer in time (" + res.error
              + "). It may still finish: ask again with the matching status command.") + ', "code": "daemon_timeout"}}')
        exit(1)
    if res.error != "":
        print('{"error": {"message": ' + json_string("omxconsole is not running on " + daemon() + " (" + res.error
              + "). Start the omxconsole app, or set MXC_PORT to its port.") + ', "code": "daemon_unreachable"}}')
        exit(3)
    return (res.status, res.text())


def done(reply: Tuple[Int, String]):
    print(reply[1])
    if reply[0] < 200 or reply[0] >= 300:
        exit(1)


def usage(why: String):
    print("omxc: " + why + "\nRun `omxc help` for the commands.", file=stderr)
    exit(2)


def flag_value(args: List[String], name: String) -> String:
    for k in range(len(args) - 1):
        if args[k] == name:
            return args[k + 1]
    return ""


def has(args: List[String], name: String) -> Bool:
    for a in args:
        if a == name:
            return True
    return False


def wait_for(path: String, first: Tuple[Int, String]) raises:
    """--wait: poll the pull or port every 2 s until it no longer runs, then print it (stdout stays one JSON reply)."""
    if first[0] < 200 or first[0] >= 300:
        done(first)
    var id = String("")
    try:
        var j = Json.parse(first[1])
        id = String(j.number(j.get(0, "id")))
    except:
        done(first)  # (not the JSON a started job answers with: printed as it came)
        exit(1)
    while True:
        var r = call("GET", path + "/" + id)
        var status = String("")
        try:
            var now = Json.parse(r[1])
            status = now.text(now.get(0, "status"))
        except:
            pass
        if r[0] != 200 or (status != "running" and status != "queued"):
            done(r)
            if status != "done":
                exit(1)  # (failed or cancelled: the reply says why)
            return
        sleep(2.0)


def need(n: Int, count: Int, shape: String):
    if n < count:
        usage("usage: omxc " + shape)


def main() raises:
    var a = List[String]()
    for k in range(1, len(argv())):
        a.append(String(argv()[k]))
    if len(a) == 0 or a[0] == "help" or a[0] == "--help" or a[0] == "-h":
        print(HELP)
        return
    var cmd = a[0]
    var n = len(a)

    if cmd == "status":
        done(call("GET", "/admin/status"))
    elif cmd == "models":
        done(call("GET", "/admin/models"))
    elif cmd == "endpoint":
        done(call("GET", "/admin/info"))
    elif cmd == "search":
        need(n, 2, "search <text>")
        var q = String("")
        for k in range(1, n):
            q += (" " if k > 1 else "") + a[k]
        done(call("GET", "/admin/search?q=" + uri_component(q), timeout_ms=120_000))
    elif cmd == "pull":
        need(n, 2, "pull <owner/name|hf url> [--name <name>] [--wait]")
        var body = '{"ref": ' + json_string(a[1])
        if flag_value(a, "--name") != "":
            body += ', "name": ' + json_string(flag_value(a, "--name"))
        var r = call("POST", "/admin/pulls", body + "}")
        if has(a, "--wait"):
            wait_for("/admin/pulls", r)
        else:
            done(r)
    elif cmd == "pulls":
        done(call("GET", "/admin/pulls"))
    elif cmd == "pull-status":
        need(n, 2, "pull-status <id>")
        done(call("GET", "/admin/pulls/" + uri_component(a[1])))
    elif cmd == "pull-cancel":
        need(n, 2, "pull-cancel <id>")
        done(call("POST", "/admin/pulls/" + uri_component(a[1]) + "/cancel"))
    elif cmd == "remove":
        need(n, 2, "remove <model>")
        done(call("DELETE", "/admin/models/" + uri_component(a[1])))
    elif cmd == "serve":
        need(n, 2, "serve <model>")
        done(call("POST", "/admin/models/" + uri_component(a[1]) + "/load", timeout_ms=660_000))
    elif cmd == "stop":
        need(n, 2, "stop <model>")
        done(call("POST", "/admin/models/" + uri_component(a[1]) + "/stop"))
    elif cmd == "chat":
        need(n, 3, "chat <model> <text>")
        var text = String("")
        for k in range(2, n):
            text += (" " if k > 2 else "") + a[k]
        var body = '{"model": ' + json_string(a[1]) + ', "messages": [{"role": "user", "content": ' + json_string(text) + "}]}"
        done(call("POST", "/admin/try/chat", body, timeout_ms=660_000))
    elif cmd == "log":
        need(n, 2, "log <model>")
        done(call("GET", "/admin/models/" + uri_component(a[1]) + "/log"))
    elif cmd == "keys":
        if n == 1:
            done(call("GET", "/admin/keys"))
        else:
            need(n, 3, "keys create|rotate|delete <app>")
            if a[1] == "create":
                done(call("POST", "/admin/keys", '{"app": ' + json_string(a[2]) + "}"))
            elif a[1] == "rotate":
                done(call("POST", "/admin/keys/" + uri_component(a[2]) + "/rotate"))
            elif a[1] == "delete":
                done(call("DELETE", "/admin/keys/" + uri_component(a[2])))
            else:
                usage("keys takes create, rotate or delete, not `" + a[1] + "`")
    elif cmd == "port":
        need(n, 2, "port <owner/name> [--attempts <1-5>] [--wait]")
        var body = '{"ref": ' + json_string(a[1])
        var tries = flag_value(a, "--attempts")
        if tries != "":
            try:
                body += ', "max_attempts": ' + String(atol(tries))
            except:
                usage("--attempts takes a whole number from 1 to 5")
        var r = call("POST", "/admin/ports", body + "}")
        if has(a, "--wait"):
            wait_for("/admin/ports", r)
        else:
            done(r)
    elif cmd == "ports":
        done(call("GET", "/admin/ports"))
    elif cmd == "port-status":
        need(n, 2, "port-status <id>")
        done(call("GET", "/admin/ports/" + uri_component(a[1])))
    elif cmd == "port-cancel":
        need(n, 2, "port-cancel <id>")
        done(call("POST", "/admin/ports/" + uri_component(a[1]) + "/cancel"))
    elif cmd == "notebook":
        need(n, 2, "notebook <model>")
        done(call("POST", "/admin/learn/" + uri_component(a[1]) + "/open", timeout_ms=320_000))
    elif cmd == "call":
        need(n, 3, "call <METHOD> <path> [json]")
        if not a[2].startswith("/admin/"):
            usage("call reaches the admin routes only: the path starts with /admin/")
        done(call(a[1].upper(), a[2], a[3] if n > 3 else String(""), timeout_ms=660_000))
    else:
        usage("no command `" + cmd + "`")
