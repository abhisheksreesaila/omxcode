# Goal 64 M2: the port worker's pure parts (examples/consoled/ports.mojo) — the agent's allow list and flags, the
# prompt that carries the error back, the stage rows, and try-N.json's shape. Offline, nothing is started.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_ports_pure.mojo -o build/test_ports_pure
from ports import (allowed_tools, claude_argv, build_prompt, stages_json, Stage, Ctx, try_config_json,
                   skill_script_command, render_event, SMOKE_PROMPT)


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def joined(argv: List[String]) -> String:
    var out = String("")
    for a in argv:
        out += (" " if out != "" else "") + a
    return out^


def main() raises:
    var tools = joined(allowed_tools(["Bash(cp -r /donor/:*)"]))
    for want in ["Read", "Write", "Edit", "Glob", "Grep", "WebFetch(domain:huggingface.co)", "Bash(cd:*)",
                 "Bash(pixi install)", "Bash(pixi run python scripts/check_port.py:*)",
                 "Bash(pixi run -e cuda python scripts/run_oss_gates.py:*)", "Bash(cp -r /donor/:*)"]:
        check(tools.find(String(want)) >= 0, "allow list is missing " + String(want))
    check(tools.find("Bash(rm") < 0 and tools.find("Bash(:*)") < 0, "the allow list must not open the shell: " + tools)

    var argv = claude_argv("/bin/claude", "do it", List[String]())
    var text = joined(argv)
    for want in ["-p do it", "--permission-mode acceptEdits", "--permission-prompts none", "--setting-sources project",
                 "--strict-mcp-config", "--output-format stream-json", "--verbose", "--no-session-persistence"]:
        check(text.find(String(want)) >= 0, "claude argv is missing " + String(want) + ": " + text)

    var ctx = Ctx()
    ctx.repo_id = "acme/weird"
    ctx.name = "weird"
    ctx.workspace = "/home/me/.mxc/ports/weird"
    ctx.port_dir = ctx.workspace + "/port/weird"
    ctx.skills_root = "/home/me/.mxc/skills/modular"
    ctx.weights = "/home/me/.mxc/models/acme--weird"
    ctx.serving_max = "26.7.0.dev2026100905"
    var first = build_prompt(ctx, 1, "", "Closest supported architecture in MAX (donor): LlamaForCausalLM.")
    check(first.find("Package folder: " + ctx.port_dir) >= 0, "the prompt names the package folder")
    check(first.find("MAX 26.7.0.dev2026100905") >= 0, "the prompt names the MAX that will serve the port")
    check(first.find(ctx.weights + " --port-dir") >= 0, "the prompt points check_port.py at the local weights")
    check(first.find("Fix this") < 0, "the first attempt has nothing to fix")
    var again = build_prompt(ctx, 2, "ImportError: BROKEN layer", "donor note")
    check(again.find("This is attempt 2") >= 0 and again.find("Fix this") >= 0 and again.find("ImportError: BROKEN layer") >= 0,
          "a retry must carry the error text: " + again)

    check(skill_script_command("/s", "check_port.py") == "pixi run --manifest-path /s/import-model/pixi.toml python /s/import-model/scripts/check_port.py",
          "the form the agent may run: " + skill_script_command("/s", "check_port.py"))

    # the rows the console's port screen reads
    var rows: List[Stage] = [Stage("workspace", "done", 1.0, 2.0, "SmolLM3ForCausalLM, donor LlamaForCausalLM", 0),
                             Stage("generate", "running", 2.0, 0.0, "running Claude Code headless…", 1)]
    var js = stages_json(rows)
    check(js.find('"name": "workspace"') >= 0 and js.find('"status": "done"') >= 0 and js.find('"attempt": null') >= 0, "stage rows: " + js)
    check(js.find('"attempt": 1') >= 0 and js.find('"ended": null') >= 0, "the running attempt row: " + js)

    # try-N.json: the flags the 14 real runs earned, and {port} left for the harness
    var cfg = try_config_json(ctx, "/opt/max/bin/max", "/home/me/.mxc/ports/7/work/try-1")
    for want in ["--no-device-graph-capture", "--no-enable-overlap-scheduler", "--force", "--no-enable-prefix-caching",
                 "--no-enable-chunked-prefill", '"{port}"', '"smoke_prompt": "' + String(SMOKE_PROMPT) + '"',
                 '"max_tries": 4', '"budget_s": 5400']:
        check(cfg.find(String(want)) >= 0, "try-1.json is missing " + String(want) + ": " + cfg)

    # the agent's stream-json becomes readable log lines
    var lines = render_event('{"type": "assistant", "message": {"content": [{"type": "text", "text": "Porting it"}]}}')
    check(len(lines) == 1 and lines[0] == "claude: Porting it", "rendered text: " + joined(lines))
    var tool = render_event('{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "pixi run python scripts/scaffold.py"}}]}}')
    check(len(tool) == 1 and tool[0] == "claude> Bash pixi run python scripts/scaffold.py", "rendered tool use: " + joined(tool))
    var done = render_event('{"type": "result", "subtype": "success", "is_error": false}')
    check(len(done) == 1 and done[0] == "claude finished: success", "rendered result: " + joined(done))
    var plain = render_event("not json at all")
    check(len(plain) == 1 and plain[0] == "not json at all", "a line that isn't json stays as it is")
    print("ports pure: ok")
