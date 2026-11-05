# consoled: omxconsole's daemon in Mojo (goal 50 M4–M5): the admin API the console's screens read and the OpenAI-shaped
# /v1 gateway in front of `max serve`, on the framework's pieces only: mojoui.serve (HTTP), mojoui.sqlite (the store,
# ~/.mxc/mst.db, the Python daemon's file and schema), mojoui.process (one `max serve` per loaded model), mojoui.hash.
#
#   MXC_HOME=~/.mxc MXC_PORT=11435 scripts/mojo_flare.sh build examples/consoled/main.mojo -o build/consoled && build/consoled
#
# Environment: MXC_HOME (the store's folder, default ~/.mxc), MXC_PORT (default 11435), MXC_ADMIN_KEY (the admin
# header's value; unset: "1", as the original accepts), MXC_IDLE_SECONDS (unload a model idle this long; default: the
# model's keep_alive), MXC_MAX (the max command, default "max").

from std.os import getenv
from mojoui.serve import Server
from daemon import Daemon, Config


def main() raises:
    var cfg = Config.from_env()
    var d = Daemon(cfg.copy())
    print("consoled on http://127.0.0.1:" + String(cfg.port) + " (store " + cfg.home + "/mst.db)")
    Server.run(d^, cfg.port, workers=8, tick_ms=1000)
