# The gateway's token meter (spec §6): a streamed reply's SSE events counted (usage when the upstream sent one), a JSON
# reply's usage read. (prompt_tokens, completion_tokens, estimated); -1 for unknown.

from mojoui.json import Json, J_OBJECT, J_NUMBER, J_STRING, J_ARRAY


def _truthy(j: Json, n: Int) -> Bool:
    if n < 0:
        return False
    if j.kind(n) == J_STRING:
        return j.text(n) != ""
    if j.kind(n) == J_ARRAY:
        return j.size(n) > 0
    return False


def meter(text: String, streamed: Bool) -> Tuple[Int, Int, Bool]:
    var prompt = -1
    var completion = -1
    if not streamed:
        try:
            var j = Json.parse(text)
            var u = j.get(0, "usage")
            if u >= 0 and j.kind(u) == J_OBJECT:
                var p = j.get(u, "prompt_tokens")
                var c = j.get(u, "completion_tokens")
                prompt = j.number(p) if p >= 0 and j.kind(p) == J_NUMBER else -1
                completion = j.number(c) if c >= 0 and j.kind(c) == J_NUMBER else -1
        except:
            pass
        return (prompt, completion, False)
    var chunks = 0
    var usage_completion = -1
    for event in text.split("\n\n"):
        for line in String(event).split("\n"):
            var l = String(line)
            if not l.startswith("data:"):
                continue
            var data = String(String(l[byte = 5 :]).strip())
            if data == "[DONE]" or data == "":
                continue
            try:
                var j = Json.parse(data)
                var u = j.get(0, "usage")
                if u >= 0 and j.kind(u) == J_OBJECT:
                    var p = j.get(u, "prompt_tokens")
                    var c = j.get(u, "completion_tokens")
                    if p >= 0 and j.kind(p) == J_NUMBER:
                        prompt = j.number(p)
                    if c >= 0 and j.kind(c) == J_NUMBER:
                        usage_completion = j.number(c)
                var choices = j.get(0, "choices")
                var generated = False
                for k in range(j.size(choices) if choices >= 0 else 0):
                    var ch = j.at(choices, k)
                    if _truthy(j, j.get(ch, "text")):
                        generated = True
                    var d = j.get(ch, "delta")
                    if d >= 0 and (_truthy(j, j.get(d, "content")) or _truthy(j, j.get(d, "reasoning_content")) or _truthy(j, j.get(d, "reasoning")) or _truthy(j, j.get(d, "tool_calls"))):
                        generated = True
                if generated:
                    var tc = j.get(0, "token_count")
                    chunks += j.number(tc) if tc >= 0 and j.kind(tc) == J_NUMBER and j.number(tc) > 0 else 1
            except:
                pass
    if usage_completion >= 0:
        return (prompt, usage_completion, False)
    return (prompt, chunks, True)
