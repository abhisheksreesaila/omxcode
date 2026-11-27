# mojoui.secrets (goal 82 M6): a value saved in the system's secret store comes back, is gone after forget(), and is
# never printed, never in an error message, never in a file. The value is made here from the clock (no real key).
from std.os import getenv
from std.testing import assert_equal, assert_true, assert_false
from mojoui.secrets import SecretStore
from mojoui.clock import now_ns
from mojoui import libc


def main() raises:
    # SECRETS_TEST_KEYCHAIN (macOS): a keychain file of the test's own (the login keychain is locked to an SSH session)
    var store = SecretStore(getenv("SECRETS_TEST_SERVICE", "omxcode test " + String(libc.getpid())), getenv("SECRETS_TEST_KEYCHAIN", ""))
    var value = "sk-test-" + String(now_ns()) + "-" + String(libc.getpid() * 7919)
    assert_false(store.has("api-key"), "nothing is saved under a fresh service")
    store.save("api-key", value)
    assert_true(store.load("api-key") == value, "the value comes back as it was saved")  # (no assert_equal: its message would print it)
    var line = "a key with\na line break"
    var refused = False
    try:
        store.save("other", line)
    except e:
        refused = True
        assert_true(String(e).find("line break") >= 0 and String(e).find("a key with") < 0, "the refusal says why, not what")
    assert_true(refused, "a value with a line break is refused")
    var again = "sk-test-second-" + String(now_ns())
    store.save("api-key", again)  # (a second save replaces the first)
    assert_true(store.load("api-key") == again, "a second save replaces the first")
    store.forget("api-key")
    assert_false(store.has("api-key"), "forget() removes it")
    assert_equal(store.load("api-key"), "", "nothing comes back after forget()")
    store.forget("api-key")  # (forgetting nothing is no error)
    print("secrets:", store.where(), "| round trip ok | forget ok | refused ok | value length", value.byte_length())
