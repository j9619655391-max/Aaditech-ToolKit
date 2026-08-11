import hmac
import io
import json
import logging as _logging
import re
import secrets
import time
import uuid
import asyncio
import csv
from datetime import datetime, timezone
from pathlib import Path

import asyncpg
from fastapi import FastAPI, Depends, Header, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import auth, bundle, certs, config, db, github, logging_setup, metrics, ratelimit, rules, vault

# D2: replace default uvicorn/formatter logs with our JSON line format before
# any request is served.
logging_setup.configure()

# B4: hide interactive API docs (/docs, /redoc, /openapi.json) in prod. Only
# exposed when ENVIRONMENT=dev.
_docs_off = not config.IS_DEV
app = FastAPI(
    title="IT-Toolkit Enterprise",
    version="1.0.0",
    docs_url="/docs" if not _docs_off else None,
    redoc_url="/redoc" if not _docs_off else None,
    openapi_url="/openapi.json" if not _docs_off else None,
)

# D2: middleware-emitted structured access line (uvicorn's own is suppressed).
_access_log = _logging.getLogger("ittoolkit.access")


@app.middleware("http")
async def _api_burst_limit(request: Request, call_next):
    # B2: general per-IP burst limiter. Exempts healthz/ingest/command channel.
    try:
        await ratelimit.enforce_api_burst(request)
    except HTTPException as exc:
        return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
    return await call_next(request)


@app.middleware("http")
async def _body_size_limit(request: Request, call_next):
    # C3: reject oversized bodies up front instead of buffering them whole.
    length = request.headers.get("content-length")
    if length is not None:
        try:
            if int(length) > config.MAX_BODY_BYTES:
                return JSONResponse(
                    status_code=413,
                    content={"detail": "Request body too large"},
                )
        except ValueError:
            pass
    return await call_next(request)


@app.middleware("http")
async def _request_id_middleware(request: Request, call_next):
    # D2: assign a request_id (honoring an inbound X-Request-ID if present, so a
    # fleet operator can correlate agent batches to their logs), tag every log
    # line in this request, and return it on the response header. We do NOT reset
    # the contextvar here: uvicorn's access line is emitted in the same task
    # after the response finishes, so it must still see this request's id; each
    # new request sets its own.
    rid = request.headers.get("X-Request-ID", "").strip() or uuid.uuid4().hex[:16]
    logging_setup.set_request_id(rid)
    request.state.request_id = rid
    response = await call_next(request)
    response.headers["X-Request-ID"] = rid
    return response


@app.middleware("http")
async def _observe_http(request: Request, call_next):
    # D1: per-request latency histogram + request/status counter. Runs first so
    # every response (success or middleware rejection) is observed.
    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        # record 500-category responses as observed, then re-raise
        metrics.http_duration.observe(time.perf_counter() - start, labels={"route": _route_for(request)})
        metrics.http_requests.inc(
            labels={"method": request.method, "route": _route_for(request), "status": "500"}
        )
        _access_log.error(
            "", extra=_access_fields(request, 500, start)
        )
        raise
    metrics.http_duration.observe(
        time.perf_counter() - start,
        {"route": _route_for(request)},
    )
    metrics.http_requests.inc(
        labels={"method": request.method, "route": _route_for(request), "status": str(response.status_code)}
    )
    _access_log.info("", extra=_access_fields(request, response.status_code, start))
    return response


def _access_fields(request: Request, status_code: int, started_at: float) -> dict:
    """Structured access-log fields for the request (request_id lives in the
    contextvar filled by _request_id_middleware)."""
    return {
        "request_id": getattr(request.state, "request_id", ""),
        "path": _route_for(request),
        "method": request.method,
        "status": status_code,
        "dur_ms": round((time.perf_counter() - started_at) * 1000.0, 2),
    }


def _route_for(request: Request) -> str:
    """Stable route label: prefer the matched route template, fall back to a
    bare path so dynamic segments (ids) don't explode label cardinality."""
    route = getattr(request, "route", None) or request.scope.get("route")
    path = getattr(route, "path", None)
    if not path:
        path = request.url.path
    # D1: collapse trailing ids / numeric path segments
    return re.sub(r"/[0-9]+(\?|$)", r"/{id}\1", path) or path

ROLES = ("admin", "operation", "monitoring")


def _clamp_limit(limit: int) -> int:
    """C3: bound LIMIT to 1..MAX_LIST_LIMIT so limit=-1 can't dump a table."""
    if limit <= 0:
        return 1
    return min(limit, config.MAX_LIST_LIMIT)


# ---------------------------------------------------------------- deps

async def require_setup_done() -> None:
    pool = await db.connect()
    done = await pool.fetchval("SELECT value FROM settings WHERE key = 'setup_complete'")
    complete = bool(done and str(done).strip() not in ("0", "", "false", "False"))
    if not complete:
        raise HTTPException(status_code=428, detail="Setup required")


async def require_session(request: Request) -> dict:
    token = request.cookies.get(auth.SESSION_COOKIE, "")
    user_id = auth.verify_session(token)
    if user_id is None:
        raise HTTPException(status_code=401, detail="Not logged in")
    pool = await db.connect()
    user = await pool.fetchrow(
        "SELECT id, username, role, active, company_id FROM users WHERE id = $1 AND active = TRUE",
        user_id,
    )
    if user is None:
        raise HTTPException(status_code=401, detail="Not logged in")
    return dict(user)


def _company_scope(user: dict, alias: str, args: list, sql: str) -> tuple[str, list]:
    """F4: restrict a query to the caller's company.

    Appends an AND clause on <alias>.company_id. Users without a company
    (legacy installs / no setup yet) are unscoped so they keep working. Rows
    with a NULL company_id (legacy agents enrolled before F4, or alerts with no
    agent) are treated as unassigned and stay visible to every company user.
    Callers must build their LIMIT clause AFTER this returns.
    """
    cid = user.get("company_id")
    if not cid:
        return sql, args
    args.append(cid)
    return f"{sql} AND ({alias}.company_id = ${len(args)} OR {alias}.company_id IS NULL)", args


async def _company_id(pool) -> int | None:
    """The 'default' company id: agents enroll into it when they first connect.
    Set during first-run setup; NULL until then."""
    val = await pool.fetchval("SELECT value FROM settings WHERE key = 'default_company_id'")
    try:
        return int(val) if val else None
    except (TypeError, ValueError):
        return None


def require_role(*roles: str):
    """Dependency factory: like require_session, but also enforces a role."""

    async def _dep(user: dict = Depends(require_session)) -> dict:
        if user["role"] not in roles:
            raise HTTPException(status_code=403, detail="Forbidden for this role")
        return user

    return _dep


# ---------------------------------------------------------------- audit trail (D3)

async def _audit(
    pool,
    *,
    action: str,
    target: str = "",
    detail: dict | None = None,
    user: dict | None = None,
    ip: str = "",
) -> None:
    """Append one row to audit_log. Never raises: audit failures must not make
    the primary operation fail."""
    try:
        await pool.execute(
            "INSERT INTO audit_log (user_id, username, role, action, target, detail, ip) "
            "VALUES ($1, $2, $3, $4, $5, $6, $7)",
            (user or {}).get("id"),
            (user or {}).get("username", ""),
            (user or {}).get("role", ""),
            action,
            target,
            json.dumps(detail or {}),
            ip,
        )
    except Exception:
        pass


# ---------------------------------------------------------------- agent auth (B6)

async def _get_or_create_agent(pool, hostname: str) -> dict:
    # F4: new agents enroll into the default company (set during setup). The
    # ON CONFLICT branch only refreshes last_seen, so an existing agent keeps
    # whatever company it was already assigned to.
    cid = await _company_id(pool)
    row = await pool.fetchrow(
        "INSERT INTO agents (hostname, company_id) VALUES ($1, $2) "
        "ON CONFLICT (hostname) DO UPDATE SET last_seen = now() "
        "RETURNING id, hostname, agent_token, agent_token_revoked, company_id",
        hostname, cid,
    )
    return dict(row)


async def issue_agent_token(pool, agent_id: int) -> str:
    """One-time: mint and persist a per-agent token. Re-runs keep the existing
    token so the agent doesn't get a new identity on every re-enroll."""
    existing = await pool.fetchval(
        "SELECT agent_token FROM agents WHERE id = $1", agent_id
    )
    if existing:
        return existing
    token = secrets.token_urlsafe(32)
    await pool.execute(
        "UPDATE agents SET agent_token = $2 WHERE id = $1", agent_id, token
    )
    return token


def _bearer_token(authorization: str) -> str:
    authorization = authorization.strip()
    if not authorization.startswith("Bearer "):
        return ""
    return authorization[len("Bearer "):].strip()


