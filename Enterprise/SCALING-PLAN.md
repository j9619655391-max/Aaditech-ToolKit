# IT-Toolkit Enterprise — Scaling Plan (Scale the Existing, Never Rebuild)

> **Purpose:** Turn the audit findings into a **dependency-ordered, test-gated** scaling
> plan for the existing Enterprise stack (agent → server → portal). Every phase keeps
> the **zero-change promise**: existing files stay untouched; everything is additive or
> a targeted fix. No rebuilds, no rewrites.
>
> **How to use this doc:** each phase lists concrete tasks. Every task has
> `[ ]` checkboxes, files to touch, and a **test gate** (how we know it worked).
> We execute strictly in order — each phase's gate must pass before the next begins.
>
> **Rule for this workstream:** no cosmetic changes, no feature bloat. Every task
> maps to a real audit finding or an enterprise requirement. No duplicate/overlapping
> work — each item appears exactly once, in exactly one phase.

---

## 0. Guiding Principles

1. **Scale, don't rebuild.** The FastAPI + Postgres + Caddy + PowerShell-agent core is
   sound and feature-complete (P0–P6.1 + Rev 3 SaaS auto-setup). We harden, secure,
   observe, and scale it.
2. **Test gate on every task.** Each task ends with a runnable check (curl, pytest,
   pwsh, compose) that must pass before moving on.
3. **One source of truth for versions.** `agent_version`, `interval_minutes`, and the
   MSI `Version=` must come from a single config, not 5 hardcoded copies.
4. **Secrets never on disk unencrypted / world-readable.** `.env` 0600, no plaintext
   SMTP/PAT in DB, code-signing material gitignored.
5. **Enterprise readiness = security + DR + observability + update path**, in that order.

---

## Phase A — Foundation: fix the "won't start / can't upgrade" blockers

> **Goal:** the agent reliably starts on a stock Windows box, MSI upgrades work, and
> deployment validates honestly. Nothing else matters until these hold.

### A1. Agent SQLite dependency — bundle `sqlite3` or drop the CLI
- **Finding:** `ToolkitData.psm1:72` throws `'sqlite3 not found on PATH'`; the MSI
  bundles no SQLite binary → agent never starts on stock Windows.
- **Decision (chosen):** bundle the **official `sqlite3.exe`** from sqlite.org in the
  MSI (installed beside the agent exe) and have the agent prepend that directory to
  `PATH` at startup. Queue code untouched; shared `ToolkitData.psm1` not modified.
  Chosen over `System.Data.SQLite` because a single signed CLI is far less fragile
  inside a ps2exe-packaged worker than a mixed-mode native DLL.
- **Files (done):** `Enterprise/agent/wix/build-msi.ps1` (download+stage sqlite3.exe),
  `Enterprise/agent/wix/Agent.wxs` (`SqliteBin` component),
  `Enterprise/agent/Agent-Collect.ps1` (`Add-BundledSqliteToPath`).
- **Test gate:** on a clean Windows VM (no SQLite installed) → MSI install → task runs
  → `queue.sqlite3` created → data flushes to server → first fleet row appears.

### A2. Single source of truth for version + interval
- **Finding:** `1.0.0` / `30` hardcoded in `bundle.py:8-9`, `deploy.sh:188`,
  `deploy.ps1:178`, `agent-config.example.json:5`, `ci.yml:109`, `Agent.wxs:23`.
- **Fix (done):** new `Enterprise/agent/agent-version.json` is the single source.
  `bundle.py` resolves it (api build context copy, fallback to repo agent/ dir);
  `deploy.sh`/`deploy.ps1` read it and copy it into the api build context before
  compose up; `ci.yml` reads it; `build-msi.ps1` injects it as WiX preprocessor
  vars `$(var.AgentVersion)`/`$(var.AgentInterval)`; `Agent.wxs` consumes them.
  `agent-config.example.json` stays a literal example (documentation only).
- **Files:** `Enterprise/agent/agent-version.json` (new), `deploy.sh`, `deploy.ps1`,
  `bundle.py`, `build-msi.ps1`, `ci.yml`, `Agent.wxs`, `.gitignore`.
- **Test gate:** run both build scripts → MSI shows the version from the config; grep
  shows no leftover hardcoded `1.0.0` in build paths.

