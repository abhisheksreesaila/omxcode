# Draft issue for ehsanmok/flare (not filed): send_streaming drops the request body

Flare v0.12.0 (and v0.13 reads the same): `HttpClient.send_streaming(req)` serialises only the request head
(`_stream_head_wire`) and writes it; `req.body` is never written and no Content-Length is sent, so a POST through
`send_streaming` or `post_streaming(url, body)` arrives with an empty body (MAX's server: 400 "Missing JSON";
uvicorn logs "Invalid HTTP request"). Seen on the wire (cleartext):
`POST /v1/chat/completions HTTP/1.1 / Host / content-type / user-agent: flare/0.12.0 / accept-encoding / Connection: close`, then nothing.
The fix we carry (vendor/patches/flare-0.12-stream-body.patch): pass `req.body` to `_stream_cleartext` / `_stream_tls`,
add `Content-Length` to the head (always for POST/PUT/PATCH), write the body after the head on the HTTP/1.1 paths. The h2
paths (`_stream_h2`) still drop it. Found 2026-11-04 proxying chat completions to `max serve`.
