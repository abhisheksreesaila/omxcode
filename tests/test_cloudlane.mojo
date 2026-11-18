# mojoui.cloudlane (goal 72 M6): which lane answers (the cloud only when named), what never leaves, the capped request to a
# command that is a child process (a script stands in for `claude`), and the record of what went out.
#   pixi run mojo build -I . -I vendor tests/test_cloudlane.mojo -o build/test_cloudlane && build/test_cloudlane
from std.os import setenv, unlink
from std.os.path import exists
from std.testing import assert_equal, assert_true
from mojoui import libc
from mojoui.clock import now_ns
from mojoui.cloudlane import route, looks_secret, CloudLane, cloud_ledger, LANE_LOCAL, LANE_CLOUD, LANE_BACKGROUND, ASK_RUNNING, ASK_DONE, ASK_FAILED


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
        f.write('#!/bin/sh\nif [ "$1" != "-p" ]; then echo "bad call" >&2; exit 2; fi\necho "You asked: $2 (model $4)."\n')
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
    assert_equal(len(String(cloud_ledger()).split("\n")), 3)  # two rows and the empty tail

    # a command that fails is a failure, recorded, not an answer
    with open(script, "w") as f:
        f.write("#!/bin/sh\necho oops >&2\nexit 3\n")
    _ = libc.chmod(script, 0o755)
    var bad = CloudLane(cap=3)
    assert_equal(bad.begin("hello", "opus"), "")
    assert_equal(wait(bad), ASK_FAILED)
    assert_equal(bad.error, "exit 3")
    assert_true('"outcome":"exit 3"' in cloud_ledger())

    # a command that doesn't exist is told, not crashed on
    _ = setenv("OMX_CLAUDE_CMD", "/nonexistent/claude", True)
    var none = CloudLane(cap=3)
    var why = none.begin("hello", "opus")
    assert_true(why.startswith("I couldn't start the cloud command") or none.state == ASK_RUNNING)
    unlink(script)
    unlink(ledger)
    print("cloudlane: ok")
