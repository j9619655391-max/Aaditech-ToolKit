import hashlib
import hmac
import json
import uuid
from pathlib import Path

from fastapi import FastAPI, Depends, Header, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import config, db

app = FastAPI(title="IT-Toolkit Enterprise", version="1.0.0")


# ---------------------------------------------------------------- auth

def require_token(authorization: str = Header(default="")) -> None:
    expected = f"Bearer {config.API_TOKEN}"
    if not hmac.compare_digest(authorization.strip(), expected):
        raise HTTPException(status_code=401, detail="Invalid or missing token")


async def get_agent_id(pool, hostname: str) -> int:
    row = await pool.fetchrow(
        "INSERT INTO agents (hostname) VALUES ($1) "
        "ON CONFLICT (hostname) DO UPDATE SET last_seen = now() RETURNING id",
        hostname,
    )
    return row["id"]


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


# ---------------------------------------------------------------- lifecycle

@app.on_event("startup")
async def startup():
    await db.connect()


@app.on_event("shutdown")
async def shutdown():
    await db.disconnect()


# ---------------------------------------------------------------- ingest

@app.post("/ingest")
async def ingest(batch: IngestBatch, request: Request, _: None = Depends(require_token)):
    pool = await db.connect()
    agent_id = await get_agent_id(pool, batch.hostname)
    await pool.execute(
        "UPDATE agents SET os = $2, agent_version = $3, ip = $4 WHERE id = $1",
        agent_id, batch.os, batch.agent_version, batch.ip,
    )

    count = 0
    for ev in batch.events:
        msg_id = ev.client_msg_id or str(uuid.uuid4())
        try:
            row = await pool.fetchrow(
                "INSERT INTO events (agent_id, kind, payload, sanitized, client_msg_id, captured_at) "
                "VALUES ($1, $2, $3, $4, $5, COALESCE(($6::text)::timestamptz, now())) "
                "ON CONFLICT (client_msg_id) DO NOTHING RETURNING id",
                agent_id, ev.kind, ev.payload, ev.sanitized, msg_id, ev.captured_at,
            )
            if row:
                count += 1
        except Exception as exc:
            request.app.state.last_ingest_error = repr(exc)
            continue

    return {"accepted": count, "agent_id": agent_id}


# ---------------------------------------------------------------- admin API

@app.get("/api/agents", dependencies=[Depends(require_token)])
async def list_agents():
    pool = await db.connect()
    rows = await pool.fetch(
        "SELECT id, hostname, os, agent_version, ip, registered_at, last_seen "
        "FROM agents ORDER BY last_seen DESC"
    )
    return [dict(r) for r in rows]


@app.get("/api/events", dependencies=[Depends(require_token)])
async def list_events(agent: str | None = None, kind: str | None = None, limit: int = 100):
    pool = await db.connect()
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
    sql += f" ORDER BY e.captured_at DESC LIMIT ${max(len(args) + 1, 1)}"
    args.append(limit)
    rows = await pool.fetch(sql, *args)
    return [dict(r) for r in rows]


@app.get("/api/features", dependencies=[Depends(require_token)])
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
        })
    return result


@app.put("/api/features/{name}", dependencies=[Depends(require_token)])
async def update_feature(name: str, update: FeatureUpdate):
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
    return {"name": name, "enabled": new_enabled, "config": new_config}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/api/status", dependencies=[Depends(require_token)])
async def api_status(request: Request):
    return {"last_ingest_error": getattr(request.app.state, "last_ingest_error", None)}


# ---------------------------------------------------------------- portal

@app.get("/", include_in_schema=False)
async def portal_index():
    return FileResponse(Path(config.PORTAL_DIR) / "index.html")


app.mount("/static", StaticFiles(directory=config.PORTAL_DIR), name="static")
