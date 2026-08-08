# IT-Toolkit Enterprise Architecture — Phase 3 (Scale-Out Blueprint)

> **Design goal:** Add a centralized **agent → server → web portal** stack that
> **scales the existing IT-Toolkit without modifying any existing script, batch
> file, module, or doc.** The current repo stays 100% untouched; everything new
> lives under `Enterprise/`.
>
> Status: **BLUEPRINT / SCAFFOLD** — committed with the full code skeleton.

---

## 1. What we ship (topology)

```
              ┌────────────────────────────────────────────────────────┐
              │  DEPLOY MACHINE  (any Linux with Docker + internet)    │
              │                                                        │
              │   ./Enterprise/deploy/deploy.sh                        │
              │     ├─ detect public/LAN IP  ─────┐                    │
              │     ├─ write .env (secrets)      │  ip + secret       │
              │     ├─ docker compose up -d      │  baked into        │
              │     └─ build agent .exe + .msi ──┘  agent config      │
              └──────────────┬─────────────────────────────────────────┘
                             │  HTTPS :443
                             ▼
              ┌────────────────────────────────────────────────────────┐
              │  ENTERPRISE SERVER  (Docker, one host)                 │
              │                                                        │
              │  caddy  (reverse proxy, TLS)                           │
              │    └─ /            → portal  (web UI, same origin)     │
              │    └─ /ingest/...  → api     (FastAPI ingest endpoint) │
              │    └─ /api/*       → api     (admin/query API)         │
              │                                                        │
              │  api  (FastAPI container)                              │
              │    └─ /ingest  ← agent log batches (Bearer token)      │
              │    └─ /api/agents, /api/events, /api/features          │
              │                                                        │
              │  db   (PostgreSQL 16, named volume, same DB)           │
              └────────────────────────┬────────────────────────────────┘
                                       │ HTTPS POST /ingest (sanitized JSON)
              ┌────────────────────────▼────────────────────────────────┐
              │  CLIENT MACHINES  (Windows, many)                       │
              │                                                        │
              │  IT-Toolkit-Agent.exe  (installed via .msi, silent)     │
              │    ├─ Windows service / scheduled task                  │
              │    ├─ reads endpoint from registry (set at install)     │
              │    ├─ runs EXISTING Scripts/*.ps1 (no modification)     │
              │    ├─ sanitizes output via EXISTING SanitizeEngine      │
              │    ├─ queues locally via EXISTING ToolkitData (sqlite)  │
              │    └─ posts batch → server /ingest                     │
              └────────────────────────────────────────────────────────┘
```

**Single database:** the portal and the ingest API both use the **same
PostgreSQL** instance. No cross-machine DB sync, nothing to migrate later.

---

## 2. How the "no existing change" promise works

The current toolkit is a **local-first** Windows PowerShell kit. The agent does
**not** rewrite anything. Instead it is a thin **orchestration wrapper**:

| Existing piece | New role | Touched? |
| --- | --- | --- |
| `Scripts/*.ps1` | Called **as-is** by the agent (captured output) | ❌ no change |
| `Toolkit-Menu.bat`, `Setup-Wizard.bat` | Unchanged; still run on-demand on the desktop | ❌ no change |
| `Scripts/Modules/SanitizeEngine.psm1` | Reused by the agent to mask PII **before** upload | ❌ reused |
| `Scripts/Modules/ToolkitData.psm1` | Reused by the agent as the **offline queue** | ❌ reused |
| `Scripts/Modules/CredentialManager.psm1` | Optional: stores the per-machine agent token | ❌ reused |
| `Config/config.json` | Untouched; agent has its own `agent.json` | ❌ no change |

Result: the existing repo stays **binary-identical**. The whole Phase-3 layer is
**additive**, so rollback = stop agents + `docker compose down`. No surgical
changes to fight later.

---

## 3. Agent design (Windows, `IT-Toolkit-Agent`)

```
IT-Toolkit-Agent.exe
├─ Agent-Collect.ps1   (the real logic, packaged by ps2exe)
│   1. load agent.json / registry → endpoint + token
│   2. run each configured Scripts/*.ps1 → capture stdout
│   3. ConvertTo-SanitizedText over every string field
│   4. Add-ToolkitDiagnostic into local sqlite queue (offline-safe)
│   5. POST batch to https://<endpoint>/ingest  (Bearer token, retry/backoff)
│   6. on success: Remove-ToolkitData entries that were flushed
└─ install/uninstall via the MSI (Windows service `ITToolkitAgent`)
```

