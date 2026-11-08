# Goal 64 M2: the port's hard-won decisions (examples/consoled/portprep.mojo) — the donor architecture a model
# starts from, the package slug MAX can import, what a port package must hold, pinning the skill's MAX, and what
# makes two failures "the same" (the stop-on-repeat rule). The expected values come from the owner's 14 real runs
# under ~/.mxc/ports/ and from the Python version's own tests, never computed by the code under test.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_port_donor.mojo -o build/test_port_donor
from portprep import (norm, common_prefix, pick_donor, package_slug, workspace_name, check_port_dir, pin_max,
                      max_pinned, failure_signature, infra_error, reached_text)

def catalog() -> List[String]:
    return ["LlamaForCausalLM", "Qwen2ForCausalLM", "StableLmForCausalLM", "GPT2LMHeadModel", "MistralForCausalLM"]


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    # the family name
    check(norm("LlamaForCausalLM") == "llama", "norm llama: " + norm("LlamaForCausalLM"))
    check(norm("SmolLM3ForCausalLM") == "smollm3", "norm smollm3: " + norm("SmolLM3ForCausalLM"))
    check(norm("GPT2LMHeadModel") == "gpt2lmheadmodel", "norm gpt2: " + norm("GPT2LMHeadModel"))
    check(common_prefix("stablelm2", "stablelm") == 8, "common prefix")

    # run 23: StableLM-2 is ported from StableLm, the same family at a nearby version
    var d = pick_donor("StableLm2ForCausalLM", "stablelm2", catalog(), "")
    check(d.architecture == "StableLmForCausalLM", "stablelm donor: " + d.architecture)
    check(d.reason.find("same family") >= 0, "stablelm reason: " + d.reason)
    # run 24: SmolLM3 shares its name with nothing in the catalog, so Llama is the fallback
    var s = pick_donor("SmolLM3ForCausalLM", "smollm3", catalog(), "")
    check(s.architecture == "LlamaForCausalLM", "smollm3 donor: " + s.architecture)
    check(s.reason.startswith("fallback:"), "smollm3 reason: " + s.reason)
    # the model_type counts too, and no source dir is no crash
    var q = pick_donor("", "qwen2", catalog(), "/nowhere")
    check(q.architecture == "Qwen2ForCausalLM" and q.source_dir == "", "qwen2 by model_type: " + q.architecture)

    # the package folder MAX imports by name
    check(package_slug("smollm3-3b") == "smollm3_3b", "slug: " + package_slug("smollm3-3b"))
    check(package_slug("1.5b!!") == "m_1_5b", "slug of digits: " + package_slug("1.5b!!"))
    check(package_slug("...") == "port", "slug of nothing: " + package_slug("..."))
    check(workspace_name("24") == "model-24" and workspace_name("gpt2") == "gpt2", "workspace name")

    # a port package: a folder with arch.py and an __init__.py that exposes ARCHITECTURES
    check(check_port_dir("/tmp/does-not-exist-64").find("is not a directory") >= 0, "missing dir")

    # the skill's MAX is pinned to the one that will serve the port
    var manifest = String('[dependencies]\nmax = ">=26.7,<27"\npython = "3.12"\n')
    var pinned = pin_max(manifest, "26.7.0.dev2026100905")
    check(max_pinned(pinned, "26.7.0.dev2026100905"), "pin: " + pinned)
    check(pinned.find('python = "3.12"') >= 0, "pin kept the rest: " + pinned)

    # the same failure twice: the gate's result lines decide, not its progress bars or timings
    var a = failure_signature("parity check failed", "Loading  45%| 3.2 it/s]\nlogits  FAIL  diff 3.2 nats at 12:00:01\noverall: 2/3", 3.0)
    var b = failure_signature("parity check failed", "Loading  91%| 9.9 it/s]\nlogits  FAIL  diff 3.2 nats at 13:41:52\noverall: 2/3", 3.0)
    check(a == b, "the same parity failure must read the same:\n" + a + "---\n" + b)
    var c = failure_signature("parity check failed", "logits  FAIL  diff 0.4 nats\noverall: 2/3", 3.0)
    check(a != c, "a different parity failure must read differently")
    # a build failure keeps its own output (the same counts with different weight names must differ)
    var x = failure_signature("build failed", "ImportError: BROKEN layer mlp.up_proj", 1.0)
    var y = failure_signature("build failed", "ImportError: BROKEN layer mlp.down_proj", 1.0)
    check(x != y, "two build failures with different weights must differ")

    # the Hub failing is not the port's fault; our own server dying is
    check(infra_error("checkpoint_meta  FAIL  429 Too Many Requests for url: https://huggingface.co/acme/weird", True) != "", "hub 429")
    check(infra_error("MAX server unreachable: Connection refused", True) == "", "our own server is the port's problem")
    check(infra_error("checkpoint_meta  FAIL  429 Too Many Requests for https://huggingface.co/x", False) == "", "a dead server means no infra retry")
    check(reached_text(1) == "it got to the build check" and reached_text(3.5) == "it served; the comparison failed", "reached text")
    print("port donor: ok")
