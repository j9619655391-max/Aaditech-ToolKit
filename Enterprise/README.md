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

> **AI-agent / automated deploys:** run the prerequisite scanner first, then follow
> `Documentation/Deployment-AI-Runbook.md` — it decides the path (Windows local
> build, Linux+GitHub, or agent-only box) from the scan verdict.
> ```powershell
> pwsh -NoProfile -File ./Enterprise/tests/Check-Deploy-Prereqs.ps1 -ShowTable
> ```

```bash
cd Enterprise/deploy
./deploy.sh          # default = LAN mode (no internet needed)  — macOS / Linux
./deploy.sh --regen  # new machine / network: regenerate .env with fresh IP

# Windows Server (also builds + signs the agent installer locally):
.\deploy.ps1                 # one-command bring-up + local MSI build
.\deploy.ps1 -SkipBuild      # server only (skip the agent build)
.\deploy.ps1 -Regen          # new machine / network
```

That one command:
- detects this machine's **LAN IP** (macOS/Linux prefers en0/en1/eth0, Windows
  prefers the Ethernet/Wi-Fi adapter; VPN interfaces never win) — clients on
  the same intranet use this address,
- **auto-generates** `.env` secrets (API token + Postgres password) — placeholders
  in a hand-copied `.env` are auto-regenerated, never used as-is,
- **writes `agent/agent-config.json` with the LAN endpoint + token baked in**
  (this is what flows into the exe/msi),
- starts `db + api + caddy` via `docker compose`,
- on Windows Server (`deploy.ps1`): additionally auto-generates the
  **code-signing CA**, builds the agent `.exe` (ps2exe) + `.msi` (WiX) **on the
  server itself**, signs them, and publishes the MSI into the `agent_artifacts`
  volume — no CI, no GitHub required,
- prints the portal URL + token.

> **Token safety net:** if the API ever boots with no `API_TOKEN` set, it
> auto-generates a random one, persists it in the `api_data` volume, and prints
> it once in `docker logs enterprise-api-1` (AUTO-GENERATED API TOKEN banner).

### First-time setup (once, in the browser)

Open the printed URL → a **setup wizard** appears (only until configured):

1. Enter **company name**, confirm the **server address**, create the **first
   admin account**, pick a **brand color**, and choose **how the agent
   installer gets built**:
   - **Windows Server — build locally (automatic)** → the server builds + signs
     the MSI itself (see `deploy.ps1`).
   - **GitHub Actions — remote build (Linux server)** → enter a **GitHub repo
     (`owner/repo`)** + a **PAT** (fine-grained, `Actions: Read/Write`); the
     portal triggers `ci.yml` via `workflow_dispatch` and downloads the signed
     MSI artifact back automatically.
   - **Manual** → you build/upload the MSI yourself.
2. The server then generates everything locally on that machine:
   - a **local CA + server certificate** (persisted in `api_data` under
     `certs/`; `ca.key` stays server-only),
   - an **authentication token**,
   - a **company-scoped agent template** (endpoint + token + CA trust).
3. You land in the branded portal, logged in as admin. On the **Users** page
   (admin-only) create team accounts with roles — **operation** (view + act,
   no user management) or **monitoring** (read-only). The **Agent Setup** tab
   shows the server host, agent token, CA download, and the **build panel**
   (build mode, trigger-a-GitHub-build button, MSI download). Monitoring users
   see dashboards but no config controls.

Public-IP deployment (internet clients): `./deploy.sh --public`, or pin a
fixed address/domain in `.env` (`SERVER_HOST=192.168.1.50` or `SERVER_HOST=it.example.com`).
Moving the server to a different machine later = just re-run `./deploy.sh --regen`.

### Remote GitHub build (Linux server mode)

The API talks to GitHub entirely from the server — the portal never needs your
PAT again after setup (it's stored in the `settings` table and used as the
fallback for `/api/build/*`):

- `GET /api/build/status` — build mode, stored repo, MSI availability, and the
  latest `ci.yml` run (push **or** `workflow_dispatch`); auto-downloads the MSI
  when the newest successful artifact is newer than the one on disk.
- `POST /api/build/validate` — check the repo is reachable + the PAT has access
  (`actions_write` = repo `admin`/`maintain`).
- `POST /api/build/trigger` — fire `workflow_dispatch` on `main` (empty token in
  the body falls back to the stored PAT).
- The download handles GitHub's signed-CDN redirect correctly (no auth header
  forwarded to the CDN), and the MSI is served to agents via
  `GET /api/agent-msi`.

## Quick start (agent + MSI) — build on Windows or a CI runner

```powershell
.\Enterprise\agent\build\build-agent.ps1     # → build/out/IT-Toolkit-Agent.exe
.\Enterprise\agent\wix\build-msi.ps1         # → build/out/IT-Toolkit-Agent-<version>.msi
```

### One-click company install (post-setup)

