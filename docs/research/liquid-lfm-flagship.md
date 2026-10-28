# Liquid AI LFM3 as the local brain for the flagship demo

Researched 2026-10-27 (LFM3's release day). Question from the owner: can Liquid AI's new small agent models,
served locally by omxconsole (`127.0.0.1:11435/v1`), drive the AG-UI `render_ui` agent (goal 35) inside omxplorer?

Facts from the web are linked. Facts about omxconsole and MAX come from reading local code (read only, nothing run):
`~/Projects/mxstudio/mxconsole`, its cached MAX catalog `~/.mxc/max_catalog.json` (written 2026-10-20), and the MAX
nightly it installed, `max-26.7.0.dev2026100905`. **No model was downloaded or run for this note: everything about
quality on our task is unverified.**

## Answer in one paragraph

The family is **LFM3**, released today. The model for the demo is **LFM3-1.7B**: the text and agent model, 1.73B
parameters, a 256K context window, and the best reported BFCL V4 score in its class (71.39, ahead of Qwen3.5-9B at
62.83). Its tool calls use Qwen3-Coder-style XML. **omxconsole can't serve it today:** MAX has no `Lfm3ForCausalLM`,
and omxconsole's port path refuses LFM3 before the agent starts, because the model needs Hub remote code and
transformers doesn't have LFM3 yet. **llama.cpp merged LFM3 support today**, so the quickest way is `llama-server` behind
the same OpenAI-style API. The longer omxconsole route: wait for transformers to add LFM3, then port it, starting from
MAX's LFM2. **Recommendation: go**, with llama.cpp for the demo and the MAX port as a follow-up (details at the end).

## 1. The models (2026)

LFM3 launched on 2026-10-27 ([Liquid blog](https://www.liquid.ai/blog/lfm3),
[collection](https://huggingface.co/collections/LiquidAI/lfm3)): six open-weight models of about 2B parameters each,
all built on one backbone, LFM3-1.7B-Base.

| Model | What | Notes |
|---|---|---|
| [LFM3-1.7B](https://huggingface.co/LiquidAI/LFM3-1.7B) | text, agents, tool calling | **the one for this demo**. 1.73B params, 256K context |
| [LFM3-1.7B-Base](https://huggingface.co/LiquidAI/LFM3-1.7B-Base) | base model | for fine-tuning |
| [LFM3-VL-2B](https://huggingface.co/LiquidAI/LFM3-VL-2B) | vision (adds video input) | could read a chart screenshot later |
| [LFM3-Audio-2B](https://huggingface.co/LiquidAI/LFM3-Audio-2B) | speech in/out, tool calling | `Lfm3AudioForConditionalGeneration` ([config](https://huggingface.co/LiquidAI/LFM3-Audio-2B/raw/main/config.json)) |
| [LFM3-Omni-2B](https://huggingface.co/LiquidAI/LFM3-Omni-2B) | omni | |
| [d1-2B](https://huggingface.co/LiquidAI/d1-2B), [d1-Omni-2B](https://huggingface.co/LiquidAI/d1-Omni-2B) | "decision" models: many answers in one forward pass | not chat agents |

The previous generation is still current, and some of it runs on MAX today (section 4):
[LFM2.5-350M](https://huggingface.co/LiquidAI/LFM2.5-350M), [LFM2.5-1.2B-Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct),
[LFM2.5-2.6B](https://huggingface.co/LiquidAI/LFM2.5-2.6B) (all `Lfm2ForCausalLM`, 128K context), and the MoEs
[LFM2.5-8B-A1B](https://huggingface.co/LiquidAI/LFM2.5-8B-A1B) and [LFM2.5-24B-A2B](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B)
(`Lfm2MoeForCausalLM`; the 24B has 2.45B active parameters).

**Architecture of LFM3-1.7B** ([blog](https://www.liquid.ai/blog/lfm3),
[config.json](https://huggingface.co/LiquidAI/LFM3-1.7B/raw/main/config.json)): a "tri-hybrid" of 24 layers:
13 gated short convolutions (kernel 7, up from 3 in LFM2), 5 sliding-window attention layers (window 256), and 6
global attention layers. GQA with 16 query heads and 4 KV heads, head size 128. Head-wise sigmoid-gated attention,
partial RoPE on the global layers, sandwich norm, a 128K vocabulary, tied embeddings, bf16. The config names
`"architectures": ["Lfm3ForCausalLM"]`, `"model_type": "lfm3"`, and an `auto_map` pointing at Hub code
(`modeling_lfm3.py`).

## 2. Licence: commercial use is allowed below $10M annual revenue

Licence: **LFM Open License v1.0** ([LICENSE](https://huggingface.co/LiquidAI/LFM3-1.7B/blob/main/LICENSE); LFM2.5
uses the same `lfm1.0` tag). It is Apache-style: you may use, modify and redistribute it (patent grant included), keep
the notices, and **commercial use is licensed only below "annual revenue of 10 million United States dollars
($10,000,000) or more"** (§1, §5). Above that, you need a separate deal with Liquid. There is no field-of-use
restriction. The licence ends automatically if you break its terms (§11). For a solo founder's demo and early products
this is fine. It is **not** OSI open source, so say "open-weight", not "open source".

## 3. Tool calling

- **Format** ([model card](https://huggingface.co/LiquidAI/LFM3-1.7B),
  [chat_template.jinja](https://huggingface.co/LiquidAI/LFM3-1.7B/raw/main/chat_template.jinja),
  [Liquid tool-use docs](https://docs.liquid.ai/docs/key-concepts/tool-use)): the template lists tools in the system
  prompt inside `<tools>…</tools>`. The model answers with
  `<tool_call>\n<function=NAME>\n<parameter=ARG>\nVALUE\n</parameter>\n</function>\n</tool_call>`, and tool results
  come back as role `tool`, wrapped in `<tool_response>`. Liquid calls this "a superset of `qwen3_coder`". It is
  **not** the LFM2/LFM2.5 format: those emit Pythonic calls between `<|tool_call_start|>` and `<|tool_call_end|>`, and
  emit JSON only if the system prompt asks for it.
- Chat format is ChatML-style. **Reasoning is on by default** (the prompt opens a `<think>` block), and
  `enable_thinking=False` turns it off, "inconsistent on reasoning-heavy tasks"
  ([card](https://huggingface.co/LiquidAI/LFM3-1.7B)). For `render_ui`, turn thinking off to cut latency, or strip it.
- Recommended settings for tool use: `temperature=0.1, top_k=50, repetition_penalty=1.1`.
- A "deferred tools" feature (`defer_loading=True`) keeps big tool catalogues out of the prompt until a search tool
  names them. We don't need it for one `render_ui` tool.
- **Our risk:** `render_ui` takes one deeply nested `ui` object, which lands in a single `<parameter=ui>` as JSON. The
  card says non-string values are emitted as JSON, but nested JSON inside an XML parameter is exactly where small models
  slip. The agentchat backend's JSON repair (`mojo-ui-agui/docs/agui.md`, "The live demo") still applies.

## 4. Benchmarks (all reported by Liquid; none checked independently)

From the [LFM3 blog](https://www.liquid.ai/blog/lfm3) and [card](https://huggingface.co/LiquidAI/LFM3-1.7B):

| Benchmark | LFM3-1.7B | LFM2.5-2.6B | Qwen3.5-4B | Qwen3.5-9B |
|---|---|---|---|---|
| BFCL V4 (function calling) | **71.39** | 55.89 | 55.12 | 62.83 |
| ToolSandbox | **80.36** | 78.04 | 75.40 | 76.41 |
| τ³-bench | 68.01 | 56.77 | 65.98 | 67.11 |
| MCP-Atlas | 32.57 | 16.45 | 41.37 | **42.67** |
| IFEval (instruction following) | **96.66** | 95.39 | 92.52 | 92.08 |
| RULER 128K (long context) | 65.56 | 1.15 | 84.63 | 87.11 |

- WebArena-Verified: 38.42 for LFM3-1.7B, against 28.94 for Qwen3.5-9B and 3.02 for LFM2.5-2.6B.
- KV cache at 128K context is 1.6 GB, against 4.3 GB for Qwen3.5-4B.
- Liquid's own caveat ([card](https://huggingface.co/LiquidAI/LFM3-1.7B)): "not recommended for agentic coding or
  complex multi-step reasoning" because of its size.
- For comparison, [LFM2.5-24B-A2B](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B) scores BFCLv4 65.01 and
  ToolSandbox 80.71: the 1.7B matches it on tool calling.

So BFCL and IFEval, the two scores closest to "fill one schema correctly", are the model's strongest. That fits a
`render_ui` agent better than any model we've tried (`qwen2.5-0.5b`, the current default, is known to break tool JSON).

## 5. Can MAX / omxconsole serve it?

**LFM2 and LFM2.5 dense models: yes, today.** MAX's catalog has `Lfm2ForCausalLM` (example repos
`LiquidAI/LFM2.5-350M`, `LiquidAI/LFM2.5-350M-Base`; encodings bfloat16 and float32). That comes from
`~/.mxc/max_catalog.json` and the source at `max/pipelines/architectures/lfm2/`: a real conv + attention hybrid with
per-request conv-state slots (`LFM2BatchProcessor`), single GPU only, no device graph capture. So `mxc pull
LiquidAI/LFM2.5-1.2B-Instruct` or `LiquidAI/LFM2.5-2.6B` should resolve as `hf-supported` (inferred from
`resolve.py`; not run).
- The catch: MAX registers **no LFM tool parser**. `lfm2/arch.py` sets no `tool_parser`. The registered parsers are
  llama, qwen3_5, gemma4, glm45, kimik2_5, minimax_m2, deepseekv3/v3_1/v4, laguna, inkling and muse_glimmer, and
  omxconsole's `supervisor._command` passes no tool-parser flag. So LFM2.5's `<|tool_call_start|>[…]` calls would
  come back as plain text, not `tool_calls`. The agentchat backend's "UI written into the words is lifted out" path
  might rescue it (unverified).
- `Lfm2MoeForCausalLM` (LFM2.5-8B-A1B, LFM2.5-24B-A2B) is **not** in MAX's catalog.

**LFM3: no, not today.**
- MAX has no `Lfm3ForCausalLM`. Neither the cached catalog nor the installed nightly has it, and GitHub search finds
  no LFM3 PR in [modular/modular](https://github.com/modular/modular).
- omxconsole's port path (`mxc port`, `port_auto.py`) would pick `Lfm2ForCausalLM` as the donor (closest name). But
  `needs_remote_code()` **parks the port before any agent time is spent**: LFM3's config has an `auto_map` and
  `model_type: "lfm3"`, which the installed transformers (5.12.1, which has only `lfm2`, `lfm2_moe` and `lfm2_vl`)
  doesn't know, and "max serve won't run remote code" (EXAONE's earlier failure).
- That stops being true once transformers ships LFM3:
  [huggingface/transformers#50036](https://github.com/huggingface/transformers/pull/50036) ("Add the LFM3 family") and
  [#50035](https://github.com/huggingface/transformers/pull/50035) (conv kernel prerequisites) are open, and the latest
  release is v5.21.0 (2026-10-26).
- **How hard the port is, once allowed.** It's a moderate job. Sliding-window and global attention exist in MAX (gemma3
  does the 5:1 local/global pattern), and LFM2's conv block and conv-state cache are the donor. The new parts are kernel
  size 7, head-wise gated attention, partial RoPE on global layers only, and sandwich norm. omxconsole's history is
  8 ports done, 9 failed and 7 cancelled (`~/.mxc/mst.db`, table `ports`), all on simpler dense or MoE transformers.
  None was a hybrid with a recurrent-style state cache, so expect several attempts.
- **Tool calls are the easy part.** MAX's `qwen3_5` tool parser (`max/pipelines/architectures/qwen3_5/tool_parser.py`)
  parses exactly `<tool_call><function=…><parameter=…>`, with JSON for non-string values, streamed per parameter. A
  ported `SupportedArchitecture` can set `tool_parser="qwen3_5"` (the field exists and is how qwen3_5 sets it),
  assuming the "superset" adds nothing our one tool needs.

## 6. Alternatives behind the same OpenAI-style endpoint

| Runtime | LFM3 status (2026-10-27) | Tool calls → OpenAI `tool_calls` |
|---|---|---|
| **llama.cpp** | **merged today**: [#31252](https://github.com/ggml-org/llama.cpp/pull/31252) "add LiquidAI/LFM3-1.7B and LFM3-VL-2B" (merge 19cce69, 16:06 UTC), "verified against the reference HF implementation (… tool calls, structured output …)", with `models/templates/LFM3.jinja` and `tests/test-chat.cpp` changed. Release builds after the merge (e.g. [b11946](https://github.com/ggml-org/llama.cpp/releases/tag/b11946)) include it. GGUFs: [LFM3-1.7B-GGUF](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF), from Q4_0 at 1.05 GB to BF16 at 3.47 GB | yes, per the PR (run `llama-server --jinja` for template-driven tool calls; check it) |
| Ollama | the card gives `ollama run hf.co/LiquidAI/LFM3-1.7B-GGUF:Q4_K_M`; needs a llama.cpp new enough to have LFM3 | unverified |
| SGLang | the blog's throughput numbers use SGLang; model support [#46858](https://github.com/sgl-project/sglang/pull/46858) still **open**, cookbook [#46859](https://github.com/sgl-project/sglang/pull/46859) merged | presumably `qwen3_coder`; unverified |
| vLLM | the card lists vLLM, but GitHub search finds no merged LFM3 PR (an `lfm2` tool parser exists: [#39243](https://github.com/vllm-project/vllm/pull/39243)) | unverified |
| MLX (Mac) | [LFM3-1.7B-MLX-4bit](https://huggingface.co/LiquidAI/LFM3-1.7B-MLX-4bit) published; [mlx-lm#2016](https://github.com/ml-explore/mlx-lm/pull/2016) "Add LFM3 Support" still **open** | unverified |

**Putting it behind 11435:** omxconsole's gateway (`gateway.py`) forwards `/v1/chat/completions` only to models its
supervisor starts with `max serve`, and it has no "external upstream" model kind. Two options:
(a) point the demo straight at llama-server (`AGUI_LLM_BASE_URL=http://127.0.0.1:8080/v1`; agentchat already reads
any OpenAI-style API), or (b) add an "external OpenAI upstream" model kind to omxconsole. Option (b) changes
mxconsole, so it is the owner's call, not ours.

## 7. Hardware

- **RTX 3090 (24 GB): far more than enough.** bf16 weights are 3.47 GB (the BF16 GGUF size), and the KV cache is
  1.6 GB at 128K ([blog](https://www.liquid.ai/blog/lfm3)). MAX would need free VRAM above omxconsole's
  `MIN_FREE_GPU_MB = 4096` and runs with `--no-device-graph-capture` on this card (`supervisor.py`). There's room left
  for omxplorer's GPU work.
- **Mac:** llama.cpp with Metal (Q4_K_M is 1.1 GB; Liquid says it ran Q4_0 on an M4 Max, "about 1 GB at 4-bit"), or
  MLX once mlx-lm#2016 lands. Any Apple-silicon Mac with 8 GB should do. Not checked: whether MAX serves LFM2/LFM3 on
  Apple GPUs.

## 8. Recommendation: go, in this order

1. **Demo now (no change to mxconsole):** a llama.cpp build from after 19cce69, then
   `llama-server -hf LiquidAI/LFM3-1.7B-GGUF:Q8_0 --jinja`, then agentchat with
   `AGUI_LLM_BASE_URL=http://127.0.0.1:8080/v1 AGUI_LLM_MODEL=LFM3-1.7B`. Turn thinking off (or strip `<think>`) and
   use temperature 0.1. **Prove it works** by running agentchat's `ui` scenario prompts live and counting accepted and
   refused `render_ui` calls against `qwen2.5-0.5b` on the same prompts. Do that before calling it a flagship. Same
   setup on the Mac.
2. **Today on MAX, as a fallback:** `LiquidAI/LFM2.5-2.6B` or `LFM2.5-1.2B-Instruct` through omxconsole. It runs
   natively, but tool calls come back as plain text (no LFM2 parser in MAX), so it leans on agentchat's text-lifting.
   That makes a weaker demo.
3. **The "all Modular" story (later):** when transformers releases LFM3 (#50036), run `mxc port LiquidAI/LFM3-1.7B`
   (donor `Lfm2ForCausalLM`, `tool_parser="qwen3_5"`), or wait for Modular to ship it. Then the demo runs on
   11435 unchanged. Until then, don't let the demo depend on MAX.

**No-go conditions:** if the live count in step 1 shows nested `ui` objects routinely broken inside `<parameter=ui>`,
flatten `render_ui`'s schema (e.g. pass `ui` as a JSON string) or use a larger local model. Liquid itself warns against
"complex multi-step reasoning". For a showcase sold to companies with $10M+ revenue, the licence needs a deal with
Liquid.