### A3. Fix MSI upgrade path
- **Finding:** `Agent.wxs:23` hardcodes `Version="1.0.0.0"`, never bumped → Windows
  Installer refuses upgrades; `<MajorUpgrade>` is a no-op.
- **Fix (done):** `build-msi.ps1` derives a monotonic 4-part ProductVersion
  `<major>.<minor>.<patch>.<days-since-epoch>` from `agent-version.json` and injects
  it as `$(var.AgentVersion)`; `UpgradeCode` unchanged. Any release on a later day
  (or after bumping the semver) upgrades cleanly.
- **Test gate:** install v1.0.0, rebuild as v1.0.1, run the new MSI → **upgrade
  completes, task recreated, agent.json replaced, ProgramData retained.**

### A4. Registry override — implement or remove honestly
- **Finding:** `Agent.wxs:127-132` writes literal `!agent.endpoint`/`!agent.token`
  (invalid MSI syntax) AND the agent never reads the registry. The documented "GPO
  override" is fiction.
- **Decision (done):** implemented for real — `Read-AgentConfig` merges
  `HKLM\SOFTWARE\ITToolkit\Agent` (`EndpointUrl`, `ApiToken`) over agent.json at
  startup. The WXS registry component now stamps only `Installed=<version>` (never
  touches override values, so upgrades can't clobber GPO settings). `bundle.py` needs
  no change — the registry is a runtime knob layered over the baked agent.json.
- **Files:** `Agent-Collect.ps1` (Read-AgentConfig merge), `Agent.wxs`.
- **Test gate:** set the registry values → restart task → agent talks to the new
  endpoint; clear them → falls back to agent.json.

### A5. Caddy cert timing — reload after setup
- **Finding:** `:9443` needs `server.crt`/`ca.crt` created by the wizard, but Caddy
  starts before setup and nothing reloads it.
- **Fix (done, improved):** empirically confirmed Caddy **hard-exits at startup**
  when the cert files are missing (`open /server.crt: no such file or directory`),
  so a post-setup `reload` can never work — Caddy is already dead. Instead
  `deploy.sh`/`deploy.ps1` now bring up **db+api first**, generate the mTLS
  CA/server certs inside the api container (`ensure_certs($HOST)`), then start
  Caddy. `agent-config.json` and the cert SAN both use `$HOST`, so the mTLS endpoint
  is consistent. The wizard's `ensure_certs()` stays idempotent.
- **Files:** `deploy/deploy.sh`, `deploy/deploy.ps1` (split bring-up + cert step).
- **Test gate:** fresh deploy → wizard → `openssl s_client` to `:9443` shows the new
  server cert + `Verify return code` reflects our CA. (Verified in a throwaway Caddy
  container: with certs present `Verify return code: 0 (ok)`; without them Caddy exits.)

### A6. Honest deployment health check
- **Finding:** `deploy.sh:202-209` prints "Server is up!" even after 30 failed tries.
- **Fix (done):** deploy scripts now `die` (exit 1) with a clear message when api or
  the main/:9443 health checks never pass; the `:9443` check uses `openssl s_client
  -CAfile <our CA>` and greps `Verify return code: 0` (server cert validates against
  the IT-Toolkit CA before Caddy's client-cert requirement kicks in).
- **Files:** `deploy/deploy.sh`, `deploy/deploy.ps1`.
- **Test gate:** stop Caddy → deploy → script exits 1 with a readable message.

### A7. Secrets file permissions
- **Finding:** `.env` + `agent-config.json` written 0644 containing token + DB password.
- **Fix (done):** `deploy.sh` `chmod 600`s `.env` (on create and on pre-existing) and
  `agent-config.json`; `deploy.ps1` adds `Set-SecretFileAcl` using
  `icacls /inheritance:r /grant:r "SYSTEM:(R,W)" "Administrators:(R,W)"` for both.
- **Files:** `deploy/deploy.sh`, `deploy/deploy.ps1`.
- **Test gate:** `stat -c %a` shows 600 after deploy; `icacls` on Windows shows no
  `Users` read.

---

## Phase B — Security hardening (the audit's biggest gap)

> **Goal:** eliminate the "monitoring can read product keys", "shared token owns the
> fleet", "login is brute-forceable", and "secrets in plaintext" findings.

### B1. RBAC enforcement on read endpoints
- **Finding:** `/api/events` (incl. `kind=licenses`), `/api/agents`, `/api/report/*`,
  `/api/commands` are any-role; portal only hides in UI.
- **Fix:** role-gate `licenses` data (admin-only) at the API; audit every read route.
  Hide Agent Setup tab for monitoring.
- **Files:** `main.py` (role deps + licenses filter), `portal/index.html`.
- **Test gate:** monitoring user hits `GET /api/events?kind=licenses` → 403; product
  keys absent from all non-admin responses.

### B2. Rate limiting + login lockout
- **Finding:** no protection on `/api/login` or any endpoint.
- **Fix (done):** new `api/app/ratelimit.py` — in-memory fixed-window counters:
  per-IP login cap (10/5min → 429), per-username lockout (5 failures → 423 for
  15min, reset on successful login), general per-IP API burst (120/10s on `api/*`,
  exempting `/healthz`, `/ingest`, `/api/commands`). `main.py` wires it as an HTTP
  middleware (returns JSON 429) and the login route calls check/record.
- **Files:** `api/app/ratelimit.py` (new), `main.py` (middleware + login).
- **Test gate:** hammer login 15× → 429 + account locked; valid user still logs in
  after cooldown. (Logic unit-tested: blocked at 5 failures, unblocked on success.)

### B3. TLS on the main port
- **Finding:** bare-IP deploys serve the portal + enroll over plain HTTP; cookie
  `secure=False`; mTLS only on `:9443`.
- **Decision (user):** serve optional TLS on `:443` with the internal CA cert, but
  KEEP the `:80` HTTP site so the first-time setup wizard works exactly as before
  (no redirect, no forced cert warnings on the admin's browser).
- **Fix:** `Caddyfile.template` (new) + a render step in `deploy.sh`/`deploy.ps1`:
  hostname/FQDN → `{$CADDY_HOST}` ACME auto-TLS; bare IP → `:443` TLS (internal CA
  cert) **plus** `:80` HTTP. Session cookie `Secure` is derived from
  `X-Forwarded-Proto` (new `auth.request_secure`), set only when served over TLS.
- **Files:** `deploy/Caddyfile.template` (new), `deploy.sh`/`deploy.ps1` (render
  step), `auth.py`, `main.py`.
- **Test gate:** ✅ `caddy adapt` passes for both modes; live ✓ `http://:80/` → 200
  (wizard unchanged); ✓ `https://:443/healthz --cacert <CA>` → 200; ✓ `:443` cert
  verifies against internal CA (`Verify return code: 0`); ✓ `:9443` mTLS unaffected;
  ✓ `auth.request_secure('https')==True`, `('http')==False`.

### B4. Hide / disable public API docs
- **Finding:** `/docs`, `/openapi.json`, `/api-docs*` proxied unauthenticated.
- **Fix:** docs/redoc/openapi disabled at the FastAPI level unless
  `ENVIRONMENT=dev` (`config.IS_DEV`); Caddy also blocks the paths at the edge
  (`__DOCS_RULE__` → `respond 404`) in prod, proxied only in dev. `ENVIRONMENT`
  defaults to `prod` and is written to `.env` + passed to the api/caddy containers.
- **Files:** `config.py`, `main.py`, `Caddyfile.template`, `deploy.sh`/`deploy.ps1`,
  `docker-compose.yml`.
- **Test gate:** ✅ prod → `/docs` + `/openapi.json` → 404 at both edge and API;
  ✅ `/`, `/healthz`, `/setup/status` still 200; ✅ `IS_DEV` True for dev/development,
  False for prod; ✅ `caddy adapt` OK both modes.

### B5. Secrets at rest
- **Finding:** SMTP password + GitHub PAT plaintext in `settings`.
- **Fix:** new `api/app/vault.py` — Fernet symmetric encryption keyed off
  `SESSION_SECRET` (SHA-256 → urlsafe base64). `github_token` + `smtp_password`
  are encrypted on write (setup, build_trigger), decrypted on read
  (`_get_build_settings`, `rules.get_smtp_settings`). Legacy plaintext values
  pass through unchanged (no migration needed), corrupt ciphertext never crashes
  the caller. Portal never re-displays the secrets.
- **Files:** new `api/app/vault.py`, `main.py`, `rules.py`.
- **Test gate:** ✅ Fernet round-trip (encrypt≠plaintext, decrypt==original) in
  the live container; ✅ stored row is ciphertext (`enc$v1$…`); ✅ legacy
  plaintext rows still decrypt/pass-through; ✅ py_compile.

### B6. Per-agent credentials (replace the shared fleet token)
- **Finding:** one `API_TOKEN` for all agents; leak = fleet impersonation + SYSTEM
  run-script on every box.
- **Fix:** at `enroll`, issue a **per-hostname agent token + client cert**; the agent
  uses its own credential thereafter; keep the shared token only for bootstrap/enroll.
  Server validates token ↔ hostname binding.
- **Files:** `certs.py`, `main.py` (enroll, ingest, poll auth), `bundle.py`,
  `Agent-Collect.ps1`, Caddyfile.
- **Status: DONE** — implements `_get_or_create_agent`/`issue_agent_token`/
  `require_agent_token`, admin endpoints `GET /api/agents/{id}/token`,
  `POST /api/agents/{id}/revoke|unrevoke`; `Agent-Collect.ps1` persists its own
  token beside the cert and re-enrolls once if the token file is missing.
- **Test gate:** two agents → two distinct tokens; using agent A's token as hostname B
  → 401; revoke one → only that agent blocked.
  **Result (live stack):** 14/14 pass — distinct tokens per hostname ✓, re-enroll
  is idempotent (same token) ✓, hostname↔token binding (A on B → 401) ✓, shared
  token rejected once a per-agent token exists ✓, no token → 401 ✓, ingest OK ✓,
  token detail ✓, revoke → 403 on ingest (both own + shared) ✓, PC-B unaffected ✓,
  unrevoke → 200 ✓. `require_token`/`get_agent_id` dead helpers removed.

---

## Phase C — Reliability & data integrity

> **Goal:** no silent data loss, no unbounded growth, no half-configured installs,
> commands execute at-most-once, and the server survives restarts.

### C1. DB backup + restore runbook
- **Finding:** no `pg_dump`, no snapshot, no restore path; only destructive reset.
- **Fix:** `Enterprise/deploy/backup.sh` (+ `restore.sh`) using `pg_dump` into a dated
  file in a `backups/` volume; cron/notes; restore verified.
- **Test gate:** backup → `docker compose down -v` → restore → agents/events/alerts
  present again.
- **Status: DONE** — `backup.sh` streams a dated custom-format dump to the HOST
  `deploy/backups/` (survives `down -v`), `BACKUP_KEEP` pruning; `restore.sh`
  stops writers, `pg_restore --clean --if-exists`, then **regenerates the mTLS
  CA + server cert** (Caddy cannot start without them after `down -v`, A5) and
  brings api+caddy back.
- **Live gate (full round-trip):** backup → `down -v` (all volumes wiped) →
  restore → agents=2, events=2, alert_rules=7 all present; portal `/healthz`
  200; `:9443` openssl Verify return code 0; `BACKUP_KEEP=1` pruning keeps only
  newest. Reliability note: `uploads`/`publish/restore` remain on host as well.

### C2. Self-contained + startup-only migrations
- **Finding:** `db.py:8-69` omits `agents`/`events`/`feature_configs` + unique index
  (silent event drop on fresh volume); `migrate()` runs 7 DDL **per request**.
- **Fix:** complete `_SCHEMA_MIGRATIONS` to cover every table + index; run once at
  startup (guarded by an asyncio lock), not per-request.
- **Files:** `db.py`, `main.py` (startup), `schema.sql` (canonical).
- **Test gate:** fresh volume → `/ingest` dedupe works (ON CONFLICT fires); perf: no
  DDL in logs after startup.
- **Status: DONE** — `_SCHEMA_MIGRATIONS` now mirrors the whole canonical schema:
  `agents` + per-agent credential columns, `events` + `uq_events_client_msg`,
  `feature_configs`, all secondary indexes, in dependency order (idempotent).
  `migrate()` runs once per process under `asyncio.Lock`; startup calls it
  explicitly and `connect()` lazily awaits the no-op'd fast path so any worker
  provisions correctly. Fixed a start-up deadlock found in review (migrate↔connect
  mutual recursion) by routing both through a raw `_get_pool()`.
- **Live gate:** fresh restore → all 8 tables + events unique index present;
  `/ingest` with the same `client_msg_id` twice → accepted 1 then 0 (ON CONFLICT
  dedupe fires); app healthy, no DDL emitted after startup.

### C3. Ingest batch transaction + bounded limits
- **Finding:** events inserted one-by-one (partial on crash); `limit` params uncapped
  (`limit=-1` dumps tables); unbounded request bodies.
- **Fix:** single transaction per batch; clamp `limit` (0<limit<=500); reject oversized
  bodies (413); validate `captured_at`/`kind` upfront.
- **Files:** `main.py` (ingest, list_*), Pydantic models.
- **Test gate:** batch with one bad row → whole batch 400 (not silent partial);
  `limit=999999` → capped; huge body → 413.
- **Status: DONE** — ingest validates every event upfront (`kind` required,
  `client_msg_id` ≤ 255 chars, `captured_at` ISO-parseable) and runs all inserts
  in a single `conn.transaction()` so a DB error rolls back the whole batch
  (caught DataError/UniqueViolation → 400). New `config` bounds:
  `MAX_LIST_LIMIT`/`MAX_INGEST_EVENTS`/`MAX_BODY_BYTES`; `_clamp_limit` applied to
  `/api/events`, `/api/alerts`, `/api/commands`; `_body_size_limit` middleware
  rejects `Content-Length` > 10MB with 413 before buffering.
- **Live gate:** valid batch → 200 accepted 2/2; batch with one bad row → 400 and
  zero rows persisted (no partial); `limit=-1`→1, `limit=0`→1, `limit=999999`→
  ≤500; 21MB body → 413 "Request body too large"; 600-event batch → 413; dedupe
  still fires (same `client_msg_id` twice → accepted 0).

### C4. Transactional setup
- **Finding:** `run_setup` writes `setup_complete=1` before build/SMTP keys; a crash
  leaves a half-configured install that 409s forever.
- **Fix:** wrap in one transaction; write `setup_complete` last; on failure, roll back
  so setup can be retried.
- **Test gate:** kill setup mid-flight → `setup_status` still false → re-run succeeds.
- **Status: DONE** — validation (SMTP provider/host/encryption, build mode) now runs
  BEFORE any write; all settings + admin user insert inside one
  `conn.transaction()` on a single connection; `setup_complete` written last; any
  failure auto-rolls back (no 409 wall, wizard retryable). `certs.ensure_certs`
  stays idempotent.
- **Live gate:** pre-inserted a conflicting admin username to force a mid-transaction
  UniqueViolation → HTTP 500, `setup_complete` still NULL and `settings` empty
  (full rollback); removed conflict → re-run setup → 200, `setup_complete: true`,
  admin user created. Also fixed a `$2`-with-no-`$1` placeholder bug in the
  `setup_complete` upsert found during the gate.

### C5. Command channel: at-most-once + sanitized output
- **Finding:** failed result post → 5-min re-delivery → duplicate execution; `run-script`
  output unsanitized; runs as SYSTEM.
- **Fix:** agent stores `command_id` of executed command, ignores re-delivery; sanitize
  command output before posting; run task as a low-privilege account with the allowlist
  enforced **agent-side** too.
- **Files:** `Agent-Collect.ps1`, `main.py` (poll window), `Agent.wxs` (task identity).
- **Test gate:** kill result post → command executes once (agent-side dedupe log);
  script output contains PII → sanitized in result payload.
- **Status: DONE (agent-side; task identity deferred)** —
  - At-most-once: new `executed_commands` SQLite table (`command_id` PK);
    `Get-ExecutedCommand`/`Record-ExecutedCommand` (idempotent upsert); main loop
    skips re-run when a re-delivered command was already executed.
  - Sanitize: `Send-CommandResult` runs output through `ConvertTo-SanitizedText`
    (SanitizeEngine) before POSTing.
  - Agent-side allowlist: `run_script_allowlist` baked into `agent-config.json`
    (mirrors `RUN_SCRIPT_ALLOWLIST`, comma-separated, both `deploy.sh`+`deploy.ps1`);
    `run-script` refuses anything not on it even if a rogue/mutated command arrives.
  - Task identity (SYSTEM→low-privilege) in `Agent.wxs` still pending real-Windows
    validation (would change which users can run reboot/WoL); tracked as follow-up.
- **Live gate (pwsh, native macOS pwsh + sqlite3):** executed-commands record is
  present, unknown id returns null, re-record upserts without PK error; sanitizer
  redacts `user@example.com`/`10.0.0.5`/`CORP\user`; allowlist blocks non-listed
  script and allows listed one; both `.ps1` files parse clean.

### C6. Cert lifecycle automation — DONE
- **Finding:** client certs expire at `CLIENT_CERT_DAYS=825` with no renewal; mTLS
  "fallback" can't work (Caddy requires client auth) → bricks agents after `down -v`
  or expiry.
- **Fix (server):** `certs.issue_client_cert` now reuses the stored cert unless it is
  within `RENEWAL_DAYS=45` of expiry (`_client_cert_expiring`), in which case it
  issues a fresh 825-day cert (rotating the key). `/api/agent/enroll` is idempotent
  and returns the same cert+token each call, so periodic re-enrollment is safe.
- **Fix (agent):** `Ensure-ClientCert` checks `Test-ClientCertExpiry` (new, 45-day
  window; also true on missing/unreadable pfx). When the cert is near expiry/missing
  **OR** the per-agent token file is missing, it drops the old pfx + token and falls
  through to the existing enroll block (runs over the *main* port with bearer auth,
  so deleting the old cert can't strand the agent). Healthy cert → CA ensured, `$pfx`
  returned unchanged.
- **Files:** `Agent-Collect.ps1` (`Test-ClientCertExpiry`, `Ensure-ClientCert`),
  `certs.py` (`RENEWAL_DAYS`, `_client_cert_expiring`, reissue path), `main.py`.
- **Test gate (live, in api container):** fresh cert → `_client_cert_expiring=False`;
  backdated to 20 days → True; `issue_client_cert` re-issues → new 824-day cert and
  different pfx; expired cert → cleared+re-issued. Agent-side (pwsh + extracted fn,
  mock pfxs): 825-day pfx → returns `$false` ("824 days left"); 20-day pfx → `$true`;
  missing / garbage pfx → `$true`. Both `.ps1` files parse clean (`PARSE ERRORS=0`).

---

## Phase D — Observability & audit

> **Goal:** the platform is observable, debuggable, and auditable.

### D1. Prometheus metrics + `/metrics` — DONE
- **Fix:** zero-dependency Prometheus text-format exporter in
  `api/app/metrics.py` (Counter/Gauge/Histogram, hand-rolled exposition) + a
  `/metrics` route that refreshes DB-backed gauges per scrape. Middleware
  observes every request (even middleware-rejected 413/429) into
  `ittoolkit_http_requests_total{method,route,status}` and
  `ittoolkit_http_request_duration_seconds{route}`, with dynamic-id segments
  collapsed to `/{id}` so label cardinality stays bounded. Ingest counters
  (`ittoolkit_ingest_batches_total`, `ittoolkit_ingest_events_total`{accepted/
  deduplicated/rejected}) and alert-opened counter
  (`ittoolkit_alerts_opened_total`) hook into the hot paths; stale
  gauges at scrape: `agents_online` (15-min window), `agents_total`,
  `alerts_open`, `pending_commands`.
- **Files:** `api/app/metrics.py` (new), `main.py` (middleware + route + ingest
  hooks), `rules.py` (alert-opened counter).
- **Test gate (live):** `/metrics` returned a well-formed exposition
  (`# HELP/# TYPE`, cumulative histogram buckets, `le="+Inf"`, `_sum`/`_count`);
  a real ingest → `ing_batches_total{accepted}` 0→1 and `ing_events_total
  {accepted}` 0→1; replays → `deduplicated` incremented; a 600-event batch →
  HTTP 413, `ing_batches_total{rejected}` +1 and `http_requests_total
  {status="413"}` +1; `agents_online` reflected the just-ingested host; DB
  gauges returned 2/2/0/…

### D2. Structured logs + request-id — DONE
- **Fix:** `api/app/logging_setup.py` (new) replaces uvicorn's plaintext logging
  with a JSON line formatter (ts/level/logger/request_id/message [+extras]) on
  `uvicorn.error`, root, and `uvicorn.access`. A `request_id` contextvar +
  `ittoolkit.access` logger carry correlation; a middleware assigns a
  request_id per request (honoring an inbound `X-Request-ID`, else UUID), tags
  every log line in that request, and echoes it on the `X-Request-ID` response
  header. The access line (method/path/status/`dur_ms`) is emitted from the
  middleware wrapper so it carries the request_id + duration; uvicorn's own
  access line is silenced to avoid duplication.
- **Files:** `logging_setup.py` (new), `main.py` (middleware + `_access_fields`).
- **Test gate (live):** `docker logs` shows only single-line JSON objects; a
  request with `X-Request-ID: rid-corp-0001` produced an
  `ittoolkit.access` line carrying `request_id`+`path`+`method`+`status`+`dur_ms`;
  a request without the header got an auto-generated 16-hex request_id on both
  the log line and the `X-Request-ID` response header; an ingest POST produced a
  correlated access line.

### D3. Fleet audit log — DONE
- **Finding:** no login/admin-action/token/command audit trail.
- **Fix:** `audit_log` table (bigserial id, ts, user_id→users, username, role,
  action, target, detail jsonb, ip) provisioned in the C2 migration with ts/action
  indexes. A `_audit()` helper in `main.py` (never raises) fires on:
  `auth.login` (success), `auth.login_failed` (401 path), `setup.complete`,
  `user.create`, `user.update` (role/active/password flags), `command.create`
  (+resolved agent hostname), `agent.revoke`, `agent.unrevoke`,
  `feature.update`, `alert_rule.update`, `build.trigger`, and
  `msi.download`. Every admin/monitor route now receives `Request` for the client
  IP. Admin-only `GET /api/audit?limit=&action=&user=` returns latest-first rows;
  non-admin → 403.
- **Files:** `db.py` (migration), `main.py` (`_audit` + hooks + endpoint).
- **Test gate (live):** >5 real admin actions (user.create, user.update,
  alert_rule.update, feature.update, command.create, agent.revoke/unrevoke, a
  failed login) produced audit rows carrying correct username/role/detail/IP;
  `?action=` filter worked; a `monitoring` user hitting `/api/audit` → 403.

---

## Phase E — Agent maturity

> **Goal:** agents behave like production software: heartbeats, bounded queues,
> self-update, least privilege.

### E1. Heartbeat + offline detection — DONE
- **Finding:** `Send-AgentHeartbeat` existed but was never invoked, so an idle
  agent (empty queue, no commands) stopped updating `last_seen` and would be
  wrongly flagged offline.
- **Fix:** added a dedicated lightweight `POST /api/agent/heartbeat`
  (agent-token auth, stores os/agent_version/ip, refreshes `last_seen`, no
  event parsing). Caddy :9443 and the Caddyfile template now route it; the
  general burst limiter exempts it (like `/ingest`). The agent calls
  `Send-AgentHeartbeat` every cycle (best-effort, never aborts the loop) against
  `…/api/agent/heartbeat`. The `agent-offline` rule already evaluated `last_seen`.
- **Files:** `main.py` (route), `ratelimit.py`, `deploy/Caddyfile` +
  `deploy/Caddyfile.template`, `Agent-Collect.ps1` (rewire + call per cycle).
- **Test gate (live):** heartbeat 200 with valid token, 401 with a bad one;
  `last_seen`+os/ip/agent_version persisted; a real idle agent aged `last_seen`
  20 min → eval opened an `agent-offline` alert; a fresh heartbeat flipped it
  back to `resolved`. Without the fix the idle agent stayed silently offline.

### E2. Queue pruning + backoff/jitter
- **Fix:** delete `delivered` rows older than N days; cap outbox size; exponential
  backoff with jitter on flush failure (thundering-herd prevention).
- **Files:** `Agent-Collect.ps1`.
- **Test gate:** 1000 delivered rows → pruned to retention; 5 agents start together →
  flush times spread; failed server → retries back off.

### E3. Agent auto-update
- **Fix:** agent checks `/api/agent/update` (version + MSI URL) each cycle; optional
  staged rollout (server marks per-company target version); silent MSI upgrade.
- **Files:** `main.py`, `bundle.py`, `Agent-Collect.ps1`, `Agent.wxs`, portal Agent Setup.
- **Test gate:** bump target version → agent downloads + installs new MSI → reports new
  `agent_version`; rollback flag → old version reinstalled.

### E4. Least-privilege agent task + file ACLs
- **Fix:** scheduled task runs as `NETWORK SERVICE` (not SYSTEM); collectors that need
  elevation are opt-in; `icacls` ProgramData to SYSTEM+admin (token, queue, pfx, logs).
- **Files:** `Agent.wxs`, `Agent-Collect.ps1`, `deploy.ps1`.
- **Test gate:** task principal != SYSTEM; standard user cannot read `agent.json`/
  `queue.sqlite3`; collectors still produce data.

---

## Phase F — Enterprise features (value-add)

> **Goal:** deliver the highest-ROI enterprise capabilities on the hardened core.

### F1. Alert notifications (Slack / Teams / Webhook)
- **Fix:** extend the alert eval loop to POST to configured webhooks; per-severity
  routing; template + throttle (no flood).
- **Files:** `rules.py`, `config.py`, `.env.example`, portal Alerts settings.
- **Test gate:** open a disk-low alert → webhook receives formatted message; throttle
  prevents >1 per N min per rule.

### F2. API platform: key auth + webhooks
- **Fix:** per-integration API keys (scoped roles), Bearer auth for `/api/*`, webhook
  delivery for alert/command events, OpenAPI still gated.
- **Files:** `main.py` (key model), new `api_keys` table, portal Integrations page.
- **Test gate:** create key with `monitoring` scope → works on GET, 403 on mutations;
  revoke → 401.

### F3. Software inventory search + license compliance
- **Fix:** index `software`/`licenses` events; portal search (app name, version) +
  license compliance view (admin); export.
- **Files:** `main.py` (search endpoint), `db.py` (index), portal Fleet/Search.
- **Test gate:** ingest software data → search returns matches; license view admin-only.

### F4. Multi-tenant SaaS foundation
- **Fix:** add `company_id` to agents/users/settings; per-tenant token+certs+MSI;
  portal picks company (admin); schema stays shared-DB with tenant scoping.
- **Files:** migrations, `main.py` (scoping), `bundle.py`, `certs.py`, portal.
- **Test gate:** two companies isolated end-to-end (data, tokens, MSI, branding).

---

## Phase G — Scale-out (HA / DR)

> **Goal:** survive instance loss and serve 24/7. Depends on C1 backup being real.

### G1. Read replica + pooled API
- **Fix:** second `api` instance behind Caddy (already stateless if `SESSION_SECRET` +
  shared DB); Postgres read replica for `/api/*` reads; keep writes on primary.
- **Files:** `docker-compose.yml` (api replicas), Caddyfile LB, `db.py` read pool.
- **Test gate:** stop one api → requests continue; replica serves reads after
  replication lag window.

### G2. DR drill
- **Fix:** scripted restore to a second host using C1 backup + `.env`; documented RTO.
- **Files:** `deploy/restore.sh`, runbook.
- **Test gate:** full restore on a new machine in <30 min; agents reconnect to new host
  (endpoint override via A4 registry knob).

---

## Phase Ordering Rationale

```
A (starts/stays up)  →  B (not leaky)  →  C (no data loss)  →  D (see it)  →  E (agents
behave)  →  F (value)  →  G (scale)
```
- **A before B:** a fleet that can't install has nothing to protect.
- **B before C:** no point backing up data you're already leaking.
- **C before D:** metrics on corrupt data are still corrupt.
- **F before G:** multi-tenant value precedes HA cost; HA needs backup (C1) real.

---

## Global Technical Debt (small, fold into phases)
- Remove dead code: `Send-AgentHeartbeat` (→ E1 uses it), unused `hashlib` import,
  double `Response` import, `API_TOKEN_FILE` dead env (B5/A7).
- Fix `client_cert_paths` NUL/`..` sanitization (B6).
- `.dockerignore` to exclude `__pycache__`; run API as non-root `USER` (B3/A7).
- Add resource limits + caddy healthcheck in compose (G1/A6).
- Add Caddy security headers (HSTS/CSP/X-Frame-Options) (B3).
- Fix `Get-DiskHealth` `.Type`→`MediaType`, `Get-LicenseInfo` decode, PS array-collapse
  (fold into F3 or a collector-hardening task).
- Reconcile CHANGELOG (v3.x) / VERSION (v1.x) / tags (A2).

---

## Definition of "Done" (exit criteria for the whole program)
- Fresh `deploy.sh --regen` + `deploy.ps1 -SkipBuild` on real Windows → wizard →
  MSI installs + upgrades on stock Windows (no external SQLite) → fleet rows appear.
- No `monitoring` data leak; login throttled; HTTPS on all ports; secrets encrypted.
- Backups verified restorable; commands at-most-once; certs renew; agents self-update.
- `/metrics`, structured logs, audit log live. Two-company tenant isolation demoed.
- 30-minute DR drill passes. CI green at every commit.
