"""In-memory per-IP sliding-window rate limiter."""

import time

from gen1online.config import RATE_LIMIT_PER_MIN


class RateLimiter:
    def __init__(self, limit_per_min=RATE_LIMIT_PER_MIN):
        self._limit = limit_per_min
        self._hits = {}

    def allowed(self, ip):
        now = time.time()
        if ip not in self._hits:
            self._hits[ip] = []
        self._hits[ip] = [t for t in self._hits[ip] if now - t < 60]
        if len(self._hits[ip]) >= self._limit:
            return False
        self._hits[ip].append(now)
        return True
