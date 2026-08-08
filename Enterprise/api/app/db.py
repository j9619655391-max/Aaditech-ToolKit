import json

import asyncpg
from . import config

_pool: asyncpg.Pool | None = None

_SCHEMA_MIGRATIONS = [
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


async def connect() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(
            config.DATABASE_URL,
            min_size=1,
            max_size=10,
            init=_init_conn,
        )
    await migrate(_pool)
    return _pool


async def migrate(pool: asyncpg.Pool) -> None:
    """Idempotent runtime migrations for volumes created before a table existed."""
    async with pool.acquire() as conn:
        for stmt in _SCHEMA_MIGRATIONS:
            await conn.execute(stmt)


async def disconnect() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None
