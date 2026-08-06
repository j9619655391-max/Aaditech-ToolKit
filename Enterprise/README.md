# IT-Toolkit Enterprise (Phase 3)

Centralized **agent → server → web portal** stack that scales the existing
IT-Toolkit **without modifying any existing script or module**. Everything here
is additive and lives under `Enterprise/`.

```
Windows clients                        Server (Docker, one host)
┌─────────────────────┐                ┌────────────────────────────────┐
│ IT-Toolkit-Agent.exe│  HTTPS POST    │ caddy (TLS)  →  api (FastAPI)  │
│ (installed via .msi)│ ─────────────► │                  └──→ portal    │
│ wraps existing      │  sanitized     │                    db (Postgres)│
│ Scripts/*.ps1 (raw) │  JSON batches  │                (one shared DB)  │
└─────────────────────┘                └────────────────────────────────┘
```

## Quick start (server)

```bash
cd Enterprise/deploy
./deploy.sh
```

That one command:
- detects this machine's **IP** (public → LAN),
- generates `.env` with random secrets,
- **writes `agent/agent-config.json` with the endpoint + token baked in**
  (this is what flows into the exe/msi),
- starts `db + api + caddy` via `docker compose`,
- prints the portal URL + token.

## Quick start (agent + MSI) — run on Windows or a CI runner

```powershell
.\Enterprise\agent\build\build-agent.ps1     # → build/out/IT-Toolkit-Agent.exe
.\Enterprise\agent\wix\build-msi.ps1         # → build/out/IT-Toolkit-Agent.msi
```

Push the MSI silently to fleets: `msiexec /i IT-Toolkit-Agent.msi /qn`
(via **Intune / GPO / SCCM**). The endpoint + token ship inside `agent.json`
and are written to `HKLM\SOFTWARE\ITToolkit\Agent` (GPO-overridable).

## What's in here

| Path | Purpose |
| --- | --- |
| `ARCHITECTURE.md` | Full blueprint (zero-change guarantee, data model, security, migration) |
| `docker-compose.yml` | One-host stack: `db` (Postgres) + `api` + `caddy` |
| `api/` | FastAPI: `POST /ingest`, `/api/agents`, `/api/events`, `/api/features`, `/healthz`; serves portal |
| `portal/` | Single-page admin UI (Agents / Events / Feature toggles / config editor) |
| `agent/` | `Agent-Collect.ps1` (worker), ps2exe + WiX MSI packaging |
| `deploy/deploy.sh` | One-command bring-up with auto-IP detection |
| `.env.example` | Template — copy to `.env` (never committed) |

## Verified

The full stack was smoke-tested locally with Docker:
ingest (with idempotent dedupe), auth (401 on bad token), agents/events
queries, feature enable/disable, and the portal all pass. `deploy.sh` runs
end-to-end (exit 0) and regenerates the baked agent config on IP change.

## Honest boundaries

- Portal has **one shared API token** (no per-user login yet).
- MSI/exe build must run on **Windows** — a GitHub Actions job is provided
  (`.github/workflows/ci.yml`).
- Agent exe is signed manually (Authenticode) — same boundary as the existing
  smoke-run doc.
