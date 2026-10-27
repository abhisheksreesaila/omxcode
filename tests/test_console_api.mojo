# examples/console/api.mojo chat_curl: the one curl the model page, Add a model's Ready card and Security show, as the
# original writes each; a name goes through json_string and a ' can't leave the shell's quotes. Build with -I examples/console.
from std.testing import assert_equal
from api import chat_curl

comptime HEAD = "curl http://127.0.0.1:11435/v1/chat/completions \\\n  -H \"Authorization: Bearer $MXC_API_KEY\" \\\n  -H \"Content-Type: application/json\" \\\n"


def main() raises:
    var url = "http://127.0.0.1:11435/v1"
    assert_equal(chat_curl(url, "qwen2.5-0.5b", "hi"), HEAD + "  -d '{\"model\":\"qwen2.5-0.5b\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")
    assert_equal(chat_curl(url, "qwen2.5-1.5b", "Hello", spaced=True),
                 HEAD + "  -d '{\"model\": \"qwen2.5-1.5b\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'")
    assert_equal(chat_curl("https://ablearn.local:8443/v1", "<model>", "hi", cacert="/ca.crt"),
                 "curl --cacert /ca.crt https://ablearn.local:8443/v1/chat/completions \\\n  -H \"Authorization: Bearer $MXC_API_KEY\" \\\n"
                 + "  -H \"Content-Type: application/json\" \\\n  -d '{\"model\":\"<model>\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")
    assert_equal(chat_curl(url, "a\"b'; rm -rf ~; '", "hi"),
                 HEAD + "  -d '{\"model\":\"a\\\"b'\\''; rm -rf ~; '\\''\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'")
    print("console_api: ok")
