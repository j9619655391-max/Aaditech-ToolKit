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

### One-click company install (post-setup)

After the setup wizard, the portal's **Agent Setup** tab generates the company
package: `agent.json` (endpoint + token + company + feature manifest),
`ca.crt`, and a live **install-agent.cmd**. Put all three next to the MSI and
run `install-agent.cmd` (or push the MSI via **Intune / GPO / SCCM** and drop
`agent.json` + `ca.crt` into `C:\ProgramData\ITToolkit-Agent\`).

The server serves these from `GET /api/agent-bundle` (+ `/api/agent/agent.json`,
`/api/agent/install.cmd`, `/api/ca.crt`, `/api/agent-msi`) — admin/operation
only. The MSI is built on CI (`agent-build` job, WiX v5) and copied into the
`agent_artifacts` volume; re-upload after each new CI build with:

```bash
docker compose cp IT-Toolkit-Agent.msi api:/artifacts/
```

## What's in here

| Path | Purpose |
| --- | --- |
| `ARCHITECTURE.md` | Full blueprint (zero-change guarantee, data model, security, migration) |
| `ROADMAP.md` | **Next-steps plan**: CI agent delivery, first-time setup wizard, support-engineer features |
| `docker-compose.yml` | One-host stack: `db` (Postgres) + `api` + `caddy` (+ `agent_artifacts` volume for the MSI) |
| `api/` | FastAPI: `POST /ingest`, `/api/agents`, `/api/events`, `/api/features`, setup + login/session + RBAC (`/api/users`), agent bundle (`/api/agent-bundle`, downloads), alerts + reports (P6), `/healthz`; serves portal |
| `portal/` | Setup wizard + login + single-page admin UI (Agents / Fleet / Events / Commands / Alerts / Reports / Feature toggles / Users / Agent Setup) |
| `agent/` | `Agent-Collect.ps1` (worker — collects, parses structured JSON, flushes, polls + executes commands), ps2exe + WiX MSI packaging |
| `agent/collectors/` | 7 support-engineer collectors (hardware, software, diskhealth, health, bitlocker, updatecompliance, licenses) |

## Remote commands (P5)

Admins/operators issue commands from the **Commands** page; agents poll each
cycle and post results back (audited history):

- `reboot` — optional delay in seconds.
- `wake` — Wake-on-LAN magic packet (MAC + optional target IP).
- `run-script` — only when `COMMANDS_RUN_SCRIPT_ALLOWED=true` in `.env` and the
  script path is in `RUN_SCRIPT_ALLOWLIST=Scripts/A.ps1,Scripts/B.ps1`.
- `monitoring` role can view history but not issue.
| `deploy/deploy.sh` | One-command bring-up with auto-IP detection |
| `.env.example` | Template — copy to `.env` (never committed) |

## Alerts + reports (P6)

Seeded rules evaluate on a background loop (`ALERT_EVAL_MINUTES` env, default
1 min) and open an alert when a condition fires, **auto-resolving** when it
clears: agent offline (>15 min), disk < 10% free, SMART predicted failure,
battery < 20%, critical service stopped, reboot pending > 7 days uptime.

- **Alerts page** (portal): status filter (open/acknowledged/resolved/all),
  ack + resolve buttons (admin/operation), and an **open-alert badge** in the
  nav (polls every 30s). Admins can toggle/enable/disable rules and edit
  severity + condition JSON.
- **Reports page** (portal): **fleet CSV** (one row per agent, latest
  hardware/health/update snapshot) and **per-agent** JSON/CSV exports.
- API: `GET /api/alerts`, `GET /api/alerts/open`, `POST /api/alerts/{id}/ack`,
  `POST /api/alerts/{id}/resolve`, `GET/PUT /api/alert-rules`,
  `GET /api/report/fleet`, `GET /api/report/agent/{id}?format=json|csv`.
- SMTP email delivery is an optional follow-up (portal-first today).

## Verified

The full stack was smoke-tested locally with Docker:
ingest (with idempotent dedupe), auth (401 on bad token), agents/events
queries, feature enable/disable, and the portal all pass. `deploy.sh` runs
end-to-end (exit 0) and regenerates the baked agent config on IP change.

## Honest boundaries

- Portal sessions + RBAC (admin / operation / monitoring) are live; **alerts +
  reports** shipped in P6 (portal-first; SMTP email delivery optional later).
- **MSI is live** (P0): built by CI on `windows-latest` and uploaded to the
  `agent_artifacts` volume — `GET /api/agent-msi` returns a valid installer.
  The `agent-build` job needs the repo secrets `SERVER_ENDPOINT` + `API_TOKEN`
  to bake the endpoint/token; otherwise it stages placeholders and refuses.
- MSI/exe build runs on **Windows** (GitHub Actions `windows-latest`).
- `wake` sends the WOL magic packet from the target's own network via the agent
  (works when the machine has a peer online); for true remote power-on you still
  need the BIOS/WoL setting enabled on the target.
- Agent exe is signed manually (Authenticode) — same boundary as the existing
  smoke-run doc.
- Collectors were verified for **syntax + JSON output** locally (pwsh); full
  Windows-only data (CIM/SMART/BitLocker/WU) needs the Windows smoke run.
