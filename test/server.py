"""HTTP server for the acurl integration tests.

Listens on an ephemeral port on 127.0.0.1 and prints the port on stdout.
Stateful endpoints take a KEY path segment so each test gets fresh state.
"""

import email.utils
import http.server
import json
import sys
import threading
import time
import urllib.parse

PAYLOAD = bytes(range(256)) * 400  # 102400 bytes, binary
COUNTS = {}
RANGES = {}
LOCK = threading.Lock()


def hit(key):
    with LOCK:
        COUNTS[key] = COUNTS.get(key, 0) + 1
        return COUNTS[key]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body=b"", headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def truncated(self, body):
        """Announce BODY but send only half of it, then drop the connection."""
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self.wfile.write(body[: len(body) // 2])
        self.wfile.flush()
        self.close_connection = True

    def ranged(self, key, body):
        rng = self.headers.get("Range")
        with LOCK:
            RANGES.setdefault(key, []).append(rng)
        if rng:
            start = int(rng.split("=")[1].split("-")[0])
            self.reply(206, body[start:], {
                "Content-Type": "application/octet-stream",
                "Content-Range": f"bytes {start}-{len(body) - 1}/{len(body)}",
                "Content-Disposition": 'attachment; filename="resumed.bin"',
            })
        else:
            self.reply(200, body, {"Content-Type": "application/octet-stream"})

    def handle_any(self):
        url = urllib.parse.urlsplit(self.path)
        parts = url.path.strip("/").split("/")
        query = dict(urllib.parse.parse_qsl(url.query))
        name, args = parts[0], parts[1:]
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length) if length else b""

        if name == "text":
            self.reply(200, "héllo wörld".encode(), {"Content-Type": "text/plain; charset=utf-8"})
        elif name == "latin1":
            self.reply(200, "héllo".encode("latin-1"), {"Content-Type": "text/plain; charset=iso-8859-1"})
        elif name == "binary":
            self.reply(200, PAYLOAD, {"Content-Type": "application/octet-stream"})
        elif name == "status":
            self.reply(int(args[0]), b"status body", {"Content-Type": "text/plain"})
        elif name == "redirect":
            n = int(args[0])
            target = f"/redirect/{n - 1}" if n > 1 else "/text"
            self.reply(302, b"", {"Location": target})
        elif name == "redirect-loop":
            self.reply(302, b"", {"Location": "/redirect-loop"})
        elif name == "echo":
            body = json.dumps({
                "method": self.command,
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": data.decode("utf-8", "replace"),
            }).encode()
            self.reply(200, body, {"Content-Type": "application/json"})
        elif name == "retry-after":
            # /retry-after/KEY/FORM: 503 with Retry-After once, then 200.
            key, form = args
            if hit(key) == 1:
                value = "1" if form == "seconds" else email.utils.formatdate(time.time() + 1, usegmt=True)
                self.reply(503, b"busy", {"Retry-After": value})
            else:
                self.reply(200, b"ok", {"Content-Type": "text/plain"})
        elif name == "fail-then-ok":
            # /fail-then-ok/KEY/N/STATUS: STATUS N times, then 200.
            key, n, status = args
            if hit(key) <= int(n):
                self.reply(int(status), b"fail")
            else:
                self.reply(200, b"ok", {"Content-Type": "text/plain"})
        elif name == "slow":
            time.sleep(float(args[0]))
            self.reply(200, b"slow", {"Content-Type": "text/plain"})
        elif name == "slow-once":
            key, delay = args
            if hit(key) == 1:
                time.sleep(float(delay))
            self.reply(200, b"fast", {"Content-Type": "text/plain"})
        elif name == "count":
            self.reply(200, str(COUNTS.get(args[0], 0)).encode())
        elif name == "ranges":
            self.reply(200, json.dumps(RANGES.get(args[0], [])).encode(), {"Content-Type": "application/json"})
        elif name == "resumable":
            # /resumable/KEY: first request truncated, then honors Range.
            key = args[0]
            if hit(key) == 1:
                with LOCK:
                    RANGES.setdefault(key, []).append(self.headers.get("Range"))
                self.truncated(PAYLOAD)
            else:
                self.ranged(key, PAYLOAD)
        elif name == "norange":
            # /norange/KEY: first request truncated, then ignores Range.
            key = args[0]
            with LOCK:
                RANGES.setdefault(key, []).append(self.headers.get("Range"))
            if hit(key) == 1:
                self.truncated(PAYLOAD)
            else:
                self.reply(200, PAYLOAD, {"Content-Type": "application/octet-stream"})
        elif name == "range416":
            # /range416/KEY: first request truncated, then rejects Range.
            key = args[0]
            with LOCK:
                RANGES.setdefault(key, []).append(self.headers.get("Range"))
            if hit(key) == 1:
                self.truncated(PAYLOAD)
            elif self.headers.get("Range"):
                self.reply(416, b"bad range", {"Content-Range": f"bytes */{len(PAYLOAD)}"})
            else:
                self.reply(200, PAYLOAD, {"Content-Type": "application/octet-stream"})
        elif name == "resume-503":
            # /resume-503/KEY: truncated, then 503 with Retry-After, then Range.
            key = args[0]
            n = hit(key)
            if n < 3:
                with LOCK:
                    RANGES.setdefault(key, []).append(self.headers.get("Range"))
            if n == 1:
                self.truncated(PAYLOAD)
            elif n == 2:
                self.reply(503, b"<html>busy</html>", {"Retry-After": "0"})
            else:
                self.ranged(key, PAYLOAD)
        elif name == "cd":
            self.reply(200, b"cd body", {
                "Content-Type": "application/octet-stream",
                "Content-Disposition": query["v"],
            })
        elif name == "files":
            self.reply(200, b"file body", {"Content-Type": "text/plain"})
        else:
            self.reply(404, b"not found")

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
