"""Realtime MMO layer request handlers: position sync, challenges and battle rooms.

All state here is transient and stays in memory only. POST handlers follow the
signature ``(storage, now, req) -> (status_code, payload)``.
"""

import logging

from gen1online.config import CHALLENGE_TTL_SECONDS, PLAYER_TIMEOUT_SECONDS, SYNC_PLAYERS_PER_MAP
from gen1online.metrics import METRICS

logger = logging.getLogger(__name__)


def players(storage):
    """GET /gts/players - live online player positions."""
    return 200, {
        "success": True,
        "online_count": len(storage.db["active_players"]),
        "players": storage.db["active_players"],
    }


def sync_pos(storage, now, req):
    trainer_id = str(req.get("trainerId"))
    map_id = req.get("map")

    if METRICS.is_banned(trainer_id)[0]:
        return 403, {"success": False, "error": "KICKED/BANNED"}

    player_entry = {
        "trainerId": trainer_id,
        "name": req.get("name", "TRAINER"),
        "map": map_id,
        "x": req.get("x", 5),
        "y": req.get("y", 5),
        "px": req.get("px"),
        "py": req.get("py"),
        "fx": req.get("fx", 5),
        "fy": req.get("fy", 5),
        "facing": req.get("facing", "down"),
        "moving": req.get("moving", False),
        "species": req.get("species"),
        "title": req.get("title", "ROOKIE"),
        "timestamp": now,
    }

    if trainer_id not in storage.db["active_players"]:
        logger.info(f"PLAYER JOINED id={trainer_id} name={req.get('name')!r} map={map_id!r}")
        storage.bump_daily_stat("joins")
        METRICS.refresh_online(storage)
    storage.db["active_players"][trainer_id] = player_entry

    # Fast cleanup for inactive players (> 30s)
    for tid, pdata in list(storage.db["active_players"].items()):
        if now - pdata.get("timestamp", 0) > PLAYER_TIMEOUT_SECONDS:
            storage.db["active_players"].pop(tid, None)

    # Filter active players on the same map (up to SYNC_PLAYERS_PER_MAP players)
    map_players = []
    for tid, p in storage.db["active_players"].items():
        if tid != trainer_id and p.get("map") == map_id:
            map_players.append(p)
            if len(map_players) >= SYNC_PLAYERS_PER_MAP:
                break

    # Check if there is a pending challenge (do not pop so delivery is guaranteed)
    challenge = storage.db["pending_challenges"].get(trainer_id)
    if challenge and (now - challenge.get("timestamp", 0) > CHALLENGE_TTL_SECONDS):
        storage.db["pending_challenges"].pop(trainer_id, None)
        challenge = None

    return 200, {"success": True, "players": map_players, "challenge": challenge,
                 "announcement": storage.db.get("announcement")}


def send_challenge(storage, now, req):
    target_id = str(req.get("targetId"))
    from_id = str(req.get("fromId"))
    from_name = req.get("fromName", "TRAINER")
    challenge_type = req.get("challengeType", "PVP")
    room_id = req.get("roomId") or f"ROOM_{min(from_id, target_id)}_{max(from_id, target_id)}"

    storage.db["pending_challenges"][target_id] = {
        "fromId": from_id,
        "fromName": from_name,
        "type": challenge_type,
        "party": req.get("party"),
        "seed": req.get("seed"),
        "roomId": room_id,
        "timestamp": now,
    }

    logger.info(f"CHALLENGE SENT from={from_id} ({from_name}) to={target_id} type={challenge_type} room={room_id}")

    return 200, {
        "success": True,
        "roomId": room_id,
        "message": f"Challenge '{challenge_type}' sent to Trainer ID {target_id}",
    }


def clear_challenge(storage, now, req):
    trainer_id = str(req.get("trainerId"))
    if trainer_id in storage.db["pending_challenges"]:
        logger.info(f"CHALLENGE CLEARED id={trainer_id}")
    storage.db["pending_challenges"].pop(trainer_id, None)
    return 200, {"success": True}


def send_battle_msg(storage, now, req):
    room_id = str(req.get("roomId"))
    target_id = str(req.get("targetId"))
    msg = req.get("msg")

    if room_id not in storage.db["battle_rooms"]:
        storage.db["battle_rooms"][room_id] = {}
    if target_id not in storage.db["battle_rooms"][room_id]:
        storage.db["battle_rooms"][room_id][target_id] = []

    storage.db["battle_rooms"][room_id][target_id].append(msg)
    logger.debug(f"BATTLE MSG room={room_id} target={target_id} from={req.get('fromId')} len={len(msg or '')}")
    return 200, {"success": True}


def poll_battle_msgs(storage, now, req):
    room_id = str(req.get("roomId"))
    my_id = str(req.get("myId"))

    pending_msgs = []
    if room_id in storage.db["battle_rooms"] and my_id in storage.db["battle_rooms"][room_id]:
        pending_msgs = storage.db["battle_rooms"][room_id].pop(my_id, [])

    return 200, {"success": True, "msgs": pending_msgs}


def clear_battle_room(storage, now, req):
    room_id = str(req.get("roomId"))
    if room_id in storage.db["battle_rooms"]:
        logger.info(f"BATTLE ROOM CLEARED room={room_id}")
    storage.db["battle_rooms"].pop(room_id, None)
    return 200, {"success": True}
