"""Goal 64's stand-in for `claude -p` (copied from the Python version's tests; it writes its state inside its own
working directory, which is the only place a sandboxed agent may write). Env: FAKE_CLAUDE_MODE = ok | fail_once | broken | broken_n | regress | parity_once |
hang | crash (broken_n: a different build error each call; regress: call 1 gets to parity, later calls break the build),
FAKE_CLAUDE_LOG (append argv, cwd and prompt as a JSON line), FAKE_CLAUDE_PIDS (hang: write own pid and a
grandchild's). It finds the package folder in the prompt ("Package folder: <path>") and writes a minimal
package there. fail_once / parity_once: the first call writes a bad package, later calls (which must carry
the error text) write a good one, so auto-fix can be tested."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

argv = sys.argv[1:]
prompt = argv[argv.index("-p") + 1]
with open(Path(os.getcwd()) / ".fake-claude.jsonl", "a") as f:  # in the workspace: the only writable place
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
    probe = os.environ.get("FAKE_CLAUDE_PROBE", "")
    f.write(json.dumps({"argv": argv, "cwd": os.getcwd(), "prompt": prompt, "env": sorted(os.environ),
                        "config_dir": cfg, "home_listing": sorted(os.listdir(os.path.expanduser("~"))),
                        "probe": probe, "probe_exists": bool(probe) and os.path.exists(probe),
                        "writable": [d for d in (os.getcwd(), os.path.expanduser("~"), "/", "/tmp")
                                     if os.access(d, os.W_OK)],
                        "ro_writable": [d for d in os.environ.get("FAKE_CLAUDE_RO", "").split(":")
                                        if d and os.access(d, os.W_OK)]}) + "\n")
if os.environ.get("FAKE_CLAUDE_TAMPER"):  # an agent that escaped and edited a gate script
    try:
        with open(os.environ["FAKE_CLAUDE_TAMPER"], "a") as f:
            f.write("\n# pwned\n")
    except OSError as e:
        print(f"tamper refused: {e}", flush=True)
mode = os.environ.get("FAKE_CLAUDE_MODE", "ok")
state = Path(os.getcwd()) / ".fake-claude-calls"
calls = int(state.read_text()) + 1 if state.exists() else 1
state.write_text(str(calls))


def emit(obj):
    print(json.dumps(obj), flush=True)


emit({"type": "assistant", "message": {"content": [{"type": "text", "text": f"Porting (call {calls})"}]}})
emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash",
                                                      "input": {"command": "pixi run python scripts/scaffold.py"}}]}})
if mode == "crash":
    print("claude: authentication failed", file=sys.stderr)
    sys.exit(2)
if mode == "hang":
    gc = subprocess.Popen(["sleep", "600"])
    (Path(os.getcwd()) / ".fake-claude-pids").write_text(f"{os.getpid()} {gc.pid}")
    time.sleep(600)
    sys.exit(0)

folder = Path(prompt.split("Package folder: ", 1)[1].split()[0])
folder.mkdir(parents=True, exist_ok=True)
(folder / "__init__.py").write_text("ARCHITECTURES = []\n")
if calls > 1:
    assert "Fix this" in prompt and "attempt" in prompt, "a retry must carry the error text"
marker = "fine"
if mode == "broken" or (mode == "fail_once" and calls == 1) or (mode == "regress" and calls > 1):
    marker = "BROKEN"
elif mode == "broken_n":
    marker = f"BROKEN variant {calls}"
elif mode == "regress" or (mode == "parity_once" and calls == 1):
    marker = "PARITY_BAD"
(folder / "arch.py").write_text(f"# {marker}\n")
emit({"type": "result", "subtype": "success", "is_error": False, "result": "done"})
