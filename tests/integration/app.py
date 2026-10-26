"""Backend on the client for tests/check_integration.sh."""

from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"hello from the client\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.send_response(400 if self.path.startswith("/api/auth/login") else 200)
        self.send_header("Content-Length", "0")
        self.end_headers()


HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
