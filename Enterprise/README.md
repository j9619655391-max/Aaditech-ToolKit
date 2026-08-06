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

## Quick start (server) — intranet / LAN first

```bash
cd Enterprise/deploy
./deploy.sh          # default = LAN mode (no internet needed)
./deploy.sh --regen  # new machine / network: regenerate .env with fresh IP
```

That one command:
- detects this machine's **LAN IP** (macOS + Linux, prefers en0/en1/eth0 so
  VPN interfaces don't win) — clients on the same intranet use this address,
- **auto-generates** `.env` secrets (API token + Postgres password) — placeholders
  in a hand-copied `.env` are auto-regenerated, never used as-is,
- **writes `agent/agent-config.json` with the LAN endpoint + token baked in**
  (this is what flows into the exe/msi),
- starts `db + api + caddy` via `docker compose`,
- prints the portal URL + token.

> **Token safety net:** if the API ever boots with no `API_TOKEN` set, it
> auto-generates a random one, persists it in the `api_data` volume, and prints
> it once in `docker logs enterprise-api-1` (AUTO-GENERATED API TOKEN banner).

### First-time setup (once, in the browser)

Open the printed URL → a **setup wizard** appears (only until configured):

1. Enter **company name**, confirm the **server address**, create the **first
   admin account**, pick a **brand color**.
2. The server then generates everything locally on that machine:
   - a **local CA + server certificate** (persisted in `api_data` under
     `certs/`; `ca.key` stays server-only),
   - an **authentication token**,
   - a **company-scoped agent template** (endpoint + token + CA trust).
3. You land in the branded portal, logged in as admin. On the **Users** page
   (admin-only) create team accounts with roles — **operation** (view + act,
   no user management) or **monitoring** (read-only). The **Agent Setup** tab
   shows the server host, agent token and CA download you'll bake into the
   company MSI in P3. Monitoring users see dashboards but no config controls.

Public-IP deployment (internet clients): `./deploy.sh --public`, or pin a
fixed address/domain in `.env` (`SERVER_HOST=192.168.1.50` or `SERVER_HOST=it.example.com`).
Moving the server to a different machine later = just re-run `./deploy.sh --regen`.

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
| `ROADMAP.md` | **Next-steps plan**: CI agent delivery, first-time setup wizard, support-engineer features |
| `docker-compose.yml` | One-host stack: `db` (Postgres) + `api` + `caddy` |
| `api/` | FastAPI: `POST /ingest`, `/api/agents`, `/api/events`, `/api/features`, setup + login/session + RBAC (`/api/users`), `/api/ca.crt`, `/api/agent-template`, `/healthz`; serves portal |
| `portal/` | Setup wizard + login + single-page admin UI (Agents / Events / Feature toggles / Users / Agent Setup) |
| `agent/` | `Agent-Collect.ps1` (worker), ps2exe + WiX MSI packaging |
| `deploy/deploy.sh` | One-command bring-up with auto-IP detection |
| `.env.example` | Template — copy to `.env` (never committed) |

## Verified

The full stack was smoke-tested locally with Docker:
ingest (with idempotent dedupe), auth (401 on bad token), agents/events
queries, feature enable/disable, and the portal all pass. `deploy.sh` runs
end-to-end (exit 0) and regenerates the baked agent config on IP change.

## Honest boundaries

- Portal sessions + RBAC (admin / operation / monitoring) are live; the
  support-engineer features that the roles will govern (commands, alerts,
  reports) land in P5/P6.
- MSI/exe build must run on **Windows** — a GitHub Actions job is provided
  (`.github/workflows/ci.yml`).
- Agent exe is signed manually (Authenticode) — same boundary as the existing
  smoke-run doc.
