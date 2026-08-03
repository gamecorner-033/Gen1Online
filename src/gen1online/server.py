"""HTTP transport layer: threaded TCP server, request handler, routing and entry point."""

import http.server
import json
import socketserver
import time

from gen1online import config, gts, realtime
from gen1online.ratelimit import RateLimiter
from gen1online.storage import Storage

POST_HANDLERS = {
    "sync_pos": realtime.sync_pos,
    "send_challenge": realtime.send_challenge,
    "clear_challenge": realtime.clear_challenge,
    "send_battle_msg": realtime.send_battle_msg,
    "poll_battle_msgs": realtime.poll_battle_msgs,
    "clear_battle_room": realtime.clear_battle_room,
    "log_trade_receipt": gts.log_trade_receipt,
    "update_profile": gts.update_profile,
    "deposit": gts.deposit,
    "trade": gts.trade,
    "withdraw": gts.withdraw,
    "claim": gts.claim,
}


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


class GTSHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    @property
    def storage(self):
        return self.server.storage

    @property
    def rate_limiter(self):
        return self.server.rate_limiter

    def get_real_ip(self):
        cf_ip = self.headers.get("CF-Connecting-IP")
        if cf_ip:
            return cf_ip
        xf_ip = self.headers.get("X-Forwarded-For")
        if xf_ip:
            return xf_ip.split(",")[0].strip()
        return self.client_address[0]

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _query_param(self, name):
        if "?" not in self.path:
            return None
        for p in self.path.split("?")[1].split("&"):
            if p.startswith(name + "="):
                return p.split("=")[1]
        return None

    def do_GET(self):
        client_ip = self.get_real_ip()
        if not self.rate_limiter.allowed(client_ip):
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        self.storage.self_clean_db()

        if self.path == "/gts/browse" or self.path == "/gts" or self.path == "/":
            status, payload = gts.browse(self.storage)
        elif self.path.startswith("/gts/players"):
            status, payload = realtime.players(self.storage)
        elif self.path.startswith("/gts/profile"):
            status, payload = gts.profile(self.storage, self._query_param("trainerId"))
        elif self.path.startswith("/gts/claims"):
            status, payload = gts.claims(self.storage, self._query_param("trainerId"))
        else:
            status, payload = 404, {"error": "Endpoint not found"}
        self._send_json(payload, status)

    def do_POST(self):
        client_ip = self.get_real_ip()
        if not self.rate_limiter.allowed(client_ip):
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        try:
            req = json.loads(body)
        except Exception:
            self._send_json({"error": "Invalid JSON"}, status=400)
            return

        action = req.get("action")
        handler = POST_HANDLERS.get(action)
        if handler is None:
            self._send_json({"error": "Unknown action"}, status=400)
            return

        now = int(time.time())
        status, payload = handler(self.storage, now, req)
        self._send_json(payload, status)


def run_server():
    storage = Storage()
    storage.init_db()
    storage.load_db()
    storage.self_clean_db()

    with ThreadedTCPServer((config.HOST, config.PORT), GTSHandler) as httpd:
        httpd.storage = storage
        httpd.rate_limiter = RateLimiter()
        print("======================================================")
        print(f"  Gen1Online Fast High-Performance Server (Port {config.PORT})")
        print(f"  Live Network Challenges: ENABLED (PVP & Link Trade)")
        print(f"  Guaranteed Challenge Delivery: ENABLED")
        print(f"  Multi-Room Lockstep Battle System: ENABLED")
        print(f"  In-Memory Position Sync: ENABLED (<1ms latency)")
        print(f"  PostgreSQL persistence: ENABLED ({config.DB_URI})")
        print("======================================================")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[GTS Cloud Server] Shutting down gracefully...")


if __name__ == "__main__":
    run_server()
