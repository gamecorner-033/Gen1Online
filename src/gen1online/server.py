"""HTTP transport layer: threaded TCP server, request handler, routing and entry point."""

import http.server
import json
import logging
import secrets
import socketserver
import time
import traceback

from gen1online import admin, config, gts, realtime, stats as stats_mod
from gen1online.logging_utils import setup_logging
from gen1online.metrics import METRICS, render_prometheus
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

ADMIN_POST_HANDLERS = {
    "kick": admin.admin_kick,
    "ban": admin.admin_ban,
    "unban": admin.admin_unban,
    "remove_listing": admin.admin_remove_listing,
    "announce": admin.admin_announce,
    "clear_announcement": admin.admin_clear_announcement,
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

    def _send_text(self, text, status=200, content_type="text/plain; charset=utf-8"):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
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

    def _admin_authorized(self):
        """Return (ok, status, payload). Empty ADMIN_TOKEN disables the admin API."""
        if not config.ADMIN_TOKEN:
            return False, 403, {"error": "Admin API disabled (ADMIN_TOKEN not set)"}
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False, 401, {"error": "Missing Authorization: Bearer token"}
        if secrets.compare_digest(auth[len("Bearer "):], config.ADMIN_TOKEN):
            return True, 200, None
        return False, 401, {"error": "Unauthorized"}

    def _healthz(self):
        try:
            with self.storage.connect() as conn:
                conn.execute("SELECT 1")
            return 200, {"status": "ok"}
        except Exception:
            logger.warning(f"HEALTHZ DB PING FAILED:\n{traceback.format_exc()}")
            return 503, {"status": "degraded"}

    def do_GET(self):
        client_ip = self.get_real_ip()
        if not self.rate_limiter.allowed(client_ip):
            logger.warning(f"RATE LIMIT EXCEEDED ip={client_ip} method=GET path={self.path}")
            METRICS.inc_counter("rate_limited_total", {"method": "GET"})
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        self.storage.self_clean_db()

        base_path = self.path.split("?")[0]
        status = 500
        payload = {"error": "Internal server error"}
        try:
            if base_path == "/healthz":
                status, payload = self._healthz()
                self._send_json(payload, status)
            elif base_path == "/metrics":
                self._send_text(render_prometheus(self.storage),
                                content_type="text/plain; version=0.0.4; charset=utf-8")
                status = 200
                payload = None
            elif base_path.startswith("/gts/admin"):
                ok, status, payload = self._admin_authorized()
                if ok:
                    if base_path == "/gts/admin/players":
                        status, payload = admin.admin_players(self.storage)
                    elif base_path == "/gts/admin/bans":
                        status, payload = admin.admin_bans(self.storage)
                    elif base_path == "/gts/admin/announcement":
                        status, payload = admin.admin_announcement(self.storage)
                    else:
                        status, payload = 404, {"error": "Unknown admin view"}
                    self._send_json(payload, status)
                else:
                    self._send_json(payload, status)
            elif base_path == "/gts/stats":
                status, payload = stats_mod.stats(self.storage)
                self._send_json(payload, status)
            elif base_path == "/gts/browse" or base_path == "/gts" or base_path == "/":
                status, payload = gts.browse(self.storage)
                self._send_json(payload, status)
            elif base_path.startswith("/gts/players"):
                status, payload = realtime.players(self.storage)
                self._send_json(payload, status)
            elif base_path.startswith("/gts/profile"):
                status, payload = gts.profile(self.storage, self._query_param("trainerId"))
                self._send_json(payload, status)
            elif base_path.startswith("/gts/claims"):
                status, payload = gts.claims(self.storage, self._query_param("trainerId"))
                self._send_json(payload, status)
            else:
                status, payload = 404, {"error": "Endpoint not found"}
                self._send_json(payload, status)
        except Exception:
            logger.error(f"Unhandled error on GET {self.path}:\n{traceback.format_exc()}")
            self._send_json({"error": "Internal server error"}, status=500)
            status = 500
            payload = None

        METRICS.inc_counter("http_requests_total", {"method": "GET", "action": base_path, "status": str(status)})
        logger.debug(f"GET {self.path} ip={client_ip} status={status}")

    def do_POST(self):
        client_ip = self.get_real_ip()
        if not self.rate_limiter.allowed(client_ip):
            logger.warning(f"RATE LIMIT EXCEEDED ip={client_ip} method=POST")
            METRICS.inc_counter("rate_limited_total", {"method": "POST"})
            self._send_json({"error": "RATE LIMIT EXCEEDED"}, status=429)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        try:
            req = json.loads(body)
        except Exception:
            logger.warning(f"INVALID JSON ip={client_ip} body={body[:200]!r}")
            self._send_json({"error": "Invalid JSON"}, status=400)
            return

        base_path = self.path.split("?")[0]
        is_admin = base_path == "/gts/admin" or base_path.startswith("/gts/admin/")

        if is_admin:
            ok, status, payload = self._admin_authorized()
            if not ok:
                self._send_json(payload, status)
                METRICS.inc_counter("http_requests_total", {"method": "POST", "action": "admin", "status": str(status)})
                return
            action = req.get("action")
            handler = ADMIN_POST_HANDLERS.get(action)
            if handler is None:
                logger.warning(f"UNKNOWN ADMIN ACTION ip={client_ip} action={action!r}")
                self._send_json({"error": "Unknown admin action"}, status=400)
                return
            now = int(time.time())
            try:
                status, payload = handler(self.storage, now, req)
            except Exception:
                logger.error(f"Unhandled error handling admin action={action} ip={client_ip}\n{traceback.format_exc()}")
                status, payload = 500, {"error": "Internal server error"}
            self._send_json(payload, status)
            METRICS.inc_counter("http_requests_total", {"method": "POST", "action": f"admin/{action}", "status": str(status)})
            logger.debug(f"POST admin action={action} ip={client_ip} status={status}")
            return

        action = req.get("action")
        handler = POST_HANDLERS.get(action)
        if handler is None:
            logger.warning(f"UNKNOWN ACTION ip={client_ip} action={action!r}")
            self._send_json({"error": "Unknown action"}, status=400)
            return

        now = int(time.time())
        try:
            status, payload = handler(self.storage, now, req)
        except Exception:
            logger.error(f"Unhandled error handling action={action} ip={client_ip}\n{traceback.format_exc()}")
            status, payload = 500, {"error": "Internal server error"}
        self._send_json(payload, status)
        METRICS.inc_counter("http_requests_total", {"method": "POST", "action": action, "status": str(status)})
        logger.debug(f"POST action={action} ip={client_ip} status={status} "
                     f"trainerId={req.get('trainerId') or req.get('fromId') or req.get('buyerId')!r}")


def run_server():
    setup_logging()
    logger.info(f"Log level: {config.LOG_LEVEL}")
    logger.info(f"Admin API: {'ENABLED' if config.ADMIN_TOKEN else 'DISABLED (set ADMIN_TOKEN to enable)'}")

    storage = Storage()
    storage.init_db()
    storage.load_db()
    storage.self_clean_db()

    with ThreadedTCPServer((config.HOST, config.PORT), GTSHandler) as httpd:
        httpd.storage = storage
        httpd.rate_limiter = RateLimiter()
        logger.info(f"Gen1Online Fast High-Performance Server (Port {config.PORT})")
        logger.info("Live Network Challenges: ENABLED (PVP & Link Trade)")
        logger.info("Guaranteed Challenge Delivery: ENABLED")
        logger.info("Multi-Room Lockstep Battle System: ENABLED")
        logger.info("In-Memory Position Sync: ENABLED (<1ms latency)")
        logger.info(f"PostgreSQL persistence: ENABLED ({config.DB_URI})")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            logger.info("Shutting down gracefully...")


if __name__ == "__main__":
    run_server()
