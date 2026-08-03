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

from fastapi import Depends, FastAPI, Query, Request
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


# --- Documentation helpers -------------------------------------------------

_STATUS_DESCRIPTIONS = {
    400: "Bad request: invalid JSON body, unknown action, or (admin) a schema validation failure.",
    401: "Unauthorized: missing or wrong Authorization: Bearer <ADMIN_TOKEN> header.",
    403: "Forbidden: admin API disabled (ADMIN_TOKEN unset) or trainer is KICKED/BANNED.",
    404: "Not found: unknown endpoint, or a listing/claim that no longer exists.",
    429: "Rate limit exceeded (2400 requests/min/IP).",
    500: "Internal server error (details logged server-side).",
    503: "Service unavailable: Postgres did not respond in time (healthz).",
}


def _doc_responses(*codes):
    """Prose-only error documentation. Never uses response_model (FastAPI would
    filter keys the client expects), so only descriptions are attached."""
    return {code: {"description": _STATUS_DESCRIPTIONS[code]} for code in codes}


POST_EXAMPLES = {
    "sync_pos": {
        "summary": "Heartbeat: publish position + receive near players/challenges/announcements",
        "value": {
            "action": "sync_pos",
            "trainerId": 45799,
            "name": "ASH",
            "title": "ROOKIE",
            "map": "VERIDIAN_CITY",
            "x": 12,
            "y": 8,
            "px": 192,
            "py": 128,
            "fx": 12,
            "fy": 7,
            "facing": "up",
            "moving": False,
            "species": "PIKACHU",
        },
    },
    "send_challenge": {
        "summary": "Send a PVP / link-trade / decline challenge to a trainer",
        "value": {
            "action": "send_challenge",
            "targetId": 12345,
            "fromId": 45799,
            "fromName": "ASH",
            "challengeType": "PVP",
            "roomId": "ROOM_45799_12345",
        },
    },
    "clear_challenge": {
        "summary": "Clear the trainer's pending challenge",
        "value": {"action": "clear_challenge", "trainerId": 45799},
    },
    "send_battle_msg": {
        "summary": "Deliver one FIFO battle message to the opponent in a room",
        "value": {"action": "send_battle_msg", "roomId": "ROOM_45799_12345", "targetId": 12345, "fromId": 45799, "msg": {"move": "TACKLE"}},
    },
    "poll_battle_msgs": {
        "summary": "Drain my FIFO inbox for a battle room (sent every frame)",
        "value": {"action": "poll_battle_msgs", "roomId": "ROOM_45799_12345", "myId": 45799},
    },
    "clear_battle_room": {
        "summary": "Destroy a battle room and drop all queued messages",
        "value": {"action": "clear_battle_room", "roomId": "ROOM_45799_12345"},
    },
    "log_trade_receipt": {
        "summary": "Record a link-trade receipt in the public history",
        "value": {"action": "log_trade_receipt", "trainerId": 45799, "text": "ASH TRADED PIKACHU TO MISTY FOR POLIWAG"},
    },
    "update_profile": {
        "summary": "Create/update the trainer's persistent profile",
        "value": {"action": "update_profile", "trainerId": 45799, "name": "ASH", "title": "POKéMON TRAINER", "badges": 8, "pokedexCount": 120, "gtsTrades": 3, "pvpWins": 10, "favoriteMon": "PIKACHU"},
    },
    "deposit": {
        "summary": "Deposit a Pokemon on the GTS (max 3 active per trainer)",
        "value": {"action": "deposit", "trainerId": 45799, "trainerName": "ASH", "offeredMon": {"species": "PIKACHU", "nickname": "SPARKY", "level": 25}, "wanted": ["BULBASAUR"]},
    },
    "trade": {
        "summary": "Buy a listing: send a Pokemon, receive the offered one into the seller's claim box",
        "value": {"action": "trade", "listingId": "GTS_42", "buyerId": 12345, "buyerName": "MISTY", "sentMon": {"species": "POLIWAG", "nickname": "TADPOLE", "level": 12}},
    },
    "withdraw": {
        "summary": "Pull back one of my own listings",
        "value": {"action": "withdraw", "listingId": "GTS_42", "trainerId": 45799},
    },
    "claim": {
        "summary": "Redeem one Pokemon from my offline claim box",
        "value": {"action": "claim", "trainerId": 45799, "index": 0},
    },
}

ADMIN_EXAMPLES = {
    "kick": {
        "summary": "Remove an online player and temp-ban them (default 300s)",
        "value": {"action": "kick", "trainerId": 45799, "duration": 300},
    },
    "ban": {
        "summary": "Ban a trainer (default 86400s) and force them offline",
        "value": {"action": "ban", "trainerId": 45799, "duration": 86400},
    },
    "unban": {
        "summary": "Clear a transient ban",
        "value": {"action": "unban", "trainerId": 45799},
    },
    "remove_listing": {
        "summary": "Remove a GTS listing (owner's active count is adjusted)",
        "value": {"action": "remove_listing", "listingId": "GTS_42"},
    },
    "announce": {
        "summary": "Set the announcement delivered to all trainers on sync_pos",
        "value": {"action": "announce", "message": "Server maintenance at 22:00 UTC"},
    },
    "clear_announcement": {
        "summary": "Remove the current announcement",
        "value": {"action": "clear_announcement"},
    },
}


