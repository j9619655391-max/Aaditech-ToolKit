import base64
import hashlib

from cryptography.fernet import Fernet, InvalidToken

from . import config

# Secrets stored in the DB `settings` table (SMTP password, GitHub PAT) are
# encrypted at rest with a Fernet key derived from SESSION_SECRET. The secret
# never lives in plaintext in Postgres and is never returned by any API.
_PREFIX = "enc$v1$"


def _fernet() -> Fernet:
    digest = hashlib.sha256(config.SESSION_SECRET.encode("utf-8")).digest()
    key = base64.urlsafe_b64encode(digest)
    return Fernet(key)


def encrypt(plaintext: str) -> str:
    """Encrypt a secret for storage. Returns a prefixed token; empty input
    encrypts to a token too, so callers can store '' like before."""
    token = _fernet().encrypt(plaintext.encode("utf-8")).decode("ascii")
    return f"{_PREFIX}{token}"


def decrypt(value: str) -> str:
    """Decrypt a stored secret. Legacy/plaintext values (not yet encrypted,
    e.g. from older installs) pass through unchanged."""
    if not value:
        return value
    if not value.startswith(_PREFIX):
        return value
    try:
        token = value[len(_PREFIX):]
        return _fernet().decrypt(token.encode("ascii")).decode("utf-8")
    except InvalidToken:
        # Corrupt/foreign ciphertext: never crash the caller, fail closed-ish
        # by returning the original so operators see something is wrong.
        return value


def is_encrypted(value: str) -> bool:
    return bool(value) and value.startswith(_PREFIX)
