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
    trainerId: MaybeId = None
    name: Optional[str] = None
    map: Optional[str] = None
    x: Optional[Union[int, float]] = None
    y: Optional[Union[int, float]] = None
    px: Optional[Union[int, float]] = None
    py: Optional[Union[int, float]] = None
    fx: Optional[Union[int, float]] = None
    fy: Optional[Union[int, float]] = None
    facing: Optional[str] = None
    moving: Optional[bool] = None
    species: Optional[str] = None
    title: Optional[str] = None


class SendChallengeRequest(LenientModel):
    targetId: MaybeId = None
    fromId: MaybeId = None
    fromName: Optional[str] = None
    challengeType: Optional[str] = None
    roomId: Optional[str] = None
    party: Optional[Any] = None
    seed: Optional[Any] = None


class ClearChallengeRequest(LenientModel):
    trainerId: MaybeId = None


class SendBattleMsgRequest(LenientModel):
    roomId: Optional[str] = None
    targetId: MaybeId = None
    fromId: MaybeId = None
    msg: Optional[Any] = None


class PollBattleMsgsRequest(LenientModel):
    roomId: Optional[str] = None
    myId: MaybeId = None


class ClearBattleRoomRequest(LenientModel):
    roomId: Optional[str] = None


class LogTradeReceiptRequest(LenientModel):
    trainerId: Optional[str] = None
    text: Optional[str] = None


class UpdateProfileRequest(LenientModel):
    trainerId: MaybeId = None
    name: Optional[str] = None
    title: Optional[str] = None
    badges: Optional[int] = None
    pokedexCount: Optional[int] = None
    gtsTrades: Optional[int] = None
    pvpWins: Optional[int] = None
    favoriteMon: Optional[str] = None


class DepositRequest(LenientModel):
    trainerId: MaybeId = None
    trainerName: Optional[str] = None
    offeredMon: Optional[Dict[str, Any]] = None
    wanted: Optional[List[Any]] = None


class TradeRequest(LenientModel):
    listingId: Optional[str] = None
    buyerId: MaybeId = None
    buyerName: Optional[str] = None
    sentMon: Optional[Dict[str, Any]] = None


class WithdrawRequest(LenientModel):
    listingId: Optional[str] = None
    trainerId: MaybeId = None


class ClaimRequest(LenientModel):
    trainerId: MaybeId = None
    index: Optional[int] = None


class AdminRequest(LenientModel):
    trainerId: MaybeId = None
    duration: Optional[int] = None
    listingId: Optional[str] = None
    message: Optional[str] = None


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
