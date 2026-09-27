"""Tiny demo service. Standard library only, so the image has almost nothing to scan."""
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_VERSION = os.environ.get("APP_VERSION", "dev")
PORT = int(os.environ.get("PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"status": "ok"})
        elif self.path == "/":
            self._send(200, {
                "app": "eks-jenkins-lab",
                "version": APP_VERSION,
                "pod": socket.gethostname(),
            })
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        # Keep health checks out of the logs.
        if "/healthz" not in (args[0] if args else ""):
            super().log_message(fmt, *args)


if __name__ == "__main__":
    print(f"demo-app {APP_VERSION} listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