**Endpoint config flow (your "IP automatically goes in the exe" requirement):**

1. Operator runs `deploy.sh` on the server → it detects the machine's LAN/Public
   IP (or reads `SERVER_HOST` from env) and writes `.env` + `agent/agent-config.json`.
2. `build-agent.ps1` reads `agent-config.json`, **bakes the endpoint + token**
   into the packaged exe as defaults.
3. The **MSI** writes the endpoint to `HKLM\SOFTWARE\ITToolkit\Agent`
   (`EndpointUrl`, `ApiToken`) at install time — this is the real deployment
   knob. MSI can be pushed via **Intune / GPO / SCCM / Winget** silently
   (`msiexec /i ITToolkit-Agent.msi /qn`).
4. Optional runtime override: admins can push a new endpoint via registry/GPO
   without reinstalling.

---

## 4. Server design (Docker, one host)

### `docker-compose.yml` services

| Service | Image | Role |
| --- | --- | --- |
| `db` | `postgres:16-alpine` | Single source of truth; named volume `pgdata` |
| `api` | build from `Enterprise/api/Dockerfile` | FastAPI: `/ingest`, `/api/*`, serves portal static |
| `caddy` | `caddy:2-alpine` | TLS reverse proxy, maps `/` → api; auto HTTPS (or IP self-signed) |

### Data model (PostgreSQL — easy to migrate: pure SQL DDL in `schema.sql`)
- `agents` — hostname, os, agent_version, last_seen, ip, registered_at
- `events` — agent_id, kind (inventory/eventlog/network/firewall/diagnostic), payload jsonb, sanitized bool, captured_at
- `feature_configs` — web-editable feature toggles/params (the "modify from portal" requirement)
- `commands` (P5) — agent_id, kind (reboot/wake/run-script), payload jsonb, status lifecycle, result jsonb, audit trail
- `alert_rules` (P6) — name, description, condition jsonb, severity, enabled
- `alerts` (P6) — rule_id, agent_id, severity, message, status (open/acknowledged/resolved), timestamps

### API surface (all Bearer-token protected)
- `POST /ingest` — agent batch upload (bulk, idempotent via `client_msg_id`)
- `GET /api/agents` — list agents + last_seen
- `GET /api/events?agent=&kind=` — query events
- `GET /api/features` — list what the toolkit can run (from a manifest)
- `PUT /api/features/{name}` — toggle/configure from the portal
- `GET /healthz` — liveness for Docker healthcheck
- P5 commands: `GET/POST /api/commands`, agent `GET /api/commands/poll`, `POST /api/commands/{id}/result`
- P6 alerts: `GET /api/alerts?status=&limit=`, `GET /api/alerts/open`, `POST /api/alerts/{id}/ack|resolve`, `GET/PUT /api/alert-rules`; eval loop background task (`ALERT_EVAL_MINUTES`)
- P6 reports: `GET /api/report/fleet` (CSV), `GET /api/report/agent/{id}?format=json|csv`
- P1 setup: `GET /api/setup/status`, `POST /api/setup` (company / admin / SMTP /
  **build mode** + optional `github_repo`/`github_token`), login/session + RBAC
- Rev 3 GitHub remote build: `GET /api/build/status` (latest `ci.yml` run +
  auto-download newest MSI), `POST /api/build/validate`, `POST /api/build/trigger`
  (`workflow_dispatch`; empty token = use stored PAT)

### Web portal (served from the API container, same origin)
Single-page HTML+JS (no build step): session login (P2) → **Agents**, **Fleet**,
**Events**, **Commands** (P5), **Alerts** (P6, with open-alert badge),
**Reports** (P6), **Features** (edit toggles), **Users** (admin), **Agent Setup**.
Because it shares the API origin, CORS is a non-issue and it's trivially redeployable.

---

## 5. Deployment (the "easy setup" story)

```bash
# on any machine with Docker (macOS dev, then the intranet server):
cd Enterprise/deploy
./deploy.sh                 # LAN/intranet mode (default) — auto-detects LAN IP
./deploy.sh --regen         # new machine/network → regenerate .env with fresh IP
./deploy.sh --public        # internet clients (public IP) instead of LAN
# on a Windows Server the same bring-up additionally builds the agent:
.\deploy.ps1                # + code-sign CA, ps2exe exe + WiX msi, sign, publish
.\deploy.ps1 -SkipBuild     # server only (bring up without building the agent)
# then build agent on Windows (or CI, or trigger it from the portal):
./Enterprise/agent/build/build-agent.ps1    # → .exe
./Enterprise/agent/wix/build-msi.ps1        # → .msi
# push the MSI to Intune/GPO/SCCM; the LAN endpoint is already baked in.
```