async def require_agent_token(hostname: str, authorization: str) -> dict:
    """Authorize an agent-facing call (ingest, command poll/result).

    Priority:
      1. A per-agent token that matches this agent's stored agent_token.
      2. The shared fleet API_TOKEN — still accepted for backwards compat, but
         only until the agent has enrolled (enroll rotates it off).
    Rejects revoked agents (agent_token_revoked) even with the right token.
    """
    pool = await db.connect()
    agent = await _get_or_create_agent(pool, hostname)
    if agent["agent_token_revoked"]:
        raise HTTPException(status_code=403, detail="Agent revoked")

    supplied = _bearer_token(authorization)
    if not supplied:
        raise HTTPException(status_code=401, detail="Invalid or missing token")

    if agent["agent_token"]:
        if not hmac.compare_digest(supplied, agent["agent_token"]):
            raise HTTPException(status_code=401, detail="Invalid agent token")
        return agent

    if hmac.compare_digest(supplied, config.API_TOKEN):
        return agent

    raise HTTPException(status_code=401, detail="Invalid or missing token")


# ---------------------------------------------------------------- models

class EventItem(BaseModel):
    kind: str
    payload: dict = Field(default_factory=dict)
    sanitized: bool = False
    captured_at: str | None = None
    client_msg_id: str | None = None


class IngestBatch(BaseModel):
    hostname: str
    os: str = ""
    agent_version: str = ""
    ip: str = ""
    events: list[EventItem] = Field(default_factory=list)


class FeatureUpdate(BaseModel):
    enabled: bool | None = None
    config: dict | None = None


class SetupSmtp(BaseModel):
    provider: str = "custom"  # hostinger | office365 | gmail | hotmail | custom | none
    email: str = ""
    password: str = ""
    recipient: str = ""
    host: str = ""
    port: int | None = None
    encryption: str = "starttls"  # starttls | ssl | none


class SetupRequest(BaseModel):
    company_name: str = Field(min_length=1, max_length=100)
    server_host: str = Field(min_length=1, max_length=255)
    admin_username: str = Field(min_length=3, max_length=40)
    admin_password: str = Field(min_length=8, max_length=128)
    branding: dict = Field(default_factory=dict)
    smtp: SetupSmtp | None = None
    # SaaS agent-build mode (Windows Server vs GitHub remote vs manual).
    build_mode: str = Field(default="manual")          # local_windows | github | manual
    github_repo: str = Field(default="", max_length=255)   # owner/repo
    github_token: str = Field(default="", max_length=255)  # PAT (actions:write+read)


class BuildTriggerRequest(BaseModel):
    repo: str = Field(default="", max_length=255)
    token: str = Field(default="", max_length=255)  # empty = use stored PAT
    branch: str = "main"


class LoginRequest(BaseModel):
    username: str
    password: str


class UserCreate(BaseModel):
    username: str = Field(min_length=3, max_length=40)
    password: str = Field(min_length=8, max_length=128)
    role: str = "monitoring"


class UserUpdate(BaseModel):
    role: str | None = None
    active: bool | None = None
    password: str | None = None


class CommandCreate(BaseModel):
    agent_id: int
    kind: str = Field(pattern="^(reboot|wake|run-script)$")
    payload: dict = Field(default_factory=dict)


class CommandResult(BaseModel):
    hostname: str
    status: str = Field(pattern="^(completed|failed)$")
    output: str = ""
    exit_code: int | None = None


class WebhookSettings(BaseModel):
    enabled: bool = False
    url: str = Field(default="", max_length=2000)
    type: str = Field(default="generic", pattern="^(generic|slack|teams)$")
    token: str = Field(default="", max_length=500)


class CompanyCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)


# ---------------------------------------------------------------- lifecycle

@app.on_event("startup")
async def startup():
    await db.migrate()  # C2: single guarded startup migration (provisions all tables)
    await db.connect()
    _alert_task = asyncio.create_task(rules.alert_loop())
    app.state.alert_task = _alert_task
    if config.API_TOKEN_AUTOGENERATED:
        print(
            "\n======================================================"
            "\n  AUTO-GENERATED API TOKEN (no API_TOKEN was configured)"
            "\n  save this now - it is shown only at first startup:"
            f"\n\n      {config.API_TOKEN}\n"
            "\n  copy it into the portal (top-right) and into"
            "\n  Enterprise/agent/agent-config.json (token field)."
            "\n======================================================\n",
            flush=True,
        )


@app.on_event("shutdown")
async def shutdown():
    task = getattr(app.state, "alert_task", None)
    if task is not None:
        task.cancel()
    await db.disconnect()


# ---------------------------------------------------------------- setup

@app.get("/api/setup/status")
async def setup_status():
    pool = await db.connect()
    done = await pool.fetchval("SELECT value FROM settings WHERE key = 'setup_complete'")
    complete = bool(done and str(done).strip() not in ("0", "", "false", "False"))
    info = {"setup_complete": complete, "default_build_mode": config.BUILD_MODE}
    if complete:
        for key in ("company_name", "server_host", "branding", "build_mode", "github_repo"):
            val = await pool.fetchval("SELECT value FROM settings WHERE key = $1", key)
            if key == "branding" and val:
                val = json.loads(val)
            info[key] = val
    return info


@app.post("/api/setup")
async def run_setup(payload: SetupRequest, request: Request, response: Response):
    pool = await db.connect()
    done = await pool.fetchval("SELECT value FROM settings WHERE key = 'setup_complete'")
    if done and str(done).strip() not in ("0", "", "false", "False"):
        raise HTTPException(status_code=409, detail="Setup already complete")

    # SESSION_SECRET: rotate to a fresh strong value on first-time setup, BEFORE
    # any vault.encrypt() below, so every stored secret is encrypted under the
    # new key. The value is handed back once for the operator to download.
    session_secret = config.rotate_session_secret()

    # C4: resolve/validate EVERYTHING before the first write so a crash can't
    # leave a half-configured install. setup_complete is written last, inside
    # the same transaction — any failure rolls back so setup can be retried.

    certs.ensure_certs(payload.server_host)

    branding = json.dumps(payload.branding or {})
    mode = payload.build_mode or config.BUILD_MODE

    smtp_values: list[tuple[str, str]] = []
    smtp = payload.smtp
    if smtp and smtp.email and smtp.provider != "none":
        if smtp.provider == "custom":
            host, port, encryption = smtp.host, smtp.port, smtp.encryption
        else:
            preset = config.SMTP_PROVIDERS.get(smtp.provider)
            if preset is None:
                raise HTTPException(status_code=422, detail=f"Unknown SMTP provider: {smtp.provider}")
            host, port, encryption = preset["host"], preset["port"], preset["encryption"]
        if not host or not port:
            raise HTTPException(status_code=422, detail="SMTP host and port are required")
        if encryption not in ("starttls", "ssl", "none"):
            raise HTTPException(status_code=422, detail="SMTP encryption must be starttls, ssl or none")
        smtp_values = [
            ("smtp_host", host),
            ("smtp_port", str(port)),
            ("smtp_user", smtp.email),
            ("smtp_password", vault.encrypt(smtp.password)),
            ("smtp_from", smtp.email),
            ("smtp_to", smtp.recipient or smtp.email),
            ("smtp_encryption", encryption),
        ]

    try:
        async with pool.acquire() as conn:
            async with conn.transaction():
                for key, value in (
                    ("company_name", payload.company_name),
                    ("server_host", payload.server_host),
                    ("branding", branding),
                    ("build_mode", mode),
                    ("github_repo", github._normalize_repo(payload.github_repo)),
                    ("github_token", vault.encrypt(payload.github_token.strip())),
                ):
                    await conn.execute(
                        "INSERT INTO settings (key, value) VALUES ($1, $2) "
                        "ON CONFLICT (key) DO UPDATE SET value = $2",
                        key, value,
                    )
                for key, value in smtp_values:
                    await conn.execute(
                        "INSERT INTO settings (key, value) VALUES ($1, $2) "
                        "ON CONFLICT (key) DO UPDATE SET value = $2",
                        key, value,
                    )
                # setup_complete LAST so a partial run never leaves a 409 wall.
                await conn.execute(
                    "INSERT INTO settings (key, value) VALUES ($1, $2) "
                    "ON CONFLICT (key) DO UPDATE SET value = $2",
                    "setup_complete", "1",
                )
                # F4: create the tenant company, make it the default (new agents
                # enroll into it), and bind the admin user to it.
                company = await conn.fetchrow(
                    "INSERT INTO companies (name) VALUES ($1) "
                    "ON CONFLICT (name) DO UPDATE SET name = companies.name "
                    "RETURNING id",
                    payload.company_name,
                )
                company_id = company["id"]
                await conn.execute(
                    "INSERT INTO settings (key, value) VALUES ($1, $2) "
                    "ON CONFLICT (key) DO UPDATE SET value = $2",
                    "default_company_id", str(company_id),
                )
                user = await conn.fetchrow(
                    "INSERT INTO users (username, password_hash, role, company_id) "
                    "VALUES ($1, $2, 'admin', $3) RETURNING id, username, role, company_id",
                    payload.admin_username, auth.hash_password(payload.admin_password), company_id,
                )
    except Exception:
        # C4: transaction above rolls back automatically on any error, so a
        # partial setup is never left behind and the wizard can be retried.
        raise
    # committed
    token = auth.issue_session(user["id"])
    response.set_cookie(**auth.secure_cookie(token, secure=auth.request_secure(request)))
    await _audit(
        pool,
        action="setup.complete",
        target="company",
        detail={"company": payload.company_name, "build_mode": mode},
        user=dict(user),
        ip=ratelimit.client_ip(request),
    )
    return {
        "company": payload.company_name,
        "server_host": payload.server_host,
        "admin": dict(user),
        "session_secret": session_secret,
    }


