# A model reference as people paste it: a curated name, owner/name, or a Hugging Face model URL (https://, http://,
# no scheme, www., a trailing /, /tree/<rev>, /blob/…, ?query, #fragment), normalised to owner/name at the boundary
# (mojoui.hf.hub_ref, used by pulls, ports and search) and refused when it doesn't reduce to a valid owner/name.
# Offline.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_model_refs.mojo -o build/test_model_refs
from mojoui.hf import hub_ref
from pulls import ref_problem


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    var good: List[String] = [
        "https://huggingface.co/openai-community/gpt2",
        "http://huggingface.co/openai-community/gpt2",
        "huggingface.co/openai-community/gpt2",
        "www.huggingface.co/openai-community/gpt2",
        "https://www.huggingface.co/openai-community/gpt2/",
        "HTTPS://HuggingFace.co/openai-community/gpt2",
        "https://huggingface.co/openai-community/gpt2/tree/main",
        "https://huggingface.co/openai-community/gpt2/tree/main/onnx",
        "https://huggingface.co/openai-community/gpt2/blob/main/config.json",
        "https://huggingface.co/openai-community/gpt2?library=transformers",
        "https://huggingface.co/openai-community/gpt2#model-card",
        "  https://huggingface.co/openai-community/gpt2/?x=1#y  ",
    ]
    for g in good:
        check(hub_ref(g) == "openai-community/gpt2", "normalised " + g + " to `" + hub_ref(g) + "`")
        check(ref_problem(g) == "", "refused " + g + ": " + ref_problem(g))
    # plain references pass through unchanged
    check(hub_ref("Qwen/Qwen2.5-0.5B-Instruct") == "Qwen/Qwen2.5-0.5B-Instruct", "owner/name changed")
    check(hub_ref("qwen2.5-0.5b") == "qwen2.5-0.5b", "a curated name changed")
    check(ref_problem("Qwen/Qwen2.5-0.5B-Instruct") == "" and ref_problem("qwen2.5-0.5b") == "", "a plain ref refused")
    check(hub_ref("https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/tree/main") == "Qwen/Qwen2.5-0.5B-Instruct", "case kept")
    # refused: other hosts, look-alikes, no owner/name, a dataset or Space, traversal, odd characters
    var bad: List[String] = [
        "", "   ",
        "https://example.com/openai-community/gpt2",
        "https://huggingface.co.evil.com/openai-community/gpt2",
        "https://evilhuggingface.co/openai-community/gpt2",
        "https://user@huggingface.co/openai-community/gpt2",
        "https://huggingface.co:443/openai-community/gpt2",
        "ftp://huggingface.co/openai-community/gpt2",
        "file:///etc/passwd",
        "https://huggingface.co/",
        "https://huggingface.co",
        "https://huggingface.co/gpt2",
        "https://huggingface.co/openai-community/",
        "https://huggingface.co//gpt2",
        "https://huggingface.co/datasets/openai/gsm8k",
        "https://huggingface.co/spaces/owner/app",
        "https://huggingface.co/models",
        "https://huggingface.co/../etc/passwd",
        "https://huggingface.co/owner/..",
        "https://huggingface.co/owner/name%2F..",
        "https://huggingface.co/own er/name",
        "../etc", "a/..", "a/.hidden", "a/b/c", "/a", "a/", "-a/b", "a/b c", "a/b;rm",
    ]
    for b in bad:
        check(ref_problem(b) != "", "accepted `" + b + "` as " + hub_ref(b))
    check(hub_ref("https://example.com/a/b") == "", "another host reduced to a ref")
    check(ref_problem("https://example.com/a/b").find("Hugging Face") >= 0, "the refusal doesn't say what to send")
    print("model refs: ok (" + String(len(good)) + " URL forms, " + String(len(bad)) + " refused)")
