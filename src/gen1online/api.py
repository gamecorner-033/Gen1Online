"""FastAPI transport layer: app factory, middleware, dependencies and routing.

Replaces the stdlib ``http.server`` transport while keeping the wire contract
frozen — every POST goes to ``/gts`` (or ``/gts/admin``) with a JSON ``action``
body, GET paths are unchanged, and only HTTP 200 responses are trusted by the
mod client. Application handlers (``gts``, ``realtime``, ``admin``, ``stats``)
still return ``(status_code, payload)`` tuples and are left untouched. Schema
validation is lenient and non-blocking for game actions (log-and-continue so a
payload mismatch can never silently break a client feature); admin actions
still 400 on validation failure.
"""

import json
import logging
import secrets
import time
import traceback
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, PlainTextResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool
from starlette.middleware.base import BaseHTTPMiddleware

from gen1online import admin, config, gts, realtime, stats as stats_mod
from gen1online.metrics import METRICS, render_prometheus
from gen1online.ratelimit import RateLimiter
from gen1online.schemas import ACTION_MODELS, ADMIN_ACTION_MODEL
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


class ApiError(Exception):
    """Carry an exact JSON payload + HTTP status to the response."""

    def __init__(self, status, payload):
        self.status = status
        self.payload = payload
        super().__init__(str(payload))


def get_real_ip(request):
    cf_ip = request.headers.get("CF-Connecting-IP")
    if cf_ip:
        return cf_ip
    xf_ip = request.headers.get("X-Forwarded-For")
    if xf_ip:
        return xf_ip.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _send_result(status, payload):
    if 200 <= status < 300:
        return payload
    raise ApiError(status, payload)


bearer_scheme = HTTPBearer(auto_error=False)


def require_admin(request: Request, creds: HTTPAuthorizationCredentials | None = Depends(bearer_scheme)):
    if not config.ADMIN_TOKEN:
        raise ApiError(403, {"error": "Admin API disabled (ADMIN_TOKEN not set)"})
    if creds is None:
        raise ApiError(401, {"error": "Missing Authorization: Bearer token"})
    if not secrets.compare_digest(creds.credentials, config.ADMIN_TOKEN):
        raise ApiError(401, {"error": "Unauthorized"})


def get_storage(request: Request) -> Storage:
    storage = request.app.state.storage
    if storage is None:
        raise ApiError(503, {"error": "Server not ready"})
    return storage


async def _parse_json_body(request: Request):
    raw = (await request.body()).decode("utf-8", errors="replace")
    try:
        return json.loads(raw)
    except Exception:
        logger.warning(f"INVALID JSON ip={get_real_ip(request)} body={raw[:200]!r}")
        raise ApiError(400, {"error": "Invalid JSON"})


def _validate_action(action, body):
    """Light type-gating for docs/early warning. Never blocks a game action:
    the Lua client trusts only HTTP 200, so a rejection would silently kill a
    feature. Log the mismatch and let the defensive handler cope.
    """
    model = ACTION_MODELS.get(action)
    if model is None:
        return
    try:
        model(**body)
    except ValidationError as exc:
        logger.warning(f"VALIDATION WARNING action={action} trainerId={body.get('trainerId')!r} "
                       f"detail={exc.errors()[0]!r} (request still processed)")


def _dispatch_post(request, body, storage):
    action = body.get("action")
    handler = POST_HANDLERS.get(action)
    if handler is None:
        logger.warning(f"UNKNOWN ACTION ip={get_real_ip(request)} action={action!r}")
        raise ApiError(400, {"error": "Unknown action"})
    _validate_action(action, body)
    request.state.metrics_action = action
    request.state.debug_trainer = body.get("trainerId") or body.get("fromId") or body.get("buyerId")
    return _send_result(*handler(storage, int(time.time()), body))


def _dispatch_admin(request, body, storage):
    action = body.get("action")
    handler = ADMIN_POST_HANDLERS.get(action)
    if handler is None:
        logger.warning(f"UNKNOWN ADMIN ACTION ip={get_real_ip(request)} action={action!r}")
        raise ApiError(400, {"error": "Unknown admin action"})
    try:
        ADMIN_ACTION_MODEL(**body)
    except ValidationError as exc:
        logger.warning(f"VALIDATION FAILED admin action={action} detail={exc.errors()[0]!r}")
        raise ApiError(400, {"error": "Invalid request body"})
    request.state.metrics_action = f"admin/{action}"
    return _send_result(*handler(storage, int(time.time()), body))


class RateLimitMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        ip = get_real_ip(request)
        if not request.app.state.rate_limiter.allowed(ip):
            logger.warning(f"RATE LIMIT EXCEEDED ip={ip} method={request.method} path={request.url.path}")
            METRICS.inc_counter("rate_limited_total", {"method": request.method})
            request.state.rate_limited = True
            return JSONResponse({"error": "RATE LIMIT EXCEEDED"}, status_code=429)
        return await call_next(request)


class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if request.method == "GET" and request.app.state.storage is not None:
            await run_in_threadpool(request.app.state.storage.self_clean_db)
        response = await call_next(request)
        if getattr(request.state, "rate_limited", False):
            return response
        action = getattr(request.state, "metrics_action", None)
        if request.method == "GET" and action is None:
            action = request.url.path
        elif (
            request.method == "POST"
            and action is None
            and request.url.path.startswith("/gts/admin")
            and response.status_code in (401, 403)
        ):
            action = "admin"
        if action is None:
            return response
        METRICS.inc_counter("http_requests_total", {
            "method": request.method,
            "action": action,
            "status": str(response.status_code),
        })
        if request.method == "POST":
            logger.debug(f"POST action={action} ip={get_real_ip(request)} status={response.status_code} "
                         f"trainerId={getattr(request.state, 'debug_trainer', None)!r}")
        else:
            logger.debug(f"GET {request.url.path} ip={get_real_ip(request)} status={response.status_code}")
        return response


