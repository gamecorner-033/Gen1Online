"""HTTP transport layer: threaded TCP server, request handler, routing and entry point."""

import http.server
import json
import logging
import socketserver
import time
import traceback

from gen1online import config, gts, realtime
from gen1online.logging_utils import setup_logging
from gen1online.ratelimit import RateLimiter
from gen1online.storage import Storage

logger = logging.getLogger(__name__)

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
            logger.warning("RATE LIMIT EXCEEDED ip=%s method=GET path=%s", client_ip, self.path)
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        self.storage.self_clean_db()

        try:
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
        except Exception:
            logger.error("Unhandled error on GET %s:\n%s", self.path, traceback.format_exc())
            status, payload = 500, {"error": "Internal server error"}
        self._send_json(payload, status)
        logger.debug("GET %s ip=%s status=%d", self.path, client_ip, status)

    def do_POST(self):
        client_ip = self.get_real_ip()
        if not self.rate_limiter.allowed(client_ip):
            logger.warning("RATE LIMIT EXCEEDED ip=%s method=POST", client_ip)
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        try:
            req = json.loads(body)
        except Exception:
            logger.warning("INVALID JSON ip=%s body=%r", client_ip, body[:200])
            self._send_json({"error": "Invalid JSON"}, status=400)
            return

        action = req.get("action")
        handler = POST_HANDLERS.get(action)
        if handler is None:
            logger.warning("UNKNOWN ACTION ip=%s action=%r", client_ip, action)
            self._send_json({"error": "Unknown action"}, status=400)
            return

        now = int(time.time())
        try:
            status, payload = handler(self.storage, now, req)
        except Exception:
            logger.error("Unhandled error handling action=%s ip=%s\n%s",
                         action, client_ip, traceback.format_exc())
            status, payload = 500, {"error": "Internal server error"}
        self._send_json(payload, status)
        logger.debug("POST action=%s ip=%s status=%d trainerId=%r",
                     action, client_ip, status, req.get("trainerId") or req.get("fromId") or req.get("buyerId"))


def run_server():
    setup_logging()
    logger.info("Log level: %s", config.LOG_LEVEL)

    storage = Storage()
    storage.init_db()
    storage.load_db()
    storage.self_clean_db()

    with ThreadedTCPServer((config.HOST, config.PORT), GTSHandler) as httpd:
        httpd.storage = storage
        httpd.rate_limiter = RateLimiter()
        logger.info("Gen1Online Fast High-Performance Server (Port %s)", config.PORT)
        logger.info("Live Network Challenges: ENABLED (PVP & Link Trade)")
        logger.info("Guaranteed Challenge Delivery: ENABLED")
        logger.info("Multi-Room Lockstep Battle System: ENABLED")
        logger.info("In-Memory Position Sync: ENABLED (<1ms latency)")
        logger.info("PostgreSQL persistence: ENABLED (%s)", config.DB_URI)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            logger.info("Shutting down gracefully...")


if __name__ == "__main__":
    run_server()
