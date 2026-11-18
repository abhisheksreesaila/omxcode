# mojoui.cloudlane (goal 72 M6): which lane answers (the cloud only when named), what never leaves, the capped request to a
# command that is a child process (a script stands in for `claude`), and the record of what went out.
#   pixi run mojo build -I . -I vendor tests/test_cloudlane.mojo -o build/test_cloudlane && build/test_cloudlane
from std.os import setenv, unlink, stat
from std.os.path import exists
from std.testing import assert_equal, assert_true
from mojoui import libc
from mojoui.clock import now_ns
from mojoui.cloudlane import route, looks_secret, CloudLane, CloudTurn, CloudStep, cloud_ledger, LANE_LOCAL, LANE_CLOUD, LANE_BACKGROUND, ASK_RUNNING, ASK_DONE, ASK_FAILED, STEP_NONE, STEP_ANSWERED, STEP_FAILED, STEP_FRAME_OFF


def lane_of(text: String) -> Int:
    return route(text).lane


def wait(mut lane: CloudLane) -> Int:
    var until = now_ns() + 20_000_000_000
    while lane.poll() == ASK_RUNNING and now_ns() < until:
        _ = libc.usleep(10_000)
    return lane.state


def main() raises:
    # where each request goes: omx-local's fixtures that name a lane, and the ones that say to stay
    assert_equal(lane_of("What time is it?"), LANE_LOCAL)
    assert_equal(lane_of("Tell me a joke about penguins."), LANE_LOCAL)
    assert_equal(lane_of("What's a fifteen percent tip on eighty dollars?"), LANE_LOCAL)
    assert_equal(lane_of("Remind me to call mum on Sunday."), LANE_LOCAL)
    assert_equal(lane_of("Write a full business plan with five year financial projections and a competitor analysis."), LANE_LOCAL)  # long, but not asked for: explicit only
    assert_equal(lane_of("Ask Claude to review my architecture document."), LANE_CLOUD)
    assert_equal(lane_of("Ask Claude: in one sentence, what is a monad?"), LANE_CLOUD)
    assert_equal(lane_of("Use Claude for the tax question please."), LANE_CLOUD)
    assert_equal(lane_of("Claude, plan a two week trip to Japan."), LANE_CLOUD)
    assert_equal(lane_of("Have Sonnet look at this."), LANE_CLOUD)
    assert_equal(lane_of("Go hybrid and plan a two week trip to Japan with a day by day budget."), LANE_CLOUD)
    assert_equal(lane_of("Don't ask Claude, just tell me what two plus two is."), LANE_LOCAL)
    assert_equal(lane_of("Ask Claude but stay local."), LANE_LOCAL)  # staying local wins
    assert_equal(lane_of("Think it through and get back to me: should I buy a second RTX 3090?"), LANE_BACKGROUND)
    assert_equal(lane_of("Take your time and tell me about the French revolution."), LANE_BACKGROUND)
    assert_equal(lane_of("Ask Claude to think it through."), LANE_CLOUD)  # a named cloud model wins over the background rule
    # a name in other words stays local: a painter, a poem, a habit, a question about the model
    assert_equal(lane_of("Claude Monet's water lilies are famous, when did he paint them?"), LANE_LOCAL)
    assert_equal(lane_of("Do you have a haiku about autumn?"), LANE_LOCAL)
    assert_equal(lane_of("Do you have Haiku about autumn?"), LANE_LOCAL)
    assert_equal(lane_of("I use Claude every day for writing, how do I get better at prompts?"), LANE_LOCAL)
    assert_equal(lane_of("What did Claude Shannon invent?"), LANE_LOCAL)
    assert_equal(lane_of("Write a haiku about the sea."), LANE_LOCAL)
    assert_equal(lane_of("Sonnet 18 is by Shakespeare, explain it."), LANE_LOCAL)
    assert_equal(lane_of("My friend Claude, the baker, makes good bread. When does he open?"), LANE_LOCAL)
    assert_equal(lane_of("The Opus Dei novel is long."), LANE_LOCAL)
    # and the forms that do ask for a model, politely too
    assert_equal(lane_of("Can you ask Claude to review this?"), LANE_CLOUD)
    assert_equal(lane_of("Please use Opus for this one."), LANE_CLOUD)
    assert_equal(lane_of("Hey Claude, what is a monad?"), LANE_CLOUD)
    assert_equal(lane_of("Claude: what is a monad?"), LANE_CLOUD)
    assert_equal(lane_of("Go ask Sonnet about it."), LANE_CLOUD)
    assert_equal(route("Ask Opus about it").model, "opus")
    assert_equal(route("Have Sonnet look at this.").model, "sonnet")
    assert_equal(route("Ask Claude about it").model, "opus")  # the default model

    # what never leaves
    assert_true(looks_secret("my password is hunter2"))
    assert_true(looks_secret("use this key sk-ant-api03-abcdefghijklmnop to call it"))
    assert_true(looks_secret("-----BEGIN PRIVATE KEY-----"))
    assert_true(looks_secret("token 3f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a"))
    assert_true(not looks_secret("What is a monad? Explain it in one sentence."))
    assert_true(not looks_secret("the Hitchhiker's Guide to the Galaxy has forty-two as its answer"))

    # a request to a command that is a child process; a script stands in for `claude`
    var script = String("/tmp/mojoui-test-fake-claude.sh")
    var ledger = String("/tmp/mojoui-test-ledger.jsonl")
    for p in [script, ledger]:
        if exists(p):
            unlink(p)
    with open(script, "w") as f:
        f.write('#!/bin/sh\nif [ "$1" != "-p" ]; then echo "bad call" >&2; exit 2; fi\nmodel=""; prompt=""; seen=""\nwhile [ $# -gt 0 ]; do\n  if [ -n "$seen" ]; then prompt="$1"; break; fi\n  if [ "$1" = "--model" ]; then model="$2"; shift; elif [ "$1" = "--" ]; then seen=1; fi\n  shift\ndone\necho "You asked: $prompt (model $model)."\n')
    _ = libc.chmod(script, 0o755)
    _ = setenv("OMX_CLAUDE_CMD", script, True)
    _ = setenv("MOJOUI_LEDGER", ledger, True)

    var lane = CloudLane(cap=2)
    assert_equal(lane.begin("my password is hunter2", "opus"), "that has what looks like a key or a password in it, and I don't send those to the cloud")
    assert_equal(lane.used, 0)  # a refusal doesn't count, and sends nothing
    assert_equal(cloud_ledger(), "")
    assert_equal(lane.begin("what is a monad?", "opus"), "")
    assert_equal(lane.state, ASK_RUNNING)
    assert_equal(wait(lane), ASK_DONE)
    assert_equal(lane.answer, "You asked: what is a monad? (model opus).")
    lane.idle()
    var rows = cloud_ledger()
    assert_true(rows.startswith('{"at":'))
    assert_true('"model":"opus","outcome":"ok","bytes_out":' in rows)
    assert_true('"bytes_in":41,' in rows)  # the answer's bytes
    assert_true('"excerpt":"what is a monad?"}' in rows)

    # a second, then the cap
    assert_equal(lane.begin("and a functor?", "sonnet"), "")
    assert_equal(wait(lane), ASK_DONE)
    lane.idle()
    assert_equal(lane.begin("one more", "opus"), "I've reached the limit of 2 cloud requests for this session")
    assert_equal(len(String(cloud_ledger()).split("\n")), 5)  # (D-7254: "sent" before it left, the outcome after) four rows and the empty tail
    assert_true('"outcome":"sent"' in cloud_ledger())
    assert_equal(stat(ledger).st_mode & 0o777, 0o600)  # the record is the person's alone

    # a command that fails is a failure, recorded, not an answer
    with open(script, "w") as f:
        f.write("#!/bin/sh\necho oops >&2\nexit 3\n")
    _ = libc.chmod(script, 0o755)
    var bad = CloudLane(cap=3)
    assert_equal(bad.begin("hello", "opus"), "")
    assert_equal(wait(bad), ASK_FAILED)
    assert_equal(bad.error, "exit 3")
    assert_true('"outcome":"exit 3"' in cloud_ledger())

    # words that start with a dash are a prompt, not the command's options (the prompt follows `--`), and a ledger excerpt cuts at
    # a character, not in the middle of one (120 bytes of "é" is 60 whole letters)
    with open(script, "w") as f:
        f.write('#!/bin/sh\nmodel=""; prompt=""; seen=""\nwhile [ $# -gt 0 ]; do\n  if [ -n "$seen" ]; then prompt="$1"; break; fi\n  if [ "$1" = "--" ]; then seen=1; fi\n  shift\ndone\necho "heard: $prompt"\n')
    _ = libc.chmod(script, 0o755)
    var dash = CloudLane(cap=5)
    assert_equal(dash.begin("--version please", "opus"), "")
    assert_equal(wait(dash), ASK_DONE)
    assert_equal(dash.answer, "heard: --version please")
    dash.idle()
    assert_equal(dash.begin("é" * 100, "opus"), "")
    assert_equal(wait(dash), ASK_DONE)
    dash.idle()
    assert_true(('"excerpt":"' + "é" * 60 + '"}') in cloud_ledger(), "the excerpt is 60 whole letters")

    # the record comes first: where it can't be written, nothing is sent (the script leaves a marker when it runs)
    var marker = String("/tmp/mojoui-test-cloud-marker")
    if exists(marker):
        unlink(marker)
    with open(script, "w") as f:
        f.write("#!/bin/sh\ntouch " + marker + "\necho ok\n")
    _ = libc.chmod(script, 0o755)
    var good_ledger = ledger
    _ = setenv("MOJOUI_LEDGER", "/proc/not-a-folder/ledger.jsonl", True)
    var blind = CloudLane(cap=5)
    assert_equal(blind.begin("what is a monad?", "opus"), "I can't write the record of what leaves this machine, so I'm not sending anything")
    assert_equal(blind.used, 0)
    _ = libc.usleep(300_000)
    assert_true(not exists(marker), "nothing was sent without a record")
    _ = setenv("MOJOUI_LEDGER", good_ledger, True)

    # cancelling never waits: the command is signalled at once and reaped by the ticks after; the ledger says it was interrupted
    with open(script, "w") as f:
        f.write("#!/bin/sh\ntrap '' TERM\nsleep 30\n")  # (one that ignores SIGTERM: the reaper's SIGKILL ends it)
    _ = libc.chmod(script, 0o755)
    var slow = CloudLane(cap=5)
    assert_equal(slow.begin("take your time", "opus"), "")
    _ = libc.usleep(200_000)
    var t0 = now_ns()
    slow.cancel()
    var cancel_ms = (now_ns() - t0) // 1_000_000
    assert_true(cancel_ms < 50, "cancel returned in " + String(cancel_ms) + " ms")
    assert_equal(slow.state, ASK_FAILED)
    assert_equal(slow.error, "interrupted")
    assert_equal(len(slow.dying), 1)
    var until = now_ns() + 5_000_000_000
    while len(slow.dying) > 0 and now_ns() < until:
        slow.reap()
        _ = libc.usleep(20_000)
    assert_equal(len(slow.dying), 0)  # (reaped within the grace, SIGKILL included)
    assert_true('"outcome":"interrupted"' in cloud_ledger())

    # a whole turn: the words, the asking, the answer, the frame until it has been said, and a failure that hands the question back
    with open(script, "w") as f:
        f.write('#!/bin/sh\nmodel=""; prompt=""; seen=""\nwhile [ $# -gt 0 ]; do\n  if [ -n "$seen" ]; then prompt="$1"; break; fi\n  if [ "$1" = "--" ]; then seen=1; fi\n  shift\ndone\necho "Cloud says: $prompt"\n')
    _ = libc.chmod(script, 0o755)
    var turn = CloudTurn(cap=3)
    assert_equal(turn.fresh("ask claude", False), "ask claude")
    assert_equal(turn.fresh("ask claude what is a monad", True), "what is a monad")  # (a merged turn: only what is new)
    assert_equal(turn.fresh("something else", True), "something else")  # (it doesn't continue those words)
    assert_equal(turn.fresh("something else entirely", False), "something else entirely")
    assert_true(not turn.framed)
    assert_equal(turn.ask("what is a monad?", "opus"), "")
    assert_true(turn.framed and turn.asking)
    var step = CloudStep(STEP_NONE)
    var wait_until = now_ns() + 20_000_000_000
    while step.kind == STEP_NONE and now_ns() < wait_until:
        step = turn.step(True)
        _ = libc.usleep(10_000)
    assert_equal(step.kind, STEP_ANSWERED)
    assert_equal(step.text, "Cloud says: what is a monad?")
    assert_equal(step.question, "what is a monad?")
    assert_equal(step.used, 1)
    assert_true(turn.framed and not turn.asking, "the frame stays while the answer is said")
    assert_equal(turn.step(True).kind, STEP_NONE)
    assert_equal(turn.step(False).kind, STEP_FRAME_OFF)  # (said: the frame goes)
    assert_true(not turn.framed)
    assert_equal(turn.step(False).kind, STEP_NONE)
    # asked, then the person speaks again: dropped, and the lane is local
    assert_equal(turn.ask("and a functor?", "opus"), "")
    assert_true(turn.cancel())
    assert_true(not turn.framed and not turn.asking)
    assert_true(not turn.cancel())  # (nothing to drop the second time)
    # a refusal leaves nothing on: a key in the words
    assert_equal(turn.ask("my password is hunter2", "opus"), "that has what looks like a key or a password in it, and I don't send those to the cloud")
    assert_true(not turn.framed)
    # a command that fails: the failure comes back with the question, and the frame is already down
    with open(script, "w") as f:
        f.write("#!/bin/sh\nexit 4\n")
    _ = libc.chmod(script, 0o755)
    assert_equal(turn.ask("will this fail?", "opus"), "")
    step = CloudStep(STEP_NONE)
    wait_until = now_ns() + 20_000_000_000
    while step.kind == STEP_NONE and now_ns() < wait_until:
        step = turn.step(False)
        _ = libc.usleep(10_000)
    assert_equal(step.kind, STEP_FAILED)
    assert_equal(step.question, "will this fail?")
    assert_equal(step.text, "exit 4")
    assert_true(not turn.framed)
    turn.close()
    if exists(marker):
        unlink(marker)

    # a command that doesn't exist is told, not crashed on
    _ = setenv("OMX_CLAUDE_CMD", "/nonexistent/claude", True)
    var none = CloudLane(cap=3)
    var why = none.begin("hello", "opus")
    assert_true(why.startswith("I couldn't start the cloud command") or none.state == ASK_RUNNING)
    unlink(script)
    unlink(ledger)
    print("cloudlane: ok")