**Intranet-first:** the server advertises its **local network IP**
(e.g. `http://192.168.1.50`), which is exactly what LAN clients reach. No
public exposure, no DNS, no internet required. `SERVER_HOST` in `.env` can pin
a fixed address/domain instead. Moving to a real server later = re-run
`deploy.sh --regen` — the whole stack (incl. the baked agent endpoint)
re-points automatically.

`deploy.sh` is idempotent: re-running after a change only recreates changed
containers; the data volume persists. If secrets are regenerated while an old
`pgdata` volume still exists, it aborts with a clear reset command instead of
silently breaking the DB.

**Agent build paths (pick one at setup-wizard time, stored as `BUILD_MODE`):**

| Mode | How the MSI gets produced | Where |
| --- | --- | --- |
| `local_windows` | `deploy.ps1` auto-generates a code-signing CA, builds exe (ps2exe) + MSI (WiX) on the server, signs, publishes to `agent_artifacts` | Windows Server |
| `github` | portal fires `workflow_dispatch` on `ci.yml` (repo + PAT from setup); `GET /api/build/status` polls and auto-downloads the newest signed MSI artifact | Linux (or any) server |
| `manual` | you build (`build-agent.ps1` / `build-msi.ps1`) or source the MSI and copy it into the `agent_artifacts` volume | anywhere |

---

## 6. What this blueprint covers (your "missed items")

| Previously missing | Now addressed |
| --- | --- |
| No `.exe` / `.msi` packaging | ps2exe agent + WiX MSI with silent install |
| No endpoint address in client | Auto-IP detection at deploy + baked/registry config |
| No log forwarding | `/ingest` + local sqlite queue + retry |
| No server | FastAPI container behind Caddy (TLS) |
| No web UI / config editing | Portal: agents, events, feature config editor |
| No single DB | Shared PostgreSQL, one named volume |
| No enterprise deployment path | MSI via Intune/GPO/SCCM, silent `/qn` |
| Sanitization before egress | Reuses existing `SanitizeEngine` |
| Offline clients | Local queue via existing `ToolkitData`, flush on reconnect |

---

## 7. Security (enterprise-grade baseline)
- HTTPS only via Caddy (real cert with a domain; self-signed on bare IP with a note)
- API auth: per-deployment `API_TOKEN` — **auto-generated** by `deploy.sh`
  (`openssl rand`); the API also self-generates + persists a token if one is
  ever missing (printed once in the api container logs)
- Optional per-agent tokens via `CredentialManager` (future flag)
- SanitizeEngine applied **client-side** before upload (PII never leaves machine raw)
- Postgres not exposed to the network; only the api container reaches it
- `.env` git-ignored; secrets never committed

---

## 8. Migration & future scale path
- **Postgres** is the interchange format → migrate to managed RDS/Cloud SQL by
  swapping the `DATABASE_URL` env var (container unchanged).
- Agent protocol is a versioned JSON batch → add a second agent type later
  (Linux/Node) without touching the API contract.
- Caddy handles TLS; moving behind a corporate LB/ingress only requires DNS
  pointing at it. `docker compose` can be ported to Swarm/K8s later because all
  state is in the volume + `.env`.

---

## 9. Honest gaps (not code yet)
- **Team accounts work** (RBAC: admin/operation/monitoring enforced in API +
  portal), the **company agent bundle downloads work**, and the **support-
  engineer features are all shipped**: commands (P5), **alerts + reports (P6)** —
  role-governed (admin/operation; monitoring read-only). Remaining:
  **SMTP email alerts** (optional flag) and mTLS client certs (flag).
- **MSI delivery is live** — three paths (Rev 3): CI (`agent-build`, Windows)
  artifacts auto-pulled by `/api/build/status` (**github** mode), built + signed
  on a Windows Server by `deploy.ps1` (**local_windows** mode), or copied
  manually (`docker compose cp IT-Toolkit-Agent.msi api:/artifacts/`). The CI
  job requires the repo secrets `SERVER_ENDPOINT` + `API_TOKEN`.
- **ps2exe** is a community tool; Authenticode signing of the exe is still a
  manual Windows step (as before) unless using `deploy.ps1`, which signs with an
  auto-generated internal code-signing CA.
- Live WinRM/agent round-trip still requires a real Windows client (CI can't
  run the interactive pieces) — same boundary as the existing smoke-run.
