"""In-memory rate limiting + login lockout (B2).

Fixed-window counters keyed by IP (login + general API burst) and by username
(failed-login lockout). A single process keeps state in memory; for
multi-worker deployments move this to Redis, but uvicorn runs one worker here.

Windows:
  LOGIN_MAX     - max login attempts per IP per LOGIN_WINDOW before 429
  FAILED_MAX    - max FAILED logins per username before a LOCKOUT_SECONDS cool-down
  API_MAX       - max api/* requests per IP per API_WINDOW (portal burst limit)
"""
import asyncio
from collections import defaultdict

from fastapi import HTTPException, Request

LOGIN_WINDOW = 300       # 5 minutes
LOGIN_MAX = 10           # per-IP over the window
FAILED_MAX = 5           # consecutive failures per username
LOCKOUT_SECONDS = 900    # 15 minutes
API_WINDOW = 10          # seconds
API_MAX = 120            # requests per IP per API_WINDOW


class _Counter:
    def __init__(self):
        self._buckets: dict[str, list[float]] = defaultdict(list)
        self._lock = asyncio.Lock()

    async def hit(self, key: str, limit: int, window: float) -> bool:
        """Record one hit; return True if allowed, False if over limit."""
        now = asyncio.get_event_loop().time()
        async with self._lock:
            recent = self._buckets[key]
            while recent and now - recent[0] > window:
                recent.pop(0)
            if len(recent) >= limit:
                return False
            recent.append(now)
            return True

    async def count(self, key: str, window: float) -> int:
        now = asyncio.get_event_loop().time()
        async with self._lock:
            recent = self._buckets[key]
            while recent and now - recent[0] > window:
                recent.pop(0)
            return len(recent)

    async def reset(self, key: str) -> None:
        async with self._lock:
            self._buckets.pop(key, None)


_ip = _Counter()
_user = _Counter()          # keyed "user:<username>" failure timestamps


def client_ip(request: Request) -> str:
    fwd = request.headers.get("X-Forwarded-For")
    if fwd:
        return fwd.split(",")[0].strip()
    if request.client:
        return request.client.host or "unknown"
    return "unknown"


async def enforce_api_burst(request: Request) -> None:
    """General per-IP burst limit on portal calls. Login, healthz, ingest and
    the agent command channel are exempt so legitimate fleet traffic isn't
    throttled."""
    path = request.url.path
    if path == "/healthz" or path.startswith("/ingest") or path.startswith("/api/commands") or path.startswith("/api/agent/heartbeat"):
        return
    ip = client_ip(request)
    if not await _ip.hit(f"api:{ip}", API_MAX, API_WINDOW):
        raise HTTPException(status_code=429, detail="Too many requests")


async def check_login(ip: str, username: str) -> None:
    """Enforce per-IP login cap and per-username lockout. Call BEFORE verifying
    credentials."""
    if not await _ip.hit(f"login:{ip}", LOGIN_MAX, LOGIN_WINDOW):
        raise HTTPException(status_code=429, detail="Too many login attempts, try later")
    recent = await _user.count(f"user:{username}", LOCKOUT_SECONDS)
    if recent >= FAILED_MAX:
        raise HTTPException(status_code=423, detail="Account locked after too many failed attempts")


async def record_failure(username: str) -> None:
    await _user.hit(f"user:{username}", FAILED_MAX + 1, LOCKOUT_SECONDS)


async def record_success(username: str) -> None:
    await _user.reset(f"user:{username}")