# ---------------------------------------------------------------- sessions

@app.post("/api/login")
async def login(payload: LoginRequest, request: Request, response: Response):
    await require_setup_done()
    # B2: per-IP login cap + per-user lockout before credential check.
    await ratelimit.check_login(ratelimit.client_ip(request), payload.username)
    pool = await db.connect()
    user = await pool.fetchrow(
        "SELECT id, username, password_hash, role, active FROM users WHERE username = $1",
        payload.username,
    )
    ok = bool(user and user["active"] and auth.verify_password(payload.password, user["password_hash"]))
    if not ok:
        await ratelimit.record_failure(payload.username)
        await _audit(
            pool,
            action="auth.login_failed",
            target="user",
            detail={"username": payload.username},
            ip=ratelimit.client_ip(request),
        )
        raise HTTPException(status_code=401, detail="Invalid credentials")
    await ratelimit.record_success(payload.username)
    token = auth.issue_session(user["id"])
    response.set_cookie(**auth.secure_cookie(token, secure=auth.request_secure(request)))
    await _audit(
        pool,
        action="auth.login",
        target=f"user:{user['username']}",
        user=dict(user),
        ip=ratelimit.client_ip(request),
    )
    return {"username": user["username"], "role": user["role"]}


@app.post("/api/logout")
async def logout(response: Response):
    response.delete_cookie(auth.SESSION_COOKIE)
    return {"ok": True}


@app.get("/api/me")
async def me(user: dict = Depends(require_session)):
    return user


@app.get("/api/bootstrap")
async def bootstrap(user: dict = Depends(require_session)):
    pool = await db.connect()
    info = {"user": user}
    for key in ("company_name", "server_host", "branding"):
        val = await pool.fetchval("SELECT value FROM settings WHERE key = $1", key)
        if key == "branding" and val:
            val = json.loads(val)
        info[key] = val
    info["agent_token_configured"] = bool(config.API_TOKEN)
    if user["role"] == "admin":
        info["agent_token"] = config.API_TOKEN
    # F4: tenant context for the current user + (admin) the company directory.
    if user.get("company_id"):
        info["company"] = await pool.fetchrow(
            "SELECT id, name, created_at FROM companies WHERE id = $1",
            user["company_id"],
        )
    if user["role"] == "admin":
        info["companies"] = [dict(r) for r in await pool.fetch("SELECT id, name, created_at FROM companies ORDER BY id")]
    return info


# ---------------------------------------------------------------- user management (admin)

def _check_role(value: str) -> None:
    if value not in ROLES:
        raise HTTPException(status_code=422, detail=f"Invalid role: {value}")


@app.get("/api/users", dependencies=[Depends(require_session)])
async def list_users(admin: dict = Depends(require_role("admin"))):
    pool = await db.connect()
    rows = await pool.fetch(
        "SELECT id, username, role, active, company_id, created_by, created_at "
        "FROM users ORDER BY id"
    )
    # F4: tenant-scoped listing — an admin only sees users of their own company
    # (unless they have no company yet, e.g. legacy/global admin).
    if admin.get("company_id"):
        rows = [r for r in rows if r["company_id"] == admin["company_id"]]
    return [dict(r) for r in rows]


@app.post("/api/users", dependencies=[Depends(require_session)])
async def create_user(payload: UserCreate, request: Request, admin: dict = Depends(require_role("admin"))):
    _check_role(payload.role)
    pool = await db.connect()
    try:
        row = await pool.fetchrow(
            "INSERT INTO users (username, password_hash, role, created_by, company_id) "
            "VALUES ($1, $2, $3, $4, $5) "
            "RETURNING id, username, role, active, company_id, created_at",
            payload.username, auth.hash_password(payload.password), payload.role,
            admin["id"], admin.get("company_id"),
        )
    except asyncpg.exceptions.UniqueViolationError:
        raise HTTPException(status_code=409, detail="Username already exists")
    await _audit(
        pool,
        action="user.create",
        target=f"user:{payload.username}",
        detail={"role": payload.role},
        user=admin,
        ip=ratelimit.client_ip(request),
    )
    return dict(row)


@app.put("/api/users/{user_id}", dependencies=[Depends(require_session)])
async def update_user(
    user_id: int, payload: UserUpdate, request: Request, admin: dict = Depends(require_role("admin"))
):
    if payload.role is not None:
        _check_role(payload.role)
    pool = await db.connect()
    row = await pool.fetchrow("SELECT * FROM users WHERE id = $1", user_id)
    if row is None:
        raise HTTPException(status_code=404, detail="User not found")
    if row["id"] == admin["id"] and payload.active is False:
        raise HTTPException(status_code=400, detail="You cannot disable your own account")

    new_role = payload.role if payload.role is not None else row["role"]
    new_active = payload.active if payload.active is not None else row["active"]
    new_hash = (
        auth.hash_password(payload.password) if payload.password else row["password_hash"]
    )
    await pool.execute(
        "UPDATE users SET role = $2, active = $3, password_hash = $4 WHERE id = $1",
        user_id, new_role, new_active, new_hash,
    )
    await _audit(
        pool,
        action="user.update",
        target=f"user:{row['username']}",
        detail={"role": new_role, "active": new_active, "password": bool(payload.password)},
        user=admin,
        ip=ratelimit.client_ip(request),
    )
    return {"ok": True, "id": user_id, "role": new_role, "active": new_active}


# ---------------------------------------------------------------- certs & agent template

