"""Stand-in for the skill's compare_layers.py (goal 64), carrying the two bugs omxconsole patches in its clone, so
the check proves the patches are applied (the real ones are in Modular's skill; see docs/decisions.md D-6404)."""
import sys


def decode_prefix(tokenizer, ids, pos):
    return tokenizer.decode(
            input_ids[0, :pos].tolist(), skip_special_tokens=True
    )


def same_text(hf_text, mx_text):
    return hf_text == mx_text or bool(
        hf_text.startswith(mx_text))


if __name__ == "__main__":
    print("probe: ok")
    sys.exit(0)
