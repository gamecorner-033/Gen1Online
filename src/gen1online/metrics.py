"""Thread-safe in-memory metrics (counters + gauges) with Prometheus text rendering.

Counters/gauges reset on restart; daily action counts live in PostgreSQL
(``daily_counts``) and are merged in by :func:`render_prometheus`.
"""

import threading
import time

START_TIME = time.time()


class Metrics:
    def __init__(self):
        self._lock = threading.Lock()
        self._counters = {}
        self._gauges = {}
        self._bans = {}

    def inc_counter(self, name, labels=None, value=1):
        key = (name, tuple(sorted((labels or {}).items())))
        with self._lock:
            self._counters[key] = self._counters.get(key, 0) + value

    def set_gauge(self, name, value, labels=None):
        key = (name, tuple(sorted((labels or {}).items())))
        with self._lock:
            self._gauges[key] = value

    def gauge_value(self, name, labels=None):
        key = (name, tuple(sorted((labels or {}).items())))
        with self._lock:
            return self._gauges.get(key, 0)

    def snapshot(self):
        with self._lock:
            return dict(self._counters), dict(self._gauges)

    # --- gauges updated by handlers -------------------------------------

    def update_online(self, players_by_map):
        total = sum(players_by_map.values())
        self.set_gauge("online_players", total)
        for map_name, count in players_by_map.items():
            self.set_gauge("players_by_map", count, {"map": map_name})
        with self._lock:
            peak = self._gauges.get(("peak_online", ()), 0)
            if total > peak:
                self._gauges[("peak_online", ())] = total

    def refresh_online(self, storage):
        self.update_online(compute_players_by_map(storage))

    # --- admin temp bans (in-memory) ------------------------------------

    def ban(self, trainer_id, duration):
        with self._lock:
            self._bans[trainer_id] = time.time() + duration

    def unban(self, trainer_id):
        with self._lock:
            self._bans.pop(trainer_id, None)

    def is_banned(self, trainer_id):
        now = time.time()
        with self._lock:
            until = self._bans.get(trainer_id)
            if until is None:
                return False, None
            if until <= now:
                self._bans.pop(trainer_id, None)
                return False, None
            return True, int(until - now)

    def active_bans(self):
        now = time.time()
        with self._lock:
            return {tid: int(until - now) for tid, until in self._bans.items() if until > now}


METRICS = Metrics()


def compute_players_by_map(storage):
    players_by_map = {}
    for p in storage.db["active_players"].values():
        map_name = str(p.get("map")) if p.get("map") else "unknown"
        players_by_map[map_name] = players_by_map.get(map_name, 0) + 1
    return players_by_map


def _label_str(labels):
    if not labels:
        return ""
    return "{" + ",".join(f'{k}="{v}"' for k, v in labels) + "}"


def render_prometheus(storage):
    """Render all metrics in the Prometheus text exposition format."""
    now = time.time()

    players_by_map = compute_players_by_map(storage)
    METRICS.update_online(players_by_map)

    daily = storage.get_daily_stats(7)
    counters, gauges = METRICS.snapshot()

    lines = []
    lines.append("# HELP gen1online_uptime_seconds Seconds since the server started.")
    lines.append("# TYPE gen1online_uptime_seconds gauge")
    lines.append(f"gen1online_uptime_seconds {int(now - START_TIME)}")

    gauges_out = {
        "online_players": sum(players_by_map.values()),
        "peak_online": gauges.get(("peak_online", ()), 0),
        "listings": len(storage.db["listings"]),
        "pending_claims": sum(len(c) for c in storage.db["claim_boxes"].values()),
        "profiles": len(storage.db["profiles"]),
    }
    for name, value in sorted(gauges_out.items()):
        lines.append(f"# HELP gen1online_{name} {name}.")
        lines.append(f"# TYPE gen1online_{name} gauge")
        lines.append(f"gen1online_{name} {value}")

    for (name, labels), value in sorted(gauges.items()):
        if name in ("online_players", "peak_online", "players_by_map"):
            if name == "players_by_map":
                lines.append(f"# HELP gen1online_players_by_map Online players per map.")
                lines.append(f"# TYPE gen1online_players_by_map gauge")
            lines.append(f"gen1online_{name}{_label_str(labels)} {value}")

    for day, stat, value in daily:
        lines.append(f"# HELP gen1online_{stat}_total {stat} on {day}.")
        lines.append(f"# TYPE gen1online_{stat}_total counter")
        lines.append(f'gen1online_{stat}_total{{day="{day}"}} {value}')

    for (name, labels), value in sorted(counters.items()):
        lines.append(f"# TYPE gen1online_{name} counter")
        lines.append(f"gen1online_{name}{_label_str(labels)} {value}")

    return "\n".join(lines) + "\n"
