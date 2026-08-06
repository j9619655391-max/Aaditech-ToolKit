CREATE TABLE IF NOT EXISTS agents (
    id             SERIAL PRIMARY KEY,
    hostname       TEXT NOT NULL UNIQUE,
    os             TEXT NOT NULL DEFAULT '',
    agent_version  TEXT NOT NULL DEFAULT '',
    ip             TEXT NOT NULL DEFAULT '',
    registered_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS events (
    id             SERIAL PRIMARY KEY,
    agent_id       INTEGER REFERENCES agents(id) ON DELETE CASCADE,
    kind           TEXT NOT NULL,
    payload        JSONB NOT NULL DEFAULT '{}'::jsonb,
    sanitized      BOOLEAN NOT NULL DEFAULT FALSE,
    client_msg_id  TEXT,
    captured_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_events_client_msg
    ON events(client_msg_id);

CREATE TABLE IF NOT EXISTS feature_configs (
    name         TEXT PRIMARY KEY,
    enabled      BOOLEAN NOT NULL DEFAULT TRUE,
    config       JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_agent ON events(agent_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind);
