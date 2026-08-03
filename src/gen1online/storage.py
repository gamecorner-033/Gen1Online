"""PostgreSQL persistence layer plus the in-memory mirror used for fast reads.

Persisted collections (``listings``, ``user_counts``, ``history``, ``claim_boxes``,
``profiles``) live in PostgreSQL and are mirrored in the in-memory ``db`` dict.
Every mutation writes to Postgres transactionally first, then updates memory.
``active_players``, ``pending_challenges`` and ``battle_rooms`` are transient and
stay in memory only (they are not part of the DB schema).
"""

import time

import psycopg
from psycopg.types.json import Jsonb

from gen1online.config import (
    CHALLENGE_TTL_SECONDS,
    CLAIM_TTL_SECONDS,
    DB_URI,
    HISTORY_LIMIT,
    LISTING_TTL_SECONDS,
    PLAYER_TIMEOUT_SECONDS,
)

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS listings (
    id            TEXT PRIMARY KEY,
    trainer_id    TEXT NOT NULL,
    trainer_name  TEXT NOT NULL,
    offered_mon   JSONB NOT NULL,
    wanted        JSONB NOT NULL DEFAULT '[]',
    ts            BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS user_counts (
    trainer_id TEXT PRIMARY KEY,
    count      INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS history (
    id   BIGSERIAL PRIMARY KEY,
    text TEXT NOT NULL,
    ts   BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS claim_boxes (
    id               BIGSERIAL PRIMARY KEY,
    trainer_id       TEXT NOT NULL,
    mon              JSONB NOT NULL,
    from_name        TEXT NOT NULL,
    from_id          TEXT NOT NULL,
    original_offered TEXT,
    ts               BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS profiles (
    trainer_id TEXT PRIMARY KEY,
    data       JSONB NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


class Storage:
    """Owns the in-memory state store and all PostgreSQL access for it."""

    def __init__(self):
        self.db = {
            "listings": {},           # listingId -> listing object
            "user_counts": {},        # trainerId -> active deposit count
            "history": [],            # array of last HISTORY_LIMIT receipts
            "claim_boxes": {},        # trainerId -> array of traded mons
            "profiles": {},           # trainerId -> persistent profile object
            "active_players": {},     # trainerId -> live position & state (IN-MEMORY ONLY)
            "pending_challenges": {}, # targetTrainerId -> challenge (fromId, fromName, type, party, seed, roomId)
            "battle_rooms": {},       # roomId -> { targetTrainerId -> [pending_messages] }
        }
        self._last_pg_clean = 0.0

    def connect(self):
        return psycopg.connect(DB_URI)

    def init_db(self):
        """Create the PostgreSQL schema if it does not exist yet."""
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute(SCHEMA_SQL)

    def load_db(self):
        """Load all persisted collections from PostgreSQL into memory."""
        db = self.db
        db["listings"] = {}
        db["user_counts"] = {}
        db["history"] = []
        db["claim_boxes"] = {}
        db["profiles"] = {}
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT id, trainer_id, trainer_name, offered_mon, wanted, ts FROM listings")
            for row in cur.fetchall():
                db["listings"][row[0]] = {
                    "id": row[0],
                    "trainerId": row[1],
                    "trainerName": row[2],
                    "offeredMon": row[3],
                    "wanted": row[4],
                    "timestamp": row[5],
                }
            cur.execute("SELECT trainer_id, count FROM user_counts")
            for row in cur.fetchall():
                db["user_counts"][row[0]] = row[1]
            cur.execute(f"SELECT text, ts FROM history ORDER BY id DESC LIMIT {HISTORY_LIMIT}")
            for row in cur.fetchall():
                db["history"].append({"text": row[0], "time": row[1]})
            cur.execute("SELECT trainer_id, mon, from_name, from_id, original_offered, ts FROM claim_boxes ORDER BY id")
            for row in cur.fetchall():
                db["claim_boxes"].setdefault(row[0], []).append({
                    "mon": row[1],
                    "fromName": row[2],
                    "fromId": row[3],
                    "originalOffered": row[4],
                    "timestamp": row[5],
                })
            cur.execute("SELECT trainer_id, data FROM profiles")
            for row in cur.fetchall():
                db["profiles"][row[0]] = row[1]

    def get_next_id(self):
        """Atomically allocate the next GTS listing id (e.g. GTS_1001)."""
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute(
                """INSERT INTO meta (key, value) VALUES ('next_id', '1001')
                   ON CONFLICT (key) DO UPDATE SET value = (meta.value::bigint + 1)::text
                   RETURNING value"""
            )
            return int(cur.fetchone()[0])

    def _bump_user_count(self, cur, trainer_id, delta):
        """Atomically adjust a trainer's deposit count (floored at 0). Returns new count."""
        cur.execute(
            """INSERT INTO user_counts (trainer_id, count) VALUES (%s, GREATEST(0, %s))
               ON CONFLICT (trainer_id) DO UPDATE SET count = GREATEST(0, user_counts.count + %s)
               RETURNING count""",
            (trainer_id, delta, delta),
        )
        return cur.fetchone()[0]

    def persist_deposit(self, listing, receipt_text):
        """Atomically insert a listing, bump the depositor count, and log a receipt."""
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO listings (id, trainer_id, trainer_name, offered_mon, wanted, ts) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (listing["id"], listing["trainerId"], listing["trainerName"],
                 Jsonb(listing["offeredMon"]), Jsonb(listing["wanted"]), listing["timestamp"]),
            )
            count = self._bump_user_count(cur, listing["trainerId"], 1)
            cur.execute("INSERT INTO history (text, ts) VALUES (%s, %s)", (receipt_text, int(time.time())))
        return count

    def persist_trade(self, listing, claim_row, receipt_text):
        """Atomically remove a listing, decrement the seller count, add a claim box row, and log a receipt."""
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute("DELETE FROM listings WHERE id = %s", (listing["id"],))
            if cur.rowcount == 0:
                return None
            seller_id = str(listing["trainerId"])
            count = self._bump_user_count(cur, seller_id, -1)
            cur.execute(
                "INSERT INTO claim_boxes (trainer_id, mon, from_name, from_id, original_offered, ts) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (seller_id, Jsonb(claim_row["mon"]), claim_row["fromName"], claim_row["fromId"],
                 claim_row["originalOffered"], int(time.time())),
            )
            cur.execute("INSERT INTO history (text, ts) VALUES (%s, %s)", (receipt_text, int(time.time())))
        return count

    def persist_withdraw(self, listing_id, trainer_id):
        """Atomically remove a listing owned by trainer_id and decrement the depositor count."""
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute("DELETE FROM listings WHERE id = %s AND trainer_id = %s", (listing_id, trainer_id))
            if cur.rowcount == 0:
                return None
            return self._bump_user_count(cur, trainer_id, -1)

    def persist_claim(self, trainer_id, idx):
        """Atomically remove the idx-th claim box row for trainer_id (insertion order preserved)."""
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT id FROM claim_boxes WHERE trainer_id = %s ORDER BY id LIMIT 1 OFFSET %s FOR UPDATE",
                (trainer_id, idx),
            )
            row = cur.fetchone()
            if not row:
                return False
            cur.execute("DELETE FROM claim_boxes WHERE id = %s", (row[0],))
        return True

    def persist_history(self, text):
        """Insert a receipt and cap the history table at the newest HISTORY_LIMIT rows."""
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute("INSERT INTO history (text, ts) VALUES (%s, %s)", (text, int(time.time())))
            cur.execute(
                f"DELETE FROM history WHERE id NOT IN "
                f"(SELECT id FROM history ORDER BY id DESC LIMIT {HISTORY_LIMIT})"
            )

    def persist_profile(self, trainer_id, profile):
        """Upsert a trainer profile."""
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute(
                """INSERT INTO profiles (trainer_id, data) VALUES (%s, %s)
                   ON CONFLICT (trainer_id) DO UPDATE SET data = EXCLUDED.data""",
                (trainer_id, Jsonb(profile)),
            )

    def add_receipt(self, text):
        """Prepend a receipt to the in-memory history log (kept to HISTORY_LIMIT entries)."""
        db = self.db
        db["history"].insert(0, {
            "text": text,
            "time": int(time.time()),
        })
        db["history"] = db["history"][:HISTORY_LIMIT]

    def self_clean_db(self):
        now = int(time.time())

        # In-memory purges (cheap, run on every request)
        # 1. Purge inactive online players (> 30 seconds timeout)
        for tid, pdata in list(self.db.get("active_players", {}).items()):
            if now - pdata.get("timestamp", 0) > PLAYER_TIMEOUT_SECONDS:
                self.db["active_players"].pop(tid, None)

        # 2. Purge stale challenges (> 15 seconds old)
        for tid, cdata in list(self.db.get("pending_challenges", {}).items()):
            if now - cdata.get("timestamp", 0) > CHALLENGE_TTL_SECONDS:
                self.db["pending_challenges"].pop(tid, None)

        # PostgreSQL purges are throttled: sync_pos hits this path at 10-20 Hz per
        # player, and disk/DB cleanups only need to happen occasionally.
        now_f = time.time()
        if now_f - self._last_pg_clean < 30.0:
            return
        self._last_pg_clean = now_f

        purged_listings = 0
        purged_claims = 0
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT id, trainer_id FROM listings WHERE %s - ts > %s", (now, LISTING_TTL_SECONDS))
            expired = cur.fetchall()
            if expired:
                cur.execute("DELETE FROM listings WHERE %s - ts > %s", (now, LISTING_TTL_SECONDS))
                purged_listings = len(expired)
                for _, tid in expired:
                    self._bump_user_count(cur, tid, -1)
            cur.execute("DELETE FROM claim_boxes WHERE %s - ts > %s", (now, CLAIM_TTL_SECONDS))
            purged_claims = cur.rowcount
            cur.execute(
                f"DELETE FROM history WHERE id NOT IN "
                f"(SELECT id FROM history ORDER BY id DESC LIMIT {HISTORY_LIMIT})"
            )

        if purged_listings > 0 or purged_claims > 0:
            print(f"[Self-Cleansing Engine] Purged {purged_listings} expired listings and {purged_claims} old claims.")
            self.load_db()  # re-sync memory from PostgreSQL
