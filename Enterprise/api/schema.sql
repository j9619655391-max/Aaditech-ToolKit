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

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id            SERIAL PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'monitoring',
    active        BOOLEAN NOT NULL DEFAULT TRUE,
    created_by    INTEGER,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

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
);
CREATE INDEX IF NOT EXISTS idx_commands_agent_pending ON commands(agent_id, status);

CREATE TABLE IF NOT EXISTS alert_rules (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    condition   jsonb NOT NULL DEFAULT '{}',
    severity    TEXT NOT NULL DEFAULT 'warning',
    enabled     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS alerts (
    id          SERIAL PRIMARY KEY,
    rule_id     INTEGER REFERENCES alert_rules(id),
    agent_id    INTEGER REFERENCES agents(id),
    severity    TEXT NOT NULL,
    message     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'open',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_alerts_status ON alerts(status);
