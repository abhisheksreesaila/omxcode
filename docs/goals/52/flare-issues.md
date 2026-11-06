# Issues for Flare (filed 2026-11-05, owner: "we can log tickets for flare")

Filed: https://github.com/ehsanmok/flare/issues/46 (1), https://github.com/ehsanmok/flare/issues/47 (2),
https://github.com/ehsanmok/flare/issues/48 (3), each with a Flare-only repro run first (no mojoui).

## 1. Streamed requests still lose their body (v0.13.1)
Same as docs/goals/50/flare-issue.md, still true in v0.13.1: `HttpClient.send_streaming` / `post_streaming` over
HTTP/1.1 write only the request head; no Content-Length, no body. The fix we carry (vendor/patches/flare-0.13-stream-body.patch,
about 20 lines) passes `req.body` to `_stream_cleartext` / `_stream_tls`, writes `Content-Length`, then the body after the
head. h2 streams still drop a request body. Goal 52's M2 proves it on both the tag and the patch.

## 2. A way to keep serving loops off Mojo's runtime pool
v0.13 runs `num_workers >= 2` serving loops as AsyncRT pool tasks while leases last (`ThreadHandle.spawn_serving`).
Two effects in an app that does more than serve:
- the program can't end after `main` returns while a loop holds a pool worker (the runtime waits for pool tasks in
  `KGEN_CompilerRT_DestroyGlobals`), so a background server must be closed first;
- work the app puts on the pool from a request (`parallelize`, e.g. a dataframe engine's kernels) waited forever
  behind the serving loops (seen in gdb: the job in `AsyncRT_DeviceContext_synchronize`, the workers in `epoll_wait`),
  even with 20 of 24 workers free.
We hold every lease before serving (`asyncrt_try_lease()` until false), so Flare takes its own OS-thread path. The ask:
a `ServerConfig` switch (say `serving_threads = OS`) instead of an app reaching into `flare.runtime._asyncrt`.

## 3. (note) Multi-worker serve has a moment with no listener
`_serve_multicore` closes the listener `bind` made, then each worker binds its own `SO_REUSEPORT` listener: a client
that connects as soon as `serve` starts can be refused. mojoui waits for a worker's answer before `Server.start`
returns. Keeping the first listener until the workers have bound would close the gap.