def _request_body_examples(examples):
    return {
        "content": {
            "application/json": {
                "schema": {"type": "object"},
                "examples": examples,
            }
        },
        "required": True,
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

    @app.get("/healthz", tags=["Monitoring"], summary="Liveness probe",
             response_description="200 ok when Postgres responds, 503 degraded otherwise",
             responses=_doc_responses(503))
    def healthz(request: Request, storage: Storage = Depends(get_storage)):
        """Return server health. Pings Postgres with a 2s connect timeout; used
        as the docker-compose healthcheck."""
        try:
            with storage.connect() as conn:
                conn.execute("SELECT 1")
            return {"status": "ok"}
        except Exception:
            logger.warning(f"HEALTHZ DB PING FAILED:\n{traceback.format_exc()}")
            raise ApiError(503, {"status": "degraded"})

    @app.get("/metrics", tags=["Monitoring"], summary="Prometheus metrics",
             response_description="Prometheus text exposition (text/plain; version=0.0.4)",
             responses=_doc_responses())
    def metrics_view(request: Request, storage: Storage = Depends(get_storage)):
        """Scrape endpoint for Prometheus: HTTP request counters, rate-limited
        requests, online gauges and active bans. Not intended for browsers."""
        return PlainTextResponse(render_prometheus(storage),
                                 media_type="text/plain; version=0.0.4; charset=utf-8")

    @app.get("/gts/stats", tags=["Monitoring"], summary="Server statistics",
             response_description="Uptime, online/peak players, listings, claims and daily counters",
             responses=_doc_responses())
    def gts_stats(request: Request, storage: Storage = Depends(get_storage)):
        """Public read-only stats: uptime, online/peak player counts, players by
        map, listing/claim/profile totals, request counters and daily counters
        (joins/deposits/trades/claims/withdrawals) for today and the last 7 days."""
        return _send_result(*stats_mod.stats(storage))

    @app.get("/gts/browse", tags=["Game Client"], summary="GTS overview",
             response_description="Server status, online players, listings and recent history",
             responses=_doc_responses())
    @app.get("/gts", tags=["Game Client"], summary="GTS overview",
             response_description="Server status, online players, listings and recent history",
             responses=_doc_responses())
    @app.get("/", tags=["Game Client"], summary="GTS overview",
             response_description="Server status, online players, listings and recent history",
             responses=_doc_responses())
    def gts_browse(request: Request, storage: Storage = Depends(get_storage)):
        """Landing page used by the mod menu: server status, the full active
        player registry, every GTS listing and the recent trade history."""
        return _send_result(*gts.browse(storage))

    @app.get("/gts/players", tags=["Game Client"], summary="Live player positions",
             response_description="Raw active player registry keyed by trainer ID",
             responses=_doc_responses())
    def gts_players(request: Request, storage: Storage = Depends(get_storage)):
        """Raw dump of the in-memory active player registry (trainerId -> last
        sync_pos entry). The mod client uses browse/sync_pos instead; handy for
        debugging."""
        return _send_result(*realtime.players(storage))

    @app.get("/gts/profile", tags=["Game Client"], summary="Trainer profile",
             response_description="Persistent profile for the trainer, or empty object when absent",
             responses=_doc_responses())
    def gts_profile(request: Request, storage: Storage = Depends(get_storage),
                    trainerId: str | None = Query(default=None, description="Numeric trainer ID (e.g. 45799).",
                                                  examples=["45799"])):
        """Fetch a trainer's persistent profile (name, title, badges, pokedex
        count, trade/PVP counters, favorite mon)."""
        return _send_result(*gts.profile(storage, trainerId))

    @app.get("/gts/claims", tags=["Game Client"], summary="Claim box and listings",
             response_description="Offline claim box plus the trainer's active listings",
             responses=_doc_responses())
    def gts_claims(request: Request, storage: Storage = Depends(get_storage),
                   trainerId: str | None = Query(default=None, description="Numeric trainer ID (e.g. 45799).",
                                                 examples=["45799"])):
        """Fetch the Pokemon waiting in a trainer's offline claim box (mons
        received via trade) together with the trainer's active GTS listings."""
        return _send_result(*gts.claims(storage, trainerId))

    @app.get("/gts/admin/players", tags=["Admin"], summary="Online players (admin)",
             response_description="Each online trainer with name, map, position and idle seconds",
             responses=_doc_responses(401, 403))
    def admin_players_view(request: Request, storage: Storage = Depends(get_storage),
                           _: None = Depends(require_admin)):
        """List currently online trainers with name, map, tile position and how
        long since their last sync_pos."""
        return _send_result(*admin.admin_players(storage))

    @app.get("/gts/admin/bans", tags=["Admin"], summary="Active bans (admin)",
             response_description="Transient in-memory bans with expiry timestamps",
             responses=_doc_responses(401, 403))
    def admin_bans_view(request: Request, storage: Storage = Depends(get_storage),
                        _: None = Depends(require_admin)):
        """List transient in-memory bans (trainerId -> unban timestamp)."""
        return _send_result(*admin.admin_bans(storage))

    @app.get("/gts/admin/announcement", tags=["Admin"], summary="Current announcement (admin)",
             response_description="The announcement string delivered on sync_pos, or null",
             responses=_doc_responses(401, 403))
    def admin_announcement_view(request: Request, storage: Storage = Depends(get_storage),
                                _: None = Depends(require_admin)):
        """Fetch the current global announcement, or null when none is set."""
        return _send_result(*admin.admin_announcement(storage))

    @app.get("/gts/admin", tags=["Admin"], summary="Unknown admin view",
             response_description="404 for admin paths that do not exist",
             responses=_doc_responses(401, 403, 404))
    @app.get("/gts/admin/{tail:path}", tags=["Admin"], summary="Unknown admin view",
             response_description="404 for admin paths that do not exist",
             responses=_doc_responses(401, 403, 404))
    def admin_unknown_view(request: Request, _: None = Depends(require_admin)):
        """Catch-all for unrecognized admin GET paths."""
        raise ApiError(404, {"error": "Unknown admin view"})

    @app.get("/{path:path}", tags=["Fallback"], summary="Unknown endpoint",
             response_description="404 for any GET path not matched above",
             responses=_doc_responses(404))
    def get_not_found(request: Request):
        """Catch-all: any GET path that matches no route returns 404."""
        raise ApiError(404, {"error": "Endpoint not found"})

    # --- POST routes ------------------------------------------------------

    @app.post("/gts", tags=["Game Client"], summary="Action dispatch",
              response_description="Handler-dependent payload; only HTTP 200 is trusted by the mod client",
              responses=_doc_responses(400, 403, 404, 429, 500),
              openapi_extra={"requestBody": _request_body_examples(POST_EXAMPLES)})
    def post_gts(request: Request, body: dict = Depends(_parse_json_body),
                 storage: Storage = Depends(get_storage)):
        """Primary endpoint used by the mod client. The JSON body carries an
        ``action`` field selecting the handler:

        - **sync_pos** — heartbeat: publish position, receive near players, pending challenges and announcements
        - **send_challenge** / **clear_challenge** — PVP & link-trade challenge flow
        - **send_battle_msg** / **poll_battle_msgs** / **clear_battle_room** — battle messaging
        - **log_trade_receipt** / **update_profile** — persistence
        - **deposit** / **trade** / **withdraw** / **claim** — GTS marketplace

        Validation is lenient: a payload mismatch logs a warning but never
        blocks the action, because the client only trusts HTTP 200.
        """
        return _dispatch_post(request, body, storage)

    @app.post("/gts/admin", tags=["Admin"], summary="Admin action dispatch",
              response_description="Action result, e.g. {success: true, bannedUntil: <ts>}",
              responses=_doc_responses(400, 401, 403, 404, 429, 500),
              openapi_extra={"requestBody": _request_body_examples(ADMIN_EXAMPLES)})
    @app.post("/gts/admin/{tail:path}", tags=["Admin"], summary="Admin action dispatch",
              response_description="Action result, e.g. {success: true, bannedUntil: <ts>}",
              responses=_doc_responses(400, 401, 403, 404, 429, 500),
              openapi_extra={"requestBody": _request_body_examples(ADMIN_EXAMPLES)})
    def post_admin(request: Request, body: dict = Depends(_parse_json_body),
                   storage: Storage = Depends(get_storage), _: None = Depends(require_admin)):
        """Token-gated moderation actions (Authorization: Bearer <ADMIN_TOKEN>).
        The JSON body carries an ``action`` field: **kick**, **ban**, **unban**,
        **remove_listing**, **announce** or **clear_announcement**. Bans are
        transient and live in memory. Unlike game actions, schema mismatches
        return a strict 400."""
        return _dispatch_admin(request, body, storage)

    # Preserve the legacy quirk where any POST path dispatches by `action`.
    @app.post("/{path:path}", tags=["Fallback"], summary="Legacy POST dispatch",
              response_description="Same response contract as POST /gts",
              responses=_doc_responses(400, 403, 404, 429, 500),
              openapi_extra={"requestBody": _request_body_examples(POST_EXAMPLES)})
    def post_any(request: Request, body: dict = Depends(_parse_json_body),
                 storage: Storage = Depends(get_storage)):
        """Legacy compatibility: any POST path (not just /gts) dispatches by the
        JSON ``action`` field exactly like POST /gts. Kept because old mod builds
        may POST to arbitrary paths."""
        return _dispatch_post(request, body, storage)

    return app
