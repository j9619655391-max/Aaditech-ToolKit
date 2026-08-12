import os
import secrets
from pathlib import Path

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://ittoolkit:change-me@db:5432/ittoolkit")
SERVER_HOST = os.environ.get("SERVER_HOST", "localhost")
PORTAL_DIR = os.environ.get("PORTAL_DIR", "/app/portal")
FEATURES_FILE = os.environ.get("FEATURES_FILE", "/app/features.json")
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
ARTIFACTS_DIR = Path(os.environ.get("ARTIFACTS_DIR", "/artifacts"))

# C3: bounds so a misbehaving client can't dump tables or exhaust memory.
MAX_LIST_LIMIT = int(os.environ.get("MAX_LIST_LIMIT", "500"))   # list_* LIMIT cap
MAX_INGEST_EVENTS = int(os.environ.get("MAX_INGEST_EVENTS", "500"))  # events/batch
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(10 * 1024 * 1024)))  # 413 threshold

# SaaS setup: how the Windows agent MSI gets built.
#   local_windows -> deploy.ps1 builds + signs + publishes on the Windows server
#   github        -> the server triggers this repo's CI (workflow_dispatch) and
#                    downloads the MSI artifact (Linux hosts)
#   manual        -> operator builds elsewhere and uploads the MSI
# The wizard may override this per-company at setup time (settings.build_mode).
BUILD_MODE = os.environ.get("BUILD_MODE", "manual")

# ---------------------------------------------------------------- environment (B4)

# "prod" (default) hides the interactive API docs (/docs, /openapi.json).
# Set ENVIRONMENT=dev to expose them for development/debugging.
ENVIRONMENT = os.environ.get("ENVIRONMENT", "prod").strip().lower()
IS_DEV = ENVIRONMENT in ("dev", "development", "test", "testing")

# ---------------------------------------------------------------- command channel (P5)

ALLOW_RUN_SCRIPT = os.environ.get("COMMANDS_RUN_SCRIPT_ALLOWED", "false").lower() in (
    "1", "true", "yes",
)
RUN_SCRIPT_ALLOWLIST = [
    s.strip()
    for s in os.environ.get("RUN_SCRIPT_ALLOWLIST", "").split(",")
    if s.strip()
]

# ---------------------------------------------------------------- alerts (P6)

ALERT_EVAL_MINUTES = int(os.environ.get("ALERT_EVAL_MINUTES", "1"))

# ---------------------------------------------------------------- time-series metrics (Phase A)
# Raw samples stream from agents at metrics_interval_seconds; the rollup task
# downsamples to hour/day buckets and retention purges old data so storage stays
# bounded on plain Postgres. Query windows wider than raw retention read the
# rollups, so 7d/30d graphs stay cheap.

TS_RAW_RETENTION_HOURS = int(os.environ.get("TS_RAW_RETENTION_HOURS", "48"))
TS_HOURLY_RETENTION_DAYS = int(os.environ.get("TS_HOURLY_RETENTION_DAYS", "30"))
TS_DAILY_RETENTION_DAYS = int(os.environ.get("TS_DAILY_RETENTION_DAYS", "365"))
TS_ROLLUP_MINUTES = int(os.environ.get("TS_ROLLUP_MINUTES", "60"))
MAX_METRICS_POINTS = int(os.environ.get("MAX_METRICS_POINTS", "2000"))
METRICS_INTERVAL_SECONDS = int(os.environ.get("METRICS_INTERVAL_SECONDS", "60"))

# SMTP email delivery for alerts (P6.1). Emails are only sent when SMTP_HOST
# is set; the rest are optional. Provider presets fill in host/port/encryption
# when the operator picks one during first-run setup (custom keeps env values).
SMTP_PROVIDERS = {
    "hostinger": {"host": "smtp.hostinger.com", "port": 465, "encryption": "ssl"},
    "office365": {"host": "smtp.office365.com", "port": 587, "encryption": "starttls"},
    "gmail": {"host": "smtp.gmail.com", "port": 587, "encryption": "starttls"},
    "hotmail": {"host": "smtp-mail.outlook.com", "port": 587, "encryption": "starttls"},
}

SMTP_HOST = os.environ.get("SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD", "")
SMTP_FROM = os.environ.get("SMTP_FROM", "")
SMTP_TO = [
    s.strip()
    for s in os.environ.get("SMTP_TO", "").split(",")
    if s.strip()
]
_SMTP_STARTTLS = os.environ.get("SMTP_STARTTLS", "true").lower() in ("1", "true", "yes")
SMTP_ENCRYPTION = os.environ.get("SMTP_ENCRYPTION", "starttls" if _SMTP_STARTTLS else "none")

# Webhook alert delivery (P6.2). Alerts are posted to a generic/Slack/Teams
# incoming webhook when WEBHOOK_ENABLED=true and WEBHOOK_URL is set. Values can
# be overridden per-install via the portal Alerts view (settings table).
WEBHOOK_ENABLED = os.environ.get("WEBHOOK_ENABLED", "false")
WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "")
WEBHOOK_TYPE = os.environ.get("WEBHOOK_TYPE", "generic")  # generic | slack | teams

# ---------------------------------------------------------------- API token

_PLACEHOLDERS = {"", "change-me", "change-me-random-token", "changeme"}


def _resolve_secret(env_name: str, filename: str) -> str:
    """Use the env var if it's a real value; else read-or-create a persisted
    random secret under DATA_DIR so it survives restarts. Values shorter than
    32 chars are treated as weak/legacy and regenerated."""
    val = os.environ.get(env_name, "")
    if val not in _PLACEHOLDERS and len(val) >= 32:
        return val
    f = DATA_DIR / filename
    if f.exists():
        tok = f.read_text(encoding="utf-8").strip()
        if tok and len(tok) >= 32:
            return tok
    tok = secrets.token_urlsafe(32)
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        f.write_text(tok, encoding="utf-8")
    except OSError:
        pass
    return tok


def _resolve_token() -> tuple[str, bool]:
    """Return (token, was_autogenerated).

    Uses API_TOKEN when it is a real value. Otherwise auto-generates a random
    token, persists it to DATA_DIR/api_token so it survives restarts, and flags
    it so startup can print it for the operator.
    """
    provided = os.environ.get("API_TOKEN", "")
    if provided not in _PLACEHOLDERS:
        return provided, False

    token_file = DATA_DIR / "api_token"
    if token_file.exists():
        token = token_file.read_text(encoding="utf-8").strip()
        if token:
            return token, False

    token = secrets.token_urlsafe(32)
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        token_file.write_text(token, encoding="utf-8")
    except OSError:
        pass  # volume unavailable -> token still valid for this process lifetime
    return token, True


API_TOKEN, API_TOKEN_AUTOGENERATED = _resolve_token()
SESSION_SECRET = _resolve_secret("SESSION_SECRET", "session_secret")


def rotate_session_secret() -> str:
    """Generate a fresh strong SESSION_SECRET, persist it to DATA_DIR so it
    survives restarts, and update the in-process value immediately (vault/auth
    read config.SESSION_SECRET at call-time, so encryption stays consistent).
    Returns the new secret for the one-time setup download."""
    global SESSION_SECRET
    tok = secrets.token_urlsafe(48)
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        (DATA_DIR / "session_secret").write_text(tok, encoding="utf-8")
    except OSError:
        pass  # volume unavailable -> in-process value still valid for this run
    SESSION_SECRET = tok
    return tok
