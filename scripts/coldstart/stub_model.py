#!/usr/bin/env python3
"""A stub OpenAI-compatible model server.

Answers /v1/chat/completions instantly, streaming or not, and writes the
monotonic timestamp of every request it receives to a file. That file is the
measurement: the gap between "we spawned Hermes" and "Hermes asked a model
anything" is the runtime's cold start with the model taken out of it.
"""
import json
import os
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STAMPS = os.environ.get("STUB_STAMPS", "/tmp/stub-stamps")
REPLY = "Yes — you said you would call the dentist this morning."


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_a):
        pass

    def _stamp(self, what):
        with open(STAMPS, "a") as fh:
            fh.write("%.6f %s %s\n" % (time.time(), what, self.path))
            fh.flush()

    def do_GET(self):
        self._stamp("GET")
        if self.path.rstrip("/").endswith("/models"):
            body = json.dumps({"object": "list", "data": [
                {"id": "stub-model", "object": "model", "owned_by": "stub"}]}).encode()
        else:
            body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        self._stamp("POST")
        try:
            req = json.loads(raw or b"{}")
        except Exception:
            req = {}
        if req.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            chunk = {"id": "stub", "object": "chat.completion.chunk",
                     "created": int(time.time()), "model": "stub-model",
                     "choices": [{"index": 0, "delta": {"role": "assistant",
                                                        "content": REPLY},
                                  "finish_reason": None}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            done = dict(chunk)
            done["choices"] = [{"index": 0, "delta": {}, "finish_reason": "stop"}]
            self.wfile.write(b"data: " + json.dumps(done).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        body = json.dumps({
            "id": "stub", "object": "chat.completion", "created": int(time.time()),
            "model": "stub-model",
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": REPLY}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(sys.argv[1])
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("stub listening on %d" % port, flush=True)
    server.serve_forever()