@asynccontextmanager
async def lifespan(app: FastAPI):
    storage = Storage()
    storage.init_db()
    storage.load_db()
    storage.self_clean_db()
    app.state.storage = storage
    logger.info(f"PostgreSQL persistence: ENABLED ({config.DB_URI})")
    yield
    app.state.storage = None


def create_app() -> FastAPI:
    app = FastAPI(
        title="Gen1Online GTS & MMO Server",
        version="0.1.0",
        lifespan=lifespan,
        openapi_tags=[
            {"name": "Game Client", "description": "Endpoints called by the mod client (LÖVE background thread). "
                                                   "POST /gts dispatches by the JSON `action` field; only HTTP 200 responses are trusted."},
            {"name": "Admin", "description": "Token-gated moderation endpoints (Authorization: Bearer <ADMIN_TOKEN>). "
                                             "Returns 403 when ADMIN_TOKEN is unset."},
            {"name": "Monitoring", "description": "Public health, stats and Prometheus metrics."},
            {"name": "Fallback", "description": "Catch-all routes: unknown GET paths return 404; any POST path still "
                                                "dispatches by `action` for legacy compatibility."},
        ],
    )
    app.state.storage = None
    app.state.rate_limiter = RateLimiter()

    app.add_middleware(MetricsMiddleware)
    app.add_middleware(RateLimitMiddleware)
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

    @app.exception_handler(ApiError)
    async def api_error_handler(request: Request, exc: ApiError):
        return JSONResponse(exc.payload, status_code=exc.status)

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception):
        logger.error(f"Unhandled error on {request.method} {request.url.path}:\n"
                     f"{''.join(traceback.format_exception(exc))}")
        return JSONResponse({"error": "Internal server error"}, status_code=500)

    # --- GET routes -------------------------------------------------------

    @app.get("/healthz", tags=["Monitoring"])
    def healthz(request: Request, storage: Storage = Depends(get_storage)):
        try:
            with storage.connect() as conn:
                conn.execute("SELECT 1")
            return {"status": "ok"}
        except Exception:
            logger.warning(f"HEALTHZ DB PING FAILED:\n{traceback.format_exc()}")
            raise ApiError(503, {"status": "degraded"})

    @app.get("/metrics", tags=["Monitoring"])
    def metrics_view(request: Request, storage: Storage = Depends(get_storage)):
        return PlainTextResponse(render_prometheus(storage),
                                 media_type="text/plain; version=0.0.4; charset=utf-8")

    @app.get("/gts/stats", tags=["Monitoring"])
    def gts_stats(request: Request, storage: Storage = Depends(get_storage)):
        return _send_result(*stats_mod.stats(storage))

    @app.get("/gts/browse", tags=["Game Client"])
    @app.get("/gts", tags=["Game Client"])
    @app.get("/", tags=["Game Client"])
    def gts_browse(request: Request, storage: Storage = Depends(get_storage)):
        return _send_result(*gts.browse(storage))

    @app.get("/gts/players", tags=["Game Client"])
    def gts_players(request: Request, storage: Storage = Depends(get_storage)):
        return _send_result(*realtime.players(storage))

    @app.get("/gts/profile", tags=["Game Client"])
    def gts_profile(request: Request, storage: Storage = Depends(get_storage)):
        return _send_result(*gts.profile(storage, request.query_params.get("trainerId")))

    @app.get("/gts/claims", tags=["Game Client"])
    def gts_claims(request: Request, storage: Storage = Depends(get_storage)):
        return _send_result(*gts.claims(storage, request.query_params.get("trainerId")))

    @app.get("/gts/admin/players", tags=["Admin"])
    def admin_players_view(request: Request, storage: Storage = Depends(get_storage),
                           _: None = Depends(require_admin)):
        return _send_result(*admin.admin_players(storage))

    @app.get("/gts/admin/bans", tags=["Admin"])
    def admin_bans_view(request: Request, storage: Storage = Depends(get_storage),
                        _: None = Depends(require_admin)):
        return _send_result(*admin.admin_bans(storage))

    @app.get("/gts/admin/announcement", tags=["Admin"])
    def admin_announcement_view(request: Request, storage: Storage = Depends(get_storage),
                                _: None = Depends(require_admin)):
        return _send_result(*admin.admin_announcement(storage))

    @app.get("/gts/admin", tags=["Admin"])
    @app.get("/gts/admin/{tail:path}", tags=["Admin"])
    def admin_unknown_view(request: Request, _: None = Depends(require_admin)):
        raise ApiError(404, {"error": "Unknown admin view"})

    @app.get("/{path:path}", tags=["Fallback"])
    def get_not_found(request: Request):
        raise ApiError(404, {"error": "Endpoint not found"})

    # --- POST routes ------------------------------------------------------

    @app.post("/gts", tags=["Game Client"])
    def post_gts(request: Request, body: dict = Depends(_parse_json_body),
                 storage: Storage = Depends(get_storage)):
        return _dispatch_post(request, body, storage)

    @app.post("/gts/admin", tags=["Admin"])
    @app.post("/gts/admin/{tail:path}", tags=["Admin"])
    def post_admin(request: Request, body: dict = Depends(_parse_json_body),
                   storage: Storage = Depends(get_storage), _: None = Depends(require_admin)):
        return _dispatch_admin(request, body, storage)

    # Preserve the legacy quirk where any POST path dispatches by `action`.
    @app.post("/{path:path}", tags=["Fallback"])
    def post_any(request: Request, body: dict = Depends(_parse_json_body),
                 storage: Storage = Depends(get_storage)):
        return _dispatch_post(request, body, storage)

    return app
