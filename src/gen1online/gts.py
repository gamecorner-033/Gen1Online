"""GTS marketplace request handlers: deposit / trade / withdraw / claim / profiles / history.

Handlers are pure application logic operating on a :class:`gen1online.storage.Storage`.
POST handlers follow the signature ``(storage, now, req) -> (status_code, payload)``.
"""

import logging

from gen1online.config import DEPOSIT_LIMIT

logger = logging.getLogger(__name__)


def browse(storage):
    """GET /gts/browse - status, online players, listings and recent history."""
    return 200, {
        "success": True,
        "status": "ONLINE",
        "active_player_count": len(storage.db["active_players"]),
        "active_players": storage.db["active_players"],
        "listings": storage.db["listings"],
        "history": storage.db["history"],
    }


def profile(storage, trainer_id):
    """GET /gts/profile?trainerId=... - persistent trainer profile."""
    return 200, {"success": True, "profile": storage.db["profiles"].get(str(trainer_id), {})}


def claims(storage, trainer_id):
    """GET /gts/claims?trainerId=... - offline claim box plus active listings."""
    claims_list = storage.db["claim_boxes"].get(str(trainer_id), [])
    listings = [l for l in storage.db["listings"].values() if str(l.get("trainerId")) == str(trainer_id)]
    return 200, {"success": True, "claims": claims_list, "my_listings": listings}


def log_trade_receipt(storage, now, req):
    text = req.get("text", "LINK TRADE COMPLETED")
    logger.info("TRADE RECEIPT id=%s: %s", req.get("trainerId"), text)
    storage.persist_history(text)
    storage.add_receipt(text)
    return 200, {"success": True}


def update_profile(storage, now, req):
    trainer_id = str(req.get("trainerId"))
    profile = storage.db["profiles"].get(trainer_id, {
        "trainerId": trainer_id,
        "name": req.get("name", "TRAINER"),
        "title": "POKéMON TRAINER",
        "badges": 0,
        "pokedexCount": 0,
        "gtsTrades": 0,
        "pvpWins": 0,
        "favoriteMon": "PIKACHU",
        "timestamp": now,
    })

    profile["name"] = req.get("name", profile.get("name"))
    if "title" in req:
        profile["title"] = req["title"]
    if "badges" in req:
        profile["badges"] = req["badges"]
    if "pokedexCount" in req:
        profile["pokedexCount"] = req["pokedexCount"]
    if "gtsTrades" in req:
        profile["gtsTrades"] = (profile.get("gtsTrades", 0) + req["gtsTrades"])
    if "pvpWins" in req:
        profile["pvpWins"] = (profile.get("pvpWins", 0) + req["pvpWins"])
    if "favoriteMon" in req:
        profile["favoriteMon"] = req["favoriteMon"]
    profile["timestamp"] = now

    storage.db["profiles"][trainer_id] = profile
    storage.persist_profile(trainer_id, profile)

    logger.info("PROFILE UPDATE id=%s name=%r badges=%s pokedex=%s trades=%s pvp=%s fav=%r",
                trainer_id, profile.get("name"), profile.get("badges"),
                profile.get("pokedexCount"), profile.get("gtsTrades"),
                profile.get("pvpWins"), profile.get("favoriteMon"))

    return 200, {"success": True, "profile": profile}


def deposit(storage, now, req):
    trainer_id = str(req.get("trainerId"))
    trainer_name = req.get("trainerName", "TRAINER")
    offered_mon = req.get("offeredMon")
    wanted = req.get("wanted", [])

    current_count = storage.db["user_counts"].get(trainer_id, 0)
    if current_count >= DEPOSIT_LIMIT:
        logger.warning("DEPOSIT REJECTED (limit %d) id=%s name=%r", DEPOSIT_LIMIT, trainer_id, trainer_name)
        return 400, {"success": False, "error": "MAX 3 DEPOSITS REACHED"}

    list_id = f"GTS_{storage.get_next_id()}"

    listing = {
        "id": list_id,
        "trainerId": trainer_id,
        "trainerName": trainer_name,
        "offeredMon": offered_mon,
        "wanted": wanted,
        "timestamp": now,
    }

    mon_name = offered_mon.get("nickname") or offered_mon.get("species")
    receipt = f"{trainer_name} (ID {trainer_id}) DEPOSITED {mon_name} LV{offered_mon.get('level', 1)}"
    new_count = storage.persist_deposit(listing, receipt)

    storage.db["listings"][list_id] = listing
    storage.db["user_counts"][trainer_id] = new_count
    storage.add_receipt(receipt)

    logger.info("DEPOSIT id=%s mon=%r LV%s wanted=%r", trainer_id, mon_name, offered_mon.get("level", 1), wanted)

    return 200, {"success": True, "listing": listing}