@app.get("/api/ca.crt", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def download_ca(_: dict = Depends(require_role("admin", "operation"))):
    path = Path(config.DATA_DIR) / "certs" / "ca.crt"
    if not path.exists():
        raise HTTPException(status_code=404, detail="CA not generated yet")
    return FileResponse(path, media_type="application/x-pem-file", filename="itk-ca.crt")


@app.get("/api/session-secret", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def download_session_secret(user: dict = Depends(require_role("admin"))):
    """Download the server's SESSION_SECRET. It encrypts DB secrets (Fernet)
    and signs sessions, so treat it like a keyfile: needed for backup/restore,
    must not leak. Returns the current persisted value."""
    path = Path(config.DATA_DIR) / "session_secret"
    if not path.exists():
        raise HTTPException(status_code=404, detail="No session secret persisted yet")
    return FileResponse(path, media_type="text/plain", filename="itk-session-secret.txt")


@app.get("/api/agent/enroll")
async def agent_enroll(hostname: str, request: Request, authorization: str = Header(default="")):
    """Agent-facing: issue (or re-serve) a client-auth cert for this agent AND
    mint a per-agent token.

    Auth: the shared fleet token, OR this agent's already-issued per-agent
    token (so a re-enrolling agent isn't forced to share the fleet secret).
    Returned {crt, key, ca, pfx} + agent_token. Idempotent — the same cert and
    token are returned on every call for a given hostname.
    """
    pool = await db.connect()
    supplied = _bearer_token(authorization)
    agent = await _get_or_create_agent(pool, hostname)
    if agent["agent_token_revoked"]:
        raise HTTPException(status_code=403, detail="Agent revoked")
    is_fleet = hmac.compare_digest(supplied, config.API_TOKEN)
    is_own = bool(agent["agent_token"]) and hmac.compare_digest(supplied, agent["agent_token"])
    if not (is_fleet or is_own):
        raise HTTPException(status_code=401, detail="Invalid or missing token")

    agent_token = await issue_agent_token(pool, agent["id"])
    creds = certs.issue_client_cert(hostname)
    creds["agent_token"] = agent_token
    return creds


@app.get("/api/agent-template", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def agent_template(_: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    server_host = await pool.fetchval("SELECT value FROM settings WHERE key = 'server_host'")
    company = await pool.fetchval("SELECT value FROM settings WHERE key = 'company_name'")
    ca_path = Path(config.DATA_DIR) / "certs" / "ca.crt"
    return {
        "company": company,
        "server_host": server_host,
        "agent_token": config.API_TOKEN,
        "ca_cert": ca_path.read_text() if ca_path.exists() else None,
    }


# ---------------------------------------------------------------- agent bundle (P3)

@app.get("/api/agent-bundle", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def agent_bundle(_: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    agent_json = await bundle.build_agent_json(pool)
    ca_path = Path(config.DATA_DIR) / "certs" / "ca.crt"
    ca_present = ca_path.exists()
    msi = bundle.msi_path()
    rollout_target = await pool.fetchval("SELECT value FROM settings WHERE key = 'agent_target_version'") or None
    return {
        "company": agent_json["company"],
        "server_host": (await pool.fetchval("SELECT value FROM settings WHERE key = 'server_host'")),
        "scheme": agent_json["endpoint"].split("://")[0],
        "agent_json": agent_json,
        "rollout_target": rollout_target,
        "ca_cert": ca_path.read_text() if ca_present else None,
        "install_cmd": bundle.build_install_cmd(agent_json, ca_present),
        "msi_available": msi.exists(),
        "msi_size": msi.stat().st_size if msi.exists() else None,
        "msi_filename": bundle.MSI_FILENAME,
        "msi_url": "/api/agent-msi",
    }


@app.get("/api/agent/agent.json", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def download_agent_json(_: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    agent_json = await bundle.build_agent_json(pool)
    return JSONResponse(
        content=agent_json,
        headers={"Content-Disposition": 'attachment; filename="agent.json"'},
    )


@app.get("/api/agent/install.cmd", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def download_install_cmd(_: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    agent_json = await bundle.build_agent_json(pool)
    ca_path = Path(config.DATA_DIR) / "certs" / "ca.crt"
    cmd = bundle.build_install_cmd(agent_json, ca_path.exists())
    return Response(
        content=cmd,
        media_type="text/plain",
        headers={"Content-Disposition": 'attachment; filename="install-agent.cmd"'},
    )


@app.get("/api/agent-msi", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def download_msi(request: Request, user: dict = Depends(require_role("admin", "operation"))):
    path = bundle.msi_path()
    if not path.exists():
        raise HTTPException(status_code=404, detail="MSI not uploaded yet — CI publishes the generic engine build (P0).")
    await _audit(
        await db.connect(),
        action="msi.download",
        user=user,
        ip=ratelimit.client_ip(request),
    )
    return FileResponse(path, media_type="application/octet-stream", filename=bundle.MSI_FILENAME)


# ---------------------------------------------------------------- SaaS build (github remote / local_windows)

async def _get_build_settings(pool) -> dict:
    rows = await pool.fetch("SELECT key, value FROM settings WHERE key IN ('build_mode','github_repo','github_token')")
    cfg = {"build_mode": config.BUILD_MODE, "github_repo": "", "github_token": ""}
    for r in rows:
        if r["key"] == "github_token":
            cfg[r["key"]] = vault.decrypt(r["value"] or "")
        else:
            cfg[r["key"]] = r["value"] or ""
    return cfg


async def _try_github_sync(pool, mode: str) -> dict:
    """If github mode is configured, refresh status + auto-fetch a finished MSI
    artifact. Never raises — returns a status dict for the portal."""
    cfg = await _get_build_settings(pool)
    if mode != "github" or not cfg["github_repo"] or not cfg["github_token"]:
        return {"mode": mode, "available": False}
    try:
        gh = github.status(cfg["github_repo"], cfg["github_token"])
        if gh["conclusion"] == "success":
            art = github.latest_artifact(cfg["github_repo"], cfg["github_token"])
            if art and _needs_msi_refresh(art):
                p = github.download_msi(cfg["github_repo"], cfg["github_token"], art["id"], art.get("created_at"))
                gh["msi_downloaded"] = str(p)
        return {"mode": mode, "available": True, "github": gh}
    except Exception as e:
        return {"mode": mode, "available": True, "error": str(e)}


def _needs_msi_refresh(art: dict) -> bool:
    """Download the artifact if we have no MSI yet, or the newest artifact is
    newer than the one we already fetched (tracked via a stamp file)."""
    if not bundle.msi_available():
        return True
    stamp_path = config.ARTIFACTS_DIR / ".msi_artifact.json"
    if not stamp_path.exists():
        # MSI exists but no stamp (e.g. placed manually, or downloaded before
        # stamping existed) — can't verify freshness, so refresh once.
        return True
    try:
        stamp = json.loads(stamp_path.read_text())
    except (OSError, ValueError):
        return True
    return (art.get("created_at") or "") > (stamp.get("created_at") or "")


@app.get("/api/build/status", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def build_status(user: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    cfg = await _get_build_settings(pool)
    info = {
        "mode": cfg["build_mode"],
        "github_repo": cfg["github_repo"],
        "msi_available": bundle.msi_available(),
        "msi_size": bundle.msi_path().stat().st_size if bundle.msi_available() else None,
    }
    if cfg["build_mode"] == "github":
        info["github"] = await _try_github_sync(pool, cfg["build_mode"])
    return info


@app.post("/api/build/validate", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def build_validate(payload: BuildTriggerRequest, user: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    cfg = await _get_build_settings(pool)
    repo = payload.repo or cfg["github_repo"]
    token = payload.token or cfg["github_token"]
    if not repo or not token:
        raise HTTPException(status_code=400, detail="GitHub repo + PAT not configured (set them during setup or send them in this request)")
    try:
        v = github.validate(repo, token)
    except github.GitHubError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return v


@app.post("/api/build/trigger", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def build_trigger(payload: BuildTriggerRequest, request: Request, user: dict = Depends(require_role("admin", "operation"))):
    """Fire a remote GitHub Actions build (workflow_dispatch) and persist the
    repo+token so /api/build/status keeps polling + auto-fetches the MSI.

    An empty token in the payload means "use the stored token from setup" —
    the portal never re-displays the PAT."""
    pool = await db.connect()
    cfg = await _get_build_settings(pool)
    repo = payload.repo or cfg["github_repo"]
    token = payload.token or cfg["github_token"]
    if not repo or not token:
        raise HTTPException(status_code=400, detail="GitHub repo + PAT not configured (set them during setup or send them in this request)")
    try:
        v = github.validate(repo, token)
        if not v["ok"]:
            raise github.GitHubError("Repo not found or token lacks access")
        github.trigger(repo, token, payload.branch or v.get("default_branch", "main"))
    except github.GitHubError as e:
        raise HTTPException(status_code=400, detail=str(e))
    for key, value in (
        ("build_mode", "github"),
        ("github_repo", github._normalize_repo(repo)),
        ("github_token", vault.encrypt(token.strip())),
    ):
        await pool.execute(
            "INSERT INTO settings (key, value) VALUES ($1, $2) "
            "ON CONFLICT (key) DO UPDATE SET value = $2",
            key, value,
        )
    await _audit(
        pool,
        action="build.trigger",
        target=repo,
        detail={"branch": payload.branch or "main"},
        user=user,
        ip=ratelimit.client_ip(request),
    )
    return {"dispatched": True, "repo": repo, "branch": payload.branch or "main", "permissions": v}


# ---------------------------------------------------------------- command channel (P5)

@app.get("/api/commands", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def list_commands(limit: int = 100, user: dict = Depends(require_session)):
    limit = _clamp_limit(limit)
    pool = await db.connect()
    sql = (
        "SELECT c.id, a.hostname, c.kind, c.payload, c.status, c.result, "
        "       c.created_at, c.picked_up_at, c.completed_at "
        "FROM commands c JOIN agents a ON a.id = c.agent_id WHERE 1=1"
    )
    args: list = []
    sql, args = _company_scope(user, "a", args, sql)
    sql += f" ORDER BY c.id DESC LIMIT ${max(len(args) + 1, 1)}"
    args.append(limit)
    rows = await pool.fetch(sql, *args)
    return [dict(r) for r in rows]


@app.post("/api/commands", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def create_command(payload: CommandCreate, request: Request, user: dict = Depends(require_role("admin", "operation"))):
    if payload.kind == "run-script" and not config.ALLOW_RUN_SCRIPT:
        raise HTTPException(status_code=403, detail="run-script is disabled (COMMANDS_RUN_SCRIPT_ALLOWED=false)")
    if payload.kind == "run-script":
        script = (payload.payload.get("script") or "").strip()
        if script not in config.RUN_SCRIPT_ALLOWLIST:
            raise HTTPException(
                status_code=403,
                detail=f"Script '{script}' is not in the allowlist ({', '.join(config.RUN_SCRIPT_ALLOWLIST) or 'empty'})",
            )
    pool = await db.connect()
    sql = "SELECT id, hostname, company_id FROM agents WHERE id = $1"
    args: list = [payload.agent_id]
    sql, args = _company_scope(user, "agents", args, sql)
    agent = await pool.fetchrow(sql, *args)
    if agent is None:
        raise HTTPException(status_code=404, detail="Agent not found")
    row = await pool.fetchrow(
        "INSERT INTO commands (agent_id, kind, payload, created_by) "
        "VALUES ($1, $2, $3, $4) RETURNING id, agent_id, kind, payload, status, created_at",
        payload.agent_id, payload.kind, payload.payload, user["id"],
    )
    await _audit(
        pool,
        action="command.create",
        target=f"agent:{agent['hostname']}",
        detail={"command_id": row["id"], "kind": payload.kind},
        user=user,
        ip=ratelimit.client_ip(request),
    )
    return dict(row)


@app.get("/api/commands/poll")
async def poll_commands(hostname: str, request: Request, authorization: str = Header(default="")):
    """Agent-facing: return pending commands for this host (per-agent token auth).
    Marks them picked_up so the portal shows they were delivered."""
    pool = await db.connect()
    agent = await require_agent_token(hostname, authorization)
    rows = await pool.fetch(
        "SELECT id, kind, payload FROM commands "
        "WHERE agent_id = $1 AND status IN ('pending', 'picked_up') "
        "  AND (picked_up_at IS NULL OR picked_up_at > now() - interval '5 minutes') "
        "ORDER BY id ASC LIMIT 10",
        agent["id"],
    )
    for r in rows:
        await pool.execute(
            "UPDATE commands SET status = 'picked_up', picked_up_at = now() WHERE id = $1",
            r["id"],
        )
    return [dict(r) for r in rows]


@app.post("/api/commands/{command_id}/result")
async def command_result(command_id: int, result: CommandResult, request: Request, authorization: str = Header(default="")):
    pool = await db.connect()
    agent = await require_agent_token(result.hostname, authorization)
    updated = await pool.execute(
        "UPDATE commands SET status = $2, result = $3, completed_at = now() "
        "WHERE id = $1 AND agent_id = $4",
        command_id, result.status,
        {"output": result.output, "exit_code": result.exit_code}, agent["id"],
    )
    if updated == "UPDATE 0":
        raise HTTPException(status_code=404, detail="Command not found for this agent")
    return {"ok": True, "id": command_id, "status": result.status}


# ---------------------------------------------------------------- alerts (P6)

class RuleUpdate(BaseModel):
    enabled: bool | None = None
    severity: str | None = None
    condition: dict | None = None


@app.get("/api/alerts", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def list_alerts(status: str | None = None, limit: int = 100, user: dict = Depends(require_session)):
    limit = _clamp_limit(limit)
    pool = await db.connect()
    sql = (
        "SELECT al.id, a.hostname, al.severity, al.message, al.status, "
        "       al.created_at, al.resolved_at, r.name AS rule "
        "FROM alerts al "
        "LEFT JOIN agents a ON a.id = al.agent_id "
        "LEFT JOIN alert_rules r ON r.id = al.rule_id WHERE 1=1"
    )
    args: list = []
    if status:
        sql += f" AND al.status = ${len(args) + 1}"
        args.append(status)
    sql, args = _company_scope(user, "a", args, sql)
    sql += f" ORDER BY al.created_at DESC LIMIT ${max(len(args) + 1, 1)}"
    args.append(limit)
    rows = await pool.fetch(sql, *args)
    return [dict(r) for r in rows]


@app.get("/api/alerts/open", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def open_alerts_count(user: dict = Depends(require_session)):
    pool = await db.connect()
    sql = "SELECT count(*) FROM alerts al LEFT JOIN agents a ON a.id = al.agent_id WHERE al.status = 'open'"
    args: list = []
    sql, args = _company_scope(user, "a", args, sql)
    count = await pool.fetchval(sql, *args)
    return {"open": count}


@app.post("/api/alerts/{alert_id}/ack", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def ack_alert(alert_id: int, _: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    await pool.execute("UPDATE alerts SET status = 'acknowledged' WHERE id = $1", alert_id)
    return {"ok": True, "id": alert_id}


@app.post("/api/alerts/{alert_id}/resolve", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def resolve_alert(alert_id: int, _: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    await pool.execute(
        "UPDATE alerts SET status = 'resolved', resolved_at = now() WHERE id = $1", alert_id,
    )
    return {"ok": True, "id": alert_id}


@app.get("/api/alert-rules", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def list_rules():
    await rules.seed_rules(await db.connect())
    pool = await db.connect()
    rows = await pool.fetch("SELECT * FROM alert_rules ORDER BY id")
    return [dict(r) for r in rows]


@app.put("/api/alert-rules/{name}", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def update_rule(name: str, update: RuleUpdate, request: Request, admin: dict = Depends(require_role("admin"))):
    pool = await db.connect()
    row = await pool.fetchrow("SELECT * FROM alert_rules WHERE name = $1", name)
    if row is None:
        raise HTTPException(status_code=404, detail="Rule not found")
    new_enabled = update.enabled if update.enabled is not None else row["enabled"]
    new_severity = update.severity if update.severity else row["severity"]
    new_condition = update.condition if update.condition is not None else row["condition"]
    await pool.execute(
        "UPDATE alert_rules SET enabled = $2, severity = $3, condition = $4 WHERE name = $1",
        name, new_enabled, new_severity, new_condition,
    )
    await _audit(
        pool,
        action="alert_rule.update",
        target=f"rule:{name}",
        detail={"enabled": new_enabled, "severity": new_severity},
        user=admin,
        ip=ratelimit.client_ip(request),
    )
    return {"ok": True, "name": name}


@app.post("/api/alerts/test-email", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def test_alert_email(_: dict = Depends(require_role("admin"))):
    """Send a test alert email using the configured SMTP settings."""
    pool = await db.connect()
    smtp = await rules.get_smtp_settings(pool)
    if not smtp["host"] or not smtp["to"]:
        raise HTTPException(status_code=400, detail="SMTP not configured (add email settings during setup or in .env)")
    sent = await rules._send_alert_email(
        pool,
        [{"severity": "info", "hostname": "test", "message": "SMTP test message from IT-Toolkit"}],
    )
    if not sent:
        raise HTTPException(status_code=502, detail="SMTP send failed — check logs")
    return {"ok": True, "from": smtp["from"], "to": smtp["to"]}


@app.get("/api/alerts/webhook", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def get_webhook_config(_: dict = Depends(require_role("admin"))):
    """F1: read the current webhook alert delivery config (generic/Slack/Teams)."""
    pool = await db.connect()
    cfg = await rules.get_webhook_settings(pool)
    return {"enabled": cfg["enabled"], "url": cfg["url"], "type": cfg["type"], "token": cfg["token"]}


@app.put("/api/alerts/webhook", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def put_webhook_config(payload: WebhookSettings, request: Request, admin: dict = Depends(require_role("admin"))):
    """F1: persist webhook alert delivery config. Returns a small 'sendable'
    hint so the portal can surface "configured but won't reach Slack" states."""
    pool = await db.connect()
    values = {
        "webhook_enabled": "true" if payload.enabled else "false",
        "webhook_url": payload.url.strip(),
        "webhook_type": payload.type,
        "webhook_token": payload.token.strip(),
    }
    for key, value in values.items():
        await pool.execute(
            "INSERT INTO settings (key, value) VALUES ($1, $2) "
            "ON CONFLICT (key) DO UPDATE SET value = $2",
            key, value,
        )
    await _audit(
        pool,
        action="alert_webhook.update",
        target="settings",
        detail={"enabled": payload.enabled, "type": payload.type, "url": bool(payload.url)},
        user=admin,
        ip=ratelimit.client_ip(request),
    )
    return {
        "ok": True,
        "enabled": payload.enabled,
        "type": payload.type,
        "configured": bool(payload.url.strip()),
        "sendable": bool(payload.url.strip() and payload.enabled),
    }


@app.post("/api/alerts/test-webhook", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def test_alert_webhook(_: dict = Depends(require_role("admin"))):
    """F1: POST a test alert to the configured webhook to verify connectivity."""
    pool = await db.connect()
    cfg = await rules.get_webhook_settings(pool)
    if not cfg["enabled"] or not cfg["url"]:
        raise HTTPException(status_code=400, detail="Webhook not enabled (enable it and set a URL first)")
    sent = await rules._send_alert_webhook(
        pool,
        [{"severity": "info", "hostname": "test", "message": "Webhook test message from IT-Toolkit"}],
    )
    if not sent:
        raise HTTPException(status_code=502, detail="Webhook POST failed — check URL/token and network")
    return {"ok": True, "type": cfg["type"], "url": cfg["url"]}


# ---------------------------------------------------------------- reports (P6)

async def _agent_report_rows(pool, user: dict) -> list[dict]:
    sql = (
        "SELECT id, hostname, os, agent_version, ip, registered_at, last_seen "
        "FROM agents WHERE 1=1"
    )
    args: list = []
    sql, args = _company_scope(user, "agents", args, sql)
    sql += " ORDER BY hostname"
    agents = await pool.fetch(sql, *args)
    rows = []
    for a in agents:
        row = dict(a)
        for kind in ("hardware", "health", "updatecompliance", "diskhealth"):
            p = await pool.fetchrow(
                "SELECT payload, captured_at FROM events WHERE agent_id = $1 AND kind = $2 "
                "ORDER BY captured_at DESC LIMIT 1",
                a["id"], kind,
            )
            if p:
                row[kind] = {"payload": p["payload"], "captured_at": p["captured_at"]}
        rows.append(row)
    return rows


def _as_csv(data: list[dict], columns: list[str]) -> str:
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=columns, extrasaction="ignore")
    writer.writeheader()
    for row in data:
        writer.writerow(row)
    return buf.getvalue()


@app.get("/api/report/fleet", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def fleet_report(user: dict = Depends(require_session)):
    pool = await db.connect()
    rows = []
    for r in await _agent_report_rows(pool, user):
        hw = (r.get("hardware") or {}).get("payload") or {}
        hl = (r.get("health") or {}).get("payload") or {}
        rows.append({
            "hostname": r["hostname"],
            "os": r["os"],
            "ip": r["ip"],
            "agent_version": r["agent_version"],
            "last_seen": r["last_seen"],
            "model": hw.get("model", ""),
            "serial": hw.get("serial", ""),
            "cpu": hw.get("cpu", ""),
            "ram_total_gb": hw.get("ram_total_gb", ""),
            "battery_wear_percent": (hw.get("battery") or {}).get("wear_percent", ""),
            "uptime_hours": hl.get("uptime_hours", ""),
            "cpu_percent": hl.get("cpu_percent", ""),
            "memory_percent": hl.get("memory_percent", ""),
            "reboot_pending": hl.get("reboot_pending", ""),
        })
    columns = ["hostname", "os", "ip", "agent_version", "last_seen", "model", "serial",
               "cpu", "ram_total_gb", "battery_wear_percent", "uptime_hours",
               "cpu_percent", "memory_percent", "reboot_pending"]
    csv_text = _as_csv(rows, columns)
    return Response(
        content=csv_text,
        media_type="text/csv",
        headers={"Content-Disposition": 'attachment; filename="fleet-report.csv"'},
    )


@app.get("/api/report/agent/{agent_id}", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def agent_report(
    agent_id: int,
    format: str = "json",
    user: dict = Depends(require_session),
):
    pool = await db.connect()
    sql = "SELECT * FROM agents WHERE id = $1"
    args: list = [agent_id]
    sql, args = _company_scope(user, "agents", args, sql)
    agent = await pool.fetchrow(sql, *args)
    if agent is None:
        raise HTTPException(status_code=404, detail="Agent not found")
    # B1: license payloads contain product keys — admin-only. Non-admins get
    # them stripped from reports too.
    license_filter = "" if user["role"] == "admin" else " AND kind <> 'licenses'"
    events = await pool.fetch(
        f"SELECT id, kind, payload, sanitized, captured_at FROM events "
        f"WHERE agent_id = $1{license_filter} ORDER BY captured_at DESC",
        agent_id,
    )
    if format == "csv":
        rows = [{
            "id": e["id"], "kind": e["kind"], "sanitized": e["sanitized"],
            "captured_at": e["captured_at"], "payload": json.dumps(e["payload"]),
        } for e in events]
        csv_text = _as_csv(rows, ["id", "kind", "sanitized", "captured_at", "payload"])
        return Response(
            content=csv_text,
            media_type="text/csv",
            headers={"Content-Disposition": f'attachment; filename="agent-{agent_id}-report.csv"'},
        )
    return {"agent": dict(agent), "event_count": len(events), "events": [dict(e) for e in events]}


# ---------------------------------------------------------------- ingest

class Heartbeat(BaseModel):
    """E1: minimal liveness ping. Carries only the identity + OS/IP/version
    fields the server stores on agents, so an idle agent (empty queue, no
    commands) still keeps last_seen fresh."""
    hostname: str
    os: str = ""
    agent_version: str = ""
    ip: str = ""


@app.post("/api/agent/heartbeat")
async def agent_heartbeat(payload: Heartbeat, request: Request, authorization: str = Header(default="")):
    """Agent-facing: refresh last_seen + store current OS/IP/version. Kept cheap
    (no event parsing, no write amplification) and runs on the mTLS port so an
    idle agent's liveness is observable via last_seen / the agent-offline rule."""
    pool = await db.connect()
    agent = await require_agent_token(payload.hostname, authorization)
    await pool.execute(
        "UPDATE agents SET os = $2, agent_version = $3, ip = $4 WHERE id = $1",
        agent["id"], payload.os, payload.agent_version, payload.ip,
    )
    return {"ok": True, "last_seen": datetime.now(timezone.utc).isoformat()}


@app.get("/api/agent/update")
async def agent_update_info(hostname: str, request: Request, authorization: str = Header(default="")):
    """E3: agent-facing self-update check. Returns the shipped agent version,
    the rollout target (from settings, defaulting to the bundled version), and
    whether an MSI upgrade is available. Auth = agent bearer token."""
    pool = await db.connect()
    agent = await require_agent_token(hostname, authorization)
    target = await pool.fetchval("SELECT value FROM settings WHERE key = 'agent_target_version'")
    target_version = target or bundle.AGENT_VERSION
    return {
        "agent_id": agent["id"],
        "current_version": bundle.AGENT_VERSION,
        "target_version": target_version,
        "update_available": target_version != bundle.AGENT_VERSION and bundle.msi_available(),
        "msi_url": "/api/agent/msi",
    }


@app.get("/api/agent/msi")
async def agent_msi_download(hostname: str, authorization: str = Header(default="")):
    """E3: agent-facing MSI binary download (mTLS + per-agent token). Unlike the
    portal's /api/agent-msi (session auth) this is meant to be fetched by the
    agent itself during a silent self-upgrade."""
    await require_agent_token(hostname, authorization)
    path = bundle.msi_path()
    if not path.exists():
        raise HTTPException(status_code=404, detail="MSI not uploaded yet")
    return FileResponse(path, media_type="application/octet-stream", filename=bundle.MSI_FILENAME)


class AgentRolloutUpdate(BaseModel):
    """E3: admin sets the staged rollout target version. Empty/None clears the
    override so agents roll back to the bundled version."""
    target_version: str = ""


@app.put("/api/agent/update-target", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def set_agent_update_target(payload: AgentRolloutUpdate, request: Request, admin: dict = Depends(require_role("admin"))):
    pool = await db.connect()
    target = payload.target_version.strip()
    if target:
        await pool.execute(
            "INSERT INTO settings (key, value) VALUES ('agent_target_version', $1) "
            "ON CONFLICT (key) DO UPDATE SET value = $1",
            target,
        )
    else:
        await pool.execute("DELETE FROM settings WHERE key = 'agent_target_version'")
    await _audit(
        pool,
        action="agent.rollout.set",
        target=f"version:{target or 'bundled'}",
        detail={"target_version": target},
        user=admin,
        ip=ratelimit.client_ip(request),
    )
    return {"target_version": target, "current_version": bundle.AGENT_VERSION, "cleared": not target}

_MAX_MSG_ID_LEN = 255


def _validate_event(ev: EventItem) -> str:
    """C3: validate an event UP FRONT so an invalid row fails the whole batch
    (400) instead of silently dropping part of it."""
    if not ev.kind or not ev.kind.strip():
        raise HTTPException(status_code=400, detail="event.kind is required")
    msg_id = ev.client_msg_id or str(uuid.uuid4())
    if len(msg_id) > _MAX_MSG_ID_LEN:
        raise HTTPException(
            status_code=400, detail=f"client_msg_id too long (> {_MAX_MSG_ID_LEN})"
        )
    if ev.captured_at:
        try:
            datetime.fromisoformat(ev.captured_at.replace("Z", "+00:00"))
        except ValueError:
            raise HTTPException(
                status_code=400, detail=f"invalid captured_at: {ev.captured_at!r}"
            )
    return msg_id


@app.post("/ingest")
async def ingest(batch: IngestBatch, request: Request, authorization: str = Header(default="")):
    if len(batch.events) > config.MAX_INGEST_EVENTS:
        metrics.ingest_batches.inc(labels={"outcome": "rejected"})
        raise HTTPException(
            status_code=413,
            detail=f"Too many events in batch (max {config.MAX_INGEST_EVENTS})",
        )
    pool = await db.connect()
    agent = await require_agent_token(batch.hostname, authorization)
    agent_id = agent["id"]
    await pool.execute(
        "UPDATE agents SET os = $2, agent_version = $3, ip = $4 WHERE id = $1",
        agent_id, batch.os, batch.agent_version, batch.ip,
    )

    # C3: validate the whole batch before writing a single row. A transaction
    # wraps all inserts so any DB error rolls the batch back (no partial write).
    prepared = [(_validate_event(ev), ev) for ev in batch.events]
    count = 0
    duplicated = 0
    try:
        async with pool.acquire() as conn:
            async with conn.transaction():
                for msg_id, ev in prepared:
                    row = await conn.fetchrow(
                        "INSERT INTO events (agent_id, kind, payload, sanitized, "
                        "client_msg_id, captured_at) "
                        "VALUES ($1, $2, $3, $4, $5, "
                        "COALESCE(($6::text)::timestamptz, now())) "
                        "ON CONFLICT (client_msg_id) DO NOTHING RETURNING id",
                        agent_id, ev.kind, ev.payload, ev.sanitized, msg_id,
                        ev.captured_at,
                    )
                    if row:
                        count += 1
                    else:
                        duplicated += 1
    except (asyncpg.DataError, asyncpg.UniqueViolationError) as exc:
        request.app.state.last_ingest_error = repr(exc)
        metrics.ingest_batches.inc(labels={"outcome": "rejected"})
        metrics.ingest_events.inc(amount=len(batch.events), labels={"outcome": "rejected"})
        raise HTTPException(status_code=400, detail="Batch rejected: %s" % exc) from exc

    metrics.ingest_batches.inc(labels={"outcome": "accepted"})
    metrics.ingest_events.inc(amount=count, labels={"outcome": "accepted"})
    metrics.ingest_events.inc(amount=duplicated, labels={"outcome": "deduplicated"})
    return {"accepted": count, "agent_id": agent_id}


# ---------------------------------------------------------------- admin API

@app.get("/api/agents", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def list_agents(user: dict = Depends(require_session)):
    pool = await db.connect()
    sql = (
        "SELECT id, hostname, os, agent_version, ip, company_id, registered_at, last_seen "
        "FROM agents WHERE 1=1"
    )
    args: list = []
    sql, args = _company_scope(user, "agents", args, sql)
    sql += " ORDER BY last_seen DESC"
    rows = await pool.fetch(sql, *args)
    return [dict(r) for r in rows]


# B6: per-agent credential lifecycle (admin).

@app.get("/api/agents/{agent_id}/token", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def agent_credential(agent_id: int, admin: dict = Depends(require_role("admin"))):
    """Return whether this agent uses a per-agent token and whether it is
    revoked. Never reveals the token itself."""
    pool = await db.connect()
    sql = "SELECT hostname, agent_token, agent_token_revoked FROM agents WHERE id = $1"
    args: list = [agent_id]
    sql, args = _company_scope(admin, "agents", args, sql)
    row = await pool.fetchrow(sql, *args)
    if row is None:
        raise HTTPException(status_code=404, detail="Agent not found")
    return {
        "hostname": row["hostname"],
        "has_per_agent_token": bool(row["agent_token"]),
        "revoked": row["agent_token_revoked"],
    }


@app.post("/api/agents/{agent_id}/revoke", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def revoke_agent(agent_id: int, request: Request, admin: dict = Depends(require_role("admin"))):
    """Cut this agent off immediately: its per-agent token (and the shared
    token) stop being accepted for ingest/polls. Only an admin can undo it."""
    pool = await db.connect()
    sql = "UPDATE agents SET agent_token_revoked = TRUE WHERE id = $1"
    args: list = [agent_id]
    sql, args = _company_scope(admin, "agents", args, sql)
    updated = await pool.execute(sql, *args)
    if updated == "UPDATE 0":
        raise HTTPException(status_code=404, detail="Agent not found")
    await _audit(
        pool,
        action="agent.revoke",
        target=f"agent:{agent_id}",
        user=admin,
        ip=ratelimit.client_ip(request),
    )
    return {"ok": True, "id": agent_id, "revoked": True}


@app.post("/api/agents/{agent_id}/unrevoke", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def unrevoke_agent(agent_id: int, request: Request, admin: dict = Depends(require_role("admin"))):
    pool = await db.connect()
    sql = "UPDATE agents SET agent_token_revoked = FALSE WHERE id = $1"
    args: list = [agent_id]
    sql, args = _company_scope(admin, "agents", args, sql)
    updated = await pool.execute(sql, *args)
    if updated == "UPDATE 0":
        raise HTTPException(status_code=404, detail="Agent not found")
    await _audit(
        pool,
        action="agent.unrevoke",
        target=f"agent:{agent_id}",
        user=admin,
        ip=ratelimit.client_ip(request),
    )
    return {"ok": True, "id": agent_id, "revoked": False}


@app.get("/api/events", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def list_events(
    agent: str | None = None,
    kind: str | None = None,
    limit: int = 100,
    user: dict = Depends(require_session),
):
    limit = _clamp_limit(limit)
    pool = await db.connect()
    # B1: license payloads contain Windows/Office product keys — admin-only.
    # Non-admins also get licenses events stripped from broad queries.
    if kind == "licenses" and user["role"] != "admin":
        raise HTTPException(status_code=403, detail="Forbidden for this role")
    sql = (
        "SELECT e.id, e.kind, e.payload, e.sanitized, e.captured_at, a.hostname "
        "FROM events e JOIN agents a ON a.id = e.agent_id WHERE 1=1"
    )
    args: list = []
    if agent:
        sql += " AND a.hostname = $1"
        args.append(agent)
    if kind:
        sql += f" AND e.kind = ${len(args) + 1}"
        args.append(kind)
    sql, args = _company_scope(user, "a", args, sql)
    if kind != "licenses" and user["role"] != "admin":
        sql += " AND e.kind <> 'licenses'"
    sql += f" ORDER BY e.captured_at DESC LIMIT ${max(len(args) + 1, 1)}"
    args.append(limit)
    rows = await pool.fetch(sql, *args)
    return [dict(r) for r in rows]


# ---------------------------------------------------------------- software inventory (F3)

async def _latest_payload_per_agent(pool, kind: str, user: dict) -> list[dict]:
    """Latest event payload of the given kind for each agent in the caller's
    company: [{hostname, agent_id, payload, captured_at}]."""
    sql = (
        "SELECT DISTINCT ON (a.id) a.id AS agent_id, a.hostname, e.payload, e.captured_at "
        "FROM agents a JOIN events e ON e.agent_id = a.id "
        "WHERE e.kind = $1"
    )
    args: list = [kind]
    sql, args = _company_scope(user, "a", args, sql)
    sql += " ORDER BY a.id, e.captured_at DESC"
    return [dict(r) for r in await pool.fetch(sql, *args)]


@app.get("/api/software/search", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def software_search(q: str = "", limit: int = 200, user: dict = Depends(require_session)):
    """F3: search installed software across the fleet.

    Searches app DisplayName / Publisher / DisplayVersion (case-insensitive
    substring) in each agent's latest 'software' event. Aggregates duplicate
    app names into a per-app count. Non-admins never see license keys (they are
    in a different event kind anyway); 'licenses' is admin-only.
    """
    limit = _clamp_limit(limit)
    pool = await db.connect()
    needle = (q or "").strip().lower()
    results: list[dict] = []
    for row in await _latest_payload_per_agent(pool, "software", user):
        payload = row["payload"] or {}
        apps = payload.get("apps") or []
        matches = [a for a in apps if not needle or needle in str(a.get("DisplayName", "")).lower()
                   or needle in str(a.get("Publisher", "")).lower()]
        if not matches:
            continue
        results.append({
            "hostname": row["hostname"],
            "agent_id": row["agent_id"],
            "count": len(matches),
            "apps": matches[:50],
        })
        if len(results) >= limit:
            break
    return {"query": q, "agents": len(results), "results": results}


@app.get("/api/software/export", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def software_export(user: dict = Depends(require_session)):
    """F3: CSV export of the full software inventory (one row per agent+app)."""
    pool = await db.connect()
    rows: list[dict] = []
    for row in await _latest_payload_per_agent(pool, "software", user):
        for app in (row["payload"] or {}).get("apps") or []:
            rows.append({
                "hostname": row["hostname"],
                "display_name": app.get("DisplayName", ""),
                "display_version": app.get("DisplayVersion", ""),
                "publisher": app.get("Publisher", ""),
            })
    rows.sort(key=lambda r: (r["hostname"].lower(), r["display_name"].lower()))
    csv_text = _as_csv(rows, ["hostname", "display_name", "display_version", "publisher"])
    return Response(
        content=csv_text,
        media_type="text/csv",
        headers={"Content-Disposition": 'attachment; filename="software-inventory.csv"'},
    )


@app.get("/api/license/compliance", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def license_compliance(user: dict = Depends(require_role("admin"))):
    """F3: per-agent license compliance view (admin-only). Windows/Office keys
    are reported last-5 characters by the agent collector; full keys never
    leave the machine. 'ok' means a key was reported."""
    pool = await db.connect()
    rows = []
    for row in await _latest_payload_per_agent(pool, "licenses", user):
        payload = row["payload"] or {}
        rows.append({
            "hostname": row["hostname"],
            "agent_id": row["agent_id"],
            "last_seen": row["captured_at"],
            "windows_key_last5": payload.get("windows_key_last5", ""),
            "office_key_last5": payload.get("office_keys_last5", ""),
            "windows_ok": bool(payload.get("windows_key_last5")),
            "office_ok": bool(payload.get("office_keys_last5")),
        })
    rows.sort(key=lambda r: r["hostname"].lower())
    return {"agents": len(rows), "compliance": rows}


@app.get("/api/license/export", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def license_export(user: dict = Depends(require_role("admin"))):
    """F3: CSV export of license compliance (admin-only)."""
    pool = await db.connect()
    rows = []
    for row in await _latest_payload_per_agent(pool, "licenses", user):
        payload = row["payload"] or {}
        rows.append({
            "hostname": row["hostname"],
            "windows_key_last5": payload.get("windows_key_last5", ""),
            "office_key_last5": payload.get("office_keys_last5", ""),
        })
    rows.sort(key=lambda r: r["hostname"].lower())
    csv_text = _as_csv(rows, ["hostname", "windows_key_last5", "office_key_last5"])
    return Response(
        content=csv_text,
        media_type="text/csv",
        headers={"Content-Disposition": 'attachment; filename="license-compliance.csv"'},
    )


# ---------------------------------------------------------------- tenants (F4)

@app.get("/api/companies", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def list_companies(user: dict = Depends(require_role("admin"))):
    """F4: tenant directory (admin-only)."""
    pool = await db.connect()
    rows = await pool.fetch(
        "SELECT c.id, c.name, c.created_at, "
        "       (SELECT count(*) FROM users u WHERE u.company_id = c.id) AS users, "
        "       (SELECT count(*) FROM agents a WHERE a.company_id = c.id) AS agents "
        "FROM companies c ORDER BY c.id"
    )
    return [dict(r) for r in rows]


@app.post("/api/companies", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def create_company(payload: CompanyCreate, request: Request, user: dict = Depends(require_role("admin"))):
    """F4: create a tenant company. It is not the default (existing agents keep
    their current company); to enroll new agents into it, assign it as default
    via /api/settings/default-company."""
    pool = await db.connect()
    try:
        row = await pool.fetchrow(
            "INSERT INTO companies (name) VALUES ($1) RETURNING id, name, created_at",
            payload.name.strip(),
        )
    except asyncpg.exceptions.UniqueViolationError:
        raise HTTPException(status_code=409, detail="Company already exists")
    await _audit(
        pool,
        action="company.create",
        target=f"company:{row['name']}",
        user=user,
        ip=ratelimit.client_ip(request),
    )
    return dict(row)


@app.get("/api/settings/default-company", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def get_default_company(user: dict = Depends(require_role("admin"))):
    """F4: which company new agents enroll into (NULL = global/no tenant)."""
    pool = await db.connect()
    cid = await _company_id(pool)
    if cid is None:
        return {"company_id": None, "name": None}
    row = await pool.fetchrow("SELECT id, name FROM companies WHERE id = $1", cid)
    return {"company_id": cid, "name": row["name"] if row else None}


@app.post("/api/settings/default-company", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def set_default_company(payload: CompanyCreate, request: Request, user: dict = Depends(require_role("admin"))):
    """F4: point new-agent enrollment at a specific company (by name)."""
    pool = await db.connect()
    row = await pool.fetchrow("SELECT id FROM companies WHERE name = $1", payload.name.strip())
    if row is None:
        raise HTTPException(status_code=404, detail="Company not found")
    await pool.execute(
        "INSERT INTO settings (key, value) VALUES ('default_company_id', $1) "
        "ON CONFLICT (key) DO UPDATE SET value = $1",
        str(row["id"]),
    )
    await _audit(
        pool,
        action="company.set_default",
        target=f"company:{payload.name.strip()}",
        user=user,
        ip=ratelimit.client_ip(request),
    )
    return {"ok": True, "company_id": row["id"], "name": payload.name.strip()}


@app.get("/api/features", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def list_features():
    pool = await db.connect()
    with open(config.FEATURES_FILE, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)["features"]

    overrides = {r["name"]: r for r in await pool.fetch("SELECT * FROM feature_configs")}
    result = []
    for feat in manifest:
        row = overrides.get(feat["name"])
        result.append({
            "name": feat["name"],
            "label": feat["label"],
            "script": feat["script"],
            "description": feat["description"],
            "enabled": row["enabled"] if row else feat.get("default_enabled", True),
            "config": row["config"] if row else {},
            "requires_elevation": bool(feat.get("requires_elevation", False)),
        })
    return result


@app.put("/api/features/{name}", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def update_feature(name: str, update: FeatureUpdate, request: Request, user: dict = Depends(require_role("admin", "operation"))):
    pool = await db.connect()
    row = await pool.fetchrow("SELECT * FROM feature_configs WHERE name = $1", name)
    if row:
        new_enabled = update.enabled if update.enabled is not None else row["enabled"]
        new_config = update.config if update.config is not None else row["config"]
        await pool.execute(
            "UPDATE feature_configs SET enabled = $2, config = $3, updated_at = now() WHERE name = $1",
            name, new_enabled, new_config,
        )
    else:
        new_enabled = update.enabled if update.enabled is not None else True
        new_config = update.config if update.config is not None else {}
        await pool.execute(
            "INSERT INTO feature_configs (name, enabled, config) VALUES ($1, $2, $3)",
            name, new_enabled, new_config,
        )
    await _audit(
        pool,
        action="feature.update",
        target=f"feature:{name}",
        detail={"enabled": new_enabled},
        user=user,
        ip=ratelimit.client_ip(request),
    )
    return {"name": name, "enabled": new_enabled, "config": new_config}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/metrics", include_in_schema=False)
async def metrics_endpoint():
    # D1: Prometheus text exposition. Scrape-only (no session secrets); DB gauges
    # are refreshed on each scrape. Pool is shared app-wide (like everywhere).
    pool = await db.connect()
    metrics.agents_total.set(
        await pool.fetchval("SELECT count(*) FROM agents") or 0
    )
    metrics.agents_online.set(
        await pool.fetchval(
            "SELECT count(*) FROM agents WHERE last_seen > now() - interval '15 minutes'"
        ) or 0
    )
    metrics.alerts_open.set(
        await pool.fetchval(
            "SELECT count(*) FROM alerts WHERE status IN ('open', 'acknowledged')"
        ) or 0
    )
    metrics.pending_commands.set(
        await pool.fetchval(
            "SELECT count(*) FROM commands WHERE status NOT IN ('completed', 'failed', 'cancelled')"
        ) or 0
    )
    return Response(content=metrics.render_all(), media_type="text/plain; version=0.0.4")


@app.get("/api/status", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def api_status(request: Request):
    return {"last_ingest_error": getattr(request.app.state, "last_ingest_error", None)}


@app.get("/api/audit", dependencies=[Depends(require_setup_done), Depends(require_session)])
async def list_audit(
    limit: int = 100,
    action: str | None = None,
    user: str | None = None,
    _: dict = Depends(require_role("admin")),
):
    """D3: admin-only audit trail. Latest first; optional action/user filters."""
    limit = _clamp_limit(limit)
    pool = await db.connect()
    sql = (
        "SELECT id, ts, username, role, action, target, detail, ip "
        "FROM audit_log WHERE 1=1"
    )
    args: list = []
    if action:
        args.append(action)
        sql += f" AND action = ${len(args)}"
    if user:
        args.append(user)
        sql += f" AND username = ${len(args)}"
    sql += f" ORDER BY ts DESC LIMIT ${max(len(args) + 1, 1)}"
    args.append(limit)
    rows = await pool.fetch(sql, *args)
    return [dict(r) for r in rows]


# ---------------------------------------------------------------- portal

@app.get("/", include_in_schema=False)
async def portal_index():
    return FileResponse(Path(config.PORTAL_DIR) / "index.html")


app.mount("/static", StaticFiles(directory=config.PORTAL_DIR), name="static")
