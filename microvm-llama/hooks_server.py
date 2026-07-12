#!/usr/bin/env python3
"""MicroVM image/runtime hooks for llama-server readiness (POST endpoints)."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOOKS_PORT = int(os.environ.get("HOOKS_PORT", "8090"))
LLAMA_HEALTH_URL = os.environ.get("LLAMA_HEALTH_URL", "http://127.0.0.1:8080/health")

READY_PATH = "/aws/lambda-microvms/runtime/v1/ready"
VALIDATE_PATH = "/aws/lambda-microvms/runtime/v1/validate"
RUN_PATH = "/aws/lambda-microvms/runtime/v1/run"
RESUME_PATH = "/aws/lambda-microvms/runtime/v1/resume"
SUSPEND_PATH = "/aws/lambda-microvms/runtime/v1/suspend"
TERMINATE_PATH = "/aws/lambda-microvms/runtime/v1/terminate"


def llama_ready() -> bool:
    try:
        with urllib.request.urlopen(LLAMA_HEALTH_URL, timeout=2) as resp:
            if resp.status != 200:
                return False
            body = resp.read()
            try:
                payload = json.loads(body.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                return True
            status = payload.get("status")
            if status is None:
                return True
            return status in ("ok", "OK", "healthy", "ready")
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


class HooksHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[hooks] {self.address_string()} - {fmt % args}", flush=True)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _respond(self, code: int, body: bytes = b"") -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        _ = self._read_body()

        if path in (READY_PATH, VALIDATE_PATH):
            if llama_ready():
                self._respond(200, b'{"status":"ok"}')
            else:
                # Return 503 immediately so Lambda can retry until timeout.
                self._respond(503, b'{"status":"not ready"}')
            return

        if path in (RUN_PATH, RESUME_PATH, SUSPEND_PATH, TERMINATE_PATH):
            self._respond(200, b'{"status":"ok"}')
            return

        self._respond(404, b'{"error":"not found"}')

    def do_GET(self) -> None:
        # Convenience for local debugging; Lambda uses POST.
        self.do_POST()


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", HOOKS_PORT), HooksHandler)
    print(f"[hooks] listening on 0.0.0.0:{HOOKS_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
