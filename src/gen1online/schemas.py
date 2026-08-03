"""Pydantic request/response schemas for the Gen1Online API.

The wire contract is frozen: every POST goes to ``/gts`` with a JSON body
carrying an ``action`` key, and the mod client only trusts HTTP 200. Schemas
therefore document the API and give light validation (``/docs``) without
tightening it: all models are lenient (every field optional, unknown fields
allowed) because the Lua client sends slightly varying payloads and handlers
read them defensively. Trainer IDs arrive as numbers (``love.math.random``) —
``MaybeId`` accepts both numbers and strings. A schema rejection never blocks
a game action (``api.py`` logs and continues); admin actions still 400 so
tooling gets explicit errors. Response schemas are documentation-only and are
never enforced with ``response_model`` (FastAPI filtering would strip keys the
client expects).
"""

from typing import Annotated, Any, Dict, List, Optional, Union

from pydantic import BaseModel, BeforeValidator, ConfigDict, Field


class LenientModel(BaseModel):
    model_config = ConfigDict(extra="allow")


def _coerce_id(value):
    """Accept str or numeric trainer IDs; normalise to str for schema purposes."""
    if value is None or isinstance(value, str):
        return value
    return str(value)


MaybeId = Annotated[Optional[str], BeforeValidator(_coerce_id)]


class SyncPosRequest(LenientModel):
    trainerId: MaybeId = Field(None, description="Numeric trainer ID (love.math.random). Used to key the online player entry.")
    name: Optional[str] = Field(None, description="Trainer display name.")
    map: Optional[str] = Field(None, description="Current map id (e.g. VERIDIAN_CITY).")
    x: Optional[Union[int, float]] = Field(None, description="Overworld tile column.")
    y: Optional[Union[int, float]] = Field(None, description="Overworld tile row.")
    px: Optional[Union[int, float]] = Field(None, description="Pixel X (cellX * 16).")
    py: Optional[Union[int, float]] = Field(None, description="Pixel Y (cellY * 16).")
    fx: Optional[Union[int, float]] = Field(None, description="Tile X of the tile behind the player (facing tile).")
    fy: Optional[Union[int, float]] = Field(None, description="Tile Y of the tile behind the player (facing tile).")
    facing: Optional[str] = Field(None, description="Facing direction (up/down/left/right).")
    moving: Optional[bool] = Field(None, description="Whether the player is currently moving.")
    species: Optional[str] = Field(None, description="Follower Pokemon species shown next to the trainer.")
    title: Optional[str] = Field(None, description="Trainer title (e.g. ROOKIE).")


class SendChallengeRequest(LenientModel):
    targetId: MaybeId = Field(None, description="ID of the trainer being challenged.")
    fromId: MaybeId = Field(None, description="ID of the challenger (self).")
    fromName: Optional[str] = Field(None, description="Challenger display name.")
    challengeType: Optional[str] = Field(None, description="PVP, ACCEPT_PVP, TRADE, ACCEPT_TRADE or DECLINE.")
    roomId: Optional[str] = Field(None, description="Unique battle room id (embeds a random seed).")
    party: Optional[Any] = Field(None, description="Packed party payload (Protocol.packParty) sent for ACCEPT_PVP.")
    seed: Optional[Any] = Field(None, description="Shared battle random seed for lockstep sync.")


class ClearChallengeRequest(LenientModel):
    trainerId: MaybeId = Field(None, description="ID of the trainer whose pending challenge should be removed.")


class SendBattleMsgRequest(LenientModel):
    roomId: Optional[str] = Field(None, description="Battle room id the message belongs to.")
    targetId: MaybeId = Field(None, description="ID of the receiving trainer. FIFO — every message must be delivered.")
    fromId: MaybeId = Field(None, description="ID of the sending trainer.")
    msg: Optional[Any] = Field(None, description="Opaque battle message payload (moves, state, bye, ...).")


class PollBattleMsgsRequest(LenientModel):
    roomId: Optional[str] = Field(None, description="Battle room id to poll.")
    myId: MaybeId = Field(None, description="Own trainer ID; drains the FIFO inbox for this trainer.")


class ClearBattleRoomRequest(LenientModel):
    roomId: Optional[str] = Field(None, description="Battle room id to destroy (drops all queued messages).")


class LogTradeReceiptRequest(LenientModel):
    trainerId: Optional[str] = Field(None, description="Numeric trainer ID (accepts a string on the wire).")
    text: Optional[str] = Field(None, description="Human-readable receipt line appended to history (default: LINK TRADE COMPLETED).")


