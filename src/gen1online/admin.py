"""Token-gated admin handlers: kick/ban/unban players, remove listings, announce.

All handlers assume the caller already passed the ``Authorization: Bearer``
check in the transport layer. Ban state is transient and lives in-memory.
"""

import logging
import time

from gen1online.config import BAN_SECONDS, KICK_BAN_SECONDS
from gen1online.metrics import METRICS

logger = logging.getLogger(__name__)


def admin_players(storage):
    now = int(time.time())
    players = []
    for tid, p in storage.db["active_players"].items():
        players.append({
            "trainerId": tid,
            "name": p.get("name"),
            "map": p.get("map"),
            "x": p.get("x"),
            "y": p.get("y"),
            "idleSeconds": max(0, now - p.get("timestamp", now)),
        })
    return 200, {"success": True, "online_count": len(players), "players": players}


def admin_bans(storage):
    return 200, {"success": True, "bans": METRICS.active_bans()}


def admin_announcement(storage):
    return 200, {"success": True, "announcement": storage.db.get("announcement")}


def admin_kick(storage, now, req):
    trainer_id = str(req.get("trainerId"))
    duration = int(req.get("duration") or KICK_BAN_SECONDS)
    if trainer_id not in storage.db["active_players"] and trainer_id not in storage.db["pending_challenges"]:
        logger.warning(f"ADMIN KICK id={trainer_id} (not online)")
        return 404, {"success": False, "error": "Trainer not online"}
    storage.db["active_players"].pop(trainer_id, None)
    storage.db["pending_challenges"].pop(trainer_id, None)
    METRICS.ban(trainer_id, duration)
    logger.info(f"ADMIN KICK id={trainer_id} ban={duration}s")
    return 200, {"success": True, "bannedUntil": now + duration}


def admin_ban(storage, now, req):
    trainer_id = str(req.get("trainerId"))
    duration = int(req.get("duration") or BAN_SECONDS)
    storage.db["active_players"].pop(trainer_id, None)
    storage.db["pending_challenges"].pop(trainer_id, None)
    METRICS.ban(trainer_id, duration)
    logger.info(f"ADMIN BAN id={trainer_id} ban={duration}s")
    return 200, {"success": True, "bannedUntil": now + duration}


def admin_unban(storage, now, req):
    trainer_id = str(req.get("trainerId"))
    METRICS.unban(trainer_id)
    logger.info(f"ADMIN UNBAN id={trainer_id}")
    return 200, {"success": True}


def admin_remove_listing(storage, now, req):
    list_id = req.get("listingId")
    if list_id not in storage.db["listings"]:
        return 404, {"success": False, "error": "Listing not found"}
    new_count = storage.remove_listing_admin(list_id)
    if new_count is None:
        return 404, {"success": False, "error": "Listing not found"}
    listing = storage.db["listings"].pop(list_id, None)
    storage.db["user_counts"][str(listing["trainerId"])] = new_count
    logger.info(f"ADMIN REMOVE LISTING listing={list_id} owner={listing.get('trainerId')}")
    return 200, {"success": True}


def admin_announce(storage, now, req):
    message = req.get("message")
    if not message or not str(message).strip():
        return 400, {"success": False, "error": "message is required"}
    storage.db["announcement"] = str(message)
    logger.info(f"ADMIN ANNOUNCE: {str(message)!r}")
    return 200, {"success": True, "announcement": str(message)}


def admin_clear_announcement(storage, now, req):
    storage.db.pop("announcement", None)
    logger.info("ADMIN ANNOUNCE CLEARED")
    return 200, {"success": True}
