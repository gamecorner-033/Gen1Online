"""Public read-only server statistics handler (``GET /gts/stats``)."""

import time

from gen1online.metrics import METRICS, START_TIME, compute_players_by_map


def stats(storage):
    players_by_map = compute_players_by_map(storage)
    METRICS.refresh_online(storage)

    counters, gauges = METRICS.snapshot()

    today = time.strftime("%Y-%m-%d")
    daily_rows = storage.get_daily_stats(7)
    daily = {}
    for day, stat, value in daily_rows:
        daily.setdefault(day, {})[stat] = value

    requests_total = sum(v for (name, _), v in counters.items() if name == "http_requests_total")
    rate_limited_total = sum(v for (name, _), v in counters.items() if name == "rate_limited_total")

    return 200, {
        "success": True,
        "uptime_seconds": int(time.time() - START_TIME),
        "online_players": sum(players_by_map.values()),
        "peak_online": gauges.get(("peak_online", ()), 0),
        "players_by_map": players_by_map,
        "listings": len(storage.db["listings"]),
        "pending_claims": sum(len(c) for c in storage.db["claim_boxes"].values()),
        "profiles": len(storage.db["profiles"]),
        "requests_total": requests_total,
        "rate_limited_total": rate_limited_total,
        "today": daily.get(today, {}),
        "daily_7d": daily,
    }