class UpdateProfileRequest(LenientModel):
    trainerId: MaybeId = Field(None, description="Numeric trainer ID whose profile is updated.")
    name: Optional[str] = Field(None, description="Trainer display name.")
    title: Optional[str] = Field(None, description="Trainer title (e.g. POKéMON TRAINER).")
    badges: Optional[int] = Field(None, description="Gym badge count (absolute).")
    pokedexCount: Optional[int] = Field(None, description="Pokedex caught count (absolute).")
    gtsTrades: Optional[int] = Field(None, description="GTS trade count (additive).")
    pvpWins: Optional[int] = Field(None, description="PVP win count (additive).")
    favoriteMon: Optional[str] = Field(None, description="Favorite species (e.g. PIKACHU).")


class DepositRequest(LenientModel):
    trainerId: MaybeId = Field(None, description="Numeric trainer ID making the deposit.")
    trainerName: Optional[str] = Field(None, description="Trainer display name (shown as OT on the listing).")
    offeredMon: Optional[Dict[str, Any]] = Field(None, description="Packed Pokemon being offered (Protocol.packMon).")
    wanted: Optional[List[Any]] = Field(None, description="Wanted species list (e.g. [PIKACHU]). Client sends up to 3.")


class TradeRequest(LenientModel):
    listingId: Optional[str] = Field(None, description="GTS listing id to buy (e.g. GTS_42).")
    buyerId: MaybeId = Field(None, description="Numeric ID of the buyer.")
    buyerName: Optional[str] = Field(None, description="Buyer display name.")
    sentMon: Optional[Dict[str, Any]] = Field(None, description="Packed Pokemon being sent in exchange (Protocol.packMon).")


class WithdrawRequest(LenientModel):
    listingId: Optional[str] = Field(None, description="GTS listing id to pull back.")
    trainerId: MaybeId = Field(None, description="Numeric trainer ID; must be the listing owner.")


class ClaimRequest(LenientModel):
    trainerId: MaybeId = Field(None, description="Numeric trainer ID whose claim box is redeemed.")
    index: Optional[int] = Field(None, description="0-based index into the trainer's claim box.")


class AdminRequest(LenientModel):
    trainerId: MaybeId = Field(None, description="Target trainer ID for kick/ban/unban.")
    duration: Optional[int] = Field(None, description="Ban duration in seconds (kick default 300, ban default 86400).")
    listingId: Optional[str] = Field(None, description="Listing id to remove (remove_listing).")
    message: Optional[str] = Field(None, description="Announcement text (announce).")


ACTION_MODELS: Dict[str, type[BaseModel]] = {
    "sync_pos": SyncPosRequest,
    "send_challenge": SendChallengeRequest,
    "clear_challenge": ClearChallengeRequest,
    "send_battle_msg": SendBattleMsgRequest,
    "poll_battle_msgs": PollBattleMsgsRequest,
    "clear_battle_room": ClearBattleRoomRequest,
    "log_trade_receipt": LogTradeReceiptRequest,
    "update_profile": UpdateProfileRequest,
    "deposit": DepositRequest,
    "trade": TradeRequest,
    "withdraw": WithdrawRequest,
    "claim": ClaimRequest,
}

ADMIN_ACTION_MODEL = AdminRequest


# --- Documentation-only response schemas (never enforced) ----------------

class ErrorResponse(BaseModel):
    success: Optional[bool] = None
    error: Optional[str] = Field(None, description="Human-readable error message")


class SuccessResponse(BaseModel):
    success: bool = True


class BrowseResponse(SuccessResponse):
    status: Optional[str] = None
    active_player_count: Optional[int] = None
    active_players: Optional[Dict[str, Any]] = None
    listings: Optional[Dict[str, Any]] = None
    history: Optional[List[Any]] = None


class SyncPosResponse(SuccessResponse):
    players: Optional[List[Dict[str, Any]]] = None
    challenge: Optional[Dict[str, Any]] = None
    announcement: Optional[str] = None


class PlayersResponse(SuccessResponse):
    online_count: Optional[int] = None
    players: Optional[Dict[str, Any]] = None


class ProfileResponse(SuccessResponse):
    profile: Optional[Dict[str, Any]] = None


class ClaimsResponse(SuccessResponse):
    claims: Optional[List[Any]] = None
    my_listings: Optional[List[Any]] = None


class StatsResponse(SuccessResponse):
    uptime_seconds: Optional[int] = None
    online_players: Optional[int] = None
    peak_online: Optional[int] = None
    players_by_map: Optional[Dict[str, int]] = None
    listings: Optional[int] = None
    pending_claims: Optional[int] = None
    profiles: Optional[int] = None
    requests_total: Optional[int] = None
    rate_limited_total: Optional[int] = None
    today: Optional[Dict[str, int]] = None
    daily_7d: Optional[Dict[str, Dict[str, int]]] = None
