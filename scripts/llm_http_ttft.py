"""Time to first token of a chat through an OpenAI-style HTTP server (llama-server), for tests/test_llm.mojo's in-process
comparison (goal 72 M1). The same messages go `runs` times (the first warms the server's prompt cache); the time is from
sending the request to the first content or reasoning delta of the stream.

    pixi run python -I scripts/llm_http_ttft.py <messages.json> [url] [runs]      ->  {"ttft_ms": [...]}  on stdout
"""
import json
import sys
import time
import urllib.request


def ttft(url, messages, tools):
    body = {"model": "x", "messages": messages, "stream": True, "max_tokens": 2, "temperature": 0.7,
            "chat_template_kwargs": {"enable_thinking": False}}
    if tools:
        body["tools"] = tools
    req = urllib.request.Request(url + "/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=120) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            delta = json.loads(line[5:])["choices"][0].get("delta", {})
            if delta.get("content") or delta.get("reasoning_content"):
                ms = (time.perf_counter() - t0) * 1000
                for _ in r:  # drain, so the server finishes the request
                    pass
                return ms
    return -1.0


def main():
    spec = json.load(open(sys.argv[1]))
    url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8181"
    runs = int(sys.argv[3]) if len(sys.argv) > 3 else 5
    out = [ttft(url, spec["messages"], spec.get("tools")) for _ in range(runs)]
    print(json.dumps({"ttft_ms": out}))


main()
