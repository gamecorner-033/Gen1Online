#!/usr/bin/env python3
"""
One-time migration: import a legacy gts_database.json into PostgreSQL.

Usage:
    uv run gen1online-migrate [path/to/gts_database.json]
    uv run python -m gen1online.migrate [path/to/gts_database.json]

Defaults to ./gts_database.json. Connects using the same DATABASE_URL env var
as the server.

WARNING: truncates all GTS tables before importing.
"""
import json
import logging
import os
import re
import sys
import time

import psycopg
from psycopg.types.json import Jsonb

from gen1online.config import DB_URI
from gen1online.logging_utils import setup_logging
from gen1online.storage import SCHEMA_SQL

logger = logging.getLogger(__name__)


def main(argv=None):
    setup_logging()
    argv = list(sys.argv[1:]) if argv is None else list(argv)
    path = argv[0] if argv else os.path.join(os.getcwd(), "gts_database.json")
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    with psycopg.connect(DB_URI) as conn, conn.cursor() as cur:
        cur.execute(SCHEMA_SQL)
        for table in ("listings", "user_counts", "history", "claim_boxes", "profiles", "meta"):
            cur.execute(f"TRUNCATE {table} RESTART IDENTITY")

        for lid, listing in data.get("listings", {}).items():
            cur.execute(
                "INSERT INTO listings (id, trainer_id, trainer_name, offered_mon, wanted, ts) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (lid, str(listing.get("trainerId", "")), listing.get("trainerName", "TRAINER"),
                 Jsonb(listing.get("offeredMon", {})), Jsonb(listing.get("wanted", [])),
                 listing.get("timestamp", int(time.time()))),
            )
        for tid, count in data.get("user_counts", {}).items():
            cur.execute(
                "INSERT INTO user_counts (trainer_id, count) VALUES (%s, %s) "
                "ON CONFLICT (trainer_id) DO UPDATE SET count = EXCLUDED.count",
                (str(tid), count),
            )
        for receipt in data.get("history", [])[:50]:
            cur.execute(
                "INSERT INTO history (text, ts) VALUES (%s, %s)",
                (receipt.get("text", ""), receipt.get("time", 0)),
            )
        for tid, claims in data.get("claim_boxes", {}).items():
            for claim in claims:
                cur.execute(
                    "INSERT INTO claim_boxes (trainer_id, mon, from_name, from_id, original_offered, ts) "
                    "VALUES (%s, %s, %s, %s, %s, %s)",
                    (str(tid), Jsonb(claim.get("mon", {})), claim.get("fromName", ""),
                     claim.get("fromId", ""), claim.get("originalOffered"),
                     claim.get("timestamp", 0)),
                )
        for tid, profile in data.get("profiles", {}).items():
            cur.execute(
                "INSERT INTO profiles (trainer_id, data) VALUES (%s, %s) "
                "ON CONFLICT (trainer_id) DO UPDATE SET data = EXCLUDED.data",
                (str(tid), Jsonb(profile)),
            )

        max_num = 1001
        for lid in data.get("listings", {}):
            m = re.match(r"GTS_(\d+)", lid)
            if m:
                max_num = max(max_num, int(m.group(1)) + 1)
        cur.execute(
            "INSERT INTO meta (key, value) VALUES ('next_id', %s) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
            (str(max_num),),
        )

    logger.info(f"Migration complete: imported {len(data.get('listings', {}))} listings, "
                f"{len(data.get('history', []))} history entries, "
                f"{len(data.get('profiles', {}))} profiles into {DB_URI}")


if __name__ == "__main__":
    main()
