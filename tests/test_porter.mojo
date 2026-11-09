# Goal 64 M0: the porting assistant setting (examples/consoled/porter.mojo). The key is stored for omxconsole only,
# mode 0600, never shown in full, never in a URL, and removable; frontier models only. Offline (no key is tested
# here: docs/goals/64-check.py does that against a stand-in server).
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_porter.mojo -o build/test_porter
from std.os import makedirs
from std.os.path import exists
from mojoui.process import output
from porter import Porter, read_porter, write_porter, remove_porter, porter_env, kind_problem, porter_json, path_of, port_preflight


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def joined(items: List[String]) -> String:
    var out = String("")
    for i in items:
        out += (" " if out != "" else "") + i
    return out^


def main() raises:
    var home = String("build/g64/portertest")
    makedirs(home, exist_ok=True)
    _ = remove_porter(home)
    check(not read_porter(home).configured(), "nothing is set up to begin with")
    check(porter_json(home).find('"configured": false') >= 0, "the view says so: " + porter_json(home))

    # an Anthropic key: stored 0600, only its prefix ever answered
    var key = String("sk-ant-api03-notarealkey-0123456789")
    write_porter(home, Porter("anthropic", "", key, ""))
    var mode = String(output(["stat", "-c", "%a", path_of(home)], 5000).strip())
    check(mode == "600", "the key file's mode must be 600, was " + mode)
    var p = read_porter(home)
    check(p.kind == "anthropic" and p.key == key, "it reads back")
    check(p.prefix() == "sk-ant-a… (35 characters)", "the prefix shown: " + p.prefix())
    var view = porter_json(home)
    check(view.find(key) < 0, "the key must never be in the view: " + view)
    check(view.find('"has_key": true') >= 0 and view.find("sk-ant-a…") >= 0, "the view says a key is there: " + view)

    # it reaches the agent as environment variables, never on a command line
    check(joined(porter_env(p)) == "ANTHROPIC_API_KEY=" + key, "anthropic env: " + joined(porter_env(p)))
    var gw = Porter("openai-compatible", "https://gw.example/v1", "sk-xyz-0123456789", "big-model")
    var env = joined(porter_env(gw))
    for want in ["ANTHROPIC_BASE_URL=https://gw.example/v1", "ANTHROPIC_AUTH_TOKEN=sk-xyz-0123456789", "ANTHROPIC_MODEL=big-model"]:
        check(env.find(String(want)) >= 0, "gateway env is missing " + String(want) + ": " + env)
    check(joined(porter_env(Porter("claude-code", "", "", ""))) == "", "Claude Code's own login needs no key")

    # what is refused
    check(kind_problem("local-model", "", "") != "", "only the three kinds are taken")
    check(kind_problem("anthropic", "", "short") != "", "a key that short isn't one")
    check(kind_problem("anthropic", "", key) == "", "a plausible key goes through")
    check(kind_problem("openai-compatible", "http://gw.example/v1", key) != "", "plain http off this machine is refused")
    check(kind_problem("openai-compatible", "https://user:pw@gw.example", key) != "", "no key in the URL")
    check(kind_problem("openai-compatible", "https://gw.example/v1?key=" + key, key) != "", "no key in the query either")
    check(kind_problem("openai-compatible", "https://gw.example/v1", key) == "", "a plain https base URL goes through")
    check(kind_problem("anthropic", "", "sk ant with a space in it") != "", "a key is one line of printable characters")

    # porting always runs Claude Code: a key only signs it in, so no claude binary refuses the port even with a key
    var link = "https://docs.anthropic.com/en/docs/claude-code"
    var keyed = port_preflight(Porter("anthropic", "", key, ""), "")
    check(keyed.code == "no_claude" and keyed.message.find(link) >= 0 and keyed.message.find("Install") >= 0,
          "a key without Claude Code must be refused with the install link: " + keyed.code + " " + keyed.message)
    check(port_preflight(gw, "").code == "no_claude", "a gateway key without Claude Code must be refused")
    var nothing = port_preflight(Porter.none(), "")
    check(nothing.code == "porter_not_configured" and nothing.message.find(link) >= 0, "nothing set up, no Claude Code: " + nothing.message)
    var found = port_preflight(Porter.none(), "/usr/bin/claude")
    check(found.code == "porter_not_configured" and found.message.find("/usr/bin/claude") >= 0 and found.message.find("API key") >= 0,
          "nothing set up, Claude Code found: " + found.message)
    check(port_preflight(Porter("anthropic", "", key, ""), "/usr/bin/claude").code == "", "a key with Claude Code may port")
    check(port_preflight(Porter("claude-code", "", "", ""), "/usr/bin/claude").code == "", "Claude Code's own login may port")
    check(port_preflight(Porter("claude-code", "", "", ""), "").code == "no_claude", "Claude Code chosen, then removed")

    # removable
    check(remove_porter(home) and not exists(path_of(home)), "the setting is removable")
    check(not read_porter(home).configured() and not remove_porter(home), "removing twice is no error")
    print("porter: ok")
