# HTTP in mojoui (goal 33)

An app asks for a request in `update()`. The runtime sends it on a worker thread. The reply comes back to `update()`
later, as an `Event`. Nothing waits: not `update()`, not a frame.

## The API

```mojo
from mojoui import App, Event
from mojoui.http import Http, Request

struct Main(App):
    comptime HTTP = True              # this app sends requests (D-321)
    var http: Http                    # the outbox

    def update(mut self, e: Event):
        if e.message == LOAD:
            self.http.send(Request.get(GOT, "http://127.0.0.1:8000/admin/models")
                .header_from_env("X-Mst-Admin", "MX_ADMIN").timeout(5000))
        elif e.message == GOT:
            if e.error != "": ...     # no reply: refused, timed out, https without TLS…
            else: ...                 # e.number = the status (a 500 too), e.text = the body

    def requests(mut self) -> List[Request]:
        return self.http.take()
```

- `Request.get(msg, url)`, `Request.post_json(msg, url, json)`, `Request(msg, method, url, body)`.
- `.header(name, value)`, `.header_from_env(name, variable)` (read on the worker when it's sent; unset: not sent),
  `.timeout(ms)` (the whole request; 30 s by default), `.tagged(id)` (comes back as `event.id`).
- The reply `Event`: `message` = the request's msg, `id`, `number` = status (0 when there's no reply), `text` = the
  body (bad UTF-8 becomes U+FFFD), `error` = why there's no reply.
- An app without `comptime HTTP = True` gets each request back at once as an error Event, and links no sockets.
- Timers live beside it: `def every(self) -> List[Every]` lists `Every(ms, msg)`; each tick is an Event with
  `number` = the tick's count. Ticks keep to the start's grid, so they don't drift (D-324).

## The seam

```
app ──Request──▶ Runtime (mojoui/app.mojo) ──start[Backend]──▶ worker thread ──Backend.send(req)──▶ server
app ◀──Event──── Runtime.poll ◀── the host's clock (wake_in) ◀── Response in the slot
```

- `mojoui/http.mojo`: `Request`, `Response`, `Http`, `Url`, and the `Transport` trait: one blocking
  `send(req) -> Response`. It knows nothing about sockets.
- `mojoui/http_socket.mojo`: `SocketTransport`, today's backend. HTTP/1.1 over libc sockets, IPv4, `http://` only,
  `Connection: close`, bodies by Content-Length, chunked or to the end. An `https://` URL comes back as the error
  "https needs a TLS backend (flare, Mojo ≥ 1.2)…", never a crash.
- `mojoui/effects.mojo`: `comptime Backend = SocketTransport`, the worker (`start`, `InFlight`), `Every`.

## Adding flare later

flare (ehsanmok/flare: HTTP/1–3, TLS) needs Mojo ≥ 1.2 and OpenSSL (D-310). When we move:

1. `mojoui/http_flare.mojo`: `struct FlareTransport(Transport)` whose `send` turns a `Request` into flare's request
   and its answer into a `Response` (status, lower-case headers, body bytes, or `error`).
2. In `mojoui/effects.mojo`: `comptime Backend = FlareTransport if is_defined["MOJOUI_FLARE"]() else SocketTransport`
   (or flare by default once it builds everywhere we ship).
3. `scripts/build.sh`: pass `-D MOJOUI_FLARE` and link OpenSSL for the apps that want it.

No app changes: apps only see `Request`, `Http` and the reply `Event`. tests/test_http.mojo runs against either.

## How replies reach update() on each host

- **GTK**: after every event the host asks `Runtime.wake_in` and arms one GLib timeout. While a request is out it
  polls every 4 ms below GTK's redraw priority, so frames never wait; timers fire at the default priority.
- **Web**: a clock thread in `mojoui/hosts/web.py` polls each tab's runtime when it's due. The page keeps one
  `/wait` long-poll open only while the app is busy (`#mojoui-busy`), then fetches `/pending`, as frames do.
- **Mac (AppKit)**: `performSelector:afterDelay:` on the host's target (`effectsDue:`). Built, not yet run on a Mac.
- iPhone and Android: not wired yet (out of goal 33's bounds). An app there gets no replies.

## Limits today

IPv4 and `localhost` only (IPv6 literals are refused), no TLS, no redirects followed, no keep-alive, no streaming
(the whole body arrives in one Event), a 256 MB cap, header values with a line break are refused.
