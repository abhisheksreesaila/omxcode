# Goal 50 M2: a small server on mojoui.serve, for the checks outside Mojo (curl, the OpenAI Python SDK):
#   build/serve_demo PORT
#   GET  /items/{id}?x=…            {"id", "x"} from the path and the query
#   POST /v1/chat/completions       an OpenAI-shaped chat: {"stream": true} streams chat.completion.chunk SSE events
#                                   word by word from a thread (a Pipe), then [DONE]; else one chat.completion
#   anything else                   404 {"error": …}
from std.sys import argv
from mojoui.serve import Server, Service, Req, Reply, Pipe, spawn
from mojoui.json import Json, json_string
from mojoui import libc

comptime WORDS = "Hello from a Mojo server, streamed one word at a time."


def chunk(model: String, text: String, finish: Bool) -> String:
    var delta = String("{}") if finish else '{"content": ' + json_string(text) + "}"
    return ('data: {"id": "chatcmpl-demo", "object": "chat.completion.chunk", "created": 0, "model": ' + json_string(model)
            + ', "choices": [{"index": 0, "delta": ' + delta + ', "finish_reason": ' + ('"stop"' if finish else "null") + "}]}\n\n")


def talk(addr: Int):
    """On its own thread: the words into the pipe, a little apart, as a model would."""
    var pipe = Pipe.at(addr)
    var words = WORDS.split(" ")
    for i in range(len(words)):
        if pipe.gone():
            break
        pipe.write(chunk("demo", (" " if i > 0 else "") + String(words[i]), False))
        _ = libc.poll(0, 0, 30)
    pipe.write(chunk("demo", "", True))
    pipe.write("data: [DONE]\n\n")
    pipe.close()
    pipe.release()


struct Demo(Service):
    var served: Int

    def __init__(out self):
        self.served = 0

    def tick(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        self.served += 1
        if req.matches("GET", "/items/{id}"):
            return Reply.json('{"id": ' + json_string(req.param("id")) + ', "x": ' + json_string(req.arg("x")) + ', "served": ' + String(self.served) + "}")
        if req.matches("POST", "/v1/chat/completions"):
            var stream = False
            try:
                var j = Json.parse(req.body)
                stream = j.flag(j.get(0, "stream"))
            except:
                return Reply.error(400, "the body isn't JSON", "bad_json")
            if not stream:
                return Reply.json('{"id": "chatcmpl-demo", "object": "chat.completion", "created": 0, "model": "demo", "choices": [{"index": 0, "message": {"role": "assistant", "content": ' + json_string(WORDS) + '}, "finish_reason": "stop"}]}')
            var pipe = Pipe()
            var reply = Reply.stream(pipe)
            if not spawn[talk](pipe.share().addr):
                pipe.close()
            pipe.release()
            return reply^
        return Reply.not_found()


def main() raises:
    var port = 8790
    if len(argv()) > 1:
        port = atol(argv()[1])
    print("serve_demo on 127.0.0.1:" + String(port))
    Server.run(Demo(), port, workers=4)