def trade(storage, now, req):
    list_id = req.get("listingId")
    buyer_id = str(req.get("buyerId"))
    buyer_name = req.get("buyerName", "TRAINER")
    sent_mon = req.get("sentMon")

    if list_id not in storage.db["listings"]:
        return 404, {"success": False, "error": "LISTING NO LONGER EXISTS"}

    listing = storage.db["listings"][list_id]
    seller_id = str(listing["trainerId"])

    offered = listing["offeredMon"]
    off_name = offered.get("nickname") or offered.get("species")
    sent_name = sent_mon.get("nickname") or sent_mon.get("species")

    claim_row = {
        "mon": sent_mon,
        "fromName": buyer_name,
        "fromId": buyer_id,
        "originalOffered": off_name,
        "timestamp": now,
    }
    receipt = f"{buyer_name} TRADED {sent_name} TO {listing['trainerName']} FOR {off_name}"
    new_count = storage.persist_trade(listing, claim_row, receipt)
    if new_count is None:
        return 404, {"success": False, "error": "LISTING NO LONGER EXISTS"}

    storage.db["listings"].pop(list_id, None)
    storage.db["user_counts"][seller_id] = new_count
    storage.db["claim_boxes"].setdefault(seller_id, []).append(claim_row)
    storage.add_receipt(receipt)

    logger.info("TRADE listing=%s buyer=%s (%s) sent=%r for=%r", list_id, buyer_id, buyer_name, sent_name, off_name)

    return 200, {"success": True, "receivedMon": offered}


def withdraw(storage, now, req):
    list_id = req.get("listingId")
    trainer_id = str(req.get("trainerId"))

    if list_id in storage.db["listings"] and str(storage.db["listings"][list_id]["trainerId"]) == trainer_id:
        listing = storage.db["listings"][list_id]
        new_count = storage.persist_withdraw(list_id, trainer_id)
        if new_count is None:
            logger.warning("WITHDRAW FAILED listing=%s id=%s (gone)", list_id, trainer_id)
            return 404, {"success": False, "error": "Listing not found or unauthorized"}
        storage.db["listings"].pop(list_id, None)
        storage.db["user_counts"][trainer_id] = new_count
        logger.info("WITHDRAW listing=%s id=%s", list_id, trainer_id)
        return 200, {"success": True, "returnedMon": listing["offeredMon"]}
    logger.warning("WITHDRAW FAILED listing=%s id=%s (not found or unauthorized)", list_id, trainer_id)
    return 404, {"success": False, "error": "Listing not found or unauthorized"}


def claim(storage, now, req):
    trainer_id = str(req.get("trainerId"))
    claim_idx = req.get("index", 0)

    claims = storage.db["claim_boxes"].get(trainer_id, [])
    if 0 <= claim_idx < len(claims):
        if not storage.persist_claim(trainer_id, claim_idx):
            logger.warning("CLAIM FAILED id=%s index=%s (db mismatch)", trainer_id, claim_idx)
            return 404, {"error": "Claim not found"}
        claimed = claims.pop(claim_idx)
        logger.info("CLAIM id=%s index=%s mon=%r", trainer_id, claim_idx, claimed["mon"])
        return 200, {"success": True, "claimedMon": claimed["mon"]}
    logger.warning("CLAIM FAILED id=%s index=%s (out of range)", trainer_id, claim_idx)
    return 404, {"error": "Claim not found"}
