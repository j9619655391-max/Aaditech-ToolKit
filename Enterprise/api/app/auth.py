import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

from . import config

SESSION_COOKIE = "itk_session"
SESSION_TTL = timedelta(hours=12)


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt.encode("utf-8"), 120_000
    ).hex()
    return f"pbkdf2_sha256${120_000}${salt}${digest}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iterations, salt, expected = stored.split("$")
        if algo != "pbkdf2_sha256":
            return False
        digest = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt.encode("utf-8"), int(iterations)
        ).hex()
        return hmac.compare_digest(digest, expected)
    except ValueError:
        return False


def _sign(payload: str) -> str:
    return hmac.new(
        config.SESSION_SECRET.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def issue_session(user_id: int) -> str:
    """Return a signed session token. We store it client-side; the server
    decodes user id + expiry, verifying the HMAC (secret persisted to disk)."""
    expiry = int((datetime.now(timezone.utc) + SESSION_TTL).timestamp())
    payload = f"{user_id}.{expiry}"
    return f"{payload}.{_sign(payload)}"


def verify_session(token: str) -> int | None:
    """Return user_id if the token is valid, else None."""
    parts = token.split(".")
    if len(parts) != 3:
        return None
    payload, signature = f"{parts[0]}.{parts[1]}", parts[2]
    if not hmac.compare_digest(_sign(payload), signature):
        return None
    try:
        user_id, expiry = int(parts[0]), int(parts[1])
    except ValueError:
        return None
    if datetime.now(timezone.utc).timestamp() > expiry:
        return None
    return user_id


def secure_cookie(token: str) -> dict:
    return {
        "key": SESSION_COOKIE,
        "value": token,
        "httponly": True,
        "samesite": "lax",
        "secure": False,  # LAN http by default; flip when TLS terminated
        "max_age": int(SESSION_TTL.total_seconds()),
    }
