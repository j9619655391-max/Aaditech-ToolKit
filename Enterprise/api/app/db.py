import asyncio
import json

import asyncpg
from . import config

_pool: asyncpg.Pool | None = None
_migrate_lock = asyncio.Lock()
_migrations_done = False

# C2: _SCHEMA_MIGRATIONS mirrors the whole canonical schema (schema.sql) — every
# table and index — in dependency order, so a fresh volume is fully provisioned
# even when created before schema.sql ever ran (or when this file pre-dates a
# table). Each statement is idempotent.
_SCHEMA_MIGRATIONS = [
    """
    CREATE TABLE IF NOT EXISTS agents (
        id                    SERIAL PRIMARY KEY,
        hostname              TEXT NOT NULL UNIQUE,
        os                    TEXT NOT NULL DEFAULT '',
        agent_version         TEXT NOT NULL DEFAULT '',
        ip                    TEXT NOT NULL DEFAULT '',
        agent_token           TEXT,
        agent_token_revoked   BOOLEAN NOT NULL DEFAULT FALSE,
        registered_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
        last_seen             TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS events (
        id            SERIAL PRIMARY KEY,
        agent_id       INTEGER REFERENCES agents(id) ON DELETE CASCADE,
        kind           TEXT NOT NULL,
        payload        jsonb NOT NULL DEFAULT '{}',
        sanitized      BOOLEAN NOT NULL DEFAULT FALSE,
        client_msg_id  TEXT,
        captured_at    TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS uq_events_client_msg
        ON events(client_msg_id)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_events_agent ON events(agent_id, captured_at DESC)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind)
    """,
    """
    CREATE TABLE IF NOT EXISTS feature_configs (
        name         TEXT PRIMARY KEY,
        enabled      BOOLEAN NOT NULL DEFAULT TRUE,
        config       jsonb NOT NULL DEFAULT '{}',
        updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS users (
        id            SERIAL PRIMARY KEY,
        username      TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role          TEXT NOT NULL DEFAULT 'monitoring',
        active        BOOLEAN NOT NULL DEFAULT TRUE,
        created_by    INTEGER,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS commands (
        id           SERIAL PRIMARY KEY,
        agent_id     INTEGER NOT NULL REFERENCES agents(id),
        kind         TEXT NOT NULL,
        payload      jsonb NOT NULL DEFAULT '{}',
        status       TEXT NOT NULL DEFAULT 'pending',
        result       jsonb,
        created_by   INTEGER,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        picked_up_at TIMESTAMPTZ,
        completed_at TIMESTAMPTZ
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_commands_agent_pending ON commands(agent_id, status)
    """,
    """
    CREATE TABLE IF NOT EXISTS alert_rules (
        id          SERIAL PRIMARY KEY,
        name        TEXT NOT NULL UNIQUE,
        description TEXT,
        condition   jsonb NOT NULL DEFAULT '{}',
        severity    TEXT NOT NULL DEFAULT 'warning',
        enabled     BOOLEAN NOT NULL DEFAULT TRUE,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS alerts (
        id          SERIAL PRIMARY KEY,
        rule_id     INTEGER REFERENCES alert_rules(id),
        agent_id    INTEGER REFERENCES agents(id),
        severity    TEXT NOT NULL,
        message     TEXT NOT NULL,
        status      TEXT NOT NULL DEFAULT 'open',
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        resolved_at TIMESTAMPTZ
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_alerts_status ON alerts(status)
    """,
    # B6: bump pre-existing volumes that had the agents table without the
    # per-agent credential columns (idempotent on newer volumes).
    """
    ALTER TABLE agents ADD COLUMN IF NOT EXISTS agent_token TEXT
    """,
    """
    ALTER TABLE agents ADD COLUMN IF NOT EXISTS agent_token_revoked BOOLEAN NOT NULL DEFAULT FALSE
    """,
]


async def _init_conn(conn: asyncpg.Connection) -> None:
    # asyncpg needs a codec before Python dicts can bind to jsonb columns.
    await conn.set_type_codec(
        "jsonb",
        encoder=json.dumps,
        decoder=json.loads,
        schema="pg_catalog",
    )


async def _get_pool() -> asyncpg.Pool:
    """Create/return the shared pool WITHOUT migrating (no recursion)."""
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(
            config.DATABASE_URL,
            min_size=1,
            max_size=10,
            init=_init_conn,
        )
    return _pool


async def connect() -> asyncpg.Pool:
    pool = await _get_pool()
    await migrate()  # no-op once done; guards workers that skip startup hook
    return pool


async def migrate() -> None:
    """Run schema migrations exactly once per process (startup only; C2).

    Any caller may await migrate() — the asyncio lock makes it race-free and a
    fast check is no-op'd once done. Startup calls it explicitly; request
    handlers lazily await it so even a misconfigured worker still provisions."""
    global _migrations_done
    if _migrations_done:
        return
    async with _migrate_lock:
        if _migrations_done:
            return
        pool = await _get_pool()
        async with pool.acquire() as conn:
            for stmt in _SCHEMA_MIGRATIONS:
                await conn.execute(stmt)
        _migrations_done = True


async def disconnect() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None