After the setup wizard, the portal's **Agent Setup** tab generates the company
package: `agent.json` (endpoint + token + company + feature manifest),
`ca.crt`, and a live **install-agent.cmd**. Put all three next to the MSI and
run `install-agent.cmd` (or push the MSI via **Intune / GPO / SCCM** and drop
`agent.json` + `ca.crt` into `C:\ProgramData\ITToolkit-Agent\`).

The server serves these from `GET /api/agent-bundle` (+ `/api/agent/agent.json`,
`/api/agent/install.cmd`, `/api/ca.crt`, `/api/agent-msi`) — admin/operation
only. Where the MSI comes from depends on your setup-wizard choice:

- **local_windows** (`deploy.ps1`) → built + signed on the server, auto-published
  to the `agent_artifacts` volume.
- **github** → built by the `agent-build` CI job on `windows-latest` (WiX v5),
  pulled back by `/api/build/status` into the `agent_artifacts` volume.
- **manual** → copy your own MSI into the volume with:

```bash
# portal serves the versioned download name; store the MSI under the canonical name
docker compose cp IT-Toolkit-Agent-<version>.msi api:/artifacts/IT-Toolkit-Agent.msi
```

## What's in here

| Path | Purpose |
| --- | --- |
| `ARCHITECTURE.md` | Full blueprint (zero-change guarantee, data model, security, migration) |
| `ROADMAP.md` | **Next-steps plan**: CI agent delivery, first-time setup wizard, support-engineer features |
| `docker-compose.yml` | One-host stack: `db` (Postgres) + `api` + `caddy` (+ `agent_artifacts` volume for the MSI) |
| `api/` | FastAPI: `POST /ingest`, `/api/agents`, `/api/events`, `/api/features`, setup + login/session + RBAC (`/api/users`), agent bundle (`/api/agent-bundle`, downloads), GitHub remote build (`/api/build/*`), alerts + reports + **webhooks (F1)** + **software/license (F3)** + **companies/tenants (F4)** (P6), `/healthz`; serves portal |
| `deploy/deploy.sh` | One-command bring-up (macOS/Linux): auto-IP detection + secrets + mTLS agent config |
| `deploy/deploy.ps1` | One-command bring-up (Windows Server): same as `deploy.sh` **plus** local code-sign CA + ps2exe/WiX MSI build + sign + publish (`BUILD_MODE=local_windows`) |
| `portal/` | Setup wizard + login + single-page admin UI (Agents / Fleet / Events / Commands / Alerts / **Software** / Reports / Feature toggles / Users + **Companies manager** / Agent Setup with build panel) |
| `agent/` | `Agent-Collect.ps1` (worker — collects, parses structured JSON, flushes, polls + executes commands; **auto-installs the server CA into `LocalMachine\Root`**), ps2exe + WiX MSI packaging |
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
- **SMTP email** (P6.1): when `SMTP_HOST` + `SMTP_TO` are set in `.env` (or via
  the setup wizard), the eval loop emails a digest whenever it opens new
  alerts. Verify delivery from the portal with the admin
  `POST /api/alerts/test-email` check.
- **Webhook delivery** (F1): the same digest can be POSTed to a **generic
  JSON**, **Slack** (blocks), or **Microsoft Teams** (MessageCard) webhook —
  independently of, or alongside, SMTP. Configure on the portal Alerts page
  (admin) via `GET/PUT /api/alerts/webhook` and test with
  `POST /api/alerts/test-webhook`. Env fallbacks: `WEBHOOK_ENABLED`,
  `WEBHOOK_URL`, `WEBHOOK_TYPE` (generic | slack | teams).
- **Software inventory** (F3): the **Software** portal tab searches installed
  apps fleet-wide by name/publisher (case-insensitive) and exports CSV:
  `GET /api/software/search?q=`, `GET /api/software/export`. Admins get a
  **license compliance** view (Windows/Office keys as last-5 only):
  `GET /api/license/compliance`, `GET /api/license/export`.
- **Multi-tenant** (F4): setup creates a `companies` tenant; the admin (and
  every user created afterwards) belongs to it, and new agents enroll into the
  current default company. Agent/event/alert/command/user/report queries are
  scoped to the signed-in user's company. Admins manage tenants from the Users
  tab (`GET/POST /api/companies`, `GET/POST /api/settings/default-company`);
  `GET /api/bootstrap` returns the caller's tenant + the company directory.
- **Reports page** (portal): **fleet CSV** (one row per agent, latest
  hardware/health/update snapshot) and **per-agent** JSON/CSV exports.
- API: `GET /api/alerts`, `GET /api/alerts/open`, `POST /api/alerts/{id}/ack`,
  `POST /api/alerts/{id}/resolve`, `GET/PUT /api/alert-rules`,
  `GET /api/report/fleet`, `GET /api/report/agent/{id}?format=json|csv`,
  `POST /api/alerts/test-email`, `GET/PUT /api/alerts/webhook`,
  `POST /api/alerts/test-webhook`, `GET /api/software/search`,
  `GET /api/software/export`, `GET /api/license/compliance`,
  `GET /api/license/export`, `GET/POST /api/companies`,
  `GET/POST /api/settings/default-company` (admins).

## Verified

The full stack was smoke-tested locally with Docker:
ingest (with idempotent dedupe), auth (401 on bad token), agents/events
queries, feature enable/disable, and the portal all pass. `deploy.sh` runs
end-to-end (exit 0) and regenerates the baked agent config on IP change.
The SaaS auto-setup flow (setup wizard → GitHub remote build → MSI download +
serve) was verified live end-to-end, and CI stayed green after both feature
commits.

## Honest boundaries

- Portal sessions + RBAC (admin / operation / monitoring) are live; **alerts +
  reports** shipped in P6, plus webhook delivery (F1), software/license
  compliance (F3) and tenant scoping (F4) on top.
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
- **SaaS auto-setup (Rev 3)**: the setup wizard + `deploy.sh`/`deploy.ps1` +
  GitHub remote-build path are **verified live end-to-end** (setup → trigger →
  poll → auto-download MSI → serve via `/api/agent-msi`). The `deploy.ps1`
  local-Windows build+sign path is written and PowerShell-parse-verified but
  still needs a real Windows Server smoke run.
