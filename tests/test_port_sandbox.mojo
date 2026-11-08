# Goal 64 M2: the sandbox the porting agent runs in (examples/consoled/sandbox.mojo). The argv is asserted, as the
# Python version's tests did: the system read-only, $HOME and MXC_HOME empty, /tmp and /run/user private, new
# pid/ipc/uts namespaces, and only the listed paths writable. Offline, nothing is started.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_port_sandbox.mojo -o build/test_port_sandbox
from sandbox import bwrap_argv, Confine, scrub, looks_secret


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def joined(argv: List[String]) -> String:
    var out = String("")
    for a in argv:
        out += (" " if out != "" else "") + a
    return out^


def main() raises:
    var c = Confine("/ws", "/home/me", "/home/me/.mxc", ["/ws", "/job/work"], ["/skills"], ["/ws/.claude/settings.json"],
                    ["/home/me/.claude/.credentials.json>/job/work/claude-cfg/.credentials.json"],
                    ["/weights/models--acme--weird>/job/work/hf/hub/models--acme--weird"], True)
    var argv = bwrap_argv(["claude", "-p", "do it"], "/usr/bin/bwrap", c)
    var text = joined(argv)
    check(argv[0] == "/usr/bin/bwrap", "bwrap first")
    for want in ["--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
                 "--ro-bind / /", "--dev-bind /dev /dev", "--proc /proc", "--tmpfs /tmp", "--tmpfs /run/user",
                 "--tmpfs /home/me", "--tmpfs /home/me/.mxc", "--ro-bind-try /skills /skills",
                 "--bind-try /ws /ws", "--bind-try /job/work /job/work",
                 "--bind-try /home/me/.claude/.credentials.json /job/work/claude-cfg/.credentials.json",
                 "--ro-bind-try /weights/models--acme--weird /job/work/hf/hub/models--acme--weird",
                 "--chdir /ws --"]:
        check(text.find(String(want)) >= 0, "missing " + String(want) + " in:\n" + text)
    # the writable workspace is bound before the read-only files inside it, or the settings would be writable
    check(text.find("--bind-try /ws /ws") < text.find("--ro-bind-try /ws/.claude/settings.json"), "ro_after must come last:\n" + text)
    check(text.endswith("-- claude -p do it"), "the command last: " + text)
    # without a GPU the device nodes are not bound through
    var plain = joined(bwrap_argv(["x"], "bwrap", Confine("/w", "/h", "/m", [], [], [], [], [], False)))
    check(plain.find("--dev /dev") >= 0 and plain.find("--dev-bind") < 0, "no gpu: " + plain)

    # the environment: anything that looks like a credential goes, claude keeps its own auth
    check(looks_secret("ANTHROPIC_API_KEY") and looks_secret("HF_TOKEN") and looks_secret("CONDA_PREFIX"), "secret names")
    check(not looks_secret("PATH") and not looks_secret("HOME"), "plain names stay")
    var drops = scrub(["PATH", "HF_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "HOME"], True)
    check(joined(drops).find("HF_TOKEN=") >= 0 and joined(drops).find("OPENAI_API_KEY=") >= 0, "drops: " + joined(drops))
    check(joined(drops).find("ANTHROPIC_API_KEY=") < 0, "claude keeps its own auth: " + joined(drops))
    check(joined(drops).find("PATH=") < 0 and joined(drops).find("HOME=") < 0, "plain names kept: " + joined(drops))
    print("port sandbox: ok")
