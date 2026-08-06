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
