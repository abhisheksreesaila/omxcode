"""A delaying TCP proxy in front of the web server: every connection the page opens (HTTP, long-polls, WebSockets) goes
through one shared link per direction, as on a real network: each chunk leaves when the link is free (bandwidth) and
lands half the round trip later (latency); a new connection pays one round trip before it carries anything (the TCP
handshake). Runs on its own thread and event loop.

    with Proxy(target_port, rtt_ms=100, down_mbit=10, up_mbit=5) as px:   # px.url → http://127.0.0.1:<port>/
        ...; px.bytes_down, px.bytes_up
"""

import asyncio
import socket
import threading
import time

CHUNK = 16384


class Link:
    """One direction: bytes leave one after another at `rate` bytes/s and arrive `delay` s later."""

    def __init__(self, rate, delay):
        self.rate, self.delay, self.free_at, self.bytes = rate, delay, 0.0, 0

    def landing(self, n, now):
        start = max(now, self.free_at)
        self.free_at = start + n / self.rate
        self.bytes += n
        return self.free_at + self.delay


class Proxy:
    def __init__(self, target_port, rtt_ms=100, down_mbit=10, up_mbit=5, host="127.0.0.1"):
        self.target = (host, target_port)
        self.down = Link(down_mbit * 1e6 / 8, rtt_ms / 2000)
        self.up = Link(up_mbit * 1e6 / 8, rtt_ms / 2000)
        self.rtt = rtt_ms / 1000
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.port}/"
        self.connections = 0
        self.loop = asyncio.new_event_loop()
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True, name="g62-proxy")

    @property
    def bytes_down(self):
        return self.down.bytes

    @property
    def bytes_up(self):
        return self.up.bytes

    def __enter__(self):
        self.thread.start()
        self.ready.wait(10)
        return self

    def __exit__(self, *exc):
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(timeout=10)

    def _run(self):
        asyncio.set_event_loop(self.loop)
        server = self.loop.run_until_complete(asyncio.start_server(self._client, "127.0.0.1", self.port))
        self.ready.set()
        try:
            self.loop.run_forever()
        finally:
            server.close()

    async def _client(self, creader, cwriter):
        self.connections += 1
        await asyncio.sleep(self.rtt)  # (the handshake: SYN, SYN-ACK)
        try:
            sreader, swriter = await asyncio.open_connection(*self.target)
        except OSError:
            cwriter.close()
            return
        await asyncio.gather(self._pump(creader, swriter, self.up), self._pump(sreader, cwriter, self.down), return_exceptions=True)

    async def _pump(self, reader, writer, link):
        """Copies reader to writer through link, in order: a queue of (landing time, bytes) drained by its own task."""
        queue = asyncio.Queue()

        async def deliver():
            while True:
                at, data = await queue.get()
                if data is None:
                    break
                wait = at - time.perf_counter()
                if wait > 0:
                    await asyncio.sleep(wait)
                try:
                    writer.write(data)
                    await writer.drain()
                except (ConnectionError, OSError):
                    break
            try:
                writer.close()
            except Exception:
                pass

        task = asyncio.ensure_future(deliver())
        try:
            while True:
                data = await reader.read(CHUNK)
                if not data:
                    break
                queue.put_nowait((link.landing(len(data), time.perf_counter()), data))
        except (ConnectionError, OSError):
            pass
        queue.put_nowait((link.landing(0, time.perf_counter()), None))
        await task
