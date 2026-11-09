# examples/console: the sidebar's New label (library-logic.js cleanLabel) and the port card's architecture, read from an
# unsupported pull's message (consoled's pulls.mojo wording). Build with -I examples/console (D-6418).
from std.testing import assert_equal
from home import clean_label
from addflow import arch_in


def main() raises:
    assert_equal(clean_label("Chat"), "chat")
    assert_equal(clean_label("  My Fast  Models "), "my-fast-models")
    assert_equal(clean_label("ported!"), "ported")
    assert_equal(clean_label("--a--b--"), "a-b")
    assert_equal(clean_label("#$%"), "")
    assert_equal(clean_label("x" * 39 + " y"), "x" * 39)  # (40 at most, no '-' left at the end)
    assert_equal(arch_in("openai-community/gpt2 is a GPT2LMHeadModel, which MAX doesn't run."), "GPT2LMHeadModel")
    assert_equal(arch_in("x/y is a model with no architecture, which MAX doesn't run."), "")
    assert_equal(arch_in("x/y has no config.json: not a transformers model MAX can serve."), "")
    print("test_console_labels: ok")
