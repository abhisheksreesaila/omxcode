# goal 82 M6's framework pieces: mojoui.aisettings (the web's Settings → AI rules, the key in the secret store, a brain
# call through curl to a loopback fake of an OpenAI endpoint, a recorded reply) and mojoui.agentedit (each case of
# docs/goals/82/agentedit-cases.json as one JSON line, compared by docs/goals/82-check.py with the web's own agent_edit.py).
# Env: AI_TEST_DIR (a scratch folder), AI_TEST_KEY (a dummy key the checker made), AI_TEST_URL (the fake's base URL),
# AI_TEST_REPLY (the fake's recorded reply), MOJOUI_AI_SERVICE (a test-only secret-store item). Never prints the key.
from std.os import getenv
from std.testing import assert_equal, assert_true, assert_false
from mojoui.aisettings import (
    AiSettings, BrainCall, save_settings, has_key, forget_key, check_key, check_url, ASK_RUNNING, ASK_DONE, ASK_FAILED,
)
from mojoui.agentedit import merge_text, changed_span
from mojoui.json import Json, json_string
from mojoui import libc


def refused(mut s: AiSettings, want: String) raises:
    try:
        s.validate()
    except e:
        assert_equal(String(e), want)
        return
    raise Error("not refused: " + want)


def main() raises:
    var dir = getenv("AI_TEST_DIR", "build/g82/ai")
    var key = getenv("AI_TEST_KEY", "")
    # the web's rules, its words
    var s = AiSettings()
    s.provider = "gemini"
    refused(s, "Pick Claude Code, Azure OpenAI or an OpenAI-compatible service.")
    s = AiSettings()
    s.provider = "openai"
    s.base_url = "http://example.com/v1"
    refused(s, "The base URL must start with https:// (plain http is only allowed for this computer).")
    s.base_url = "https://user:pw@example.com/v1"
    refused(s, "The base URL must be just an address, without a login, query or #.")
    s.base_url = "https://example.com/v1/"
    s.model = "org/model:7b"
    s.validate()
    assert_equal(s.base_url, "https://example.com/v1", "a trailing slash goes")
    s.deployment = "a/b"
    refused(s, "The deployment name has characters it cannot have, or is too long.")
    var bad_key = False
    try:
        _ = check_key("sk with space")
    except:
        bad_key = True
    assert_true(bad_key, "a key with a space is refused")
    # a local endpoint: http to this computer is fine and needs no key
    var local = AiSettings()
    local.provider = "openai"
    local.base_url = "http://127.0.0.1:8000/v1"
    local.model = "qwen"
    local.validate()
    assert_true(local.is_local(), "loopback is local")
    assert_equal(local.label(), "Local model")
    print("ai rules: ok")
    # saved: the file has the choices and never the key; the key is in the secret store
    if has_key():
        forget_key()
    var t = AiSettings()
    t.provider = "openai"
    t.base_url = getenv("AI_TEST_URL", "http://127.0.0.1:9/v1")
    t.model = "test-model"
    _ = save_settings(t, dir, key)
    assert_true(has_key(), "the key is in the secret store")
    var file = String(open(dir + "/ai-settings.json", "r").read())
    assert_true(file.find(key) < 0 and file.find('"baseUrl": "' + t.base_url + '"') >= 0, "the file has the address, not the key")
    var back = AiSettings.load(dir)
    assert_equal(back.base_url, t.base_url)
    print("ai settings: saved (file without the key; key in the store)")
    # a brain call: curl to the fake, the key as its bearer header (the checker reads what the fake saw)
    var call = BrainCall.start(back, "SYSTEM", "USER WORDS")
    while call.poll() == ASK_RUNNING:
        _ = libc.usleep(20_000)
    if call.state != ASK_DONE:
        print("ai call: FAIL " + call.error)
        raise Error("the call failed")
    assert_equal(call.answer, String(open(getenv("AI_TEST_REPLY", ""), "r").read()), "the fake's reply comes back as it was")
    print("ai call: ok in", call.seconds(), "s")
    # a key belongs to its address: a new address drops it
    var moved = AiSettings.load(dir)
    moved.base_url = "https://elsewhere.example/v1"
    var dropped = save_settings(moved, dir)
    assert_true(dropped and not has_key(), "a new address drops the saved key")
    print("ai key follows its address: ok")
    # agent edits, for the checker to compare with the web's
    var cases = Json.parse(String(open("docs/goals/82/agentedit-cases.json", "r").read()))
    for i in range(cases.size(0)):
        var c = cases.at(0, i)
        var before = cases.text(cases.get(c, "before"))
        var after = cases.text(cases.get(c, "after"))
        var now = cases.text(cases.get(c, "now"))
        var undo = merge_text(after, now, before)
        var span = changed_span(before, after)
        print('{"case": ' + String(i) + ', "undo": ' + (json_string(undo.value()) if undo else String("null")) + ', "span": [' + String(span[0]) + ", " + String(span[1]) + "]}")
