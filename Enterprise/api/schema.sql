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

-- D3: fleet audit trail. One row per security/admin-relevant action.
CREATE TABLE IF NOT EXISTS audit_log (
    id         BIGSERIAL PRIMARY KEY,
    ts         TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id    INTEGER REFERENCES users(id) ON DELETE SET NULL,
    username   TEXT,
    role       TEXT,
    action     TEXT NOT NULL,
    target     TEXT,
    detail     jsonb NOT NULL DEFAULT '{}',
    ip         TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_log_ts ON audit_log(ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log(action);

-- F3: fast "latest event per agent" lookups for software/license compliance.
CREATE INDEX IF NOT EXISTS idx_events_kind_agent ON events(kind, agent_id, captured_at DESC);

-- F4: multi-tenant foundation. One row per company; users + agents belong to a
-- company and list queries are scoped to the caller's company_id.
CREATE TABLE IF NOT EXISTS companies (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE agents ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id);
ALTER TABLE users  ADD COLUMN IF NOT EXISTS company_id INTEGER REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_agents_company ON agents(company_id);
CREATE INDEX IF NOT EXISTS idx_users_company ON users(company_id);

-- Phase A: real-time metrics time-series. One row per agent sample (kind
-- 'metrics' events are routed here by /ingest, NOT into events). payload is a
-- stable JSONB shape the rollup + API render from. client_msg_id gives
-- at-most-once dedup identical to events.
CREATE TABLE IF NOT EXISTS metrics (
    id            BIGSERIAL PRIMARY KEY,
    agent_id      INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
    client_msg_id TEXT,
    payload       JSONB NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_metrics_client_msg ON metrics(client_msg_id);
CREATE INDEX IF NOT EXISTS idx_metrics_agent_ts ON metrics(agent_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_ts ON metrics USING brin (ts);

-- Phase A: downsampled rollups (hour/day) kept long-term while raw samples are
-- purged after TS_RAW_RETENTION_HOURS. avg/max/min are flattened numeric dicts
-- (e.g. {"cpu": 12.3, "disk_used_pct:C": 74.1}).
CREATE TABLE IF NOT EXISTS metrics_rollup (
    id            BIGSERIAL PRIMARY KEY,
    agent_id      INTEGER NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    granularity   TEXT NOT NULL,                 -- 'hour' | 'day'
    bucket        TIMESTAMPTZ NOT NULL,
    avg           JSONB NOT NULL,
    max           JSONB NOT NULL,
    min           JSONB NOT NULL,
    samples       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_metrics_rollup ON metrics_rollup(agent_id, granularity, bucket);
CREATE INDEX IF NOT EXISTS idx_metrics_rollup_agent ON metrics_rollup(agent_id, bucket DESC);
