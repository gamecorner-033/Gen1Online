"""Environment-driven configuration and tuning constants."""

import os

HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", 7779))
DB_URI = os.environ.get("DATABASE_URL", "postgresql://gts:gts@localhost:5432/gts")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

LISTING_TTL_SECONDS = 30 * 86400
CLAIM_TTL_SECONDS = 60 * 86400
PLAYER_TIMEOUT_SECONDS = 30  # 30s timeout guard for map transitions
CHALLENGE_TTL_SECONDS = 15   # Challenges expire in 15s so stale challenges never launch on join

HISTORY_LIMIT = 50
DEPOSIT_LIMIT = 3
RATE_LIMIT_PER_MIN = 2400
SYNC_PLAYERS_PER_MAP = 16
