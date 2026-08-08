# D2: structured JSON logging with a per-request request_id.
#
# Uvicorn's plaintext loggers (root, uvicorn.error, uvicorn.access) get replaced
# with a JSON Formatter emitting one object per line. A contextvar carries the
# active request_id so every log line emitted during a request is tagged with it
# (access lines too, via our custom AccessFormatter).

import json
import logging
import uuid
from contextvars import ContextVar

_LOCAL = ContextVar("ittoolkit_request_id", default="")


def current_request_id() -> str:
    return _LOCAL.get()


def set_request_id(rid: str) -> None:
    _LOCAL.set(rid)


class JsonFormatter(logging.Formatter):
    """Emit '%s'% ... msg as an inline JSON object, always including the
    request_id captured from the contextvar at emit time (for worker tasks
    that are not request-scoped, rid is empty)."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": current_request_id(),
        }
        # copy over any extra fields set via {extra: ...}
        for k in ("path", "status", "method", "dur_ms"):
            if hasattr(record, k):
                entry[k] = getattr(record, k)
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False, default=str)


class AccessFormatter(logging.Formatter):
    """Formats access records into JSON with structured fields.

    Records carry {path, method, status, dur_ms, request_id} as attrs (set via
    LogRecord.extra by the middleware). request_id is read from the record when
    available, falling back to the contextvar (for non-request logs).
    """

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "request_id": getattr(record, "request_id", None) or current_request_id(),
        }
        msg = record.getMessage()
        for k in ("path", "method", "status", "dur_ms"):
            if hasattr(record, k):
                entry[k] = getattr(record, k)
        entry["message"] = msg if msg else _message_from_args(record)
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry)


def _message_from_args(record: logging.LogRecord) -> str:
    """If a caller passed the uvicorn-style %s tuple, render a readable line."""
    try:
        if record.args:
            args = list(record.args)
            client, method, path, http_version, status = str(args[0]), str(args[1]), str(args[2]), str(args[3]), args[4]
            return f'{client} - "{method} {path} HTTP/{http_version}" {status}'
    except Exception:
        pass
    return ""


def configure() -> None:
    """Install JSON formatters on the app/uvicorn loggers (idempotent)."""
    fmt = JsonFormatter()
    access = AccessFormatter()
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    # remove any default handlers (uvicorn may add a base Config handler)
    for h in list(root.handlers):
        root.removeHandler(h)
    stdout = logging.StreamHandler()
    stdout.setFormatter(fmt)
    root.addHandler(stdout)

    for name in ("uvicorn", "uvicorn.error"):
        lg = logging.getLogger(name)
        lg.handlers.clear()
        lg.propagate = False
        sh = logging.StreamHandler()
        sh.setFormatter(fmt)
        lg.addHandler(sh)
        lg.setLevel(logging.INFO)

    access_log = logging.getLogger("uvicorn.access")
    access_log.handlers.clear()
    access_log.propagate = False
    ah = logging.StreamHandler()
    ah.setFormatter(access)
    access_log.addHandler(ah)
    # D2: the middleware emits the authoritative access line (with request_id +
    # duration) via the ittoolkit.access logger; uvicorn's own line is suppressed
    # so we don't emit two access records per request.
    access_log.setLevel(logging.WARNING)

    # ittoolkit.access: our own structured access line emitted by middleware.
    app_access = logging.getLogger("ittoolkit.access")
    app_access.handlers.clear()
    app_access.propagate = False
    aah = logging.StreamHandler()
    aah.setFormatter(AccessFormatter())
    app_access.addHandler(aah)
    app_access.setLevel(logging.INFO)